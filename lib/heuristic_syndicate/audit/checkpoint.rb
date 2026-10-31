# frozen_string_literal: true

require "openssl"
require "time"

module HeuristicSyndicate
  module Audit
    # Cryptographically signed Audit Integrity Checkpoint stored in an external AnchorStore (ADR-007).
    class Checkpoint
      attr_reader :id, :tenant_id, :run_id, :up_to_sequence, :head_event_hash,
                  :created_at, :signature

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        up_to_sequence:,
        head_event_hash:,
        signing_key: nil,
        signature: nil,
        created_at: Time.now.utc
      )
        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @up_to_sequence = Integer(up_to_sequence)
        @head_event_hash = head_event_hash.to_s
        @created_at = created_at.is_a?(String) ? Time.parse(created_at).utc : created_at.utc
        key = signing_key || HeuristicSyndicate.config.audit_secret
        @signature = (signature || compute_signature(key)).to_s
        freeze
      end

      def compute_signature(signing_key)
        canonical = Execution::Idempotency.canonical_json(
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          up_to_sequence: @up_to_sequence,
          head_event_hash: @head_event_hash,
          created_at: @created_at.utc.iso8601(6)
        )
        OpenSSL::HMAC.hexdigest("SHA256", signing_key.to_s, canonical)
      end

      def valid_signature?(signing_key = HeuristicSyndicate.config.audit_secret)
        expected = compute_signature(signing_key)
        OpenSSL.fixed_length_secure_compare(expected, @signature)
      rescue ArgumentError
        false
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          up_to_sequence: @up_to_sequence,
          head_event_hash: @head_event_hash,
          created_at: @created_at.utc.iso8601(6),
          signature: @signature
        }
      end
    end

    # Write-once (WORM / Object Lock semantics) external integrity anchor store (ADR-007).
    class InMemoryAnchorStore
      def initialize
        @mutex = Mutex.new
        @anchors = {}
      end

      def write_anchor!(checkpoint)
        @mutex.synchronize do
          key = [checkpoint.tenant_id, checkpoint.run_id, checkpoint.up_to_sequence]
          if @anchors.key?(key)
            raise AuditIntegrityError,
                  "Object Lock violation: audit anchor for #{key.inspect} already exists and cannot be overwritten"
          end
          @anchors[key] = checkpoint
        end
        checkpoint
      end

      def list_anchors(run_id:, tenant:)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        @mutex.synchronize do
          @anchors
            .select { |(t, r, _), _| t == tid && r == run_id.to_s }
            .values
            .sort_by(&:up_to_sequence)
        end
      end
    end
  end
end
