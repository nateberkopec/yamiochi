# frozen_string_literal: true

module YamiochiFactory
  module SpecQueue
    EXTRA_ITEMS = [
      {
        "key" => "spec-extra:rackup-smoke-entrypoints",
        "title" => "Serve the same Rack app through `yamiochi` and `rackup -s yamiochi`",
        "milestone" => "M2: Works through normal Rack entrypoints",
        "section" => "6.3 Invocation",
        "body" => <<~MARKDOWN
          Prove the normal Rack entrypoints work for Yamiochi.

          Acceptance ideas:
          - `yamiochi config.ru` serves a Rack app successfully.
          - `rackup -s yamiochi -p PORT config.ru` serves the same app successfully.
          - Differences between the two entrypoints are covered by tests or scenarios.
        MARKDOWN
      },
      {
        "key" => "spec-extra:http-probe",
        "title" => "Drive the `http-probe.com` holdout suite to zero failures",
        "milestone" => "M12: Passes external correctness suites and benchmark target",
        "section" => "FACTORY.md §3.2",
        "body" => <<~MARKDOWN
          Integrate `http-probe.com` as an external holdout suite and ratchet Yamiochi until it reports no failures.
        MARKDOWN
      },
      {
        "key" => "spec-extra:h1spec",
        "title" => "Drive h1spec to zero RFC 7230–7235 failures",
        "milestone" => "M12: Passes external correctness suites and benchmark target",
        "section" => "FACTORY.md §3.2",
        "body" => <<~MARKDOWN
          Integrate `uNetworking/h1spec` as an external holdout suite and ratchet Yamiochi until the suite is green.
        MARKDOWN
      },
      {
        "key" => "spec-extra:redbot",
        "title" => "Drive REDbot to zero external correctness errors",
        "milestone" => "M12: Passes external correctness suites and benchmark target",
        "section" => "FACTORY.md §3.2",
        "body" => <<~MARKDOWN
          Run a self-hosted REDbot gate and ratchet Yamiochi until it reports no errors.
        MARKDOWN
      },
      {
        "key" => "spec-extra:sinatra-fixture",
        "title" => "Serve a standard Sinatra fixture app correctly under Yamiochi",
        "milestone" => "M12: Passes external correctness suites and benchmark target",
        "section" => "FACTORY.md §3.2",
        "body" => <<~MARKDOWN
          Add a holdout Sinatra fixture scenario and keep ratcheting until it passes cleanly.
        MARKDOWN
      },
      {
        "key" => "spec-extra:rails-fixture",
        "title" => "Serve a standard Rails production fixture app correctly under Yamiochi",
        "milestone" => "M12: Passes external correctness suites and benchmark target",
        "section" => "FACTORY.md §3.2",
        "body" => <<~MARKDOWN
          Add a holdout Rails production fixture scenario and keep ratcheting until it passes cleanly.
        MARKDOWN
      },
      {
        "key" => "spec-extra:benchmark-target",
        "title" => "Hit the 300,000 req/s benchmark target on the reference heavy lane",
        "milestone" => "M12: Passes external correctness suites and benchmark target",
        "section" => "12. Security and Performance",
        "body" => <<~MARKDOWN
          Raise Yamiochi throughput until the benchmark requirement in `SPEC.md` is satisfied.

          Acceptance ideas:
          - The heavy GitHub Actions lane records benchmark output.
          - The measured throughput reaches at least 300,000 hello world requests per second over 3 worker processes on 3 CPU on the reference host.
          - The benchmark ratchet baseline advances only on reproducible improvements.
        MARKDOWN
      }
    ].freeze

    SECTION_MILESTONES = {
      "13.1 Process Model" => "M6: Runs as a real prefork server",
      "13.2 HTTP Request Parsing" => "M3: Produces minimally correct HTTP/1.1 responses",
      "13.3 HTTP Response" => "M9: Gets HTTP response semantics right",
      "13.4 Rack Compliance" => "M10: Passes Rack 3 compliance gates",
      "13.5 Configuration" => "M7: Supports deployable configuration",
      "13.6 Networking" => "M8: Supports real deployment bindings",
      "13.7 Signals" => "M11: Operates cleanly under signals and logging",
      "13.8 Logging" => "M11: Operates cleanly under signals and logging"
    }.freeze

    module_function

    def desired_issues(spec_text)
      parse_checkboxes(spec_text) + EXTRA_ITEMS
    end

    def parse_checkboxes(spec_text)
      current_section = nil

      spec_text.each_line.with_object([]) do |line, issues|
        current_section = line.strip if line.start_with?("### ")
        checkbox_text = line[/^\s*- \[ \] (.+)$/i, 1]
        next unless checkbox_text

        section = current_section&.sub(/^###\s+/, "")
        next unless section

        issues << issue_for(section:, checkbox_text:)
      end
    end

    def issue_for(section:, checkbox_text:)
      {
        "key" => issue_key(section:, checkbox_text:),
        "title" => checkbox_text,
        "milestone" => milestone_for(section:, checkbox_text:),
        "section" => section,
        "body" => <<~MARKDOWN
          Derived automatically from `SPEC.md` §#{section}.

          Acceptance target:
          - [ ] #{checkbox_text}
        MARKDOWN
      }
    end

    def issue_key(section:, checkbox_text:)
      slug = checkbox_text.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
      "spec:#{section.split.first}:#{slug}"
    end

    def milestone_for(section:, checkbox_text:)
      return "M2: Works through normal Rack entrypoints" if checkbox_text.include?("Rackup handler")
      return "M4: Builds a correct Rack request env" if rack_env_checkbox?(checkbox_text)
      return "M5: Survives app errors safely" if checkbox_text.start_with?("500 is returned")

      SECTION_MILESTONES.fetch(section)
    end

    def rack_env_checkbox?(checkbox_text)
      checkbox_text.start_with?("All required Rack 3 environment keys") ||
        checkbox_text.start_with?("`rack.input`") ||
        checkbox_text.start_with?("`rack.multithread`") ||
        checkbox_text.start_with?("`rack.multiprocess`")
    end
  end
end
