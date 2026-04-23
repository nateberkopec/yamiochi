# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/gate_registry"
require_relative "../../../factory/scripts/lib/yamiochi_factory/merge_gates"

class YamiochiFactoryMergeGatesTest < Minitest::Test
  def test_evaluate_applies_observe_ratchet_and_hard_semantics
    validation = {
      "commands" => {
        "lint" => {"success" => true},
        "test" => {"success" => true},
        "scenarios" => {"success" => true}
      },
      "deny_paths_passed" => true,
      "scores" => {
        "http_probe" => 0,
        "h1spec" => 0,
        "redbot" => 0,
        "sinatra_fixture" => 0,
        "rails_fixture" => 0,
        "internal_scenarios" => 2,
        "benchmark_rps" => 285_000.0,
        "spec_definition_of_done" => 3
      },
      "maximums" => {
        "internal_scenarios" => 2,
        "spec_definition_of_done" => 4
      }
    }
    judge = {"score" => 0.9, "decision" => "pass"}
    registry = YamiochiFactory::GateRegistry.load
    baseline = YamiochiFactory::MergeGates.default_baseline(registry:)
    baseline["gates"]["internal_scenarios"]["baseline_value"] = 2
    baseline["gates"]["benchmark_rps"]["baseline_value"] = 300_000.0
    baseline["gates"]["spec_definition_of_done"]["baseline_value"] = 2

    report = YamiochiFactory::MergeGates.evaluate(validation:, judge:, baseline:, registry:)

    assert report.fetch("pass")
    assert_equal "observe", report.dig("gates", "sinatra_fixture", "level")
    assert report.dig("gates", "sinatra_fixture", "level_pass")
    refute report.dig("gates", "sinatra_fixture", "full_pass")
    assert report.dig("gates", "benchmark_rps", "level_pass")
    assert_in_delta 285_000.0, report.dig("gates", "benchmark_rps", "threshold_value"), 0.001
    assert report.dig("gates", "internal_scenarios", "full_pass")
  end

  def test_evaluate_fails_when_hard_gate_or_ratchet_regresses
    validation = {
      "commands" => {
        "lint" => {"success" => false},
        "test" => {"success" => true},
        "scenarios" => {"success" => true}
      },
      "deny_paths_passed" => true,
      "scores" => {
        "http_probe" => 0,
        "h1spec" => 0,
        "redbot" => 0,
        "sinatra_fixture" => 0,
        "rails_fixture" => 0,
        "internal_scenarios" => 1,
        "benchmark_rps" => 100.0,
        "spec_definition_of_done" => 1
      },
      "maximums" => {
        "internal_scenarios" => 2,
        "spec_definition_of_done" => 4
      }
    }
    judge = {"score" => 0.5, "decision" => "revise"}
    registry = YamiochiFactory::GateRegistry.load
    baseline = YamiochiFactory::MergeGates.default_baseline(registry:)
    baseline["gates"]["internal_scenarios"]["baseline_value"] = 2
    baseline["gates"]["benchmark_rps"]["baseline_value"] = 300_000.0
    baseline["gates"]["spec_definition_of_done"]["baseline_value"] = 2

    report = YamiochiFactory::MergeGates.evaluate(validation:, judge:, baseline:, registry:)

    refute report.fetch("pass")
    refute report.dig("gates", "lint", "level_pass")
    refute report.dig("gates", "judge", "level_pass")
    refute report.dig("gates", "internal_scenarios", "level_pass")
    refute report.dig("gates", "benchmark_rps", "level_pass")
    assert report.dig("gates", "benchmark_rps", "regression")
  end

  def test_promote_updates_ratchet_baselines_and_streaks
    validation = {
      "commands" => {
        "lint" => {"success" => true},
        "test" => {"success" => true},
        "scenarios" => {"success" => true}
      },
      "deny_paths_passed" => true,
      "scores" => {
        "http_probe" => 0,
        "h1spec" => 0,
        "redbot" => 0,
        "sinatra_fixture" => 0,
        "rails_fixture" => 0,
        "internal_scenarios" => 2,
        "benchmark_rps" => 310_000.0,
        "spec_definition_of_done" => 4
      },
      "maximums" => {
        "internal_scenarios" => 2,
        "spec_definition_of_done" => 4
      }
    }
    judge = {"score" => 0.9, "decision" => "pass"}
    registry = YamiochiFactory::GateRegistry.load
    baseline = YamiochiFactory::MergeGates.default_baseline(registry:)
    report = YamiochiFactory::MergeGates.evaluate(validation:, judge:, baseline:, registry:)

    promoted = YamiochiFactory::MergeGates.promote(baseline:, report:, registry:)

    assert_equal 2.0, promoted.dig("gates", "internal_scenarios", "baseline_value")
    assert_equal 310_000.0, promoted.dig("gates", "benchmark_rps", "baseline_value")
    assert_equal 1, promoted.dig("gates", "internal_scenarios", "full_pass_streak")
    assert_equal 1, promoted.dig("gates", "lint", "full_pass_streak")
  end
end
