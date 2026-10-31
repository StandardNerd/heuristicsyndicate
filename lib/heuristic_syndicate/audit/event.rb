# frozen_string_literal: true

require "digest"
require "time"
require "json"

module HeuristicSyndicate
  module Audit
    # Append-only, hash-chained Audit Event (ADR-007).
    class Event
      GENESIS_HASH = ("0" * 64).freeze

      attr_reader :id, :tenant_id, :run_id, :sequence, :timestamp,
                  :actor_id, :event_type, :payload, :payload_digest,
                  :previous_hash, :event_hash

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        sequence:,
        actor_id:,
        event_type:,
        payload: {},
        timestamp: Time.now.utc,
        payload_digest: nil,
        previous_hash: GENESIS_HASH,
        event_hash: nil
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @sequence = Integer(sequence)
        @timestamp = timestamp.is_a?(String) ? Time.parse(timestamp).utc : timestamp.utc
        @actor_id = actor_id.to_s
        @event_type = event_type.to_s
        @payload = payload || {}
        @payload_digest = payload_digest || Execution::Idempotency.digest(@payload)
        @previous_hash = (previous_hash || GENESIS_HASH).to_s
        @event_hash = (event_hash || compute_hash).to_s
        freeze
      end

      def compute_hash
        canonical = Execution::Idempotency.canonical_json(
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          sequence: @sequence,
          timestamp: @timestamp.utc.iso8601(6),
          actor_id: @actor_id,
          event_type: @event_type,
          payload_digest: @payload_digest,
          previous_hash: @previous_hash
        )
        Digest::SHA256.hexdigest(canonical)
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          sequence: @sequence,
          timestamp: @timestamp.utc.iso8601(6),
          actor_id: @actor_id,
          event_type: @event_type,
          payload: @payload,
          payload_digest: @payload_digest,
          previous_hash: @previous_hash,
          event_hash: @event_hash
        }
      end

      def self.from_h(hash)
        h = hash.transform_keys(&:to_sym)
        new(**h)
      end
    end
  end
end
