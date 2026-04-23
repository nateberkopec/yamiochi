# frozen_string_literal: true

require "open3"
require "rbconfig"
require "socket"
require "tmpdir"

require_relative "../test_helper"

class YamiochiRackupProcessTest < Minitest::Test
  def test_rackup_can_boot_yamiochi_handler_and_serve_a_request
    skip_unless_rackup_available

    Dir.mktmpdir("yamiochi-rackup-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents("hello from rackup"))

      port = available_port
      stdout_text = nil
      stderr_text = nil
      status = nil
      response_text = nil

      Open3.popen3(*rackup_command(config_ru, port), chdir: repo_root) do |stdin, stdout, stderr, wait_thr|
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

      assert status.success?, "Expected rackup to exit successfully, stdout: #{stdout_text.inspect}, stderr: #{stderr_text.inspect}"
      assert_empty stdout_text
      assert_empty stderr_text
      assert_equal "HTTP/1.1 200 OK", response_status_line(response_text)
      assert_equal "hello from rackup", response_body(response_text)

      headers = response_headers(response_text)
      assert_equal "Yamiochi", headers.fetch("Server")
      assert_equal "close", headers.fetch("Connection")
      assert_equal "17", headers.fetch("Content-Length")
      assert headers.key?("Date"), "Expected response to include a Date header"
    end
  end

  private

  def skip_unless_rackup_available
    return if system(RbConfig.ruby, "-S", "rackup", "--version", out: File::NULL, err: File::NULL)

    skip "rackup executable is unavailable in the test environment"
  rescue Errno::ENOENT
    skip "rackup executable is unavailable in the test environment"
  end

  def rackup_command(config_ru, port)
    [
      RbConfig.ruby,
      "-Ilib",
      "-S",
      "rackup",
      "-q",
      "-E",
      "none",
      "-s",
      "yamiochi",
      "-o",
      "127.0.0.1",
      "-p",
      port.to_s,
      config_ru
    ]
  end

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
    _head, body = response_text.split("\r\n\r\n", 2)
    body
  end

  def response_head(response_text)
    head, _body = response_text.split("\r\n\r\n", 2)
    head
  end

  def repo_root
    File.expand_path("../..", __dir__)
  end

  def available_port
    TCPServer.open("127.0.0.1", 0) do |server|
      return server.local_address.ip_port
    end
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
        flunk "rackup exited before accepting a client connection"
      end

      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end

    flunk "Timed out waiting for rackup to accept a client connection"
  end

  def wait_for_exit(wait_thr, timeout: 5)
    return wait_thr.value if wait_thr.join(timeout)

    flunk "Timed out waiting for rackup to exit after serving one client"
  end

  def terminate_process(wait_thr)
    return unless wait_thr.alive?

    Process.kill("TERM", wait_thr.pid)
    wait_thr.join(5)
  rescue Errno::ESRCH
    nil
  end
end
