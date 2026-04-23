# frozen_string_literal: true

require "rubocop"

module CustomCops
  class NoSleepInTests < RuboCop::Cop::Base
    MSG = "Do not call `sleep` in the test suite. Use a polling helper that does not depend on `sleep` instead."
    RESTRICT_ON_SEND = %i[sleep].freeze

    def on_send(node)
      add_offense(node.loc.selector || node.loc.expression)
    end
  end
end
