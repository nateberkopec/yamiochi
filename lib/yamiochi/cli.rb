# frozen_string_literal: true

module Yamiochi
  class CLI
    USAGE = "Usage: yamiochi CONFIG.RU"

    def self.start(argv, out: $stdout, err: $stderr, server_class: Yamiochi::Server)
      new(argv, out:, err:, server_class:).start
    end

    def initialize(argv, out:, err:, server_class:)
      @argv = Array(argv).dup
      @out = out
      @err = err
      @server_class = server_class
    end

    def start
      rackup_path = extract_rackup_path
      return 1 unless rackup_path

      server_class.new(rackup_path:, out:, err:).run
      0
    rescue ArgumentError => e
      err.puts(e.message)
      1
    end

    private

    attr_reader :argv, :out, :err, :server_class

    def extract_rackup_path
      if argv.empty?
        err.puts "missing Rackup file path"
        err.puts USAGE
        return
      end

      if argv.length > 1
        err.puts "unexpected arguments: #{argv[1..].join(' ')}"
        err.puts USAGE
        return
      end

      argv.first
    end
  end
end
