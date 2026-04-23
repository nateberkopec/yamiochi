#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "time"
require_relative "lib/yamiochi_factory/github_client"

module YamiochiFactory
  class Autopilot
    def initialize(repo_root:, options:)
      @repo_root = repo_root
      @options = options
      @github = GitHubClient.new
      @baseline_file = options.fetch(:baseline_file)
      @worktree_root = options.fetch(:worktree_root)
      FileUtils.mkdir_p(@worktree_root)
      FileUtils.mkdir_p(File.dirname(@baseline_file))
    end

    def run
      completed = 0

      loop do
        issue = select_issue
        break unless issue

        completed += 1
        process_issue(issue)
        break if options.fetch(:once)
        break if options.fetch(:max_issues) && completed >= options.fetch(:max_issues)
      end
    end

    private

    attr_reader :repo_root, :options, :github, :baseline_file, :worktree_root

    def process_issue(issue)
      issue_number = issue.fetch("number")
      worktree_dir = create_worktree(issue)

      run_id = run_implement_issue(worktree_dir, issue_number)
      inspect_payload = inspect_run(run_id)
      run_branch = inspect_payload.dig(0, "start_record", "run_branch")
      raise "Fabro run #{run_id} did not record run_branch" if run_branch.to_s.empty?

      create_pull_request(run_id)
      pull_request = pull_request_record(run_id)
      pull_request_number = pull_request.fetch("number")
      wait_for_checks(pull_request_number)
      merge_pull_request(run_id)
      close_issue(issue_number, pull_request_number)
      promote_baseline(worktree_dir)
    ensure
      cleanup_worktree(worktree_dir, keep: $ERROR_INFO)
    end

    def select_issue
      stdout, = capture!(%w[ruby factory/scripts/select_work.rb], chdir: repo_root)
      return nil if stdout.strip.empty?

      JSON.parse(stdout)
    end

    def create_worktree(issue)
      slug = issue.fetch("title").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40]
      worktree_dir = File.join(worktree_root, "issue-#{issue.fetch("number")}-#{slug}-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}")

      capture!(%w[git fetch origin], chdir: repo_root)
      capture!(["git", "worktree", "add", "--detach", worktree_dir, "origin/main"], chdir: repo_root)
      worktree_dir
    end

    def run_implement_issue(worktree_dir, issue_number)
      stdout, = capture!(
        ["fabro", "run", options.fetch(:workflow), "--goal", issue_number.to_s, "--auto-approve", "--json"],
        chdir: worktree_dir,
        env: fabro_env
      )
      run_id = JSON.parse(stdout).fetch("run_id")
      wait_status = JSON.parse(capture!(["fabro", "wait", run_id, "--json"], chdir: worktree_dir, env: fabro_env).first)
      raise "Fabro run #{run_id} finished with status #{wait_status.fetch("status")}" unless wait_status.fetch("status") == "succeeded"

      run_id
    end

    def inspect_run(run_id)
      JSON.parse(capture!(["fabro", "inspect", run_id, "--json"], chdir: repo_root, env: fabro_env).first)
    end

    def create_pull_request(run_id)
      capture!(["fabro", "pr", "create", run_id, "--json"], chdir: repo_root, env: fabro_env)
    end

    def pull_request_record(run_id)
      JSON.parse(capture!(["fabro", "pr", "view", run_id, "--json"], chdir: repo_root, env: fabro_env).first)
    end

    def wait_for_checks(pull_request_number)
      capture!(["gh", "pr", "checks", pull_request_number.to_s, "--watch", "--fail-fast", "-R", github.repository], chdir: repo_root)
    end

    def merge_pull_request(run_id)
      capture!(["fabro", "pr", "merge", run_id, "--method", "squash", "--json"], chdir: repo_root, env: fabro_env)
    end

    def close_issue(issue_number, pull_request_number)
      capture!(["gh", "issue", "close", issue_number.to_s, "-R", github.repository, "-c", "Completed autonomously in PR ##{pull_request_number}."], chdir: repo_root)
    end

    def promote_baseline(worktree_dir)
      capture!(
        ["ruby", "factory/scripts/promote_merge_gate_baseline.rb", "tmp/factory-gates/report.json", baseline_file],
        chdir: worktree_dir
      )
    end

    def cleanup_worktree(worktree_dir, keep: false)
      return if worktree_dir.to_s.empty?
      return if keep && !options.fetch(:cleanup_failed)

      capture!(["git", "worktree", "remove", "--force", worktree_dir], chdir: repo_root, allow_failure: true)
    end

    def fabro_env
      { "FABRO_SERVER" => options.fetch(:fabro_server) }
    end

    def capture!(command, chdir:, env: {}, allow_failure: false)
      stdout, stderr, status = Open3.capture3(env, *command, chdir:)
      return [stdout, stderr] if status.success? || allow_failure

      raise <<~ERROR
        Command failed (#{status.exitstatus}): #{Shellwords.join(command)}
        cwd: #{chdir}
        stdout:
        #{stdout}
        stderr:
        #{stderr}
      ERROR
    end
  end
end

repo_root = Dir.pwd
options = {
  once: false,
  max_issues: nil,
  cleanup_failed: false,
  workflow: ".fabro/workflows/implement-issue/workflow.toml",
  fabro_server: ENV["FABRO_SERVER"] || "http://127.0.0.1:32276",
  worktree_root: ENV["YAMIOCHI_FACTORY_WORKTREE_ROOT"] || "/tmp/yamiochi-factory-worktrees",
  baseline_file: ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "/tmp/yamiochi-factory-baselines/merge-gates.json"
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby factory/scripts/autopilot.rb [options]"

  parser.on("--once", "Process only one issue") { options[:once] = true }
  parser.on("--max-issues N", Integer, "Process at most N issues") { |value| options[:max_issues] = value }
  parser.on("--cleanup-failed", "Remove failed worktrees too") { options[:cleanup_failed] = true }
  parser.on("--workflow PATH", "Fabro workflow to run") { |value| options[:workflow] = value }
  parser.on("--fabro-server URL", "Fabro server URL") { |value| options[:fabro_server] = value }
  parser.on("--worktree-root PATH", "Directory for disposable worktrees") { |value| options[:worktree_root] = value }
  parser.on("--baseline-file PATH", "Path to the persistent merge-gate baseline file") { |value| options[:baseline_file] = value }
end.parse!

options[:once] = true if options[:max_issues] == 1
YamiochiFactory::Autopilot.new(repo_root:, options:).run
