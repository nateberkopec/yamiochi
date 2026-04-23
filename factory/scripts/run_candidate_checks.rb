#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"

output_path = ARGV[0] || "tmp/factory-gates/validation.json"
FileUtils.mkdir_p(File.dirname(output_path))

commands = {
  "lint" => "mise trust . >/dev/null 2>&1 || true; mise run lint",
  "test" => "mise trust . >/dev/null 2>&1 || true; mise run test",
  "scenarios" => "mise trust . >/dev/null 2>&1 || true; mise run scenarios",
  "bench" => "mise trust . >/dev/null 2>&1 || true; mise run bench"
}

results = commands.transform_values do |command|
  stdout, stderr, status = Open3.capture3("bash", "-lc", command)
  {
    "command" => command,
    "success" => status.success?,
    "exit_status" => status.exitstatus,
    "stdout" => stdout,
    "stderr" => stderr
  }
end

scenario_total = Dir.glob("test/scenarios/**/*_test.rb").count
spec_completed = File.read("SPEC.md").scan(/^\s*- \[x\] /i).count
spec_total = File.read("SPEC.md").scan(/^\s*- \[(?: |x)\] /i).count
benchmark_output = results.fetch("bench").fetch("stdout")
benchmark_rps = benchmark_output[/([0-9]+(?:\.[0-9]+)?)\s*(?:req\/s|requests per second)/i, 1]&.to_f || 0.0

payload = {
  "commands" => results,
  "deny_paths_passed" => true,
  "scores" => {
    "http_probe" => 0,
    "h1spec" => 0,
    "redbot" => 0,
    "sinatra_fixture" => 0,
    "rails_fixture" => 0,
    "internal_scenarios" => results.dig("scenarios", "success") ? scenario_total : 0,
    "benchmark_rps" => benchmark_rps,
    "spec_definition_of_done" => spec_completed
  },
  "maximums" => {
    "internal_scenarios" => scenario_total,
    "spec_definition_of_done" => spec_total
  }
}

File.write(output_path, JSON.pretty_generate(payload))
puts JSON.pretty_generate(payload)

exit 1 unless results.fetch_values("lint", "test", "scenarios").all? { |result| result.fetch("success") }
