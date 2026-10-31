# frozen_string_literal: true

require "time"

module HeuristicSyndicate
  module Execution
    class Run
      STATUSES = %i[pending running suspended completed failed cancelled].freeze

      attr_reader :id, :tenant_id, :pipeline_name, :status, :inputs, :outputs,
                  :state, :visit_counts, :interrupt_ids, :budget_state,
                  :error, :created_at, :updated_at

      def initialize(
        id:,
        tenant_id:,
        pipeline_name:,
        status: :pending,
        inputs: {},
        outputs: {},
        state: {},
        visit_counts: {},
        interrupt_ids: [],
        budget_state: {},
        error: nil,
        created_at: Time.now.utc,
        updated_at: Time.now.utc
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @pipeline_name = pipeline_name.to_s
        @status = status.to_sym
        raise ArgumentError, "Invalid Run status: #{@status}" unless STATUSES.include?(@status)

        @inputs = inputs || {}
        @outputs = outputs || {}
        @state = state || {}
        @visit_counts = (visit_counts || {}).transform_keys(&:to_s)
        @interrupt_ids = Array(interrupt_ids).map(&:to_s)
        @budget_state = budget_state || {}
        @error = error
        @created_at = created_at.is_a?(String) ? Time.parse(created_at) : created_at
        @updated_at = updated_at.is_a?(String) ? Time.parse(updated_at) : updated_at
      end

      def completed?
        @status == :completed
      end

      def suspended?
        @status == :suspended
      end

      def failed?
        @status == :failed
      end

      def running?
        @status == :running
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          pipeline_name: @pipeline_name,
          status: @status.to_s,
          inputs: @inputs,
          outputs: @outputs,
          state: @state,
          visit_counts: @visit_counts,
          interrupt_ids: @interrupt_ids,
          budget_state: @budget_state,
          error: @error,
          created_at: @created_at.utc.iso8601(6),
          updated_at: @updated_at.utc.iso8601(6)
        }
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        new(**h)
      end
    end
  end
end
