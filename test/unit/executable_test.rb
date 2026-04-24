# frozen_string_literal: true

require "open3"
require "socket"
require "tmpdir"

require_relative "../test_helper"

class YamiochiExecutableTest < Minitest::Test
  def test_executable_serves_one_http_response_and_exits_successfully_with_explicit_bind
    Dir.mktmpdir("yamiochi-exe-test") do |dir|
      body_text = "hello from exe"
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents(body_text))

      with_available_tcp_port do |port|
        bind_uri = "tcp://127.0.0.1:#{port}"
        stdout_text = nil
        stderr_text = nil
        status = nil
        response_text = nil

        Open3.popen3(executable_path, "-b", bind_uri, config_ru, chdir: repo_root) do |stdin, stdout, stderr, wait_thr|
          stdin.close

          begin
            response_text = connect_when_ready("127.0.0.1", port, wait_thr) do |client|
              client.write(basic_request("/"))
              client.close_write
              client.read
            end

            status = wait_for_exit(wait_thr)
          ensure
            terminate_process(wait_thr) unless status
            stdout_text = stdout.read
            stderr_text = stderr.read
          end
        end

        assert status.success?, "Expected executable to exit successfully, stdout: #{stdout_text.inspect}, stderr: #{stderr_text.inspect}"
        assert_empty stdout_text
        assert_empty stderr_text
        assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
        assert_equal body_text, response_body(response_text)

        headers = response_headers(response_text)
        assert_equal "Yamiochi", headers.fetch("Server")
        assert_equal "close", headers.fetch("Connection")
        assert_equal body_text.bytesize.to_s, headers.fetch("Content-Length")
        refute headers.key?("Transfer-Encoding")
        assert headers.key?("Date"), "Expected response to include a Date header"
      end
    end
  end

  private

  def rackup_contents(body)
    "run ->(_env) { [200, {}, [#{body.dump}]] }\n"
  end

  def basic_request(target)
    "GET #{target} HTTP/1.1\r\nHost: localhost\r\n\r\n"
  end

  def response_status_line(response_text)
    response_head(response_text).lines.first.chomp
  end

  def response_headers(response_text)
    response_head(response_text).lines.drop(1).each_with_object({}) do |line, headers|
      name, value = line.chomp.split(": ", 2)
      headers[name] = value
    end
  end

  def response_body(response_text)
    headers = response_headers(response_text)
    body = wire_response_body(response_text)
    return decode_chunked_body(body) if headers["Transfer-Encoding"] == "chunked"

    body
  end

  def wire_response_body(response_text)
    _head, body = response_text.split("\r\n\r\n", 2)
    body.to_s
  end

  def decode_chunked_body(body)
    remaining = body.to_s.b
    decoded = +"".b

    loop do
      line_end = remaining.index("\r\n")
      raise "Malformed chunked body: missing size delimiter" unless line_end

      chunk_size = Integer(remaining.byteslice(0, line_end), 16)
      remaining = remaining.byteslice(line_end + 2, remaining.bytesize).to_s
      break if chunk_size.zero?

      decoded << remaining.byteslice(0, chunk_size)
      remaining = remaining.byteslice(chunk_size + 2, remaining.bytesize).to_s
    end

    decoded
  end

  def response_head(response_text)
    head, _body = response_text.split("\r\n\r\n", 2)
    head
  end

  def repo_root
    File.expand_path("../..", __dir__)
  end

  def executable_path
    File.join(repo_root, "exe", "yamiochi")
  end

  def with_available_tcp_port(host = "127.0.0.1")
    probe = TCPServer.new(host, 0)
    port = probe.local_address.ip_port
    probe.close
    yield port
  end

  def connect_when_ready(host, port, wait_thr, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      begin
        return Socket.tcp(host, port, connect_timeout: 0.1) { |client| yield client }
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
        nil
      end

      unless wait_thr.alive?
        flunk "Executable exited before accepting a client connection"
      end

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      IO.select(nil, nil, nil, 0.01)
    end

    flunk "Timed out waiting for executable to accept a client connection"
  end

  def wait_for_exit(wait_thr, timeout: 5)
    return wait_thr.value if wait_thr.join(timeout)

    flunk "Timed out waiting for executable to exit after serving one client"
  end

  def terminate_process(wait_thr)
    return unless wait_thr.alive?

    Process.kill("TERM", wait_thr.pid)
    wait_thr.join(5)
  rescue Errno::ESRCH
    nil
  end
end
