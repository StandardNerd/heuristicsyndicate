# frozen_string_literal: true

require "time"

module HeuristicSyndicate
  module Execution
    # Pipeline-level Checkpoint (ADR-003 & Spike 1/2 §2).
    # Independent of ConversationCheckpoint. Never serializes credentials or live clients.
    class Checkpoint
      FORBIDDEN_CLASS_PATTERNS = [/Proc/, /Method/, /Thread/, /Mutex/, /IO/, /File/, /Socket/].freeze

      attr_reader :id, :tenant_id, :run_id, :node_id, :status, :node_outputs,
                  :visit_counts, :pending_interrupt_id, :conversation_checkpoint_id,
                  :dependency_refs, :budget_snapshot, :created_at

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        node_id: nil,
        status: :suspended,
        node_outputs: {},
        visit_counts: {},
        pending_interrupt_id: nil,
        conversation_checkpoint_id: nil,
        dependency_refs: [],
        budget_snapshot: {},
        created_at: Time.now.utc
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        validate_serializable!(node_outputs, "node_outputs")
        validate_serializable!(dependency_refs, "dependency_refs")

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @node_id = node_id&.to_s
        @status = status.to_sym
        @node_outputs = node_outputs || {}
        @visit_counts = (visit_counts || {}).transform_keys(&:to_s)
        @pending_interrupt_id = pending_interrupt_id&.to_s
        @conversation_checkpoint_id = conversation_checkpoint_id&.to_s
        @dependency_refs = Array(dependency_refs).map(&:to_s)
        @budget_snapshot = budget_snapshot || {}
        @created_at = created_at.is_a?(String) ? Time.parse(created_at) : created_at
        freeze
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          node_id: @node_id,
          status: @status.to_s,
          node_outputs: @node_outputs,
          visit_counts: @visit_counts,
          pending_interrupt_id: @pending_interrupt_id,
          conversation_checkpoint_id: @conversation_checkpoint_id,
          dependency_refs: @dependency_refs,
          budget_snapshot: @budget_snapshot,
          created_at: @created_at.utc.iso8601(6)
        }
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        new(**h)
      end

      private

      def validate_serializable!(value, path)
        case value
        when nil, TrueClass, FalseClass, Numeric, String, Symbol
          true
        when Array
          value.each_with_index { |item, idx| validate_serializable!(item, "#{path}[#{idx}]") }
        when Hash
          value.each do |k, v|
            if k.to_s.match?(/secret|password|api_key|token|credential|client/i) && !v.is_a?(Numeric)
              raise SerializationError, "Refusing to serialize sensitive key '#{k}' at #{path}"
            end
            validate_serializable!(v, "#{path}.#{k}")
          end
        else
          raise SerializationError,
                "Refusing to serialize non-primitive object of class #{value.class} at #{path} (ADR-003)"
        end
      end
    end
  end
end
