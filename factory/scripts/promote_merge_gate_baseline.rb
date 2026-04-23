#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"

report_path = ARGV[0] || "tmp/factory-gates/report.json"
state_path = ARGV[1] || ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/gates.json"
registry_path = ARGV[2] || ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || "factory/gates.yml"

registry = YamiochiFactory::GateRegistry.load(registry_path)
report = JSON.parse(File.read(report_path))
state = YamiochiFactory::GateState.load(state_path, registry:)
promoted = YamiochiFactory::GateState.promote(state:, report:, registry:)

FileUtils.mkdir_p(File.dirname(state_path))
File.write(state_path, JSON.pretty_generate(promoted))
puts JSON.pretty_generate(promoted)
