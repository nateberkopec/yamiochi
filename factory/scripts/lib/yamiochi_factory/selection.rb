# frozen_string_literal: true

module YamiochiFactory
  module Selection
    module_function

    def select_issue(issues)
      issues
        .reject { |issue| issue.key?("pull_request") }
        .reject { |issue| blocked?(issue) }
        .select { |issue| factory_managed?(issue) }
        .min_by { |issue| priority_tuple(issue) }
    end

    def priority_tuple(issue)
      [milestone_priority(issue), bot_priority(issue), issue.fetch("number")]
    end

    def blocked?(issue)
      labels = issue.fetch("labels", []).map { |label| label.fetch("name").downcase }
      labels.any? { |label| label == "blocked" || label == "factory:blocked" || label == "in-progress" }
    end

    def factory_managed?(issue)
      milestone = issue["milestone"]
      milestone && milestone.fetch("title", "").match?(/\AM\d+:/)
    end

    def milestone_priority(issue)
      title = issue.fetch("milestone").fetch("title", "")
      ordinal = title[/\AM(?<ordinal>\d+):/, :ordinal]&.to_i
      [ordinal || 9_999, issue.fetch("number")]
    end

    def bot_priority(issue)
      user = issue.fetch("user", {})
      return 1 if user["type"] == "Bot"
      return 1 if user.fetch("login", "").end_with?("[bot]")

      0
    end
  end
end
