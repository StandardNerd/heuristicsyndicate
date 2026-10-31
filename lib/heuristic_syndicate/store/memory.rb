# frozen_string_literal: true

require "securerandom"
require "time"

module HeuristicSyndicate
  module Store
    # Thread-safe in-memory store with atomic compare-and-swap claims, fencing token checks,
    # lease expiration, outbox, and strict multi-tenant scoping (ADR-002, ADR-005, ADR-010).
    class Memory
      attr_reader :capabilities

      def initialize
        @mutex = Mutex.new
        @capabilities = StoreCapabilities.new(
          atomic_claims: true,
          compare_and_swap: true,
          transactions: true,
          durable_writes: false,
          multi_process: false,
          tenant_scoping: true,
          append_only_audit: true
        )
        reset!
      end

      def reset!
        synchronize do
          @runs = {}
          @node_executions = {}
          @idempotency_keys = {}
          @checkpoints = {}
          @conversation_checkpoints = {}
          @conversations = {}
          @interrupts = {}
          @approvals = {}
          @audit_events = []
          @execution_events = []
          @outbox = []
          @cache = {}
          @traces = []
          @documents = {}
        end
      end

      def transaction
        synchronize { yield self }
      end

      # --- Runs ---

      def save_run(run, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(run.tenant_id, tenant_id)
        synchronize do
          @runs[[tenant_id, run.id]] = deep_copy(run.to_h)
        end
        run
      end

      def find_run(run_id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          data = @runs[[tenant_id, run_id.to_s]]
          if data.nil?
            check_cross_tenant_violation!(@runs, run_id.to_s, tenant_id)
            return nil
          end
          Execution::Run.from_h(deep_copy(data))
        end
      end

      # --- NodeExecutions & Atomic Claim / Fencing (ADR-002 & Spike 2 §4.5) ---

      def create_node_execution(node_exec, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(node_exec.tenant_id, tenant_id)
        synchronize do
          if node_exec.idempotency_key
            idem_entry = @idempotency_keys[[tenant_id, node_exec.idempotency_key]]
            if idem_entry && idem_entry[:input_digest] != node_exec.input_digest
              raise IdempotencyConflict,
                    "Idempotency key '#{node_exec.idempotency_key}' already registered with different input_digest"
            end
            @idempotency_keys[[tenant_id, node_exec.idempotency_key]] = {
              input_digest: node_exec.input_digest,
              node_execution_id: node_exec.id
            }
          end
          @node_executions[[tenant_id, node_exec.id]] = deep_copy(node_exec.to_h)
        end
        node_exec
      end

      def find_node_execution(node_execution_id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          data = @node_executions[[tenant_id, node_execution_id.to_s]]
          if data.nil?
            check_cross_tenant_violation!(@node_executions, node_execution_id.to_s, tenant_id)
            return nil
          end
          Execution::NodeExecution.from_h(deep_copy(data))
        end
      end

      def list_node_executions(run_id:, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @node_executions.filter_map do |(t, _), data|
            Execution::NodeExecution.from_h(deep_copy(data)) if t == tenant_id && data[:run_id] == run_id.to_s
          end
        end
      end

      # Atomically claims a claimable NodeExecution, increments fencing_token, and assigns lease.
      # Returns the claimed NodeExecution or nil if not claimable.
      def claim_node_execution(node_execution_id:, worker_id:, tenant:, lease_duration: 60, now: Time.now.utc)
        tenant_id = require_tenant!(tenant)
        synchronize do
          key = [tenant_id, node_execution_id.to_s]
          data = @node_executions[key]
          if data.nil?
            check_cross_tenant_violation!(@node_executions, node_execution_id.to_s, tenant_id)
            return nil
          end

          current = Execution::NodeExecution.from_h(data)
          return nil unless current.claimable?(now)

          new_token = current.fencing_token + 1
          new_lease = Execution::ExecutionLease.new(
            owner: worker_id.to_s,
            expires_at: now + lease_duration,
            fencing_token: new_token
          )

          claimed = Execution::NodeExecution.new(
            id: current.id,
            tenant_id: current.tenant_id,
            run_id: current.run_id,
            node_id: current.node_id,
            status: :claimed,
            attempt: current.attempt + 1,
            input_digest: current.input_digest,
            idempotency_key: current.idempotency_key,
            lease: new_lease,
            output: current.output,
            error: nil,
            started_at: current.started_at || now,
            completed_at: nil,
            side_effect_recorded: current.side_effect_recorded
          )

          @node_executions[key] = deep_copy(claimed.to_h)
          record_execution_event_unlocked(
            tenant_id: tenant_id,
            run_id: claimed.run_id,
            node_execution_id: claimed.id,
            event_type: "node_claimed",
            fencing_token: new_token,
            occurred_at: now,
            payload: { worker_id: worker_id.to_s, attempt: claimed.attempt }
          )
          claimed
        end
      end

      # Atomically transitions a NodeExecution while enforcing the fencing token and state machine.
      # Optionally inserts an outbox message in the same atomic operation (Spike 2 §4.8).
      def transition_node_execution!(
        node_execution_id:,
        fencing_token:,
        to_status:,
        tenant:,
        output: :unchanged,
        error: :unchanged,
        side_effect_recorded: :unchanged,
        outbox_event: nil,
        now: Time.now.utc
      )
        tenant_id = require_tenant!(tenant)
        synchronize do
          key = [tenant_id, node_execution_id.to_s]
          data = @node_executions[key]
          if data.nil?
            check_cross_tenant_violation!(@node_executions, node_execution_id.to_s, tenant_id)
            raise RecoveryConflict, "NodeExecution '#{node_execution_id}' not found"
          end

          current = Execution::NodeExecution.from_h(data)
          if Integer(fencing_token) != current.fencing_token
            raise LeaseLostError,
                  "Stale fencing token #{fencing_token} rejected (current token is #{current.fencing_token}) " \
                  "for NodeExecution #{node_execution_id}"
          end

          current.validate_transition!(to_status)

          updated = Execution::NodeExecution.new(
            id: current.id,
            tenant_id: current.tenant_id,
            run_id: current.run_id,
            node_id: current.node_id,
            status: to_status.to_sym,
            attempt: current.attempt,
            input_digest: current.input_digest,
            idempotency_key: current.idempotency_key,
            lease: current.lease,
            output: output == :unchanged ? current.output : output,
            error: error == :unchanged ? current.error : error,
            started_at: current.started_at || now,
            completed_at: Execution::NodeExecution::TERMINAL_STATUSES.include?(to_status.to_sym) ? now : nil,
            side_effect_recorded: side_effect_recorded == :unchanged ? current.side_effect_recorded : side_effect_recorded
          )

          @node_executions[key] = deep_copy(updated.to_h)

          record_execution_event_unlocked(
            tenant_id: tenant_id,
            run_id: updated.run_id,
            node_execution_id: updated.id,
            event_type: "node_#{to_status}",
            fencing_token: current.fencing_token,
            occurred_at: now,
            payload: { status: to_status.to_s }
          )

          if outbox_event
            insert_outbox_unlocked(
              tenant_id: tenant_id,
              event_type: outbox_event[:event_type],
              aggregate_id: outbox_event[:aggregate_id] || updated.id,
              deduplication_key: outbox_event[:deduplication_key] || "#{outbox_event[:event_type]}:#{updated.id}:#{current.fencing_token}",
              payload: outbox_event[:payload] || {}
            )
          end

          updated
        end
      end

      def execution_events(run_id:, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @execution_events
            .select { |e| e[:tenant_id] == tenant_id && e[:run_id] == run_id.to_s }
            .map { |e| Execution::ExecutionEvent.from_h(deep_copy(e)) }
        end
      end

      # --- Outbox (ADR-002 & Spike 2 §4.8) ---

      def insert_outbox(tenant:, event_type:, aggregate_id:, deduplication_key:, payload: {})
        tenant_id = require_tenant!(tenant)
        synchronize do
          insert_outbox_unlocked(
            tenant_id: tenant_id,
            event_type: event_type,
            aggregate_id: aggregate_id,
            deduplication_key: deduplication_key,
            payload: payload
          )
        end
      end

      def pending_outbox_entries(tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @outbox.select { |e| e[:tenant_id] == tenant_id && e[:status] == "pending" }.map { |e| deep_copy(e) }
        end
      end

      def mark_outbox_delivered(deduplication_key, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          entry = @outbox.find { |e| e[:tenant_id] == tenant_id && e[:deduplication_key] == deduplication_key.to_s }
          entry[:status] = "delivered" if entry
          entry ? deep_copy(entry) : nil
        end
      end

      # --- Checkpoints & ConversationCheckpoints ---

      def save_checkpoint(checkpoint, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(checkpoint.tenant_id, tenant_id)
        synchronize do
          @checkpoints[[tenant_id, checkpoint.id]] = deep_copy(checkpoint.to_h)
        end
        checkpoint
      end

      def find_checkpoint(checkpoint_id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          data = @checkpoints[[tenant_id, checkpoint_id.to_s]]
          if data.nil?
            check_cross_tenant_violation!(@checkpoints, checkpoint_id.to_s, tenant_id)
            return nil
          end
          Execution::Checkpoint.from_h(deep_copy(data))
        end
      end

      def latest_checkpoint_for_run(run_id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          matches = @checkpoints.filter_map do |(t, _), data|
            Execution::Checkpoint.from_h(deep_copy(data)) if t == tenant_id && data[:run_id] == run_id.to_s
          end
          matches.max_by(&:created_at)
        end
      end

      def save_conversation_checkpoint(conv_chk, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(conv_chk.tenant_id, tenant_id)
        synchronize do
          @conversation_checkpoints[[tenant_id, conv_chk.id]] = deep_copy(conv_chk.to_h)
        end
        conv_chk
      end

      def find_conversation_checkpoint(id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          data = @conversation_checkpoints[[tenant_id, id.to_s]]
          if data.nil?
            check_cross_tenant_violation!(@conversation_checkpoints, id.to_s, tenant_id)
            return nil
          end
          LLM::ConversationCheckpoint.from_h(deep_copy(data))
        end
      end

      # --- Conversations / Transcripts ---

      def save_transcript(transcript_ref, tenant:, data:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @conversations[[tenant_id, transcript_ref.to_s]] = deep_copy(data)
        end
      end

      def load_transcript(transcript_ref, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          data = @conversations[[tenant_id, transcript_ref.to_s]]
          if data.nil?
            check_cross_tenant_violation!(@conversations, transcript_ref.to_s, tenant_id)
            return nil
          end
          deep_copy(data)
        end
      end

      # --- Interrupts & Approvals ---

      def save_interrupt(interrupt, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(interrupt.tenant_id, tenant_id)
        synchronize do
          @interrupts[[tenant_id, interrupt.id]] = deep_copy(interrupt.to_h)
        end
        interrupt
      end

      def find_interrupt(interrupt_id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          data = @interrupts[[tenant_id, interrupt_id.to_s]]
          if data.nil?
            check_cross_tenant_violation!(@interrupts, interrupt_id.to_s, tenant_id)
            return nil
          end
          Interrupts::Interrupt.from_h(deep_copy(data))
        end
      end

      def save_approval(approval_hash, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(approval_hash[:tenant_id], tenant_id)
        synchronize do
          @approvals[[tenant_id, approval_hash[:id].to_s]] = deep_copy(approval_hash)
        end
        approval_hash
      end

      def find_approvals_for_plan(plan_id, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @approvals.filter_map do |(t, _), data|
            deep_copy(data) if t == tenant_id && data[:plan_id].to_s == plan_id.to_s
          end
        end
      end

      # --- Append-Only Audit Events (ADR-007) ---

      def append_audit_event(event, tenant:)
        tenant_id = require_tenant!(tenant)
        verify_record_tenant!(event.tenant_id, tenant_id)
        synchronize do
          existing_seq = @audit_events.any? do |e|
            e[:tenant_id] == tenant_id && e[:run_id] == event.run_id && e[:sequence] == event.sequence
          end
          if existing_seq
            raise AuditIntegrityError,
                  "Duplicate audit sequence #{event.sequence} for tenant '#{tenant_id}' run '#{event.run_id}'"
          end
          @audit_events << deep_copy(event.to_h)
        end
        event
      end

      def list_audit_events(run_id:, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @audit_events
            .select { |e| e[:tenant_id] == tenant_id && e[:run_id] == run_id.to_s }
            .sort_by { |e| e[:sequence] }
            .map { |e| Audit::Event.from_h(deep_copy(e)) }
        end
      end

      # --- Cache ---

      def read_cache(cache_key, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @cache[[tenant_id, cache_key.to_s]]
        end
      end

      def write_cache(cache_key, value, tenant:)
        tenant_id = require_tenant!(tenant)
        synchronize do
          @cache[[tenant_id, cache_key.to_s]] = deep_copy(value)
        end
      end

      private

      def synchronize(&block)
        if @mutex.owned?
          yield
        else
          @mutex.synchronize(&block)
        end
      end

      def require_tenant!(tenant)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id : tenant
        raise TenantAccessDeniedError, "Explicit tenant is required for all store queries (ADR-005)" if tid.nil? || tid.to_s.empty?

        tid.to_s
      end

      def verify_record_tenant!(record_tenant_id, expected_tenant_id)
        return true if record_tenant_id.to_s == expected_tenant_id.to_s

        raise TenantAccessDeniedError,
              "Record tenant_id '#{record_tenant_id}' does not match store query tenant '#{expected_tenant_id}'"
      end

      def check_cross_tenant_violation!(map, record_id, current_tenant_id)
        other_tenant = map.keys.find { |(t, id)| id == record_id && t != current_tenant_id }
        return unless other_tenant

        raise TenantAccessDeniedError,
              "Cross-tenant access denied for record '#{record_id}' (requested by tenant '#{current_tenant_id}')"
      end

      def record_execution_event_unlocked(tenant_id:, run_id:, node_execution_id:, event_type:, fencing_token:, occurred_at:, payload:)
        seq = @execution_events.count { |e| e[:tenant_id] == tenant_id && e[:run_id] == run_id } + 1
        ev = Execution::ExecutionEvent.new(
          id: "ev_#{SecureRandom.hex(6)}",
          tenant_id: tenant_id,
          run_id: run_id,
          node_execution_id: node_execution_id,
          sequence: seq,
          event_type: event_type,
          fencing_token: fencing_token,
          occurred_at: occurred_at,
          payload: payload
        )
        @execution_events << deep_copy(ev.to_h)
      end

      def insert_outbox_unlocked(tenant_id:, event_type:, aggregate_id:, deduplication_key:, payload:)
        existing = @outbox.find { |e| e[:tenant_id] == tenant_id && e[:deduplication_key] == deduplication_key.to_s }
        return deep_copy(existing) if existing

        entry = {
          id: "outbox_#{SecureRandom.hex(6)}",
          tenant_id: tenant_id,
          event_type: event_type.to_s,
          aggregate_id: aggregate_id.to_s,
          deduplication_key: deduplication_key.to_s,
          payload: deep_copy(payload),
          status: "pending",
          created_at: Time.now.utc.iso8601(6)
        }
        @outbox << entry
        deep_copy(entry)
      end

      def deep_copy(obj)
        JSON.parse(JSON.generate(obj), symbolize_names: true)
      end
    end
  end
end
