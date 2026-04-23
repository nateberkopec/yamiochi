# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/selection"

class YamiochiFactorySelectionTest < Minitest::Test
  def test_select_issue_prefers_milestone_human_issue
    issues = [
      issue(number: 20, milestone_title: nil, user_type: "User"),
      issue(number: 21, milestone_title: "M2: Two", user_type: "Bot"),
      issue(number: 22, milestone_title: "M1: One", user_type: "User")
    ]

    selected = YamiochiFactory::Selection.select_issue(issues)

    assert_equal 22, selected.fetch("number")
  end

  def test_select_issue_skips_blocked_and_pull_request_entries
    issues = [
      issue(number: 30, milestone_title: "M1: One", labels: ["blocked"]),
      issue(number: 31, milestone_title: "M1: One", pull_request: { "url" => "https://example.test" }),
      issue(number: 32, milestone_title: nil)
    ]

    selected = YamiochiFactory::Selection.select_issue(issues)

    assert_equal 32, selected.fetch("number")
  end

  private

  def issue(number:, milestone_title:, user_type: "User", labels: [], pull_request: nil)
    payload = {
      "number" => number,
      "title" => "Issue #{number}",
      "labels" => labels.map { |name| { "name" => name } },
      "user" => { "login" => "nateberkopec", "type" => user_type }
    }
    payload["milestone"] = milestone_title ? { "title" => milestone_title } : nil
    payload["pull_request"] = pull_request if pull_request
    payload
  end
end
