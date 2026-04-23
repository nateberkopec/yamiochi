# frozen_string_literal: true

require "socket"
require "stringio"
require "tmpdir"

require_relative "../test_helper"

class YamiochiServerTest < Minitest::Test
  def test_initialization_normalizes_rackup_path
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents("ok"))
      relative_path = File.join(dir, ".", "config.ru")

      server = Yamiochi::Server.new(rackup_path: relative_path, out: StringIO.new, err: StringIO.new)

      assert_equal File.expand_path(config_ru), server.rackup_path
    end
  end

  def test_run_raises_when_rackup_file_does_not_call_run
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, "lambda { |_env| [200, {}, ['ok']] }\n")

      server = Yamiochi::Server.new(rackup_path: config_ru, out: StringIO.new, err: StringIO.new)

      error = assert_raises(ArgumentError) { server.run }

      assert_match(/did not call run/, error.message)
      assert_match(/#{Regexp.escape(config_ru)}/, error.message)
    end
  end

  def test_run_serves_one_http_response_and_exits
    response_text, server, thread, bound_port = run_server_request(
      rackup_source: rackup_contents("hello world"),
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal bound_port, server.bound_port
    assert_operator server.bound_port, :>, 0

    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "hello world", response_body(response_text)

    headers = response_headers(response_text)
    assert_equal "Yamiochi", headers.fetch("Server")
    assert_equal "close", headers.fetch("Connection")
    assert_equal "11", headers.fetch("Content-Length")
    assert headers.key?("Date"), "Expected response to include a Date header"
  end

  def test_run_serves_a_directly_supplied_rack_app
    app = ->(_env) { [200, {}, ["direct app"]] }

    response_text, server, thread, bound_port = run_server_request(
      app: app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_nil server.rackup_path
    assert_equal bound_port, server.bound_port
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "direct app", response_body(response_text)
  end

  def test_initialize_requires_exactly_one_app_source
    error = assert_raises(ArgumentError) do
      Yamiochi::Server.new(out: StringIO.new, err: StringIO.new)
    end

    assert_equal "Provide exactly one of rackup_path or app", error.message

    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents("ok"))

      error = assert_raises(ArgumentError) do
        Yamiochi::Server.new(
          rackup_path: config_ru,
          app: ->(_env) { [200, {}, ["ok"]] },
          out: StringIO.new,
          err: StringIO.new
        )
      end

      assert_equal "Provide exactly one of rackup_path or app", error.message
    end
  end

  def test_run_passes_request_path_and_query_string_to_rack_app
    rackup_source = <<~'RUBY'
      run ->(env) { [200, {}, ["#{env.fetch("PATH_INFO")}?#{env.fetch("QUERY_STRING")}"]] }
    RUBY

    response_text, server, thread, _bound_port = run_server_request(
      rackup_source: rackup_source,
      request_text: basic_request("/greetings/from/yamiochi?name=test")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "/greetings/from/yamiochi?name=test", response_body(response_text)
  end

  def test_run_returns_bad_request_for_http_1_0_requests
    response_text = assert_bad_request("GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")

    assert_equal "", response_body(response_text)
  end

  def test_run_returns_bad_request_when_host_header_is_missing
    assert_bad_request("GET / HTTP/1.1\r\n\r\n")
  end

  def test_run_returns_bad_request_for_duplicate_host_headers
    assert_bad_request("GET / HTTP/1.1\r\nHost: localhost\r\nHost: example.test\r\n\r\n")
  end

  def test_run_returns_bad_request_for_malformed_header_syntax
    assert_bad_request("GET / HTTP/1.1\r\nHost: localhost\r\nBad Header: value\r\n\r\n")
  end

  def test_run_returns_bad_request_for_invalid_or_conflicting_content_length
    [
      "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: nope\r\n\r\n",
      "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n",
      "POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3, 4\r\n\r\n"
    ].each do |request_text|
      assert_bad_request(request_text)
    end
  end

  def test_run_returns_bad_request_when_transfer_encoding_is_present
    assert_bad_request("POST / HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n")
  end

  def test_run_reads_post_body_into_rack_input
    rackup_source = <<~'RUBY'
      run lambda { |env|
        body = env.fetch("rack.input").read
        [200, {}, ["#{env.fetch("CONTENT_LENGTH")}|#{env.fetch("CONTENT_TYPE")}|#{body}"]]
      }
    RUBY

    response_text, server, thread, _bound_port = run_server_request(
      rackup_source: rackup_source,
      request_text: request_with_body("POST", "/submit", "hello world", "Content-Type" => "text/plain")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "11|text/plain|hello world", response_body(response_text)
  end

  def test_run_rewinds_rack_input_before_app_invocation
    rackup_source = <<~'RUBY'
      run lambda { |env|
        input = env.fetch("rack.input")
        [200, {}, ["#{input.pos}:#{input.read}"]]
      }
    RUBY

    response_text, server, thread, _bound_port = run_server_request(
      rackup_source: rackup_source,
      request_text: request_with_body("POST", "/submit", "abc")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "0:abc", response_body(response_text)
  end

  def test_run_preserves_unrecognized_request_methods
    rackup_source = <<~'RUBY'
      run ->(env) { [200, {}, [env.fetch("REQUEST_METHOD")]] }
    RUBY

    response_text, server, thread, _bound_port = run_server_request(
      rackup_source: rackup_source,
      request_text: "BREW /coffee HTTP/1.1\r\nHost: localhost\r\n\r\n"
    )

    assert_server_thread_exits(thread, server)
    assert_equal "BREW", response_body(response_text)
  end

  def test_run_returns_bad_request_for_truncated_request_bodies
    assert_bad_request(request_with_body("POST", "/submit", "hello", "Content-Length" => "11"))
  end

  private

  def rackup_contents(body)
    "run ->(_env) { [200, {}, [#{body.dump}]] }\n"
  end

  def basic_request(target)
    "GET #{target} HTTP/1.1\r\nHost: localhost\r\n\r\n"
  end

  def request_with_body(method, target, body, headers = {})
    body = body.b
    request_headers = { "Host" => "localhost", "Content-Length" => body.bytesize.to_s }.merge(headers)
    header_lines = request_headers.map { |name, value| "#{name}: #{value}" }

    "#{method} #{target} HTTP/1.1\r\n#{header_lines.join("\r\n")}\r\n\r\n#{body}"
  end

  def run_server_request(rackup_source: nil, app: nil, request_text:)
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      server = if rackup_source
        config_ru = File.join(dir, "config.ru")
        File.write(config_ru, rackup_source)

        Yamiochi::Server.new(
          rackup_path: config_ru,
          host: "127.0.0.1",
          port: 0,
          out: StringIO.new,
          err: StringIO.new
        )
      else
        Yamiochi::Server.new(
          app: app,
          host: "127.0.0.1",
          port: 0,
          out: StringIO.new,
          err: StringIO.new
        )
      end

      thread = Thread.new do
        Thread.current.report_on_exception = false
        server.run
      end

      bound_port = wait_for_bound_port(server, thread)
      response_text = request_response("127.0.0.1", bound_port, request_text)

      [response_text, server, thread, bound_port]
    end
  end

  def assert_bad_request(request_text, rackup_source: rackup_contents("ok"))
    response_text, server, thread, _bound_port = run_server_request(rackup_source: rackup_source, request_text: request_text)

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 400 Bad Request", response_status_line(response_text)

    response_text
  end

  def assert_server_thread_exits(thread, server)
    assert thread.join(5), "Expected server thread to exit after handling one client"
    assert_same server, thread.value
  end

  def request_response(host, port, request_text)
    TCPSocket.open(host, port) do |client|
      client.write(request_text)
      client.close_write
      client.read
    end
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
    _head, body = response_text.split("\r\n\r\n", 2)
    body
  end

  def response_head(response_text)
    head, _body = response_text.split("\r\n\r\n", 2)
    head
  end

  def wait_for_bound_port(server, thread, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      return server.bound_port if server.bound_port

      unless thread.alive?
        assert_same server, thread.value
        flunk "Server thread exited before publishing its bound port"
      end

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end

    flunk "Timed out waiting for server to bind a port"
  end
end
