#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "lib/yamiochi_factory/merge_gates"

report_path = ARGV[0] || "tmp/factory-gates/report.json"
baseline_path = ARGV[1] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/baseline.json"

report = JSON.parse(File.read(report_path))
baseline = File.exist?(baseline_path) ? JSON.parse(File.read(baseline_path)) : YamiochiFactory::MergeGates.default_baseline
promoted = YamiochiFactory::MergeGates.promote(baseline:, report:)

FileUtils.mkdir_p(File.dirname(baseline_path))
File.write(baseline_path, JSON.pretty_generate(promoted))
puts JSON.pretty_generate(promoted)
