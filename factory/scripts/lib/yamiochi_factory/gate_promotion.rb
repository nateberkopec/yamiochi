# frozen_string_literal: true

module YamiochiFactory
  module GatePromotion
    LEVELS = %w[observe ratchet hard].freeze

    module_function

    def next_level(level)
      index = LEVELS.index(level)
      return if index.nil? || index >= LEVELS.length - 1

      LEVELS[index + 1]
    end

    def eligible_promotions(registry:, state:)
      registry.gates.values.filter_map do |gate|
        target_level = next_level(gate.fetch("level"))
        next if target_level.nil?

        gate_state = state.dig("gates", gate.fetch("name")) || {}
        required_streak = gate.dig("promotion", "min_full_pass_streak").to_i
        required_streak = 3 if required_streak <= 0

        next unless gate_state.fetch("full_pass_streak", 0) >= required_streak
        next unless gate_state.dig("last_result", "full_pass")

        {
          "type" => "gate_promotion",
          "id" => "promote-#{gate.fetch("name").tr("_", "-")}-to-#{target_level}",
          "target_gate" => gate.fetch("name"),
          "current_level" => gate.fetch("level"),
          "next_level" => target_level,
          "selection_priority" => gate.fetch("selection_priority"),
          "evidence" => {
            "full_pass_streak" => gate_state.fetch("full_pass_streak", 0),
            "required_full_pass_streak" => required_streak,
            "last_result" => gate_state["last_result"]
          },
          "title" => "Promote gate: #{gate.fetch("name")} #{gate.fetch("level")} → #{target_level}",
          "pull_request_title" => "Promote gate: #{gate.fetch("name")} #{gate.fetch("level")} → #{target_level}",
          "branch_slug" => "promote-#{gate.fetch("name").tr("_", "-")}-to-#{target_level}"
        }
      end.sort_by { |proposal| [proposal.fetch("selection_priority"), proposal.fetch("target_gate")] }
    end

    def validate_transition(base_registry:, candidate_registry:, state:)
      errors = []
      promotions = []

      if base_registry.gates.keys.sort != candidate_registry.gates.keys.sort
        errors << "Gate registry may not add, remove, or rename gates in a promotion diff"
        return result(errors:, promotions:)
      end

      base_registry.gates.each do |name, base_gate|
        candidate_gate = candidate_registry.gate(name)

        unless same_except_level?(base_gate, candidate_gate)
          errors << "Gate #{name} changes fields other than level"
          next
        end

        next if base_gate.fetch("level") == candidate_gate.fetch("level")

        expected = next_level(base_gate.fetch("level"))
        unless candidate_gate.fetch("level") == expected
          errors << "Gate #{name} must move only one step upward (expected #{expected.inspect})"
          next
        end

        gate_state = state.dig("gates", name) || {}
        required_streak = base_gate.dig("promotion", "min_full_pass_streak").to_i
        required_streak = 3 if required_streak <= 0

        unless gate_state.fetch("full_pass_streak", 0) >= required_streak && gate_state.dig("last_result", "full_pass")
          errors << "Gate #{name} lacks promotion evidence (needs #{required_streak} consecutive full passes)"
          next
        end

        promotions << {
          "target_gate" => name,
          "from" => base_gate.fetch("level"),
          "to" => candidate_gate.fetch("level"),
          "full_pass_streak" => gate_state.fetch("full_pass_streak", 0)
        }
      end

      result(errors:, promotions:)
    end

    def to_work_item(proposal)
      proposal.merge(
        "success_condition" => "Update factory/gates.yml so #{proposal.fetch("target_gate")} moves from #{proposal.fetch("current_level")} to #{proposal.fetch("next_level")} and passes promotion checks",
        "focus_area" => "Only change factory/gates.yml. Do not weaken any other gate field.",
        "artifacts" => ["factory/gates.yml"]
      )
    end

    def result(errors:, promotions:)
      {
        "pass" => errors.empty?,
        "errors" => errors,
        "promotions" => promotions
      }
    end
    private_class_method :result

    def same_except_level?(base_gate, candidate_gate)
      strip_level(base_gate) == strip_level(candidate_gate)
    end
    private_class_method :same_except_level?

    def strip_level(gate)
      gate.except("level")
    end
    private_class_method :strip_level
  end
end
