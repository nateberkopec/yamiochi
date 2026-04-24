# frozen_string_literal: true

require "stringio"

require_relative "../test_helper"

class YamiochiBenchmarkRunnerTest < Minitest::Test
  def test_run_prints_parsable_requests_per_second_output
    out = StringIO.new
    runner = Yamiochi::BenchmarkRunner.new(
      request_count: 3,
      warmup_requests: 1,
      out: out,
      err: StringIO.new
    )

    runner.run

    assert_match(/\A\d+(?:\.\d+)? req\/s\n\z/, out.string)
  end

  def test_run_drives_real_requests_through_server
    requests = []
    requests_mutex = Mutex.new
    app = lambda { |env|
      requests_mutex.synchronize do
        requests << [env.fetch("REQUEST_METHOD"), env.fetch("PATH_INFO"), env.fetch("HTTP_HOST")]
      end
      [200, {"Content-Length" => "2"}, ["ok"]]
    }
    runner = Yamiochi::BenchmarkRunner.new(
      app: app,
      request_count: 4,
      warmup_requests: 2,
      out: StringIO.new,
      err: StringIO.new
    )

    runner.run

    assert_equal 6, requests.length
    assert_equal Array.new(6, ["GET", "/", "localhost"]), requests
  end

  def test_run_returns_positive_numeric_throughput
    runner = Yamiochi::BenchmarkRunner.new(
      request_count: 3,
      warmup_requests: 1,
      out: StringIO.new,
      err: StringIO.new
    )

    requests_per_second = runner.run

    assert_kind_of Float, requests_per_second
    assert_operator requests_per_second, :>, 0.0
  end
end
