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

    assert thread.join(5), "Expected server thread to exit after handling one client"
    assert_same server, thread.value
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

  def test_run_passes_request_path_and_query_string_to_rack_app
    rackup_source = <<~'RUBY'
      run ->(env) { [200, {}, ["#{env.fetch("PATH_INFO")}?#{env.fetch("QUERY_STRING")}"]] }
    RUBY

    response_text, server, thread, _bound_port = run_server_request(
      rackup_source:,
      request_text: basic_request("/greetings/from/yamiochi?name=test")
    )

    assert thread.join(5), "Expected server thread to exit after handling one client"
    assert_same server, thread.value
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "/greetings/from/yamiochi?name=test", response_body(response_text)
  end

  private

  def rackup_contents(body)
    "run ->(_env) { [200, {}, [#{body.dump}]] }\n"
  end

  def basic_request(target)
    "GET #{target} HTTP/1.1\r\nHost: localhost\r\n\r\n"
  end

  def run_server_request(rackup_source:, request_text:)
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_source)

      server = Yamiochi::Server.new(
        rackup_path: config_ru,
        host: "127.0.0.1",
        port: 0,
        out: StringIO.new,
        err: StringIO.new
      )

      thread = Thread.new do
        Thread.current.report_on_exception = false
        server.run
      end

      bound_port = wait_for_bound_port(server, thread)
      response_text = request_response("127.0.0.1", bound_port, request_text)

      [response_text, server, thread, bound_port]
    end
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
