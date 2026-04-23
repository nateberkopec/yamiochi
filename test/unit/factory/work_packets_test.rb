# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/gate_registry"
require_relative "../../../factory/scripts/lib/yamiochi_factory/gate_state"
require_relative "../../../factory/scripts/lib/yamiochi_factory/work_packets"

class YamiochiFactoryWorkPacketsTest < Minitest::Test
  def test_select_best_prefers_hard_failures_over_observe_opportunities
    registry = YamiochiFactory::GateRegistry.load
    state = YamiochiFactory::GateState.default_state(registry:)
    state["gates"]["lint"]["last_result"] = {
      "candidate_value" => false,
      "baseline_value" => nil,
      "threshold_value" => nil,
      "full_pass_target" => true,
      "full_pass" => false,
      "priority_reason" => "hard_fail",
      "failure_summary" => "syntax error",
      "artifacts" => ["tmp/factory-gates/validation.json"]
    }
    state["gates"]["sinatra_fixture"]["last_result"] = {
      "candidate_value" => 0,
      "baseline_value" => 0,
      "threshold_value" => nil,
      "full_pass_target" => 1,
      "full_pass" => false,
      "priority_reason" => "observe_opportunity",
      "failure_summary" => "score 0",
      "artifacts" => ["tmp/factory-gates/validation.json"]
    }

    packet = YamiochiFactory::WorkPackets.select_best(registry:, state:, state_path: "/tmp/gates.json")

    assert_equal "lint", packet.fetch("target_gate")
    assert_equal "hard_fail", packet.fetch("priority_reason")
  end

  def test_select_best_generates_ratchet_work_from_baseline_only_state
    registry = YamiochiFactory::GateRegistry.load
    state = YamiochiFactory::GateState.default_state(registry:)
    state["gates"]["internal_scenarios"]["baseline_value"] = 0

    packet = YamiochiFactory::WorkPackets.select_best(registry:, state:, state_path: "/tmp/gates.json")

    assert_equal "internal_scenarios", packet.fetch("target_gate")
    assert_equal "ratchet_opportunity", packet.fetch("priority_reason")
  end
end
