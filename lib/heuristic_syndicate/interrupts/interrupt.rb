# frozen_string_literal: true

require "time"

module HeuristicSyndicate
  module Interrupts
    # Pipeline Interrupt model (ADR-003).
    # Decoupled from RubyLLM approval internals; supports plan approvals, tool approvals, and manual review.
    class Interrupt
      STATUSES = %i[pending approved rejected resolved expired].freeze

      attr_reader :id, :tenant_id, :run_id, :node_id, :type, :resource_type,
                  :resource_id, :resource_digest, :status, :decision,
                  :decided_by, :decided_at, :created_at, :metadata

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        type: :approval,
        node_id: nil,
        resource_type: nil,
        resource_id: nil,
        resource_digest: nil,
        status: :pending,
        decision: nil,
        decided_by: nil,
        decided_at: nil,
        created_at: Time.now.utc,
        metadata: {}
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @node_id = node_id&.to_s
        @type = type.to_sym
        @resource_type = resource_type&.to_s
        @resource_id = resource_id&.to_s
        @resource_digest = resource_digest&.to_s
        @status = status.to_sym
        raise ArgumentError, "Invalid interrupt status: #{@status}" unless STATUSES.include?(@status)

        @decision = decision
        @decided_by = decided_by&.to_s
        @decided_at = decided_at.is_a?(String) ? Time.parse(decided_at) : decided_at
        @created_at = created_at.is_a?(String) ? Time.parse(created_at) : created_at
        @metadata = metadata || {}
      end

      def pending?
        @status == :pending
      end

      def approved?
        @status == :approved
      end

      def rejected?
        @status == :rejected
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          node_id: @node_id,
          type: @type.to_s,
          resource_type: @resource_type,
          resource_id: @resource_id,
          resource_digest: @resource_digest,
          status: @status.to_s,
          decision: @decision,
          decided_by: @decided_by,
          decided_at: @decided_at&.utc&.iso8601(6),
          created_at: @created_at.utc.iso8601(6),
          metadata: @metadata
        }
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        new(**h)
      end
    end
  end
end
