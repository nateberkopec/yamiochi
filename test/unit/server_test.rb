# frozen_string_literal: true

require "socket"
require "json"
require "rack/lint"
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

  def test_run_streams_chunked_responses_when_content_length_is_unknown
    body = rack_body("hello", " world")
    app = ->(_env) { [200, {}, body] }

    response_text, server, thread, bound_port = run_server_request(
      app: app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal bound_port, server.bound_port
    assert_operator server.bound_port, :>, 0

    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "hello world", response_body(response_text)
    assert_equal "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", wire_response_body(response_text)

    headers = response_headers(response_text)
    assert_equal "Yamiochi", headers.fetch("Server")
    assert_equal "close", headers.fetch("Connection")
    refute headers.key?("Content-Length")
    assert_equal "chunked", headers.fetch("Transfer-Encoding")
    assert headers.key?("Date"), "Expected response to include a Date header"
    assert body.closed?, "Expected streamed response body to be closed after writing"
  end

  def test_run_uses_content_length_for_array_backed_response_bodies
    body = array_backed_body("hello world")
    app = ->(_env) { [200, {}, body] }

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "hello world", response_body(response_text)
    assert_equal "hello world", wire_response_body(response_text)

    headers = response_headers(response_text)
    assert_equal "Yamiochi", headers.fetch("Server")
    assert_equal "close", headers.fetch("Connection")
    assert_equal "11", headers.fetch("Content-Length")
    refute headers.key?("Transfer-Encoding")
    assert headers.key?("Date"), "Expected response to include a Date header"
    assert_equal 1, body.each_calls, "Expected identity responses to iterate the body once"
    assert body.closed?, "Expected array-backed response body to be closed after writing"
  end

  def test_run_counts_bytes_across_multi_chunk_array_backed_response_bodies
    chunks = ["hi", " ", "💎"]
    body = array_backed_body(*chunks)
    app = ->(_env) { [200, {}, body] }

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal chunks.join.b, response_body(response_text)

    headers = response_headers(response_text)
    assert_equal chunks.join.bytesize.to_s, headers.fetch("Content-Length")
    refute headers.key?("Transfer-Encoding")
    assert_equal 1, body.each_calls, "Expected identity responses to iterate the multi-chunk body once"
    assert body.closed?, "Expected multi-chunk array-backed response body to be closed after writing"
  end

  def test_run_omits_wire_body_for_head_requests_but_preserves_chunked_framing_headers
    body = rack_body("hello", " world")
    app = ->(_env) { [200, {}, body] }

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: basic_request("/", method: "HEAD")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "", wire_response_body(response_text)

    headers = response_headers(response_text)
    assert_equal "Yamiochi", headers.fetch("Server")
    assert_equal "close", headers.fetch("Connection")
    refute headers.key?("Content-Length")
    assert_equal "chunked", headers.fetch("Transfer-Encoding")
    assert headers.key?("Date"), "Expected response to include a Date header"
    assert_equal 0, body.each_calls, "Expected HEAD responses to avoid iterating the body"
    assert body.closed?, "Expected response body to be closed after a HEAD response"
  end

  def test_run_omits_wire_body_for_head_requests_but_preserves_computed_content_length
    body = array_backed_body("hello", " world")
    app = ->(_env) { [200, {}, body] }

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: basic_request("/", method: "HEAD")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "", wire_response_body(response_text)

    headers = response_headers(response_text)
    assert_equal "Yamiochi", headers.fetch("Server")
    assert_equal "close", headers.fetch("Connection")
    assert_equal "11", headers.fetch("Content-Length")
    refute headers.key?("Transfer-Encoding")
    assert headers.key?("Date"), "Expected response to include a Date header"
    assert_equal 0, body.each_calls, "Expected HEAD responses to avoid iterating array-backed bodies"
    assert body.closed?, "Expected array-backed response body to be closed after a HEAD response"
  end

  def test_run_preserves_explicit_content_length_when_present
    body = rack_body("hello", " world")
    app = ->(_env) { [200, {"Content-Length" => "11"}, body] }

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "hello world", response_body(response_text)
    assert_equal "hello world", wire_response_body(response_text)

    headers = response_headers(response_text)
    assert_equal "Yamiochi", headers.fetch("Server")
    assert_equal "close", headers.fetch("Connection")
    assert_equal "11", headers.fetch("Content-Length")
    refute headers.key?("Transfer-Encoding")
    assert headers.key?("Date"), "Expected response to include a Date header"
    assert body.closed?, "Expected explicit-length body to be closed after writing"
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

  def test_run_handles_multiple_sequential_clients_when_max_requests_is_set
    request_paths = []
    request_paths_mutex = Mutex.new
    app = lambda { |env|
      request_paths_mutex.synchronize do
        request_paths << env.fetch("PATH_INFO")
      end
      [200, {"Content-Length" => "2"}, ["ok"]]
    }
    server = Yamiochi::Server.new(
      app: app,
      host: "127.0.0.1",
      port: 0,
      out: StringIO.new,
      err: StringIO.new,
      max_requests: 2
    )
    thread = Thread.new do
      Thread.current.report_on_exception = false
      server.run
    end
    bound_port = wait_for_bound_port(server, thread)

    first_response = request_response("127.0.0.1", bound_port, basic_request("/first"))
    second_response = request_response("127.0.0.1", bound_port, basic_request("/second"))

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(first_response)
    assert_equal "HTTP/1.1 200 OK", response_status_line(second_response)
    assert_equal ["/first", "/second"], request_paths
  end

  def test_run_still_handles_one_client_by_default
    calls = 0
    calls_mutex = Mutex.new
    app = lambda do |_env|
      calls_mutex.synchronize { calls += 1 }
      [200, {"Content-Length" => "2"}, ["ok"]]
    end
    server = Yamiochi::Server.new(
      app: app,
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

    response_text = request_response("127.0.0.1", bound_port, basic_request("/once"))

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal 1, calls
    assert_raises(Errno::ECONNREFUSED) do
      request_response("127.0.0.1", bound_port, basic_request("/twice"))
    end
  end

  def test_run_sets_rack_hijack_capability_flag_to_false
    app = lambda { |env|
      [200, {}, [env.fetch("rack.hijack?").to_s]]
    }

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "false", response_body(response_text)
  end

  def test_run_builds_a_rack_3_request_environment
    captured_env = nil
    rack_errors = StringIO.new
    app = lambda do |env|
      captured_env = env
      [200, {"Content-Length" => "2"}, ["ok"]]
    end

    response_text, server, thread, bound_port = run_server_request(
      app: app,
      err: rack_errors,
      request_text: request_with_body(
        "POST",
        "/rack/env?debug=1",
        "hello world",
        "Host" => "example.test:1234",
        "Content-Type" => "text/plain; charset=utf-8"
      )
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    refute_nil captured_env
    assert captured_env.keys.all?(String), "Expected Rack env keys to all be strings"

    assert_equal "POST", captured_env.fetch("REQUEST_METHOD")
    assert_equal "", captured_env.fetch("SCRIPT_NAME")
    assert_equal "/rack/env", captured_env.fetch("PATH_INFO")
    assert_equal "debug=1", captured_env.fetch("QUERY_STRING")
    assert_equal "example.test", captured_env.fetch("SERVER_NAME")
    assert_equal bound_port.to_s, captured_env.fetch("SERVER_PORT")
    assert_equal "HTTP/1.1", captured_env.fetch("SERVER_PROTOCOL")
    assert_equal [3, 0], captured_env.fetch("rack.version")
    assert_equal "http", captured_env.fetch("rack.url_scheme")
    assert_same rack_errors, captured_env.fetch("rack.errors")
    assert_instance_of StringIO, captured_env.fetch("rack.input")
    assert_equal false, captured_env.fetch("rack.multithread")
    assert_equal true, captured_env.fetch("rack.multiprocess")
    assert_equal false, captured_env.fetch("rack.run_once")
    assert_equal false, captured_env.fetch("rack.hijack?")
    assert_equal "example.test:1234", captured_env.fetch("HTTP_HOST")
    assert_equal "11", captured_env.fetch("CONTENT_LENGTH")
    assert_equal "text/plain; charset=utf-8", captured_env.fetch("CONTENT_TYPE")
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

  def test_run_exposes_rack_input_with_gets_each_read_and_rewind
    request_body = "alpha\nbeta\n"
    app = lambda do |env|
      input = env.fetch("rack.input")
      payload = {
        "start_pos" => input.pos,
        "first_gets" => input.gets,
        "second_gets" => input.gets,
        "third_gets" => input.gets
      }

      input.rewind
      payload["rewound_pos"] = input.pos
      each_lines = []
      input.each { |line| each_lines << line }
      payload["each_lines"] = each_lines

      input.rewind
      payload["read_after_rewind"] = input.read
      payload["read_at_eof"] = input.read

      response_body = JSON.generate(payload)
      [200, {"Content-Length" => response_body.bytesize.to_s}, [response_body]]
    end

    response_text, server, thread, _bound_port = run_server_request(
      app: app,
      request_text: request_with_body("POST", "/submit", request_body, "Content-Type" => "text/plain")
    )

    assert_server_thread_exits(thread, server)

    payload = JSON.parse(response_body(response_text))
    assert_equal 0, payload.fetch("start_pos")
    assert_equal "alpha\n", payload.fetch("first_gets")
    assert_equal "beta\n", payload.fetch("second_gets")
    assert_nil payload.fetch("third_gets")
    assert_equal 0, payload.fetch("rewound_pos")
    assert_equal ["alpha\n", "beta\n"], payload.fetch("each_lines")
    assert_equal request_body, payload.fetch("read_after_rewind")
    assert_equal "", payload.fetch("read_at_eof")
  end

  def test_run_passes_a_real_request_through_rack_lint
    linted_app = Rack::Lint.new(
      lambda do |_env|
        [200, {"content-type" => "text/plain", "content-length" => "7"}, ["lint ok"]]
      end
    )

    response_text, server, thread, _bound_port = run_server_request(
      app: linted_app,
      request_text: basic_request("/")
    )

    assert_server_thread_exits(thread, server)
    assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
    assert_equal "lint ok", response_body(response_text)
  end

  def test_run_preserves_unrecognized_request_methods
    rackup_source = <<~RUBY
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

  def rack_body(*chunks)
    tracked_body(*chunks) do |body|
      body.define_singleton_method(:each) do |&block|
        @each_calls += 1
        @chunks.each(&block)
      end
    end
  end

  def array_backed_body(*chunks)
    tracked_body(*chunks) do |body|
      body.define_singleton_method(:to_ary) do
        @chunks
      end
      body.define_singleton_method(:each) do |&block|
        @each_calls += 1
        @chunks.each(&block)
      end
    end
  end

  def tracked_body(*chunks)
    Object.new.tap do |body|
      body.instance_variable_set(:@chunks, chunks)
      body.instance_variable_set(:@closed, false)
      body.instance_variable_set(:@each_calls, 0)
      yield body
      body.define_singleton_method(:close) do
        @closed = true
      end
      body.define_singleton_method(:closed?) do
        @closed
      end
      body.define_singleton_method(:each_calls) do
        @each_calls
      end
    end
  end

  def basic_request(target, method: "GET")
    "#{method} #{target} HTTP/1.1\r\nHost: localhost\r\n\r\n"
  end

  def request_with_body(method, target, body, headers = {})
    body = body.b
    request_headers = {"Host" => "localhost", "Content-Length" => body.bytesize.to_s}.merge(headers)
    header_lines = request_headers.map { |name, value| "#{name}: #{value}" }

    "#{method} #{target} HTTP/1.1\r\n#{header_lines.join("\r\n")}\r\n\r\n#{body}"
  end

  def run_server_request(request_text:, rackup_source: nil, app: nil, out: StringIO.new, err: StringIO.new)
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      server = if rackup_source
        config_ru = File.join(dir, "config.ru")
        File.write(config_ru, rackup_source)

        Yamiochi::Server.new(
          rackup_path: config_ru,
          host: "127.0.0.1",
          port: 0,
          out: out,
          err: err
        )
      else
        Yamiochi::Server.new(
          app: app,
          host: "127.0.0.1",
          port: 0,
          out: out,
          err: err
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

  def wait_for_bound_port(server, thread, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      return server.bound_port if server.bound_port

      unless thread.alive?
        assert_same server, thread.value
        flunk "Server thread exited before publishing its bound port"
      end

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      IO.select(nil, nil, nil, 0.01)
    end

    flunk "Timed out waiting for server to bind a port"
  end
end
