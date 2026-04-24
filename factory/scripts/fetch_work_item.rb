#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/github_client"

goal = ARGV.fetch(0) do
  warn "Usage: ruby factory/scripts/fetch_work_item.rb GOAL [OUTPUT_PATH]"
  exit 1
end
output_path = ARGV[1]

payload = case goal
when /\Afile:(.+)\z/
  JSON.parse(File.read(Regexp.last_match(1)))
when /\A\d+\z/
  issue = YamiochiFactory::GitHubClient.new.issue(goal)
  {
    "type" => "issue",
    "id" => "issue-#{issue.fetch("number")}",
    "number" => issue.fetch("number"),
    "title" => issue.fetch("title"),
    "issue" => issue,
    "focus_area" => issue.fetch("body", ""),
    "success_condition" => "Address GitHub issue ##{issue.fetch("number")}",
    "pull_request_title" => issue.fetch("title"),
    "branch_slug" => "issue-#{issue.fetch("number")}"
  }
else
  JSON.parse(goal)
end

json = JSON.pretty_generate(payload)
File.write(output_path, json) if output_path
puts json
