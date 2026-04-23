# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/merge_gates"

class YamiochiFactoryMergeGatesTest < Minitest::Test
  def test_evaluate_passes_when_scores_meet_or_beat_baseline
    validation = {
      "commands" => {
        "lint" => { "success" => true },
        "test" => { "success" => true },
        "scenarios" => { "success" => true }
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
      }
    }
    judge = { "score" => 0.9, "decision" => "pass" }
    baseline = {
      "scores" => {
        "internal_scenarios" => 2,
        "benchmark_rps" => 300_000.0,
        "spec_definition_of_done" => 2
      },
      "pinned_green" => []
    }

    report = YamiochiFactory::MergeGates.evaluate(validation:, judge:, baseline:)

    assert report.fetch("pass")
    assert report.dig("ratchets", "benchmark_rps", "pass")
  end

  def test_evaluate_fails_when_hard_gate_or_ratchet_regresses
    validation = {
      "commands" => {
        "lint" => { "success" => false },
        "test" => { "success" => true },
        "scenarios" => { "success" => true }
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
      }
    }
    judge = { "score" => 0.5, "decision" => "revise" }
    baseline = {
      "scores" => {
        "internal_scenarios" => 2,
        "benchmark_rps" => 300_000.0,
        "spec_definition_of_done" => 2
      },
      "pinned_green" => []
    }

    report = YamiochiFactory::MergeGates.evaluate(validation:, judge:, baseline:)

    refute report.fetch("pass")
    refute report.dig("hard_gates", "lint")
    refute report.dig("hard_gates", "judge")
    refute report.dig("ratchets", "internal_scenarios", "pass")
  end
end
