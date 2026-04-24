# frozen_string_literal: true

module YamiochiFactory
  module WorkPackets
    PRIORITY = {
      "hard_fail" => 0,
      "ratchet_regression" => 1,
      "ratchet_opportunity" => 2,
      "observe_opportunity" => 3
    }.freeze

    module_function

    def from_state(registry:, state:, state_path:)
      registry.gates.values.filter_map do |gate|
        gate_state = state.dig("gates", gate.fetch("name")) || {}
        packet_for(gate:, gate_state:, state_path:)
      end.sort_by do |packet|
        [
          PRIORITY.fetch(packet.fetch("priority_reason"), 99),
          packet.fetch("selection_priority"),
          -packet.fetch("opportunity_gap").to_f,
          packet.fetch("target_gate")
        ]
      end
    end

    def select_best(registry:, state:, state_path:)
      from_state(registry:, state:, state_path:).first
    end

    def packet_for(gate:, gate_state:, state_path:)
      observed = !gate_state["last_result"].nil?
      snapshot = gate_state["last_result"] || default_snapshot(gate:, gate_state:)
      priority_reason = snapshot["priority_reason"] || default_priority_reason(gate:, snapshot:, observed:)
      return if priority_reason.nil?

      target_gate = gate.fetch("name")
      {
        "type" => "gate_packet",
        "id" => "gate-#{target_gate.tr("_", "-")}-#{priority_reason.tr("_", "-")}",
        "title" => work_title(gate:, priority_reason:),
        "target_gate" => target_gate,
        "gate_level" => gate.fetch("level"),
        "priority_reason" => priority_reason,
        "selection_priority" => gate.fetch("selection_priority"),
        "opportunity_gap" => opportunity_gap(gate:, snapshot:),
        "focus_area" => snapshot["failure_summary"] || default_focus_area(gate:, snapshot:),
        "success_condition" => success_condition(gate:, snapshot:),
        "evidence" => [state_path, *Array(snapshot["artifacts"])].uniq,
        "artifacts" => Array(snapshot["artifacts"]),
        "pull_request_title" => work_title(gate:, priority_reason:),
        "branch_slug" => "gate-#{target_gate.tr("_", "-")}"
      }
    end
    private_class_method :packet_for

    def default_snapshot(gate:, gate_state:)
      {
        "candidate_value" => gate_state.fetch("baseline_value", (gate.fetch("metric_type") == "score") ? 0 : false),
        "baseline_value" => gate_state.fetch("baseline_value", (gate.fetch("metric_type") == "score") ? 0 : nil),
        "threshold_value" => gate_state.fetch("baseline_value", (gate.fetch("metric_type") == "score") ? 0 : nil),
        "full_pass_target" => nil,
        "full_pass" => false,
        "priority_reason" => nil,
        "failure_summary" => nil,
        "artifacts" => []
      }
    end
    private_class_method :default_snapshot

    def default_priority_reason(gate:, snapshot:, observed:)
      return nil if observed && snapshot.fetch("full_pass", false)
      return "hard_fail" if observed && gate.fetch("level") == "hard" && !snapshot.fetch("full_pass", false)
      return "ratchet_regression" if observed && gate.fetch("level") == "ratchet" && snapshot.fetch("candidate_value").to_f < snapshot.fetch("threshold_value").to_f
      return "ratchet_opportunity" if gate.fetch("level") == "ratchet"
      return "observe_opportunity" if gate.fetch("level") == "observe"

      nil
    end
    private_class_method :default_priority_reason

    def work_title(gate:, priority_reason:)
      prefix = case priority_reason
      when "hard_fail"
        "Repair gate"
      when "ratchet_regression"
        "Recover gate"
      when "ratchet_opportunity"
        "Improve gate"
      else
        "Advance gate"
      end
      "#{prefix}: #{gate.fetch("name")}"
    end
    private_class_method :work_title

    def opportunity_gap(gate:, snapshot:)
      return 1 unless gate.fetch("metric_type") == "score"

      target = snapshot["full_pass_target"]
      return [target.to_f - snapshot.fetch("candidate_value").to_f, 0].max if target.is_a?(Numeric)

      0
    end
    private_class_method :opportunity_gap

    def default_focus_area(gate:, snapshot:)
      parts = [gate.fetch("title")]
      parts << "current #{snapshot.fetch("candidate_value")}"
      parts << "baseline #{snapshot["baseline_value"]}" if gate.fetch("level") == "ratchet"
      parts.join("; ")
    end
    private_class_method :default_focus_area

    def success_condition(gate:, snapshot:)
      if gate.fetch("level") == "hard"
        "Make #{gate.fetch("name")} fully passing"
      elsif gate.fetch("level") == "ratchet"
        target = snapshot["full_pass_target"] || "> #{snapshot.fetch("baseline_value", 0)}"
        "Improve #{gate.fetch("name")} toward #{target} without regressing below #{snapshot.fetch("threshold_value", snapshot.fetch("baseline_value", 0))}"
      else
        target = snapshot["full_pass_target"] || "a measurable score improvement"
        "Increase #{gate.fetch("name")} toward #{target}"
      end
    end
    private_class_method :success_condition
  end
end
