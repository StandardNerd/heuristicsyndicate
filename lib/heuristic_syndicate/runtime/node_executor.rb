# frozen_string_literal: true

require "securerandom"

module HeuristicSyndicate
  module Runtime
    # Durable Node Executor & Crash Recovery Manager (ADR-002 & Spike 2 §4.2-4.8).
    # Implements atomic claims, lease + fencing enforcement, deterministic crash-injection hooks,
    # side-effect reconciliation, and outbox publishing.
    class NodeExecutor
      attr_reader :store, :lease_duration, :crash_injector

      def initialize(store:, lease_duration: 60, crash_injector: nil)
        @store = store
        @lease_duration = lease_duration
        @crash_injector = crash_injector
      end

      # Executes or recovers a NodeExecution under worker_id.
      # Supports crash injection at:
      #   :before_claim, :after_claim_before_start, :during_execution,
      #   :before_side_effect, :after_side_effect_before_commit,
      #   :after_commit_before_publish, :after_success_before_continue
      def execute_node(
        node_execution_id:,
        worker_id:,
        tenant:,
        inputs: {},
        action_contract: nil,
        now: Time.now.utc,
        &work_block
      )
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        trigger_crash!(:before_claim, node_execution_id: node_execution_id, worker_id: worker_id)

        claimed = @store.claim_node_execution(
          node_execution_id: node_execution_id,
          worker_id: worker_id,
          tenant: tid,
          lease_duration: @lease_duration,
          now: now
        )
        return nil if claimed.nil?

        token = claimed.fencing_token
        trigger_crash!(:after_claim_before_start, node_execution_id: claimed.id, worker_id: worker_id, fencing_token: token)

        # Verify input digest consistency if already recorded (REC-11)
        current_digest = Execution::Idempotency.digest(inputs)
        if claimed.input_digest && claimed.input_digest != current_digest
          raise IdempotencyConflict,
                "Input digest mismatch for NodeExecution #{claimed.id} " \
                "(expected #{claimed.input_digest}, got #{current_digest})"
        end

        running = @store.transition_node_execution!(
          node_execution_id: claimed.id,
          fencing_token: token,
          to_status: :running,
          tenant: tid,
          now: now
        )

        trigger_crash!(:during_execution, node_execution_id: running.id, worker_id: worker_id, fencing_token: token)

        # If this is a recovery attempt (attempt > 1) and a side effect may have occurred, reconcile!
        output = if running.attempt > 1 && running.side_effect_recorded && action_contract
                   recover_side_effect!(
                     node_execution: running,
                     action_contract: action_contract,
                     inputs: inputs,
                     fencing_token: token,
                     tenant: tid,
                     now: now
                   )
                 else
                   execute_fresh_work!(
                     node_execution: running,
                     action_contract: action_contract,
                     inputs: inputs,
                     worker_id: worker_id,
                     fencing_token: token,
                     tenant: tid,
                     now: now,
                     &work_block
                   )
                 end

        return output if output.is_a?(Execution::NodeExecution) && %i[interrupted uncertain_outcome].include?(output.status)

        outbox_ev = {
          event_type: "node_succeeded",
          aggregate_id: running.id,
          deduplication_key: "node_succeeded:#{running.id}",
          payload: { run_id: running.run_id, node_id: running.node_id }
        }

        succeeded = @store.transition_node_execution!(
          node_execution_id: running.id,
          fencing_token: token,
          to_status: :succeeded,
          output: output,
          outbox_event: outbox_ev,
          tenant: tid,
          now: now
        )

        trigger_crash!(:after_commit_before_publish, node_execution_id: succeeded.id, worker_id: worker_id, fencing_token: token)
        publish_outbox!(tenant: tid)
        trigger_crash!(:after_success_before_continue, node_execution_id: succeeded.id, worker_id: worker_id, fencing_token: token)

        succeeded
      end

      def publish_outbox!(tenant:, &dispatcher)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        entries = @store.pending_outbox_entries(tenant: tid)
        entries.each do |entry|
          dispatcher&.call(entry)
          @store.mark_outbox_delivered(entry[:deduplication_key], tenant: tid)
        end
        entries
      end

      private

      def execute_fresh_work!(node_execution:, action_contract:, inputs:, worker_id:, fencing_token:, tenant:, now:, &work_block)
        trigger_crash!(:before_side_effect, node_execution_id: node_execution.id, worker_id: worker_id, fencing_token: fencing_token)

        if action_contract
          # Record intent that external side effect is being invoked so recovery knows it may have happened
          @store.transition_node_execution!(
            node_execution_id: node_execution.id,
            fencing_token: fencing_token,
            to_status: :running,
            side_effect_recorded: true,
            tenant: tenant,
            now: now
          )
          idem_key = node_execution.idempotency_key || action_contract.idempotency_key({ run_id: node_execution.run_id }, inputs)
          result = action_contract.apply({ run_id: node_execution.run_id, fencing_token: fencing_token }, inputs, idempotency_key: idem_key)
        elsif work_block
          result = work_block.call(node_execution, fencing_token)
        else
          result = inputs
        end

        trigger_crash!(
          :after_side_effect_before_commit,
          node_execution_id: node_execution.id,
          worker_id: worker_id,
          fencing_token: fencing_token
        )
        result
      end

      def recover_side_effect!(node_execution:, action_contract:, inputs:, fencing_token:, tenant:, now:)
        strategy = action_contract.class.recovery_strategy
        idem_key = node_execution.idempotency_key || action_contract.idempotency_key({ run_id: node_execution.run_id }, inputs)
        ctx = { run_id: node_execution.run_id, fencing_token: fencing_token }

        case strategy
        when :idempotent
          action_contract.apply(ctx, inputs, idempotency_key: idem_key)
        when :reconcile
          action_contract.reconcile(ctx, inputs, idempotency_key: idem_key)
        when :manual_review, :non_retryable
          @store.transition_node_execution!(
            node_execution_id: node_execution.id,
            fencing_token: fencing_token,
            to_status: :uncertain_outcome,
            error: "Side effect outcome uncertain for #{strategy} action #{action_contract.class.name}",
            tenant: tenant,
            now: now
          )
        end
      rescue UncertainOutcome => e
        @store.transition_node_execution!(
          node_execution_id: node_execution.id,
          fencing_token: fencing_token,
          to_status: :uncertain_outcome,
          error: e.message,
          tenant: tenant,
          now: now
        )
      end

      def trigger_crash!(point, **metadata)
        @crash_injector&.check!(point, **metadata)
      end
    end
  end
end
