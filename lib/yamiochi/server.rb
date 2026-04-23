# frozen_string_literal: true

require "socket"

module Yamiochi
  class Server
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9292

    attr_reader :rackup_path, :host, :port, :bound_port

    def initialize(rackup_path:, host: DEFAULT_HOST, port: DEFAULT_PORT, out: $stdout, err: $stderr)
      @rackup_path = File.expand_path(rackup_path.to_s)
      @host = host
      @port = Integer(port)
      @bound_port = nil
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
      listener = nil

      begin
        listener = open_listener
        handle_single_client(listener)
      ensure
        close_socket(listener)
        flush_streams
      end
    end

    def open_listener
      listener = TCPServer.new(host, port)
      listener.listen(1024)
      @bound_port = listener.local_address.ip_port
      listener
    end

    def handle_single_client(listener)
      client = listener.accept

      begin
        enable_tcp_nodelay(client)
        read_request_bytes(client)
      ensure
        close_socket(client)
      end
    end

    def enable_tcp_nodelay(client)
      client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    end

    def read_request_bytes(client)
      client.readpartial(1024)
    rescue EOFError
      nil
    end

    def close_socket(socket)
      socket&.close
    rescue IOError
      nil
    end

    def flush_streams
      out.flush
      err.flush
    end
  end
end
