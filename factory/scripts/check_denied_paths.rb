# frozen_string_literal: true

require "shellwords"

base_ref = ARGV[0] || "origin/main"
deny_list_path = ARGV[1] || File.join(__dir__, "..", "deny_paths.txt")
flags = File::FNM_PATHNAME | File::FNM_DOTMATCH | File::FNM_EXTGLOB

patterns = File.readlines(deny_list_path, chomp: true)
  .map(&:strip)
  .reject { |line| line.empty? || line.start_with?("#") }

merge_base = `git merge-base HEAD #{Shellwords.escape(base_ref)} 2>/dev/null`.strip

if merge_base.empty? && base_ref == "origin/main"
  system("git fetch origin main >/dev/null 2>&1")
  merge_base = `git merge-base HEAD #{Shellwords.escape(base_ref)} 2>/dev/null`.strip
end

abort("Could not determine merge base against #{base_ref}") if merge_base.empty?

changed_files = `git diff --name-only #{merge_base}...HEAD`
  .lines
  .map(&:strip)
  .reject(&:empty?)

violations = changed_files.select do |path|
  patterns.any? { |pattern| File.fnmatch?(pattern, path, flags) }
end

if violations.empty?
  puts "No denied paths changed."
  exit 0
end

warn "Denied paths changed:"
violations.each { |path| warn "- #{path}" }
exit 1
