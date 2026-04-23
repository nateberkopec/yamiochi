#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "time"
require_relative "lib/yamiochi_factory/gate_promotion"
require_relative "lib/yamiochi_factory/gate_registry"
require_relative "lib/yamiochi_factory/gate_state"
require_relative "lib/yamiochi_factory/github_client"
require_relative "lib/yamiochi_factory/selection"
require_relative "lib/yamiochi_factory/work_packets"

module YamiochiFactory
  class Autopilot
    FACTORY_BRANCH_PREFIXES = %w[issue- gate- promote-].freeze

    def initialize(repo_root:, options:)
      @repo_root = repo_root
      @options = options
      @github = GitHubClient.new
      @baseline_file = options.fetch(:baseline_file)
      @gate_registry_path = options.fetch(:gate_registry_path)
      @worktree_root = options.fetch(:worktree_root)
      @attempts_file = options.fetch(:attempts_file)
      FileUtils.mkdir_p(@worktree_root)
      FileUtils.mkdir_p(File.dirname(@baseline_file))
      FileUtils.mkdir_p(File.dirname(@attempts_file))
      ensure_git_push_auth!
    end

    def run
      completed = 0

      loop do
        sync_queue

        completed += 1
        work_item = nil
        pull_request = nil

        begin
          if (pull_request = select_pull_request)
            resume_pull_request(pull_request)
            clear_work_failure(pull_request.fetch("issue_number") ? issue_failure_key(pull_request.fetch("issue_number")) : nil)
          else
            work_item = select_work_item
            break unless work_item

            process_work_item(work_item)
            clear_work_failure(work_failure_key(work_item))
          end
        rescue StandardError => e
          failure_key = if work_item
            work_failure_key(work_item)
          elsif pull_request&.fetch("issue_number", nil)
            issue_failure_key(pull_request.fetch("issue_number"))
          end
          record_work_failure(failure_key, e) if failure_key
          warn e.full_message
        end
        break if options.fetch(:once)
        break if options.fetch(:max_issues) && completed >= options.fetch(:max_issues)
      end
    end

    private

    attr_reader :repo_root, :options, :github, :baseline_file, :gate_registry_path, :worktree_root, :attempts_file

    def process_work_item(work_item)
      case work_item.fetch("type")
      when "issue", "gate_packet"
        process_candidate_work_item(work_item)
      when "gate_promotion"
        process_promotion_work_item(work_item)
      else
        raise "Unknown work item type #{work_item.fetch('type').inspect}"
      end
    end

    def process_candidate_work_item(work_item)
      worktree = create_mainline_worktree(work_item)
      worktree_dir = worktree.fetch(:dir)
      goal = workflow_goal_for(worktree_dir, work_item)
      run_id = run_workflow_with_retries(worktree_dir, options.fetch(:workflow), goal)
      fabro_run_branch = recorded_run_branch(run_id)
      run_branch = fabro_run_branch || worktree.fetch(:branch_name)
      pull_request = create_or_fetch_pull_request(
        run_id,
        work_item,
        worktree_dir,
        run_branch,
        fabro_run_branch:
      )

      stabilize_pull_request(run_id:, pull_request:, issue_number: work_item["number"])
      promote_baseline(worktree_dir)
    ensure
      cleanup_worktree(worktree_dir, keep: $ERROR_INFO)
    end

    def process_promotion_work_item(work_item)
      worktree = create_mainline_worktree(work_item)
      worktree_dir = worktree.fetch(:dir)
      goal = workflow_goal_for(worktree_dir, work_item)
      run_id = run_workflow_with_retries(worktree_dir, options.fetch(:promotion_workflow), goal)
      run_branch = recorded_run_branch(run_id) || worktree.fetch(:branch_name)
      pull_request = manual_create_pull_request(work_item, worktree_dir, run_branch)
      stabilize_pull_request(run_id: nil, pull_request:, issue_number: nil)
    ensure
      cleanup_worktree(worktree_dir, keep: $ERROR_INFO)
    end

    def sync_queue
      capture!(%w[ruby factory/scripts/sync_spec_queue.rb], chdir: repo_root, allow_failure: true)
    end

    def select_pull_request
      pull_requests = JSON.parse(
        capture!(
          [
            "gh", "pr", "list",
            "-R", github.repository,
            "--state", "open",
            "--json", "number,title,url,headRefName,baseRefName,state,createdAt"
          ],
          chdir: repo_root
        ).first
      )

      pull_requests
        .select { |pull_request| factory_branch?(pull_request.fetch("headRefName", "")) }
        .map do |pull_request|
          issue_number = issue_number_from_branch(pull_request.fetch("headRefName", ""))
          pull_request.merge("issue_number" => issue_number)
        end
        .min_by { |pull_request| [pull_request.fetch("createdAt"), pull_request.fetch("number")] }
    end

    def select_work_item
      registry = GateRegistry.load(gate_registry_path)
      state = GateState.load(baseline_file, registry:)

      packet = WorkPackets.from_state(registry:, state:, state_path: baseline_file)
        .reject { |item| suppressed_work?(work_failure_key(item)) }
        .first
      return packet if packet

      promotion = GatePromotion.eligible_promotions(registry:, state:)
        .map { |proposal| GatePromotion.to_work_item(proposal) }
        .reject { |item| suppressed_work?(work_failure_key(item)) }
        .first
      return promotion if promotion

      issue = select_issue
      return unless issue

      issue.merge(
        "type" => "issue",
        "id" => issue_failure_key(issue.fetch("number")),
        "pull_request_title" => issue.fetch("title"),
        "branch_slug" => "issue-#{issue.fetch('number')}"
      )
    end

    def select_issue
      issues = github.issues
      available_issues = issues.reject { |issue| suppressed_work?(issue_failure_key(issue.fetch("number"))) }
      Selection.select_issue(available_issues)
    end

    def resume_pull_request(pull_request)
      stabilize_pull_request(
        run_id: nil,
        pull_request: pull_request,
        issue_number: pull_request.fetch("issue_number")
      )
    end

    def stabilize_pull_request(run_id:, pull_request:, issue_number:)
      repair_attempt = 0

      loop do
        checks = wait_for_checks(pull_request.fetch("number"))
        if checks.fetch(:status) == :success
          merge_pull_request(run_id, pull_request)
          close_issue(issue_number, pull_request.fetch("number")) if issue_number
          return
        end

        repair_attempt += 1
        if repair_attempt > options.fetch(:max_repairs)
          raise "PR ##{pull_request.fetch('number')} failed after #{repair_attempt - 1} repair attempts"
        end

        repair_pull_request(pull_request.fetch("number"), repair_attempt)
      end
    end

    def create_mainline_worktree(work_item)
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      branch_name = branch_name_for(work_item, timestamp:)

      {
        dir: create_clone(branch_name, branch_name:, start_point: "origin/main"),
        branch_name:
      }
    end

    def create_repair_worktree(pull_request_number, branch_name)
      slug = branch_name.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40]
      timestamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      {
        dir: create_clone(
          "repair-pr-#{pull_request_number}-#{slug}-#{timestamp}",
          branch_name:,
          start_point: "origin/#{branch_name}"
        ),
        branch_name:
      }
    end

    def branch_name_for(work_item, timestamp:)
      case work_item.fetch("type")
      when "issue"
        slug = work_item.fetch("title").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 40]
        "issue-#{work_item.fetch('number')}-#{slug}-#{timestamp}"
      else
        slug = work_item.fetch("branch_slug").downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")[0, 60]
        "#{slug}-#{timestamp}"
      end
    end

    def workflow_goal_for(worktree_dir, work_item)
      return work_item.fetch("number").to_s if work_item.fetch("type") == "issue"

      goal_path = File.join(worktree_dir, "tmp", "factory-goal.json")
      FileUtils.mkdir_p(File.dirname(goal_path))
      File.write(goal_path, JSON.pretty_generate(work_item))
      "file:tmp/factory-goal.json"
    end

    def create_clone(name, branch_name:, start_point:)
      worktree_dir = File.join(worktree_root, name)
      remote_url = capture!(%w[git remote get-url origin], chdir: repo_root).first.strip
      FileUtils.rm_rf(worktree_dir)
      capture!(["git", "clone", "--quiet", repo_root, worktree_dir], chdir: repo_root)
      capture!(["git", "remote", "set-url", "origin", remote_url], chdir: worktree_dir)
      capture!(["git", "fetch", "--prune", "origin"], chdir: worktree_dir)
      capture!(["git", "checkout", "-B", branch_name, start_point], chdir: worktree_dir)
      worktree_dir
    end

    def run_workflow_with_retries(worktree_dir, workflow, goal)
      attempts = 0

      begin
        attempts += 1
        run_workflow(worktree_dir, workflow, goal)
      rescue StandardError => e
        raise unless retryable_run_error?(e) && attempts < options.fetch(:max_run_attempts)

        sleep options.fetch(:poll_interval)
        retry
      end
    end

    def run_workflow(worktree_dir, workflow, goal)
      stdout, = capture!(
        ["fabro", "run", workflow, "--goal", goal.to_s, "--auto-approve", "--detach", "--json"],
        chdir: worktree_dir,
        env: fabro_env
      )
      run_id = JSON.parse(stdout).fetch("run_id")
      wait_status = JSON.parse(capture!(["fabro", "wait", run_id, "--json"], chdir: worktree_dir, env: fabro_env).first)
      raise "Fabro run #{run_id} finished with status #{wait_status.fetch('status')}" unless wait_status.fetch("status") == "succeeded"

      run_id
    end

    def recorded_run_branch(run_id)
      inspect_run(run_id).dig(0, "start_record", "run_branch")
    end

    def inspect_run(run_id)
      JSON.parse(capture!(["fabro", "inspect", run_id, "--json"], chdir: repo_root, env: fabro_env).first)
    end

    def create_or_fetch_pull_request(run_id, work_item, worktree_dir, run_branch, fabro_run_branch: nil)
      return manual_create_pull_request(work_item, worktree_dir, run_branch) if fabro_run_branch.to_s.empty? || work_item.fetch("type") != "issue"

      create_pull_request(run_id)
      pull_request_record(run_id)
    rescue StandardError
      manual_create_pull_request(work_item, worktree_dir, run_branch)
    end

    def create_pull_request(run_id)
      capture!("fabro pr create #{run_id} --json", chdir: repo_root, env: fabro_env, shell: true)
    end

    def pull_request_record(run_id)
      JSON.parse(capture!("fabro pr view #{run_id} --json", chdir: repo_root, env: fabro_env, shell: true).first)
    end

    def manual_create_pull_request(work_item, worktree_dir, branch_name)
      commit_if_needed(worktree_dir, commit_message_for(work_item))
      capture!(["git", "push", "-u", "origin", "HEAD:#{branch_name}"], chdir: worktree_dir)
      capture!(
        [
          "gh", "pr", "create", "-R", github.repository,
          "--head", branch_name,
          "--base", "main",
          "--title", work_item.fetch("pull_request_title", work_item.fetch("title")),
          "--body", ""
        ],
        chdir: worktree_dir
      )
      view_pull_request(branch_name)
    end

    def commit_message_for(work_item)
      case work_item.fetch("type")
      when "issue"
        "Implement ##{work_item.fetch('number')}: #{work_item.fetch('title')}"
      when "gate_promotion"
        "Promote gate #{work_item.fetch('target_gate')} to #{work_item.fetch('next_level')}"
      else
        "Improve gate #{work_item.fetch('target_gate')}: #{work_item.fetch('priority_reason').tr('_', ' ')}"
      end
    end

    def merge_pull_request(run_id, pull_request)
      if run_id
        capture!("fabro pr merge #{run_id} --method squash --json", chdir: repo_root, env: fabro_env, shell: true)
      else
        merge_pull_request_with_gh(pull_request)
      end
    rescue StandardError
      merge_pull_request_with_gh(pull_request)
    end

    def merge_pull_request_with_gh(pull_request)
      capture!(
        ["gh", "pr", "merge", pull_request.fetch("number").to_s, "--squash", "--delete-branch", "-R", github.repository],
        chdir: repo_root
      )
    end

    def repair_pull_request(pull_request_number, attempt)
      pull_request = view_pull_request(pull_request_number.to_s)
      branch_name = pull_request.fetch("headRefName")
      worktree = create_repair_worktree(pull_request_number, branch_name)
      worktree_dir = worktree.fetch(:dir)
      run_workflow_with_retries(worktree_dir, options.fetch(:repair_workflow), pull_request_number)
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
              "gh", "pr", "view", pull_request_number.to_s,
              "-R", github.repository,
              "--json", "statusCheckRollup"
            ],
            chdir: repo_root
          ).first
        ).fetch("statusCheckRollup", [])

        buckets = checks.map { |check| check_bucket(check) }
        return { status: :success, checks: } if !checks.empty? && buckets.all? { |bucket| %i[pass skipping].include?(bucket) }
        return { status: :fail, checks: } if buckets.include?(:fail)

        sleep options.fetch(:poll_interval)
      end
    end

    def check_bucket(check)
      case check["__typename"]
      when "CheckRun"
        return :pending unless check["status"] == "COMPLETED"

        case check["conclusion"]
        when "SUCCESS", "NEUTRAL"
          :pass
        when "SKIPPED"
          :skipping
        else
          :fail
        end
      when "StatusContext"
        case check["state"]
        when "SUCCESS"
          :pass
        when "PENDING", "EXPECTED"
          :pending
        else
          :fail
        end
      else
        :pending
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
        ["ruby", "factory/scripts/promote_merge_gate_baseline.rb", "tmp/factory-gates/report.json", baseline_file, gate_registry_path],
        chdir: worktree_dir
      )
    end

    def suppressed_work?(key)
      return false if key.to_s.empty?

      cooldown_until = load_attempt_state.dig(key, "cooldown_until")
      return false if cooldown_until.to_s.empty?

      Time.parse(cooldown_until) > Time.now.utc
    rescue ArgumentError
      false
    end

    def clear_work_failure(key)
      return if key.to_s.empty?

      state = load_attempt_state
      return unless state.delete(key)

      save_attempt_state(state)
    end

    def record_work_failure(key, error)
      return if key.to_s.empty?

      state = load_attempt_state
      record = state.fetch(key, {})
      failures = record.fetch("failures", 0) + 1
      timestamp = Time.now.utc

      updated_record = record.merge(
        "failures" => failures,
        "last_error" => error.message.lines.first.to_s.strip,
        "updated_at" => timestamp.iso8601
      )

      if failures >= options.fetch(:failure_threshold)
        updated_record["cooldown_until"] = (timestamp + options.fetch(:failure_cooldown_seconds)).iso8601
      else
        updated_record.delete("cooldown_until")
      end

      state[key] = updated_record
      save_attempt_state(state)
    end

    def load_attempt_state
      @attempt_state ||= begin
        if File.exist?(attempts_file)
          JSON.parse(File.read(attempts_file))
        else
          {}
        end
      rescue JSON::ParserError
        {}
      end
    end

    def save_attempt_state(state)
      File.write(attempts_file, JSON.pretty_generate(state))
      @attempt_state = state
    end

    def issue_failure_key(issue_number)
      "issue-#{issue_number}"
    end

    def work_failure_key(work_item)
      work_item.fetch("id", work_item.fetch("type"))
    end

    def issue_number_from_branch(branch_name)
      branch_name[/\Aissue-(\d+)-/, 1]&.to_i
    end

    def factory_branch?(branch_name)
      FACTORY_BRANCH_PREFIXES.any? { |prefix| branch_name.start_with?(prefix) }
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

      FileUtils.rm_rf(worktree_dir)
    end

    def retryable_run_error?(error)
      message = error.message
      message.include?("signal: 9") ||
        message.include?("Communication Error") ||
        message.include?("error decoding response body") ||
        message.include?("Worker exited before emitting a terminal run event")
    end

    def ensure_git_push_auth!
      return if ENV["GH_TOKEN"].to_s.empty? && ENV["GITHUB_TOKEN"].to_s.empty?

      capture!(["gh", "auth", "setup-git"], chdir: repo_root)
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
  max_run_attempts: Integer(ENV.fetch("YAMIOCHI_FACTORY_MAX_RUN_ATTEMPTS", "3")),
  poll_interval: Integer(ENV.fetch("YAMIOCHI_FACTORY_POLL_INTERVAL", "15")),
  workflow: ".fabro/workflows/implement-issue/workflow.toml",
  promotion_workflow: ".fabro/workflows/promote-gate/workflow.toml",
  repair_workflow: ".fabro/workflows/repair-pr/workflow.toml",
  fabro_server: ENV["FABRO_SERVER"] || "http://127.0.0.1:32276",
  worktree_root: ENV["YAMIOCHI_FACTORY_WORKTREE_ROOT"] || "/tmp/yamiochi-factory-worktrees",
  baseline_file: ENV["YAMIOCHI_FACTORY_GATE_STATE_FILE"] || ENV["YAMIOCHI_FACTORY_BASELINE_FILE"] || "/tmp/yamiochi-factory-baselines/gates.json",
  gate_registry_path: ENV["YAMIOCHI_FACTORY_GATE_REGISTRY"] || File.join(repo_root, "factory", "gates.yml"),
  attempts_file: ENV["YAMIOCHI_FACTORY_ATTEMPTS_FILE"] || "/tmp/yamiochi-factory-baselines/autopilot-attempts.json",
  failure_threshold: Integer(ENV.fetch("YAMIOCHI_FACTORY_FAILURE_THRESHOLD", "3")),
  failure_cooldown_seconds: Integer(ENV.fetch("YAMIOCHI_FACTORY_FAILURE_COOLDOWN_SECONDS", "3600"))
}

