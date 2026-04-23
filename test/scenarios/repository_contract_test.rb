# frozen_string_literal: true

require_relative "../test_helper"

class RepositoryContractScenarioTest < Minitest::Test
  def test_factory_control_files_exist
    required_files = %w[
      .fabro/project.toml
      .fabro/workflows/smoke/workflow.fabro
      .fabro/workflows/implement-issue/workflow.fabro
      .fabro/workflows/select-work/workflow.fabro
      .fabro/workflows/repair-pr/workflow.fabro
      .fabro/workflows/promote-gate/workflow.fabro
      factory/deny_paths.txt
      factory/gates.yml
      factory/judge.md
      factory/yamiochi.dot
      mise.toml
      hk.pkl
    ]

    required_files.each do |path|
      assert File.exist?(path), "expected #{path} to exist"
    end
  end

  def test_deny_paths_cover_human_owned_controls
    patterns = File.readlines("factory/deny_paths.txt", chomp: true)
      .reject { |line| line.empty? || line.start_with?("#") }

    %w[SPEC.md FACTORY.md ops/** factory/** .fabro/** test/scenarios/** .github/workflows/** mise.toml hk.pkl].each do |pattern|
      assert_includes patterns, pattern
    end
  end
end
