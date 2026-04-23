# frozen_string_literal: true

require "uri"

module Yamiochi
  class CLI
    USAGE = "Usage: yamiochi [-b tcp://HOST:PORT] CONFIG.RU"

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
      server_options = extract_server_options
      return 1 unless server_options

      rackup_path = extract_rackup_path
      return 1 unless rackup_path

      server_class.new(rackup_path:, out:, err:, **server_options).run
      0
    rescue ArgumentError => e
      err.puts(e.message)
      1
    end

    private

    attr_reader :argv, :out, :err, :server_class

    def extract_server_options
      return {} unless bind_flag?(argv.first)

      flag = argv.shift
      bind_uri = argv.shift

      unless bind_uri
        err.puts "missing bind URI after #{flag}"
        err.puts USAGE
        return
      end

      parse_bind_uri(bind_uri)
    end

    def bind_flag?(arg)
      arg == "-b" || arg == "--bind"
    end

    def parse_bind_uri(bind_uri)
      uri = URI.parse(bind_uri)

      unless uri.scheme == "tcp"
        scheme = uri.scheme || "(none)"
        raise ArgumentError, "unsupported bind scheme: #{scheme} (expected tcp://HOST:PORT)"
      end

      host = normalize_bind_host(uri.host)
      port = uri.port

      unless valid_bind_uri?(uri, host:, port:)
        raise ArgumentError, "invalid bind URI: #{bind_uri.inspect} (expected tcp://HOST:PORT)"
      end

      { host:, port: }
    rescue URI::InvalidURIError
      raise ArgumentError, "invalid bind URI: #{bind_uri.inspect} (expected tcp://HOST:PORT)"
    end

    def normalize_bind_host(host)
      return unless host

      host.delete_prefix("[").delete_suffix("]")
    end

    def valid_bind_uri?(uri, host:, port:)
      host &&
        !host.empty? &&
        port &&
        (1..65_535).cover?(port) &&
        uri.userinfo.nil? &&
        uri.path.to_s.empty? &&
        uri.query.nil? &&
        uri.fragment.nil?
    end

    def extract_rackup_path
      if argv.empty?
        err.puts "missing Rackup file path"
        err.puts USAGE
        return
      end

      if argv.length > 1
        err.puts "unexpected arguments: #{argv[1..].join(" ")}"
        err.puts USAGE
        return
      end

      argv.first
    end
  end
end
