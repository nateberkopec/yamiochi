#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/github_client"

issue_number = ARGV.fetch(0) do
  warn "Usage: ruby factory/scripts/fetch_issue.rb ISSUE_NUMBER [OUTPUT_PATH]"
  exit 1
end
output_path = ARGV[1]

issue = YamiochiFactory::GitHubClient.new.issue(issue_number)
payload = JSON.pretty_generate(issue)

if output_path
  File.write(output_path, payload)
end

puts payload
