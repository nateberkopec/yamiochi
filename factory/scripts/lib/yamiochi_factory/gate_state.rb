# frozen_string_literal: true

require "json"
require "time"

module YamiochiFactory
  module GateState
    HISTORY_LIMIT = 20

    module_function

    def default_state(registry:)
      {
        "version" => 1,
        "updated_at" => nil,
        "gates" => registry.gates.each_with_object({}) do |(name, gate), state|
          state[name] = default_gate_state(gate)
        end
      }
    end

    def load(path, registry:)
      return default_state(registry:) unless path && File.exist?(path)

      raw = JSON.parse(File.read(path))
      normalize(raw, registry:)
    rescue JSON::ParserError
      default_state(registry:)
    end

    def normalize(raw_state, registry:)
      state = default_state(registry:)
      raw_gates = raw_state.fetch("gates", {})

      registry.each do |name, gate|
        persisted = raw_gates.fetch(name, {})
        state["gates"][name] = default_gate_state(gate).merge(
          "baseline_value" => persisted["baseline_value"].nil? ? default_baseline_value(gate) : persisted["baseline_value"],
          "last_result" => persisted["last_result"],
          "history" => Array(persisted["history"]).last(HISTORY_LIMIT),
          "green_streak" => persisted.fetch("green_streak", 0).to_i,
          "full_pass_streak" => persisted.fetch("full_pass_streak", 0).to_i,
          "level" => gate.fetch("level")
        )
      end

      state["updated_at"] = raw_state["updated_at"]
      state
    end

    def promote(state:, report:, registry:)
      promoted = normalize(state, registry:)
      timestamp = report.fetch("generated_at", Time.now.utc.iso8601)

      registry.each do |name, gate|
        gate_report = report.fetch("gates").fetch(name)
        gate_state = promoted.fetch("gates").fetch(name)
        gate_state["level"] = gate.fetch("level")
        gate_state["baseline_value"] = promoted_baseline(gate:, gate_state:, gate_report:)
        gate_state["green_streak"] = gate_report.fetch("level_pass") ? gate_state.fetch("green_streak", 0) + 1 : 0
        gate_state["full_pass_streak"] = gate_report.fetch("full_pass") ? gate_state.fetch("full_pass_streak", 0) + 1 : 0

        snapshot = result_snapshot(gate_report, timestamp:)
        gate_state["last_result"] = snapshot
        gate_state["history"] = Array(gate_state["history"]).push(snapshot).last(HISTORY_LIMIT)
      end

      promoted["updated_at"] = timestamp
      promoted
    end

    def default_baseline_value(gate)
      gate.fetch("metric_type") == "score" ? 0 : nil
    end

    def default_gate_state(gate)
      {
        "level" => gate.fetch("level"),
        "baseline_value" => default_baseline_value(gate),
        "last_result" => nil,
        "history" => [],
        "green_streak" => 0,
        "full_pass_streak" => 0
      }
    end
    private_class_method :default_gate_state, :default_baseline_value

    def promoted_baseline(gate:, gate_state:, gate_report:)
      return gate_state.fetch("baseline_value", default_baseline_value(gate)) unless gate.fetch("level") == "ratchet"
      return gate_state.fetch("baseline_value", default_baseline_value(gate)) unless gate.fetch("metric_type") == "score"

      current_baseline = gate_state.fetch("baseline_value", default_baseline_value(gate)).to_f
      candidate_value = gate_report.fetch("candidate_value").to_f
      [current_baseline, candidate_value].max
    end
    private_class_method :promoted_baseline

    def result_snapshot(gate_report, timestamp:)
      {
        "checked_at" => timestamp,
        "level" => gate_report.fetch("level"),
        "level_pass" => gate_report.fetch("level_pass"),
        "full_pass" => gate_report.fetch("full_pass"),
        "full_pass_known" => gate_report.fetch("full_pass_known"),
        "candidate_value" => gate_report.fetch("candidate_value"),
        "baseline_value" => gate_report["baseline_value"],
        "threshold_value" => gate_report["threshold_value"],
        "full_pass_target" => gate_report["full_pass_target"],
        "regression" => gate_report.fetch("regression"),
        "priority_reason" => gate_report["priority_reason"],
        "failure_summary" => gate_report["failure_summary"],
        "artifacts" => gate_report.fetch("artifacts")
      }
    end
    private_class_method :result_snapshot
  end
end
