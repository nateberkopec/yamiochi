#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "lib/yamiochi_factory/gate_evaluator"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"
require_relative "lib/yamiochi_factory/judge_report"

validation_path = ARGV[0] || "tmp/factory-gates/validation.json"
judge_path = ARGV[1] || "tmp/judge.md"
output_path = ARGV[2] || "tmp/factory-gates/report.json"
registry_path = ARGV[3] || ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || "factory/gates.yml"
state_path = ARGV[4] || ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/gates.json"

registry = YamiochiFactory::GateRegistry.load(registry_path)
validation = JSON.parse(File.read(validation_path))
judge = YamiochiFactory::JudgeReport.parse(File.read(judge_path))
state = YamiochiFactory::GateState.load(state_path, registry:)
report = YamiochiFactory::GateEvaluator.evaluate(registry:, validation:, judge:, state:)

FileUtils.mkdir_p(File.dirname(output_path))
File.write(output_path, JSON.pretty_generate(report))
puts JSON.pretty_generate(report)

exit 1 unless report.fetch("pass")
