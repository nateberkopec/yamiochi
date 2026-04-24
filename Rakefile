# frozen_string_literal: true

require "open3"
require "rake"
require "rake/testtask"

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

def capture_output(*command)
  Open3.capture2e(*command)
end

desc "Run standardrb with project custom cops"
task :standard do
  sh "bundle exec standardrb"
end

desc "Run flog against lib"
task :flog do
  output, status = capture_output("bundle", "exec", "flog", "-a", "lib")
  unless status.success?
    puts output
    exit status.exitstatus || 1
  end

  threshold = Integer(ENV.fetch("FLOG_THRESHOLD", "25"), 10)
  failing_methods = output.each_line.filter_map do |line|
    match = line.match(/^\s*(\d+\.\d+):\s+(.+#.+)\s+(.+)$/)
    next unless match

    score = match[1].to_f
    next unless score > threshold

    "#{match[1]}: #{match[2]} #{match[3]}"
  end

  next if failing_methods.empty?

  puts "\nFlog failed: Methods with complexity score > #{threshold}:"
  failing_methods.each { |method| puts "  #{method}" }
  exit 1
end

desc "Run flay against lib"
task :flay do
  output, status = capture_output("bundle", "exec", "flay", "lib")
  threshold = Integer(ENV.fetch("FLAY_THRESHOLD", "0"), 10)
  match = output.match(/Total score \(lower is better\) = (\d+)/)

  if match && match[1].to_i > threshold
    puts "\nFlay failed: Total duplication score is #{match[1]}, must be <= #{threshold}"
    puts output
    exit 1
  end

  next if status.success?

  puts output
  exit status.exitstatus || 1
end

desc "Run the lint suite"
task lint: %i[standard flog flay]

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
