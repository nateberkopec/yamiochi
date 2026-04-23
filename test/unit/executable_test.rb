# frozen_string_literal: true

require "open3"
require "tmpdir"

require_relative "../test_helper"

class YamiochiExecutableTest < Minitest::Test
  def test_executable_starts_successfully_with_valid_rackup_file
    Dir.mktmpdir("yamiochi-exe-test") do |dir|
      config_ru = File.join(dir, "config.ru")
      File.write(config_ru, "run ->(_env) { [200, {}, ['ok']] }\n")

      stdout, stderr, status = Open3.capture3(executable_path, config_ru, chdir: repo_root)

      assert status.success?, "Expected executable to exit successfully, stdout: #{stdout.inspect}, stderr: #{stderr.inspect}"
      assert_empty stdout
      assert_empty stderr
    end
  end

  private

  def repo_root
    File.expand_path("../..", __dir__)
  end

  def executable_path
    File.join(repo_root, "exe", "yamiochi")
  end
end
