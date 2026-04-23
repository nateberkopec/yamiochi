#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/gate_promotion"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"
require_relative "lib/yamiochi_factory/github_client"
require_relative "lib/yamiochi_factory/selection"
require_relative "lib/yamiochi_factory/work_packets"

output_path = ARGV[0]
registry_path = ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || "factory/gates.yml"
state_path = ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "tmp/factory-gates/gates.json"

registry = YamiochiFactory::GateRegistry.load(registry_path)
state = YamiochiFactory::GateState.load(state_path, registry:)

selected = if (packet = YamiochiFactory::WorkPackets.select_best(registry:, state:, state_path:))
  packet.merge(
    "selection_reason" => {
      "source" => "gate_packet",
      "priority_reason" => packet.fetch("priority_reason")
    }
  )
elsif (promotion = YamiochiFactory::GatePromotion.eligible_promotions(registry:, state:).first)
  YamiochiFactory::GatePromotion.to_work_item(promotion).merge(
    "selection_reason" => {
      "source" => "gate_promotion",
      "priority_reason" => "promotion_ready"
    }
  )
else
  issue = YamiochiFactory::Selection.select_issue(YamiochiFactory::GitHubClient.new.issues)
  issue&.merge(
    "type" => "issue",
    "id" => "issue-#{issue.fetch('number')}",
    "selection_reason" => {
      "source" => "issue_fallback",
      "milestone_priority" => YamiochiFactory::Selection.milestone_priority(issue),
      "bot_priority" => YamiochiFactory::Selection.bot_priority(issue)
    }
  )
end

if selected.nil?
  warn "No selectable work item found."
  exit 0
end

json = JSON.pretty_generate(selected)
File.write(output_path, json) if output_path
puts json
