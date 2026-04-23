#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "lib/yamiochi_factory/github_client"

pull_request_number = ARGV.fetch(0) do
  warn "Usage: ruby factory/scripts/fetch_pull_request.rb PR_NUMBER [OUTPUT_PATH]"
  exit 1
end
output_path = ARGV[1]

pull_request = YamiochiFactory::GitHubClient.new.pull_request(pull_request_number)
payload = JSON.pretty_generate(pull_request)

if output_path
  File.write(output_path, payload)
end

puts payload
