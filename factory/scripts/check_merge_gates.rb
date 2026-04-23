#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "lib/yamiochi_factory/judge_report"
require_relative "lib/yamiochi_factory/merge_gates"

validation_path = ARGV[0] || "tmp/factory-gates/validation.json"
judge_path = ARGV[1] || "tmp/judge.md"
output_path = ARGV[2] || "tmp/factory-gates/report.json"
baseline_path = ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/baseline.json"

validation = JSON.parse(File.read(validation_path))
judge = YamiochiFactory::JudgeReport.parse(File.read(judge_path))
baseline = File.exist?(baseline_path) ? JSON.parse(File.read(baseline_path)) : YamiochiFactory::MergeGates.default_baseline
report = YamiochiFactory::MergeGates.evaluate(validation:, judge:, baseline:)

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(report))
puts JSON.pretty_generate(report)

exit 1 unless report.fetch("pass")
