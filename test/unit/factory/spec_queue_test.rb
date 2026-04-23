# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/spec_queue"

class YamiochiFactorySpecQueueTest < Minitest::Test
  def test_desired_issues_include_spec_checkbox_entries_and_extras
    issues = YamiochiFactory::SpecQueue.desired_issues(File.read("SPEC.md"))

    assert issues.any? { |issue| issue.fetch("title") == "Master binds all sockets before forking any workers" }
    assert issues.any? { |issue| issue.fetch("title") == "Serve the same Rack app through `yamiochi` and `rackup -s yamiochi`" }
  end

  def test_rackup_handler_checkbox_maps_to_milestone_two
    issue = YamiochiFactory::SpecQueue.issue_for(
      section: "13.4 Rack Compliance",
      checkbox_text: "Rackup handler `yamiochi` is registered and invocable via `rackup -s yamiochi`"
    )

    assert_equal "M2: Works through normal Rack entrypoints", issue.fetch("milestone")
  end

  def test_application_error_checkbox_maps_to_milestone_five
    issue = YamiochiFactory::SpecQueue.issue_for(
      section: "13.3 HTTP Response",
      checkbox_text: "500 is returned when the Rack app raises an unhandled exception"
    )

    assert_equal "M5: Survives app errors safely", issue.fetch("milestone")
  end

  def test_rack_env_checkbox_maps_to_milestone_four
    issue = YamiochiFactory::SpecQueue.issue_for(
      section: "13.4 Rack Compliance",
      checkbox_text: "All required Rack 3 environment keys are present and correctly typed"
    )

    assert_equal "M4: Builds a correct Rack request env", issue.fetch("milestone")
  end
end
