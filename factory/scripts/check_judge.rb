#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/yamiochi_factory/judge_report"

judge_path = ARGV[0] || "tmp/judge.md"
report = YamiochiFactory::JudgeReport.parse(File.read(judge_path))
puts report

exit 1 unless report.fetch("decision") == "pass" && report.fetch("score") >= 0.8
