#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/yamiochi_factory/github_client"
require_relative "lib/yamiochi_factory/spec_queue"

spec_text = File.read("SPEC.md")
github = YamiochiFactory::GitHubClient.new
milestones = github.milestones.each_with_object({}) do |milestone, index|
  index[milestone.fetch("title")] = milestone.fetch("number")
end
existing_issues = github.issues(state: "all")
existing_keys = existing_issues.each_with_object({}) do |issue, index|
  body = issue.fetch("body", nil).to_s
  key = body[/<!-- factory-key:(.+?) -->/, 1]
  index[key] = issue if key
end

created = []
updated = []

YamiochiFactory::SpecQueue.desired_issues(spec_text).each do |desired_issue|
  milestone_title = desired_issue.fetch("milestone")
  milestone_number = milestones.fetch(milestone_title)
  body = <<~MARKDOWN
    <!-- factory-key:#{desired_issue.fetch("key")} -->
    <!-- factory-section:#{desired_issue.fetch("section")} -->

    #{desired_issue.fetch("body")}
  MARKDOWN

  existing_issue = existing_keys[desired_issue.fetch("key")]
  if existing_issue
    next if existing_issue.fetch("title") == desired_issue.fetch("title") &&
      existing_issue.fetch("milestone", {}).fetch("number") == milestone_number &&
      existing_issue.fetch("body", nil).to_s == body

    updated << github.update_issue(
      existing_issue.fetch("number"),
      title: desired_issue.fetch("title"),
      body:,
      milestone: milestone_number
    )
    next
  end

  created << github.create_issue(
    title: desired_issue.fetch("title"),
    body:,
    milestone: milestone_number
  )
end

puts({
  created_count: created.size,
  created_numbers: created.map { |issue| issue.fetch("number") },
  updated_count: updated.size,
  updated_numbers: updated.map { |issue| issue.fetch("number") }
})
