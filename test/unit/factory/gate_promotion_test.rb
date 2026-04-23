# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/gate_promotion"
require_relative "../../../factory/scripts/lib/yamiochi_factory/gate_registry"
require_relative "../../../factory/scripts/lib/yamiochi_factory/gate_state"

class YamiochiFactoryGatePromotionTest < Minitest::Test
  def test_eligible_promotions_require_full_pass_streak
    registry = YamiochiFactory::GateRegistry.load
    state = YamiochiFactory::GateState.default_state(registry:)
    state["gates"]["internal_scenarios"]["full_pass_streak"] = 3
    state["gates"]["internal_scenarios"]["last_result"] = { "full_pass" => true }

    proposals = YamiochiFactory::GatePromotion.eligible_promotions(registry:, state:)

    proposal = proposals.find { |entry| entry.fetch("target_gate") == "internal_scenarios" }
    refute_nil proposal
    assert_equal "hard", proposal.fetch("next_level")
  end

  def test_validate_transition_allows_single_step_upward_level_change
    base_registry = YamiochiFactory::GateRegistry.load
    candidate_registry = duplicated_registry(base_registry)
    candidate_registry.gates["sinatra_fixture"]["level"] = "ratchet"
    state = YamiochiFactory::GateState.default_state(registry: candidate_registry)
    state["gates"]["sinatra_fixture"]["full_pass_streak"] = 3
    state["gates"]["sinatra_fixture"]["last_result"] = { "full_pass" => true }

    result = YamiochiFactory::GatePromotion.validate_transition(base_registry:, candidate_registry:, state:)

    assert result.fetch("pass")
    assert_equal "sinatra_fixture", result.fetch("promotions").first.fetch("target_gate")
  end

  def test_validate_transition_rejects_non_level_changes
    base_registry = YamiochiFactory::GateRegistry.load
    candidate_registry = duplicated_registry(base_registry)
    candidate_registry.gates["sinatra_fixture"]["title"] = "Not Allowed"
    candidate_registry.gates["sinatra_fixture"]["level"] = "ratchet"
    state = YamiochiFactory::GateState.default_state(registry: candidate_registry)
    state["gates"]["sinatra_fixture"]["full_pass_streak"] = 3
    state["gates"]["sinatra_fixture"]["last_result"] = { "full_pass" => true }

    result = YamiochiFactory::GatePromotion.validate_transition(base_registry:, candidate_registry:, state:)

    refute result.fetch("pass")
    assert_includes result.fetch("errors"), "Gate sinatra_fixture changes fields other than level"
  end

  private

  def duplicated_registry(registry)
    YamiochiFactory::GateRegistry.new(
      path: registry.path,
      version: registry.version,
      gates: Marshal.load(Marshal.dump(registry.gates))
    )
  end
end
