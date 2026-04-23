# frozen_string_literal: true

require "stringio"
require "tmpdir"

require_relative "../test_helper"

class YamiochiServerTest < Minitest::Test
  def test_initialization_normalizes_rackup_path
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, "run ->(_env) { [200, {}, ['ok']] }\n")
      relative_path = File.join(dir, ".", "config.ru")

      server = Yamiochi::Server.new(rackup_path: relative_path, out: StringIO.new, err: StringIO.new)

      assert_equal File.expand_path(config_ru), server.rackup_path
    end
  end

  def test_run_completes_for_a_valid_rackup_file
    Dir.mktmpdir("yamiochi-server-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, "run ->(_env) { [200, {}, ['ok']] }\n")

      server = Yamiochi::Server.new(rackup_path: config_ru, out: StringIO.new, err: StringIO.new)

      assert_same server, server.run
    end
  end
end
