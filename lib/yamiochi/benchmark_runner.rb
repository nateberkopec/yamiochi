# frozen_string_literal: true

require "socket"

require_relative "server"

module Yamiochi
  class BenchmarkRunner
    DEFAULT_REQUEST_COUNT = 200
    DEFAULT_WARMUP_REQUESTS = 20
    DEFAULT_HOST = "127.0.0.1"
    DEFAULT_RESPONSE_BODY = "ok"
    REQUEST_TEXT = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".b.freeze
    WAIT_TIMEOUT = 5

    def initialize(request_count: DEFAULT_REQUEST_COUNT, warmup_requests: DEFAULT_WARMUP_REQUESTS,
      host: DEFAULT_HOST, port: 0, out: $stdout, err: $stderr, server_class: Yamiochi::Server,
      socket_class: TCPSocket, app: nil)
      @request_count = normalize_count(request_count, name: "request_count", minimum: 1)
      @warmup_requests = normalize_count(warmup_requests, name: "warmup_requests", minimum: 0)
      @host = host
      @port = Integer(port)
      @out = out
      @err = err
      @server_class = server_class
      @socket_class = socket_class
      @app = app || default_app
    end

    def run
      with_running_server do |bound_port, thread, server|
        warm_up(bound_port)
        finish_run(thread, server, measure_requests_per_second(bound_port))
      end
    end

    private

    attr_reader :request_count, :warmup_requests, :host, :port, :out, :err, :server_class, :socket_class, :app

    def normalize_count(value, name:, minimum:)
      normalized_value = Integer(value)
      return normalized_value if normalized_value >= minimum

      raise ArgumentError, "#{name} must be >= #{minimum}"
    end

    def default_app
      body = DEFAULT_RESPONSE_BODY
      ->(_env) { [200, {"Content-Length" => body.bytesize.to_s, "Content-Type" => "text/plain"}, [body]] }
    end

    def with_running_server
      server = build_server
      thread = start_server_thread(server)

      yield wait_for_bound_port(server, thread), thread, server
    ensure
      cleanup_thread(thread)
    end

    def build_server
      server_class.new(app:, host:, port:, out:, err:, max_requests: total_request_count)
    end

    def total_request_count
      request_count + warmup_requests
    end

    def start_server_thread(server)
      Thread.new do
        Thread.current.report_on_exception = false
        server.run
      end
    end

    def warm_up(bound_port)
      warmup_requests.times do
        issue_request(bound_port)
      end
    end

    def measure_requests_per_second(bound_port)
      started_at = monotonic_time
      request_count.times do
        issue_request(bound_port)
      end
      elapsed = [monotonic_time - started_at, Float::EPSILON].max
      request_count / elapsed
    end

    def finish_run(thread, server, requests_per_second)
      wait_for_server_exit(thread, server)
      out.puts(format("%.1f req/s", requests_per_second))
      requests_per_second
    end

    def cleanup_thread(thread)
      return unless thread&.alive?

      thread.kill
      thread.join(1)
    end

    def wait_for_bound_port(server, thread, timeout: WAIT_TIMEOUT)
      deadline = monotonic_time + timeout

      loop do
        return server.bound_port if server.bound_port

        unless thread.alive?
          thread.value
          raise "benchmark server exited before binding a port"
        end

        raise "timed out waiting for benchmark server to bind a port" if monotonic_time >= deadline

        IO.select(nil, nil, nil, 0.01)
      end
    end

    def issue_request(bound_port)
      response_text = socket_class.open(host, bound_port) do |client|
        client.write(REQUEST_TEXT)
        client.close_write
        client.read
      end

      return if response_text.start_with?("HTTP/1.1 200 OK\r\n")

      status_line = response_text.lines.first.to_s.chomp
      raise "unexpected benchmark response: #{status_line}"
    end

    def wait_for_server_exit(thread, server, timeout: WAIT_TIMEOUT)
      raise "benchmark server did not exit cleanly" unless thread.join(timeout)
      raise "benchmark server returned an unexpected value" unless thread.value.equal?(server)
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
