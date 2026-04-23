#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "tempfile"
require_relative "lib/yamiochi_factory/gate_promotion"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"

base_source = ARGV[0] || "origin/main"
candidate_path = ARGV[1] || "factory/gates.yml"
state_path = ARGV[2] || ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/gates.json"

candidate_registry = YamiochiFactory::GateRegistry.load(candidate_path)
base_registry = if File.exist?(base_source)
  YamiochiFactory::GateRegistry.load(base_source)
else
  merge_base = `git merge-base HEAD #{base_source} 2>/dev/null`.strip
  abort("Could not determine merge base against #{base_source}") if merge_base.empty?

  yaml = `git show #{merge_base}:factory/gates.yml 2>/dev/null`
  abort("Could not load factory/gates.yml from #{merge_base}") if yaml.empty?

  temp = Tempfile.new(["gate-registry-base", ".yml"])
  begin
    temp.write(yaml)
    temp.flush
    YamiochiFactory::GateRegistry.load(temp.path)
  ensure
    temp.close!
  end
end
state = YamiochiFactory::GateState.load(state_path, registry: candidate_registry)
result = YamiochiFactory::GatePromotion.validate_transition(base_registry:, candidate_registry:, state:)
puts JSON.pretty_generate(result)

exit 1 unless result.fetch("pass")
