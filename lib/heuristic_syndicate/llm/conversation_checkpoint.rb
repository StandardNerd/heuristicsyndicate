# frozen_string_literal: true

require "time"
require "json"

module HeuristicSyndicate
  module LLM
    # Versioned, JSON-safe ConversationCheckpoint contract (ADR-003 & Spike 1 §3.4).
    # Never serializes Ruby objects, credentials, open connections, or tool instances.
    class ConversationCheckpoint
      CURRENT_SCHEMA_VERSION = 1

      FORBIDDEN_KEY_PATTERN = /\A(api_key|secret|password|token|authorization|credential|client|connection)\z/i

      attr_reader :id, :tenant_id, :schema_version, :adapter, :adapter_version,
                  :conversation_id, :agent_name, :provider, :model, :status,
                  :transcript_ref, :pending_operation, :tool_registry_version,
                  :created_at

      def initialize(
        id:,
        tenant_id:,
        conversation_id:,
        adapter:,
        adapter_version:,
        provider:,
        model:,
        status:,
        transcript_ref:,
        agent_name: nil,
        schema_version: CURRENT_SCHEMA_VERSION,
        pending_operation: nil,
        tool_registry_version: nil,
        created_at: Time.now.utc
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @schema_version = Integer(schema_version)
        @adapter = adapter.to_s
        @adapter_version = adapter_version.to_s
        @conversation_id = conversation_id.to_s
        @agent_name = agent_name&.to_s
        @provider = provider.to_s
        @model = model.to_s
        @status = status.to_s
        @transcript_ref = transcript_ref.to_s
        @pending_operation = normalize_pending_operation(pending_operation)
        @tool_registry_version = tool_registry_version.to_s
        @created_at = created_at.is_a?(String) ? Time.parse(created_at) : created_at

        validate_no_forbidden_data!(to_h)
        freeze
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          schema_version: @schema_version,
          adapter: @adapter,
          adapter_version: @adapter_version,
          conversation_id: @conversation_id,
          agent_name: @agent_name,
          provider: @provider,
          model: @model,
          status: @status,
          transcript_ref: @transcript_ref,
          pending_operation: @pending_operation,
          tool_registry_version: @tool_registry_version,
          created_at: @created_at.utc.iso8601(6)
        }
      end

      def to_json(*args)
        JSON.generate(to_h, *args)
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        if h[:schema_version] && Integer(h[:schema_version]) != CURRENT_SCHEMA_VERSION
          raise SerializationError, "Unsupported ConversationCheckpoint schema_version: #{h[:schema_version]}"
        end
        new(**h)
      end

      def self.from_json(json_str)
        parsed = JSON.parse(json_str)
        from_h(parsed)
      rescue JSON::ParserError => e
        raise SerializationError, "Invalid ConversationCheckpoint JSON: #{e.message}"
      end

      private

      def normalize_pending_operation(op)
        return nil if op.nil?

        raise SerializationError, "pending_operation must be a Hash" unless op.is_a?(Hash)

        op.transform_keys(&:to_sym)
      end

      def validate_no_forbidden_data!(value, path = "root")
        case value
        when nil, TrueClass, FalseClass, Numeric, String, Symbol
          true
        when Array
          value.each_with_index { |v, i| validate_no_forbidden_data!(v, "#{path}[#{i}]") }
        when Hash
          value.each do |k, v|
            if k.to_s.match?(FORBIDDEN_KEY_PATTERN)
              raise SerializationError, "Forbidden credential/connection key '#{k}' in ConversationCheckpoint at #{path}"
            end
            validate_no_forbidden_data!(v, "#{path}.#{k}")
          end
        else
          raise SerializationError, "Non-serializable object #{value.class} in ConversationCheckpoint at #{path}"
        end
      end
    end
  end
end
