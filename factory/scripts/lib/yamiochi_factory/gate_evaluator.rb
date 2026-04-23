# frozen_string_literal: true

require "time"

module YamiochiFactory
  module GateEvaluator
    module_function

    def evaluate(registry:, validation:, judge:, state:)
      gates = registry.gates.each_with_object({}) do |(name, gate), report|
        gate_state = state.dig("gates", name) || {}
        report[name] = evaluate_gate(name:, gate:, gate_state:, validation:, judge:)
      end

      {
        "generated_at" => Time.now.utc.iso8601,
        "pass" => gates.values.all? { |gate| !gate.fetch("blocking") || gate.fetch("level_pass") },
        "gates" => gates,
        "summary" => summary_for(gates)
      }
    end

    def evaluate_gate(name:, gate:, gate_state:, validation:, judge:)
      candidate_value = candidate_value_for(gate:, validation:, judge:)
      baseline_value = baseline_value_for(gate:, gate_state:)
      threshold_value = threshold_value_for(gate:, baseline_value:)
      full_pass_target = full_pass_target_for(gate:, validation:, judge:)
      full_pass_known = gate.fetch("metric_type") == "binary" || !full_pass_target.nil?
      full_pass = full_pass_for(gate:, candidate_value:, full_pass_target:)
      level_pass = level_pass_for(gate:, candidate_value:, threshold_value:, full_pass:)
      regression = gate.fetch("level") == "ratchet" && !compare(gate:, left: candidate_value, right: threshold_value)
      priority_reason = priority_reason_for(gate:, full_pass:, regression:)

      {
        "name" => name,
        "title" => gate.fetch("title"),
        "group" => gate.fetch("group"),
        "level" => gate.fetch("level"),
        "metric_type" => gate.fetch("metric_type"),
        "selection_priority" => gate.fetch("selection_priority"),
        "candidate_value" => candidate_value,
        "baseline_value" => baseline_value,
        "threshold_value" => threshold_value,
        "full_pass_target" => full_pass_target,
        "full_pass_known" => full_pass_known,
        "full_pass" => full_pass,
        "level_pass" => level_pass,
        "blocking" => gate.fetch("level") != "observe",
        "regression" => regression,
        "priority_reason" => priority_reason,
        "opportunity_gap" => opportunity_gap_for(gate:, candidate_value:, baseline_value:, full_pass_target:),
        "failure_summary" => failure_summary_for(gate:, candidate_value:, baseline_value:, threshold_value:, full_pass_target:, validation:, judge:),
        "artifacts" => artifacts_for(gate:)
      }
    end
    private_class_method :evaluate_gate

    def summary_for(gates)
      levels = Hash.new(0)
      blocking_failures = []

      gates.each_value do |gate|
        levels[gate.fetch("level")] += 1
        blocking_failures << gate.fetch("name") if gate.fetch("blocking") && !gate.fetch("level_pass")
      end

      {
        "levels" => levels,
        "blocking_failures" => blocking_failures,
        "full_pass_count" => gates.values.count { |gate| gate.fetch("full_pass") },
        "observe_count" => gates.values.count { |gate| gate.fetch("level") == "observe" }
      }
    end
    private_class_method :summary_for

    def candidate_value_for(gate:, validation:, judge:)
      source = gate.fetch("source")

      case source.fetch("kind")
      when "command"
        !!validation.dig("commands", source.fetch("name"), "success")
      when "validation"
        validation.fetch(source.fetch("key"), false)
      when "score"
        validation.dig("scores", source.fetch("key")) || 0
      when "judge"
        judge.fetch("decision") == "pass" && judge.fetch("score").to_f >= 0.8
      else
        raise ArgumentError, "Unsupported gate source #{source.fetch('kind').inspect}"
      end
    end
    private_class_method :candidate_value_for

    def baseline_value_for(gate:, gate_state:)
      return nil unless gate.fetch("metric_type") == "score"

      gate_state.fetch("baseline_value", 0)
    end
    private_class_method :baseline_value_for

    def threshold_value_for(gate:, baseline_value:)
      return nil unless gate.fetch("level") == "ratchet"
      return nil unless gate.fetch("metric_type") == "score"

      baseline = baseline_value.to_f
      baseline_config = gate.fetch("baseline", {})
      return baseline if baseline.zero?

      case baseline_config.fetch("kind", "exact")
      when "ratio"
        baseline * baseline_config.fetch("ratio", 1.0).to_f
      else
        baseline
      end
    end
    private_class_method :threshold_value_for

    def full_pass_target_for(gate:, validation:, judge:)
      return true if gate.fetch("metric_type") == "binary" && gate.fetch("full_pass", {}).empty?

      full_pass = gate.fetch("full_pass", {})
      case full_pass.fetch("kind", gate.fetch("metric_type") == "binary" ? "literal" : "none")
      when "literal"
        full_pass["value"]
      when "metadata"
        validation.dig("maximums", full_pass.fetch("key")) || validation.dig("metadata", full_pass.fetch("key"))
      when "judge_threshold"
        judge.fetch("score")
      when "none"
        nil
      else
        nil
      end
    end
    private_class_method :full_pass_target_for

    def full_pass_for(gate:, candidate_value:, full_pass_target:)
      return candidate_value == true if gate.fetch("metric_type") == "binary" && full_pass_target == true
      return candidate_value == full_pass_target if gate.fetch("metric_type") == "binary"
      return false if full_pass_target.nil?

      compare(gate:, left: candidate_value, right: full_pass_target)
    end
    private_class_method :full_pass_for

    def level_pass_for(gate:, candidate_value:, threshold_value:, full_pass:)
      case gate.fetch("level")
      when "observe"
        true
      when "ratchet"
        compare(gate:, left: candidate_value, right: threshold_value)
      when "hard"
        full_pass
      else
        false
      end
    end
    private_class_method :level_pass_for

    def compare(gate:, left:, right:)
      return !!left == !!right if gate.fetch("metric_type") == "binary"

      left.to_f >= right.to_f
    end
    private_class_method :compare

    def priority_reason_for(gate:, full_pass:, regression:)
      return "hard_fail" if gate.fetch("level") == "hard" && !full_pass
      return "ratchet_regression" if gate.fetch("level") == "ratchet" && regression
      return "ratchet_opportunity" if gate.fetch("level") == "ratchet" && !full_pass
      return "observe_opportunity" if gate.fetch("level") == "observe" && !full_pass

      nil
    end
    private_class_method :priority_reason_for

    def opportunity_gap_for(gate:, candidate_value:, baseline_value:, full_pass_target:)
      return 1 unless gate.fetch("metric_type") == "score"
      return [full_pass_target.to_f - candidate_value.to_f, 0].max if full_pass_target
      return [baseline_value.to_f - candidate_value.to_f, 0].max if gate.fetch("level") == "ratchet"

      0
    end
    private_class_method :opportunity_gap_for

    def failure_summary_for(gate:, candidate_value:, baseline_value:, threshold_value:, full_pass_target:, validation:, judge:)
      source = gate.fetch("source")

      case source.fetch("kind")
      when "command"
        command = validation.dig("commands", source.fetch("name")) || {}
        first_line(command["stderr"]) || first_line(command["stdout"]) || "#{gate.fetch('title')} did not pass"
      when "judge"
        "Judge score #{judge.fetch('score')} with decision #{judge.fetch('decision')}"
      when "validation"
        candidate_value ? nil : "Validation key #{source.fetch('key')} was false"
      when "score"
        parts = ["score #{candidate_value}"]
        parts << "baseline #{baseline_value}" if gate.fetch("level") == "ratchet"
        parts << "threshold #{threshold_value}" if gate.fetch("level") == "ratchet"
        parts << "target #{full_pass_target}" if full_pass_target
        parts.join(", ")
      end
    end
    private_class_method :failure_summary_for

    def artifacts_for(gate:)
      case gate.dig("source", "kind")
      when "judge"
        ["tmp/judge.md"]
      else
        ["tmp/factory-gates/validation.json"]
      end
    end
    private_class_method :artifacts_for

    def first_line(text)
      text.to_s.lines.map(&:strip).reject(&:empty?).first
    end
    private_class_method :first_line
  end
end
