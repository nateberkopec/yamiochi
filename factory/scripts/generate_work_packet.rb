#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"
require_relative "lib/yamiochi_factory/work_packets"

output_path = ARGV[0]
registry_path = ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || "factory/gates.yml"
state_path = ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/gates.json"

registry = YamiochiFactory::GateRegistry.load(registry_path)
state = YamiochiFactory::GateState.load(state_path, registry:)
packet = YamiochiFactory::WorkPackets.select_best(registry:, state:, state_path:)

if packet.nil?
  warn "No gate-derived work packet available."
  exit 0
end

json = JSON.pretty_generate(packet)
File.write(output_path, json) if output_path
puts json
