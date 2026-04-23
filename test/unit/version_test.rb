# frozen_string_literal: true

require_relative "../test_helper"

class YamiochiVersionTest < Minitest::Test
  def test_version_is_present
    refute_nil Yamiochi::VERSION
    refute_empty Yamiochi::VERSION
  end
end
