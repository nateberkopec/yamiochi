# frozen_string_literal: true

require_relative "gate_evaluator"
require_relative "gate_registry"
require_relative "gate_state"

module YamiochiFactory
  module MergeGates
    module_function

    def default_baseline(registry: GateRegistry.load)
      GateState.default_state(registry:)
    end

    def evaluate(validation:, judge:, baseline: default_baseline, registry: GateRegistry.load)
      state = GateState.normalize(baseline, registry:)
      GateEvaluator.evaluate(registry:, validation:, judge:, state:)
    end

    def promote(baseline:, report:, registry: GateRegistry.load)
      state = GateState.normalize(baseline, registry:)
      GateState.promote(state:, report:, registry:)
    end
  end
end
