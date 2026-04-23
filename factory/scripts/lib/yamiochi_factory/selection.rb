# frozen_string_literal: true

module YamiochiFactory
  module Selection
    module_function

    def select_issue(issues)
      issues
        .reject { |issue| issue.key?("pull_request") }
        .reject { |issue| blocked?(issue) }
        .min_by { |issue| priority_tuple(issue) }
    end

    def priority_tuple(issue)
      [milestone_priority(issue), bot_priority(issue), issue.fetch("number")]
    end

    def blocked?(issue)
      labels = issue.fetch("labels", []).map { |label| label.fetch("name").downcase }
      labels.any? { |label| label == "blocked" || label == "factory:blocked" || label == "in-progress" }
    end

    def milestone_priority(issue)
      milestone = issue["milestone"]
      return [1, issue.fetch("number")] unless milestone

      title = milestone.fetch("title", "")
      ordinal = title[/\AM(?<ordinal>\d+):/, :ordinal]&.to_i
      [0, ordinal || 9_999]
    end

    def bot_priority(issue)
      user = issue.fetch("user", {})
      return 1 if user["type"] == "Bot"
      return 1 if user.fetch("login", "").end_with?("[bot]")

      0
    end
  end
end
