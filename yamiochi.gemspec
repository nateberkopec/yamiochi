# frozen_string_literal: true

require_relative "lib/yamiochi/version"

Gem::Specification.new do |spec|
  spec.name = "yamiochi"
  spec.version = Yamiochi::VERSION
  spec.authors = ["Nate Berkopec"]
  spec.email = ["nate.berkopec@gmail.com"]

  spec.summary = "Minimal HTTP/1.1 Rack server"
  spec.description = "Yamiochi is a preforking Rack application server designed to run behind a reverse proxy, with correctness, security, and performance as primary goals."
  spec.homepage = "https://github.com/nateberkopec/yamiochi"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/nateberkopec/yamiochi"
  spec.metadata["changelog_uri"] = "https://github.com/nateberkopec/yamiochi/releases"

  # Specify which files should be added to the gem when it is released.
  # Use an allowlist so factory/control-plane files, ops material, tests, and
  # other repository-only docs never ship by accident.
  allowed_files = %w[
    README.md
    CHANGELOG.md
    LICENSE.md
  ]
  allowed_prefixes = %w[
    exe/
    lib/
  ]

  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).select do |f|
      allowed_files.include?(f) || allowed_prefixes.any? { |prefix| f.start_with?(prefix) }
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]
end
