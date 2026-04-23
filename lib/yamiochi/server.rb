# frozen_string_literal: true

require "socket"
require "stringio"
require "time"

module Yamiochi
  class Server
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9292
    MAX_HEADER_BYTES = 16 * 1024

    STATUS_REASONS = {
      200 => "OK",
      400 => "Bad Request",
      500 => "Internal Server Error"
    }.freeze

    class BadRequestError < StandardError; end

    class RackupLoader
      def self.load(path)
        new(path).load
      end

      def initialize(path)
        @path = path
        @app = nil
      end

      def load
        instance_eval(File.read(path), path, 1)

        return app if app

        raise ArgumentError, "Rackup file did not call run: #{path}"
      end

      def run(configured_app)
        @app = configured_app
      end

      private

      attr_reader :path, :app
    end

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
      rack_app
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
        request_bytes = read_request_bytes(client)
        return unless request_bytes

        request_env = build_request_env(listener, request_bytes)
        write_rack_response(client, *call_app(request_env))
      rescue BadRequestError
        write_simple_response(client, 400)
      ensure
        close_socket(client)
      end
    end

    def enable_tcp_nodelay(client)
      client.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    end

    def read_request_bytes(client)
      request_bytes = String.new.b

      loop do
        request_bytes << client.readpartial(1024)

        return request_bytes if request_bytes.include?("\r\n\r\n")

        if request_bytes.bytesize > MAX_HEADER_BYTES
          raise BadRequestError, "request headers exceed #{MAX_HEADER_BYTES} bytes"
        end
      end
    rescue EOFError
      return nil if request_bytes.empty?

      request_bytes
    end

    def build_request_env(listener, request_bytes)
      unless request_bytes.include?("\r\n\r\n")
        raise BadRequestError, "incomplete request headers"
      end

      header_block, = request_bytes.split("\r\n\r\n", 2)
      request_line, *header_lines = header_block.split("\r\n")
      method, request_target, server_protocol = parse_request_line(request_line)
      headers = parse_headers(header_lines)
      path_info, query_string = split_request_target(request_target)

      {
        "REQUEST_METHOD" => method,
        "SCRIPT_NAME" => "",
        "PATH_INFO" => path_info,
        "QUERY_STRING" => query_string,
        "SERVER_NAME" => server_name(listener, headers["Host"]),
        "SERVER_PORT" => listener.local_address.ip_port.to_s,
        "SERVER_PROTOCOL" => server_protocol,
        "rack.version" => [3, 0],
        "rack.url_scheme" => "http",
        "rack.input" => StringIO.new(String.new.b),
        "rack.errors" => err,
        "rack.multithread" => false,
        "rack.multiprocess" => true,
        "rack.run_once" => false
      }.merge(rack_headers(headers))
    end

    def parse_request_line(request_line)
      method, request_target, server_protocol = request_line.to_s.split(" ", 3)

      if [method, request_target, server_protocol].any?(&:nil?)
        raise BadRequestError, "malformed request line"
      end

      unless server_protocol == "HTTP/1.1"
        raise BadRequestError, "unsupported protocol: #{server_protocol}"
      end

      [method, request_target, server_protocol]
    end

    def parse_headers(header_lines)
      header_lines.each_with_object({}) do |line, headers|
        name, value = line.split(":", 2)
        raise BadRequestError, "malformed header: #{line.inspect}" unless name && value

        headers[name] = value.lstrip
      end
    end

    def split_request_target(request_target)
      path_info, query_string = request_target.split("?", 2)
      raise BadRequestError, "unsupported request target: #{request_target}" unless path_info&.start_with?("/")

      [path_info, query_string.to_s]
    end

    def server_name(listener, host_header)
      return host_header_name(host_header) if host_header

      listener.local_address.ip_address
    end

    def host_header_name(host_header)
      if host_header.start_with?("[")
        host_header[/\A\[(?<host>[^\]]+)\](?::\d+)?\z/, :host] || host_header
      else
        host_header.split(":", 2).first
      end
    end

    def rack_headers(headers)
      headers.each_with_object({}) do |(name, value), env|
        env[env_header_name(name)] = value
      end
    end

    def env_header_name(header_name)
      normalized_name = header_name.upcase.tr("-", "_")
      return normalized_name if %w[CONTENT_LENGTH CONTENT_TYPE].include?(normalized_name)

      "HTTP_#{normalized_name}"
    end

    def call_app(request_env)
      rack_app.call(request_env)
    rescue StandardError
      [500, {}, []]
    end

    def rack_app
      @rack_app ||= RackupLoader.load(rackup_path)
    end

    def write_simple_response(client, status)
      write_rack_response(client, status, {}, [])
    end

    def write_rack_response(client, status, headers, body)
      response_status = Integer(status)
      response_headers = headers || {}
      response_body = read_response_body(body)
      normalized_headers = build_response_headers(response_headers, response_body)

      client.write("HTTP/1.1 #{response_status} #{reason_phrase(response_status)}\r\n")
      normalized_headers.each do |name, value|
        client.write("#{name}: #{value}\r\n")
      end
      client.write("\r\n")
      client.write(response_body)
    ensure
      body.close if body.respond_to?(:close)
    end

    def read_response_body(body)
      response_body = String.new.b
      body.each do |chunk|
        response_body << chunk.to_s
      end
      response_body
    end

    def build_response_headers(headers, response_body)
      response_headers = headers.each_with_object({}) do |(name, value), normalized_headers|
        normalized_headers[name.to_s] = value.to_s
      end

      set_response_header!(response_headers, "Server", "Yamiochi")
      set_response_header!(response_headers, "Connection", "close")
      set_response_header!(response_headers, "Date", Time.now.httpdate)

      unless response_header?(response_headers, "Content-Length") || response_header?(response_headers, "Transfer-Encoding")
        response_headers["Content-Length"] = response_body.bytesize.to_s
      end

      response_headers
    end

    def set_response_header!(headers, name, value)
      delete_response_header!(headers, name)
      headers[name] = value
    end

    def response_header?(headers, name)
      headers.any? { |header_name, _| header_name.casecmp?(name) }
    end

    def delete_response_header!(headers, name)
      existing_name, = headers.find { |header_name, _| header_name.casecmp?(name) }
      headers.delete(existing_name) if existing_name
    end

    def reason_phrase(status)
      STATUS_REASONS.fetch(status, "Unknown")
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
