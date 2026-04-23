# frozen_string_literal: true

require "rake"
require "rake/testtask"
require "rbconfig"
require "shellwords"

ruby_files = FileList[
  "Rakefile",
  "lib/**/*.rb",
  "exe/**/*.rb",
  "test/**/*.rb",
  "factory/scripts/**/*.rb"
].existing.reject { |path| File.directory?(path) }

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.pattern = "test/unit/**/*_test.rb"
  t.warning = true
end

Rake::TestTask.new(:scenarios) do |t|
  t.libs << "test"
  t.pattern = "test/scenarios/**/*_test.rb"
  t.warning = true
end

desc "Run Ruby syntax checks"
task :lint do
  abort "No Ruby files found to lint" if ruby_files.empty?

  sh [RbConfig.ruby, "-cw", *ruby_files].shelljoin
end

desc "Build the gem"
task :build do
  sh "gem build yamiochi.gemspec"
end

desc "Placeholder benchmark frontend"
task :bench do
  puts "Benchmark harness not implemented yet. See SPEC.md §12 and FACTORY.md §9."
end

desc "Run the fast local verification set"
task verify: %i[lint test scenarios build]

task default: :verify
