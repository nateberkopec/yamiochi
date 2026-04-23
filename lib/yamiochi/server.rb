# frozen_string_literal: true

module Yamiochi
  class Server
    attr_reader :rackup_path

    def initialize(rackup_path:, out: $stdout, err: $stderr)
      @rackup_path = File.expand_path(rackup_path.to_s)
      @out = out
      @err = err
    end

    def run
      validate_rackup_path!
      boot
      self
    end

    private

    attr_reader :out, :err

    def validate_rackup_path!
      return if File.file?(rackup_path)

      raise ArgumentError, "Rackup file not found: #{rackup_path}"
    end

    def boot
      # Follow-up issues extend this shared boot path to bind listeners and load
      # the Rack app from `rackup_path`.
      out.flush
      err.flush
      true
    end
  end
end
