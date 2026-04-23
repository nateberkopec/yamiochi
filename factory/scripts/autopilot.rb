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
        sync_queue
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
      worktree_dir = create_mainline_worktree(issue)
      run_id = run_workflow(worktree_dir, options.fetch(:workflow), issue_number)
      run_branch = require_run_branch(run_id)
      pull_request = create_or_fetch_pull_request(run_id, issue, worktree_dir, run_branch)

      stabilize_pull_request(run_id:, pull_request:, issue_number:)
      promote_baseline(worktree_dir)
    ensure
      cleanup_worktree(worktree_dir, keep: $ERROR_INFO)
    end

    def sync_queue
      capture!(%w[ruby factory/scripts/sync_spec_queue.rb], chdir: repo_root, allow_failure: true)
    end

    def select_issue
      stdout, = capture!(%w[ruby factory/scripts/select_work.rb], chdir: repo_root)
      return nil if stdout.strip.empty?

      JSON.parse(stdout)
    end

    def stabilize_pull_request(run_id:, pull_request:, issue_number:)
      repair_attempt = 0

      loop do
        checks = wait_for_checks(pull_request.fetch("number"))
        if checks.fetch(:status) == :success
          merge_pull_request(run_id, pull_request)
          close_issue(issue_number, pull_request.fetch("number"))
          return
        end

        repair_attempt += 1
        if repair_attempt > options.fetch(:max_repairs)
          raise "PR ##{pull_request.fetch("number")} failed after #{repair_attempt - 1} repair attempts"
        end

        repair_pull_request(pull_request.fetch("number"), repair_attempt)
      end
    end

    def create_mainline_worktree(issue)
      slug = issue.fetch("title").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40]
      create_worktree(
        "issue-#{issue.fetch("number")}-#{slug}-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}",
        "origin/main"
      )
    end

    def create_repair_worktree(pull_request_number, branch_name)
      slug = branch_name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40]
      create_worktree(
        "repair-pr-#{pull_request_number}-#{slug}-#{Time.now.utc.strftime("%Y%m%d%H%M%S")}",
        "origin/#{branch_name}"
      )
    end

    def create_worktree(name, ref)
      worktree_dir = File.join(worktree_root, name)
      capture!(%w[git fetch origin], chdir: repo_root)
      capture!(["git", "worktree", "add", "--detach", worktree_dir, ref], chdir: repo_root)
      worktree_dir
    end

    def run_workflow(worktree_dir, workflow, goal)
      stdout, = capture!(
        ["fabro", "run", workflow, "--goal", goal.to_s, "--auto-approve", "--detach", "--json"],
        chdir: worktree_dir,
        env: fabro_env
      )
      run_id = JSON.parse(stdout).fetch("run_id")
      wait_status = JSON.parse(capture!(["fabro", "wait", run_id, "--json"], chdir: worktree_dir, env: fabro_env).first)
      raise "Fabro run #{run_id} finished with status #{wait_status.fetch("status")}" unless wait_status.fetch("status") == "succeeded"

      run_id
    end

    def require_run_branch(run_id)
      run_branch = inspect_run(run_id).dig(0, "start_record", "run_branch")
      raise "Fabro run #{run_id} did not record run_branch" if run_branch.to_s.empty?

      run_branch
    end

    def inspect_run(run_id)
      JSON.parse(capture!(["fabro", "inspect", run_id, "--json"], chdir: repo_root, env: fabro_env).first)
    end

    def create_or_fetch_pull_request(run_id, issue, worktree_dir, run_branch)
      create_pull_request(run_id)
      pull_request_record(run_id)
    rescue StandardError
      manual_create_pull_request(issue, worktree_dir, run_branch)
    end

    def create_pull_request(run_id)
      capture!("fabro pr create #{run_id} --json", chdir: repo_root, env: fabro_env, shell: true)
    end

    def pull_request_record(run_id)
      JSON.parse(capture!("fabro pr view #{run_id} --json", chdir: repo_root, env: fabro_env, shell: true).first)
    end

    def manual_create_pull_request(issue, worktree_dir, branch_name)
      commit_if_needed(worktree_dir, "Implement ##{issue.fetch("number")}: #{issue.fetch("title")}")
      capture!(["git", "push", "-u", "origin", "HEAD:#{branch_name}"], chdir: worktree_dir)
      capture!(
        [
          "gh", "pr", "create", "-R", github.repository,
          "--head", branch_name,
          "--base", "main",
          "--title", issue.fetch("title"),
          "--body", ""
        ],
        chdir: worktree_dir
      )
      view_pull_request(branch_name)
    end

    def merge_pull_request(run_id, pull_request)
      capture!("fabro pr merge #{run_id} --method squash --json", chdir: repo_root, env: fabro_env, shell: true)
    rescue StandardError
      capture!(
        ["gh", "pr", "merge", pull_request.fetch("number").to_s, "--squash", "--delete-branch", "-R", github.repository],
        chdir: repo_root
      )
    end

    def repair_pull_request(pull_request_number, attempt)
      pull_request = view_pull_request(pull_request_number.to_s)
      branch_name = pull_request.fetch("headRefName")
      worktree_dir = create_repair_worktree(pull_request_number, branch_name)
      run_workflow(worktree_dir, options.fetch(:repair_workflow), pull_request_number)
      commit_if_needed(worktree_dir, "Repair PR ##{pull_request_number} after CI failure (attempt #{attempt})")
      capture!(["git", "push", "origin", "HEAD:#{branch_name}"], chdir: worktree_dir)
    ensure
      cleanup_worktree(worktree_dir, keep: $ERROR_INFO)
    end

    def wait_for_checks(pull_request_number)
      loop do
        checks = JSON.parse(
          capture!(
            [
              "gh", "pr", "checks", pull_request_number.to_s,
              "--json", "bucket,completedAt,description,event,link,name,startedAt,state,workflow",
              "-R", github.repository
            ],
            chdir: repo_root
          ).first
        )

        buckets = checks.map { |check| check.fetch("bucket") }
        return { status: :success, checks: } if buckets.all? { |bucket| %w[pass skipping].include?(bucket) }
        return { status: :fail, checks: } if buckets.include?("fail")

        sleep options.fetch(:poll_interval)
      end
    end

    def view_pull_request(number_or_branch)
      JSON.parse(
        capture!(
          [
            "gh", "pr", "view", number_or_branch.to_s,
            "-R", github.repository,
            "--json", "number,title,url,headRefName,baseRefName,state"
          ],
          chdir: repo_root
        ).first
      )
    end

    def close_issue(issue_number, pull_request_number)
      capture!(
        [
          "gh", "issue", "close", issue_number.to_s,
          "-R", github.repository,
          "-c", "Completed autonomously in PR ##{pull_request_number}."
        ],
        chdir: repo_root
      )
    end

    def promote_baseline(worktree_dir)
      capture!(
        ["ruby", "factory/scripts/promote_merge_gate_baseline.rb", "tmp/factory-gates/report.json", baseline_file],
        chdir: worktree_dir
      )
    end

    def commit_if_needed(worktree_dir, message)
      stdout, = capture!(["git", "status", "--short"], chdir: worktree_dir)
      return if stdout.strip.empty?

      capture!(%w[git add -A], chdir: worktree_dir)
      capture!(
        [
          "git", "-c", "user.name=yamiochi-factory", "-c", "user.email=yamiochi-factory@speedshop.co",
          "commit", "--no-gpg-sign", "-m", message
        ],
        chdir: worktree_dir
      )
    end

    def cleanup_worktree(worktree_dir, keep: false)
      return if worktree_dir.to_s.empty?
      return if keep && !options.fetch(:cleanup_failed)

      capture!(["git", "worktree", "remove", "--force", worktree_dir], chdir: repo_root, allow_failure: true)
    end

    def fabro_env
      {
        "FABRO_SERVER" => options.fetch(:fabro_server),
        "FABRO_DEV_TOKEN" => ENV.fetch("FABRO_DEV_TOKEN", "")
      }
    end

    def capture!(command, chdir:, env: {}, allow_failure: false, shell: false)
      stdout, stderr, status = if shell
        Open3.capture3(env, "bash", "-lc", command, chdir:)
      else
        Open3.capture3(env, *command, chdir:)
      end
      return [stdout, stderr] if status.success? || allow_failure

      raise <<~ERROR
        Command failed (#{status.exitstatus}): #{shell ? command : Shellwords.join(command)}
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
  max_repairs: Integer(ENV.fetch("YAMIOCHI_FACTORY_MAX_REPAIRS", "3")),
  poll_interval: Integer(ENV.fetch("YAMIOCHI_FACTORY_POLL_INTERVAL", "15")),
  workflow: ".fabro/workflows/implement-issue/workflow.toml",
  repair_workflow: ".fabro/workflows/repair-pr/workflow.toml",
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
  parser.on("--repair-workflow PATH", "Fabro repair workflow to run") { |value| options[:repair_workflow] = value }
  parser.on("--fabro-server URL", "Fabro server URL") { |value| options[:fabro_server] = value }
  parser.on("--worktree-root PATH", "Directory for disposable worktrees") { |value| options[:worktree_root] = value }
  parser.on("--baseline-file PATH", "Path to the persistent merge-gate baseline file") { |value| options[:baseline_file] = value }
end.parse!

options[:once] = true if options[:max_issues] == 1
YamiochiFactory::Autopilot.new(repo_root:, options:).run
