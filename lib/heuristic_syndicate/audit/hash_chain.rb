# frozen_string_literal: true

require "securerandom"

module HeuristicSyndicate
  module Audit
    # Appends hash-chained audit events, emits signed integrity anchors, and verifies tamper evidence (ADR-007).
    class HashChain
      attr_reader :store, :anchor_store, :signing_key

      def initialize(store:, anchor_store: nil, signing_key: nil)
        @store = store
        @anchor_store = anchor_store || HeuristicSyndicate.config.anchor_store || InMemoryAnchorStore.new
        @signing_key = signing_key || HeuristicSyndicate.config.audit_secret
        @mutex = Mutex.new
      end

      def append(tenant:, run_id:, actor_id:, event_type:, payload: {})
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        @mutex.synchronize do
          events = @store.list_audit_events(run_id: run_id, tenant: tid)
          prev = events.last
          seq = prev ? prev.sequence + 1 : 1
          prev_hash = prev ? prev.event_hash : Event::GENESIS_HASH

          event = Event.new(
            id: "audit_#{SecureRandom.hex(8)}",
            tenant_id: tid,
            run_id: run_id.to_s,
            sequence: seq,
            actor_id: actor_id.to_s,
            event_type: event_type.to_s,
            payload: payload || {},
            previous_hash: prev_hash
          )
          @store.append_audit_event(event, tenant: tid)
          event
        end
      end

      def create_anchor!(tenant:, run_id:)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        events = @store.list_audit_events(run_id: run_id, tenant: tid)
        raise AuditIntegrityError, "Cannot create audit anchor for empty audit log" if events.empty?

        last = events.last
        chk = Checkpoint.new(
          id: "anchor_#{SecureRandom.hex(6)}",
          tenant_id: tid,
          run_id: run_id.to_s,
          up_to_sequence: last.sequence,
          head_event_hash: last.event_hash,
          signing_key: @signing_key
        )
        @anchor_store.write_anchor!(chk)
      end

      def verify!(tenant:, run_id:)
        Verifier.verify!(
          store: @store,
          anchor_store: @anchor_store,
          signing_key: @signing_key,
          tenant: tenant,
          run_id: run_id
        )
      end
    end

    module Verifier
      module_function

      def verify!(store:, tenant:, run_id:, anchor_store: nil, signing_key: HeuristicSyndicate.config.audit_secret)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        events = store.list_audit_events(run_id: run_id, tenant: tid)

        expected_prev = Event::GENESIS_HASH
        events.each_with_index do |ev, idx|
          expected_seq = idx + 1
          if ev.sequence != expected_seq
            raise AuditIntegrityError,
                  "Audit sequence gap/reorder at index #{idx}: expected #{expected_seq}, got #{ev.sequence}"
          end

          if ev.previous_hash != expected_prev
            raise AuditIntegrityError,
                  "Audit chain broken at sequence #{ev.sequence}: previous_hash mismatch"
          end

          actual_payload_digest = Execution::Idempotency.digest(ev.payload)
          if ev.payload_digest != actual_payload_digest
            raise AuditIntegrityError,
                  "Audit payload tampered at sequence #{ev.sequence}: payload_digest mismatch"
          end

          recomputed = ev.compute_hash
          if ev.event_hash != recomputed
            raise AuditIntegrityError,
                  "Audit event hash tampered at sequence #{ev.sequence}"
          end

          expected_prev = ev.event_hash
        end

        if anchor_store
          anchors = anchor_store.list_anchors(run_id: run_id, tenant: tid)
          anchors.each do |anchor|
            unless anchor.valid_signature?(signing_key)
              raise AuditIntegrityError,
                    "External audit anchor '#{anchor.id}' failed cryptographic signature verification"
            end

            matching_ev = events.find { |e| e.sequence == anchor.up_to_sequence }
            if matching_ev.nil?
              raise AuditIntegrityError,
                    "Audit truncation detected: events up to sequence #{anchor.up_to_sequence} missing from store"
            end

            if matching_ev.event_hash != anchor.head_event_hash
              raise AuditIntegrityError,
                    "External audit anchor mismatch at sequence #{anchor.up_to_sequence}: database chain was rewritten"
            end
          end
        end

        true
      end
    end
  end
end
