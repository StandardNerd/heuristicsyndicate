# frozen_string_literal: true

require "time"

module HeuristicSyndicate
  module Execution
    class ExecutionEvent
      attr_reader :id, :tenant_id, :run_id, :node_execution_id, :sequence,
                  :event_type, :fencing_token, :occurred_at, :payload

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        node_execution_id:,
        sequence:,
        event_type:,
        fencing_token: 0,
        occurred_at: Time.now.utc,
        payload: {}
      )
        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @node_execution_id = node_execution_id&.to_s
        @sequence = Integer(sequence)
        @event_type = event_type.to_s
        @fencing_token = Integer(fencing_token || 0)
        @occurred_at = occurred_at.is_a?(String) ? Time.parse(occurred_at) : occurred_at
        @payload = payload || {}
        freeze
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          node_execution_id: @node_execution_id,
          sequence: @sequence,
          event_type: @event_type,
          fencing_token: @fencing_token,
          occurred_at: @occurred_at.utc.iso8601(6),
          payload: @payload
        }
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        new(**h)
      end
    end
  end
end
