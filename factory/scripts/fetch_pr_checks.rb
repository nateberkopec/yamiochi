#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"

pull_request_number = ARGV.fetch(0) do
  warn "Usage: ruby factory/scripts/fetch_pr_checks.rb PR_NUMBER [OUTPUT_PATH]"
  exit 1
end
output_path = ARGV[1]
repository = ENV["GITHUB_REPOSITORY"] || ENV["YAMIOCHI_FACTORY_REPOSITORY"]

command = %W[gh pr checks #{pull_request_number} --json bucket,completedAt,description,event,link,name,startedAt,state,workflow]
command += ["-R", repository] if repository && !repository.empty?
stdout, stderr, status = Open3.capture3(*command)
abort(stderr) unless status.success?

checks = JSON.parse(stdout)
payload = JSON.pretty_generate(checks)
File.write(output_path, payload) if output_path
puts payload
