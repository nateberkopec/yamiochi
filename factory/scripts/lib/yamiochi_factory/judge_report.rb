# frozen_string_literal: true

module YamiochiFactory
  module JudgeReport
    module_function

    def parse(text)
      score = text[/^score:\s*([0-9]+(?:\.[0-9]+)?)$/i, 1]
      decision = text[/^decision:\s*(pass|revise)$/i, 1]

      raise ArgumentError, "Judge report is missing a score" unless score
      raise ArgumentError, "Judge report is missing a decision" unless decision

      {
        "score" => score.to_f,
        "decision" => decision.downcase,
        "raw" => text
      }
    end
  end
end
