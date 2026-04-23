#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/gate_promotion"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"

output_path = ARGV[0]
registry_path = ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || "factory/gates.yml"
state_path = ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/gates.json"

registry = YamiochiFactory::GateRegistry.load(registry_path)
state = YamiochiFactory::GateState.load(state_path, registry:)
proposals = YamiochiFactory::GatePromotion.eligible_promotions(registry:, state:)
payload = {
  "selected" => proposals.first && YamiochiFactory::GatePromotion.to_work_item(proposals.first),
  "proposals" => proposals
}
json = JSON.pretty_generate(payload)
File.write(output_path, json) if output_path
puts json
