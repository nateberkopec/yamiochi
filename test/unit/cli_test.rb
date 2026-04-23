# frozen_string_literal: true

require "stringio"
require "tmpdir"

require_relative "../test_helper"

class YamiochiCliTest < Minitest::Test
  class FakeServer
    class << self
      attr_reader :calls, :run_count

      def reset!
        @calls = []
        @run_count = 0
      end
    end

    reset!

    def initialize(rackup_path:, host: Yamiochi::Server::DEFAULT_HOST, port: Yamiochi::Server::DEFAULT_PORT, out:, err:)
      self.class.instance_variable_get(:@calls) << {rackup_path:, host:, port:, out:, err:}
    end

    def run
      self.class.instance_variable_set(:@run_count, self.class.run_count + 1)
      true
    end
  end

  def setup
    FakeServer.reset!
  end

  def test_success_without_bind_preserves_default_host_and_port
    with_temp_rackup_file do |config_ru|
      out = StringIO.new
      err = StringIO.new

      status = Yamiochi::CLI.start([config_ru], out:, err:, server_class: FakeServer)

      assert_equal 0, status
      assert_equal 1, FakeServer.calls.length
      assert_equal config_ru, FakeServer.calls.first[:rackup_path]
      assert_equal Yamiochi::Server::DEFAULT_HOST, FakeServer.calls.first[:host]
      assert_equal Yamiochi::Server::DEFAULT_PORT, FakeServer.calls.first[:port]
      assert_same out, FakeServer.calls.first[:out]
      assert_same err, FakeServer.calls.first[:err]
      assert_equal 1, FakeServer.run_count
      assert_empty out.string
      assert_empty err.string
    end
  end

  def test_success_accepts_bind_option_and_starts_server
    with_temp_rackup_file do |config_ru|
      out = StringIO.new
      err = StringIO.new

      status = Yamiochi::CLI.start(["-b", "tcp://127.0.0.1:4567", config_ru], out:, err:, server_class: FakeServer)

      assert_equal 0, status
      assert_equal 1, FakeServer.calls.length
      assert_equal config_ru, FakeServer.calls.first[:rackup_path]
      assert_equal "127.0.0.1", FakeServer.calls.first[:host]
      assert_equal 4567, FakeServer.calls.first[:port]
      assert_same out, FakeServer.calls.first[:out]
      assert_same err, FakeServer.calls.first[:err]
      assert_equal 1, FakeServer.run_count
      assert_empty out.string
      assert_empty err.string
    end
  end

  def test_missing_argument_returns_non_zero_and_prints_usage
    status, _out, err = run_cli([])

    assert_equal 1, status
    assert_match(/missing Rackup file path/, err)
    assert_match(/Usage: yamiochi \[-b tcp:\/\/HOST:PORT\] CONFIG\.RU/, err)
  end

  def test_missing_bind_argument_returns_non_zero_and_prints_usage
    status, _out, err = run_cli(["-b"])

    assert_equal 1, status
    assert_match(/missing bind URI after -b/, err)
    assert_match(/Usage: yamiochi \[-b tcp:\/\/HOST:PORT\] CONFIG\.RU/, err)
  end

  def test_extra_arguments_return_non_zero_and_print_usage
    with_temp_rackup_file do |config_ru|
      status, _out, err = run_cli([config_ru, "extra.ru"])

      assert_equal 1, status
      assert_match(/unexpected arguments: extra\.ru/, err)
      assert_match(/Usage: yamiochi \[-b tcp:\/\/HOST:PORT\] CONFIG\.RU/, err)
    end
  end

  def test_nonexistent_path_returns_non_zero_with_clear_error
    missing_path = File.join(Dir.tmpdir, "yamiochi-missing-#{Process.pid}-#{rand(1_000_000)}.ru")
    out = StringIO.new
    err = StringIO.new

    status = Yamiochi::CLI.start([missing_path], out:, err:)

    assert_equal 1, status
    assert_match(/Rackup file not found/i, err.string)
    assert_match(/#{Regexp.escape(missing_path)}/, err.string)
    assert_empty out.string
  end

  def test_invalid_bind_uri_returns_non_zero_with_clear_error
    with_temp_rackup_file do |config_ru|
      status, _out, err = run_cli(["-b", "tcp:/127.0.0.1:4567", config_ru])

      assert_equal 1, status
      assert_match(/invalid bind URI: "tcp:\/127\.0\.0\.1:4567"/, err)
      assert_match(/expected tcp:\/\/HOST:PORT/, err)
    end
  end

  def test_unsupported_bind_scheme_returns_non_zero_with_clear_error
    with_temp_rackup_file do |config_ru|
      status, _out, err = run_cli(["--bind", "unix:///tmp/yamiochi.sock", config_ru])

      assert_equal 1, status
      assert_match(/unsupported bind scheme: unix/, err)
      assert_match(/expected tcp:\/\/HOST:PORT/, err)
    end
  end

  private

  def run_cli(argv)
    out = StringIO.new
    err = StringIO.new
    status = Yamiochi::CLI.start(argv, out:, err:, server_class: FakeServer)

    [status, out.string, err.string]
  end

  def with_temp_rackup_file
    Dir.mktmpdir do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, rackup_contents)
      yield config_ru
    end
  end

  def rackup_contents
    "run ->(_env) { [200, {}, ['ok']] }\n"
  end
end
