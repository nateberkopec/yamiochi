# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../../factory/scripts/lib/yamiochi_factory/judge_report"

class YamiochiFactoryJudgeReportTest < Minitest::Test
  def test_parse_reads_score_and_decision
    report = YamiochiFactory::JudgeReport.parse(<<~TEXT)
      score: 0.85
      decision: pass
      summary: Looks good
      strengths:
      - Covers the behavior
      risks:
      - None
      next_actions:
      - Merge it
    TEXT

    assert_equal 0.85, report.fetch("score")
    assert_equal "pass", report.fetch("decision")
  end

  def test_parse_rejects_missing_score
    error = assert_raises(ArgumentError) do
      YamiochiFactory::JudgeReport.parse("decision: revise\n")
    end

    assert_match(/missing a score/, error.message)
  end
end
