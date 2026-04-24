# frozen_string_literal: true

require "socket"
require "stringio"
require "time"

module Yamiochi
  class Server
    DEFAULT_HOST = "0.0.0.0"
    DEFAULT_PORT = 9292
    MAX_HEADER_BYTES = 16 * 1024
    HEADER_TERMINATOR = "\r\n\r\n".b.freeze
    HEADER_NAME_PATTERN = /\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/
    CONTENT_LENGTH_PATTERN = /\A\d+\z/
    HOST_HEADER_PATTERN = /\A(?:\[(?<ip_literal>[0-9A-Fa-f:.]+)\]|(?<host>[A-Za-z0-9\-._~%!$&'()*+;=]+))(?::(?<port>\d+))?\z/

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

    def initialize(rackup_path: nil, app: nil, host: DEFAULT_HOST, port: DEFAULT_PORT, out: $stdout, err: $stderr)
      validate_app_source!(rackup_path, app)
      @rackup_path = rackup_path && File.expand_path(rackup_path.to_s)
      @rack_app = app
      @host = host
      @port = Integer(port)
      @bound_port = nil
      @out = out
      @err = err
    end

    def run
      rack_app
      boot
      self
    end

    private

    attr_reader :out, :err

    def validate_app_source!(rackup_path, app)
      sources = [rackup_path, app].count { |source| !source.nil? }
      return if sources == 1

      raise ArgumentError, "Provide exactly one of rackup_path or app"
    end

    def validate_rackup_path!
      return unless rackup_path
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

        request_env = build_request_env(listener, client, request_bytes)
        write_rack_response(client, request_env.fetch("REQUEST_METHOD"), *call_app(request_env))
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
      request_bytes = +"".b

      loop do
        request_bytes << client.readpartial(1024)

        if (header_end = request_bytes.index(HEADER_TERMINATOR))
          if header_end + HEADER_TERMINATOR.bytesize > MAX_HEADER_BYTES
            raise BadRequestError, "request headers exceed #{MAX_HEADER_BYTES} bytes"
          end

          return request_bytes
        end

        if request_bytes.bytesize > MAX_HEADER_BYTES
          raise BadRequestError, "request headers exceed #{MAX_HEADER_BYTES} bytes"
        end
      end
    rescue EOFError
      return nil if request_bytes.empty?

      request_bytes
    end

    def build_request_env(listener, client, request_bytes)
      request = parse_request(request_bytes)
      path_info, query_string = split_request_target(request.fetch(:request_target))

      request_env(listener, request, path_info:, query_string:)
        .merge(rack_input_env(client, request))
        .merge(rack_headers(request.fetch(:headers)))
    end

    def request_env(listener, request, path_info:, query_string:)
      {
        "REQUEST_METHOD" => request.fetch(:method),
        "SCRIPT_NAME" => "",
        "PATH_INFO" => path_info,
        "QUERY_STRING" => query_string,
        "SERVER_NAME" => server_name(listener, request.fetch(:headers)["host"]),
        "SERVER_PORT" => listener.local_address.ip_port.to_s,
        "SERVER_PROTOCOL" => request.fetch(:server_protocol),
        "rack.version" => [3, 0],
        "rack.url_scheme" => "http",
        "rack.errors" => err,
        "rack.multithread" => false,
        "rack.multiprocess" => true,
        "rack.run_once" => false,
        "rack.hijack?" => false
      }
    end

    def rack_input_env(client, request)
      request_body = read_request_body(client, request.fetch(:buffered_body), request[:content_length])
      rack_input = StringIO.new(request_body)
      rack_input.rewind
      {"rack.input" => rack_input}
    end

    def parse_request(request_bytes)
      header_block, buffered_body = split_request_bytes(request_bytes)
      request_line, *header_lines = header_block.split("\r\n")
      method, request_target, server_protocol = parse_request_line(request_line)
      raw_headers = parse_headers(header_lines)
      validate_request_framing!(raw_headers)
      host_header = normalize_host_header(raw_headers["host"])
      content_length = normalize_content_length(raw_headers["content-length"])

      {
        method:,
        request_target:,
        server_protocol:,
        headers: normalize_headers(raw_headers, host_header:, content_length:),
        buffered_body:,
        content_length:
      }
    end

    def split_request_bytes(request_bytes)
      header_end = request_bytes.index(HEADER_TERMINATOR)
      raise BadRequestError, "incomplete request headers" unless header_end

      header_block = request_bytes.byteslice(0, header_end)
      buffered_body = request_bytes.byteslice(header_end + HEADER_TERMINATOR.bytesize, request_bytes.bytesize) || +"".b
      [header_block, buffered_body]
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
        raise BadRequestError, "invalid header name: #{name.inspect}" unless HEADER_NAME_PATTERN.match?(name)

        normalized_name = name.downcase
        headers[normalized_name] ||= []
        headers[normalized_name] << value.sub(/\A[ \t]*/, "")
      end
    end

    def validate_request_framing!(headers)
      return unless headers.key?("transfer-encoding")

      raise BadRequestError, "unsupported transfer encoding"
    end

    def normalize_host_header(values)
      host_values = Array(values)
      raise BadRequestError, "missing Host header" if host_values.empty?
      raise BadRequestError, "multiple Host headers" unless host_values.one?
      raise BadRequestError, "invalid Host header" unless valid_host_header?(host_values.first)

      host_values.first
    end

    def normalize_content_length(values)
      content_length_values = Array(values)
      return nil if content_length_values.empty?

      parsed_lengths = content_length_values.flat_map { |value| value.split(",").map(&:strip) }.map do |value|
        raise BadRequestError, "invalid Content-Length" unless CONTENT_LENGTH_PATTERN.match?(value)

        Integer(value, 10)
      end

      raise BadRequestError, "conflicting Content-Length" unless parsed_lengths.uniq.one?

      parsed_lengths.first
    end

    def normalize_headers(headers, host_header:, content_length:)
      headers.each_with_object({}) do |(name, values), normalized_headers|
        normalized_headers[name] = case name
        when "host"
          host_header
        when "content-length"
          content_length.to_s
        else
          values.join(", ")
        end
      end
    end

    def valid_host_header?(host_header)
      !host_header.include?(",") && HOST_HEADER_PATTERN.match?(host_header)
    end

    def read_request_body(client, buffered_body, content_length)
      return +"".b unless content_length

      body = buffered_body.byteslice(0, content_length).to_s.b

      while body.bytesize < content_length
        body << client.readpartial([1024, content_length - body.bytesize].min)
      end

      body
    rescue EOFError
      raise BadRequestError, "truncated request body"
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
      host_header_match = HOST_HEADER_PATTERN.match(host_header)
      return host_header unless host_header_match

      host_header_match[:ip_literal] || host_header_match[:host]
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
    rescue
      [500, {}, []]
    end

    def rack_app
      @rack_app ||= begin
        validate_rackup_path!
        RackupLoader.load(rackup_path)
      end
    end

    def write_simple_response(client, status)
      write_rack_response(client, nil, status, {}, [])
    end

    def write_rack_response(client, request_method, status, headers, body)
      response_status = Integer(status)
      response_headers = headers || {}
      response_body = response_body_metadata(response_headers, body)
      normalized_headers = build_response_headers(response_headers, response_body)

      client.write("HTTP/1.1 #{response_status} #{reason_phrase(response_status)}\r\n")
      normalized_headers.each do |name, value|
        client.write("#{name}: #{value}\r\n")
      end
      client.write("\r\n")
      write_response_body(client, body, response_body.fetch(:framing)) unless request_method == "HEAD"
    ensure
      body.close if body.respond_to?(:close)
    end

    def response_body_metadata(headers, body)
      return {framing: :transfer_encoded} if response_header?(headers, "Transfer-Encoding")
      return {framing: :content_length} if response_header?(headers, "Content-Length")

      content_length = known_response_content_length(body)
      return {framing: :content_length, content_length: content_length.to_s} if content_length

      {framing: :chunked}
    end

    def known_response_content_length(body)
      return unless body.respond_to?(:to_ary)

      chunks = body.to_ary
      return unless chunks

      chunks.sum { |chunk| chunk.to_s.bytesize }
    end

    def write_response_body(client, body, body_framing)
      case body_framing
      when :chunked
        write_chunked_response_body(client, body)
      else
        write_identity_response_body(client, body)
      end
    end

    def write_identity_response_body(client, body)
      body.each do |chunk|
        client.write(chunk.to_s)
      end
    end

    def write_chunked_response_body(client, body)
      body.each do |chunk|
        chunk = chunk.to_s
        next if chunk.empty?

        client.write("#{chunk.bytesize.to_s(16)}\r\n")
        client.write(chunk)
        client.write("\r\n")
      end

      client.write("0\r\n\r\n")
    end

    def build_response_headers(headers, response_body)
      response_headers = headers.each_with_object({}) do |(name, value), normalized_headers|
        normalized_headers[name.to_s] = value.to_s
      end

      set_response_header!(response_headers, "Server", "Yamiochi")
      set_response_header!(response_headers, "Connection", "close")
      set_response_header!(response_headers, "Date", Time.now.httpdate)

      if response_body.fetch(:framing) == :chunked
        set_response_header!(response_headers, "Transfer-Encoding", "chunked")
      end

      if response_body.fetch(:framing) == :content_length && !response_header?(response_headers, "Content-Length")
        set_response_header!(response_headers, "Content-Length", response_body.fetch(:content_length))
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
