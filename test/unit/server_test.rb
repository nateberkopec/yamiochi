# frozen_string_literal: true

require "socket"
require "stringio"
require "tmpdir"

require_relative "../test_helper"

class YamiochiServerTest < Minitest::Test
  def test_initialization_normalizes_rackup_path
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents)
      relative_path = File.join(dir, ".", "config.ru")

      server = Yamiochi::Server.new(rackup_path: relative_path, out: StringIO.new, err: StringIO.new)

      assert_equal File.expand_path(config_ru), server.rackup_path
    end
  end

  def test_run_binds_and_handles_one_client_connection
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents)

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

      TCPSocket.open("127.0.0.1", bound_port) do |client|
        client.write("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
      end

      assert thread.join(5), "Expected server thread to exit after handling one client"
      assert_same server, thread.value
      assert_equal bound_port, server.bound_port
      assert_operator server.bound_port, :>, 0
    end
  end

  private

  def rackup_contents
    "run ->(_env) { [200, {}, ['ok']] }\n"
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
