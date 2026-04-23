#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/github_client"
require_relative "lib/yamiochi_factory/selection"

output_path = ARGV[0]
issues = YamiochiFactory::GitHubClient.new.issues
issue = YamiochiFactory::Selection.select_issue(issues)

if issue.nil?
  warn "No selectable open issues found."
  exit 0
end

payload = issue.merge(
  "selection_reason" => {
    "milestone_priority" => YamiochiFactory::Selection.milestone_priority(issue),
    "bot_priority" => YamiochiFactory::Selection.bot_priority(issue)
  }
)
json = JSON.pretty_generate(payload)

if output_path
  File.write(output_path, json)
end

puts json
