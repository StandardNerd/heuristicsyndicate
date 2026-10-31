# frozen_string_literal: true

require "time"

module HeuristicSyndicate
  module Execution
    # NodeExecution state machine & model (ADR-002 & Spike 2 §4.3-4.4)
    class NodeExecution
      STATUSES = %i[
        pending
        claimed
        running
        succeeded
        failed
        retry_scheduled
        interrupted
        uncertain_outcome
        skipped
        cancelled
      ].freeze

      TERMINAL_STATUSES = %i[succeeded failed skipped cancelled].freeze

      VALID_TRANSITIONS = {
        pending: %i[claimed skipped cancelled],
        claimed: %i[running claimed failed interrupted uncertain_outcome cancelled],
        running: %i[running succeeded failed retry_scheduled interrupted uncertain_outcome claimed cancelled],
        retry_scheduled: %i[claimed failed cancelled],
        interrupted: %i[claimed running succeeded failed cancelled],
        uncertain_outcome: %i[claimed running succeeded failed interrupted cancelled],
        succeeded: [],
        failed: [],
        skipped: [],
        cancelled: []
      }.freeze

      attr_reader :id, :tenant_id, :run_id, :node_id, :status, :attempt,
                  :input_digest, :idempotency_key, :lease, :output, :error,
                  :started_at, :completed_at, :side_effect_recorded

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        node_id:,
        status: :pending,
        attempt: 0,
        input_digest: nil,
        idempotency_key: nil,
        lease: nil,
        output: nil,
        error: nil,
        started_at: nil,
        completed_at: nil,
        side_effect_recorded: false
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @node_id = node_id.to_s
        @status = status.to_sym
        raise ArgumentError, "Invalid status: #{@status}" unless STATUSES.include?(@status)

        @attempt = Integer(attempt)
        @input_digest = input_digest
        @idempotency_key = idempotency_key
        @lease = lease.is_a?(ExecutionLease) ? lease : ExecutionLease.from_h(lease)
        @output = output
        @error = error
        @started_at = parse_time(started_at)
        @completed_at = parse_time(completed_at)
        @side_effect_recorded = !side_effect_recorded.nil? && side_effect_recorded != false
      end

      def fencing_token
        @lease.fencing_token.to_i
      end

      def lease_owner
        @lease.owner
      end

      def lease_expires_at
        @lease.expires_at
      end

      def terminal?
        TERMINAL_STATUSES.include?(@status)
      end

      def claimable?(now = Time.now.utc)
        return false if terminal?
        return true if %i[pending retry_scheduled].include?(@status)
        return true if %i[claimed running].include?(@status) && @lease.expired?(now)

        false
      end

      def can_transition_to?(new_status)
        VALID_TRANSITIONS.fetch(@status, []).include?(new_status.to_sym)
      end

      def validate_transition!(new_status)
        target = new_status.to_sym
        return true if can_transition_to?(target)

        raise RecoveryConflict,
              "Invalid NodeExecution state transition for #{@id} (#{@node_id}): #{@status} -> #{target}"
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          node_id: @node_id,
          status: @status.to_s,
          attempt: @attempt,
          input_digest: @input_digest,
          idempotency_key: @idempotency_key,
          lease: @lease.to_h,
          output: @output,
          error: @error,
          started_at: @started_at&.utc&.iso8601(6),
          completed_at: @completed_at&.utc&.iso8601(6),
          side_effect_recorded: @side_effect_recorded
        }
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        new(
          id: h[:id],
          tenant_id: h[:tenant_id],
          run_id: h[:run_id],
          node_id: h[:node_id],
          status: h[:status]&.to_sym || :pending,
          attempt: h[:attempt] || 0,
          input_digest: h[:input_digest],
          idempotency_key: h[:idempotency_key],
          lease: ExecutionLease.from_h(h[:lease]),
          output: h[:output],
          error: h[:error],
          started_at: h[:started_at],
          completed_at: h[:completed_at],
          side_effect_recorded: h.fetch(:side_effect_recorded, false)
        )
      end

      private

      def parse_time(val)
        return nil if val.nil?

        val.is_a?(String) ? Time.parse(val) : val
      end
    end
  end
end
