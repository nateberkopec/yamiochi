#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"

source_path = ARGV.fetch(0) do
  warn "Usage: ruby factory/scripts/migrate_gate_state.rb OLD_PATH NEW_PATH [REGISTRY_PATH]"
  exit 1
end

target_path = ARGV.fetch(1) do
  warn "Usage: ruby factory/scripts/migrate_gate_state.rb OLD_PATH NEW_PATH [REGISTRY_PATH]"
  exit 1
end

registry_path = ARGV[2] || ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || "factory/gates.yml"
registry = YamiochiFactory::GateRegistry.load(registry_path)
state = YamiochiFactory::GateState.default_state(registry:)

legacy = JSON.parse(File.read(source_path))
legacy_scores = legacy.fetch("scores", {})

registry.each do |name, gate|
  next unless gate.fetch("metric_type") == "score"

  state["gates"][name]["baseline_value"] = legacy_scores.fetch(name, legacy_scores.fetch(name.to_sym, 0))
end

FileUtils.mkdir_p(File.dirname(target_path))
File.write(target_path, JSON.pretty_generate(state))
puts JSON.pretty_generate(state)