OptionParser.new do |parser|
  parser.banner = "Usage: ruby factory/scripts/autopilot.rb [options]"

  parser.on("--once", "Process only one issue") { options[:once] = true }
  parser.on("--max-issues N", Integer, "Process at most N issues") { |value| options[:max_issues] = value }
  parser.on("--cleanup-failed", "Remove failed worktrees too") { options[:cleanup_failed] = true }
  parser.on("--workflow PATH", "Fabro workflow to run for code changes") { |value| options[:workflow] = value }
  parser.on("--promotion-workflow PATH", "Fabro workflow to run for gate promotions") { |value| options[:promotion_workflow] = value }
  parser.on("--repair-workflow PATH", "Fabro repair workflow to run") { |value| options[:repair_workflow] = value }
  parser.on("--fabro-server URL", "Fabro server URL") { |value| options[:fabro_server] = value }
  parser.on("--worktree-root PATH", "Directory for disposable worktrees") { |value| options[:worktree_root] = value }
  parser.on("--baseline-file PATH", "Path to the persistent gate state file") { |value| options[:baseline_file] = value }
  parser.on("--gate-state-file PATH", "Alias for --baseline-file") { |value| options[:baseline_file] = value }
  parser.on("--gate-registry PATH", "Path to factory/gates.yml") { |value| options[:gate_registry_path] = value }
end.parse!

options[:once] = true if options[:max_issues] == 1
YamiochiFactory::Autopilot.new(repo_root:, options:).run
