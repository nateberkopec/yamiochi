# frozen_string_literal: true

require "yaml"

module YamiochiFactory
  class GateRegistry
    LEVELS = %w[observe ratchet hard].freeze
    METRIC_TYPES = %w[binary score].freeze

    def self.default_path
      File.expand_path("../../../gates.yml", __dir__)
    end

    def self.load(path = default_path)
      raw = YAML.safe_load_file(path, aliases: false) || {}
      gates = raw.fetch("gates", {}).each_with_object({}) do |(name, gate), registry|
        registry[name.to_s] = normalize_gate(name.to_s, gate || {})
      end
      new(path:, version: Integer(raw.fetch("version", 1)), gates:)
    end

    def self.normalize_gate(name, gate)
      normalized = stringify_keys(gate).merge("name" => name)
      level = normalized.fetch("level")
      metric_type = normalized.fetch("metric_type")

      raise ArgumentError, "Unknown gate level #{level.inspect} for #{name}" unless LEVELS.include?(level)
      raise ArgumentError, "Unknown metric type #{metric_type.inspect} for #{name}" unless METRIC_TYPES.include?(metric_type)
      raise ArgumentError, "Gate #{name} is missing source.kind" if normalized.dig("source", "kind").to_s.empty?

      normalized["group"] ||= "ungrouped"
      normalized["selection_priority"] = Integer(normalized.fetch("selection_priority", 999))
      normalized["promotion"] = stringify_keys(normalized.fetch("promotion", {}))
      normalized["baseline"] = stringify_keys(normalized.fetch("baseline", {}))
      normalized["full_pass"] = stringify_keys(normalized.fetch("full_pass", {}))
      normalized["source"] = stringify_keys(normalized.fetch("source", {}))
      normalized
    end

    def self.stringify_keys(object)
      case object
      when Hash
        object.each_with_object({}) do |(key, value), normalized|
          normalized[key.to_s] = stringify_keys(value)
        end
      when Array
        object.map { |value| stringify_keys(value) }
      else
        object
      end
    end
    private_class_method :normalize_gate, :stringify_keys

    def initialize(path:, version:, gates:)
      @path = path
      @version = version
      @gates = gates
    end

    attr_reader :gates, :path, :version

    def gate(name)
      gates.fetch(name.to_s)
    end

    def each(&block)
      gates.each(&block)
    end

    def to_h
      {
        "version" => version,
        "gates" => gates
      }
    end
  end
end
