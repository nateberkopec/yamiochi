# frozen_string_literal: true

module YamiochiFactory
  module MergeGates
    BINARY_GATES = %w[sinatra_fixture rails_fixture].freeze

    module_function

    def default_baseline
      {
        "scores" => {
          "http_probe" => 0,
          "h1spec" => 0,
          "redbot" => 0,
          "sinatra_fixture" => 0,
          "rails_fixture" => 0,
          "internal_scenarios" => 0,
          "benchmark_rps" => 0.0,
          "spec_definition_of_done" => 0
        },
        "pinned_green" => []
      }
    end

    def evaluate(validation:, judge:, baseline: default_baseline)
      current_scores = validation.fetch("scores")
      baseline_scores = default_baseline.fetch("scores").merge(baseline.fetch("scores", {}))
      pinned_green = Array(baseline["pinned_green"])

      hard_gates = {
        "lint" => validation.dig("commands", "lint", "success"),
        "test" => validation.dig("commands", "test", "success"),
        "scenarios" => validation.dig("commands", "scenarios", "success"),
        "deny_paths" => validation.fetch("deny_paths_passed"),
        "judge" => judge.fetch("decision") == "pass" && judge.fetch("score") >= 0.8
      }

      ratchets = current_scores.each_with_object({}) do |(name, current_value), report|
        baseline_value = baseline_scores.fetch(name, 0)
        threshold = benchmark_threshold(name, baseline_value)
        report[name] = {
          "current" => current_value,
          "baseline" => baseline_value,
          "threshold" => threshold,
          "pass" => current_value >= threshold
        }
      end

      pinned = pinned_green.each_with_object({}) do |name, report|
        current_value = current_scores.fetch(name, 0)
        report[name] = {
          "current" => current_value,
          "pass" => current_value.positive?
        }
      end

      {
        "hard_gates" => hard_gates,
        "ratchets" => ratchets,
        "pinned_green" => pinned,
        "pass" => hard_gates.values.all? && ratchets.values.all? { |gate| gate.fetch("pass") } && pinned.values.all? { |gate| gate.fetch("pass") }
      }
    end

    def promote(baseline:, report:)
      baseline_scores = default_baseline.fetch("scores").merge(baseline.fetch("scores", {}))
      report_scores = report.fetch("ratchets")
      promoted_scores = baseline_scores.merge(
        report_scores.transform_values { |gate| [gate.fetch("baseline"), gate.fetch("current")].max }
      )

      pinned_green = Array(baseline["pinned_green"]).dup
      BINARY_GATES.each do |name|
        next unless report_scores.dig(name, "current").to_i.positive?
        next if pinned_green.include?(name)

        pinned_green << name
      end

      {
        "scores" => promoted_scores,
        "pinned_green" => pinned_green.sort
      }
    end

    def benchmark_threshold(name, baseline_value)
      return baseline_value * 0.95 if name == "benchmark_rps" && baseline_value.to_f.positive?

      baseline_value
    end
  end
end
