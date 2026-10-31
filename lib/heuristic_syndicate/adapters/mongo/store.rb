# frozen_string_literal: true

module HeuristicSyndicate
  module Adapters
    module Mongo
      # First-class MongoDB Store Adapter (ADR-002, ADR-005, ADR-010 & Spike 2/3).
      # Uses atomic find_one_and_update for node claims, $inc for fencing tokens,
      # composite tenant indexes, and MongoDB replica-set transactions when supported.
      class Store
        attr_reader :client, :capabilities

        def initialize(client, transactions_supported: true)
          @client = client
          @capabilities = HeuristicSyndicate::Store::StoreCapabilities.new(
            atomic_claims: true,
            compare_and_swap: true,
            transactions: transactions_supported,
            durable_writes: true,
            multi_process: true,
            tenant_scoping: true,
            append_only_audit: true
          )
        end

        def ensure_indexes!
          @client[:runs].indexes.create_one({ tenant_id: 1, id: 1 }, unique: true)
          @client[:node_executions].indexes.create_one({ tenant_id: 1, id: 1 }, unique: true)
          @client[:node_executions].indexes.create_one({ tenant_id: 1, idempotency_key: 1 }, unique: true, sparse: true)
          @client[:audit_events].indexes.create_one({ tenant_id: 1, run_id: 1, sequence: 1 }, unique: true)
          @client[:outbox].indexes.create_one({ tenant_id: 1, deduplication_key: 1 }, unique: true)
          true
        end

        def claim_node_execution(node_execution_id:, worker_id:, tenant:, lease_duration: 60, now: Time.now.utc)
          tenant_id = require_tenant!(tenant)
          now_iso = now.utc.iso8601(6)
          expires_iso = (now + lease_duration).utc.iso8601(6)

          filter = {
            tenant_id: tenant_id,
            id: node_execution_id.to_s,
            "$or" => [
              { status: { "$in" => %w[pending retry_scheduled] } },
              { status: { "$in" => %w[claimed running] }, "lease.expires_at" => { "$lte" => now_iso } }
            ]
          }

          update = {
            "$set" => {
              status: "claimed",
              "lease.owner" => worker_id.to_s,
              "lease.expires_at" => expires_iso
            },
            "$inc" => {
              attempt: 1,
              "lease.fencing_token" => 1
            }
          }

          doc = @client[:node_executions].find_one_and_update(
            filter,
            update,
            return_document: :after
          )
          doc ? Execution::NodeExecution.from_h(doc) : nil
        end

        private

        def require_tenant!(tenant)
          tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id : tenant
          if tid.nil? || tid.to_s.empty?
            raise TenantAccessDeniedError, "Explicit tenant is required for MongoDB store queries"
          end

          tid.to_s
        end
      end
    end
  end
end
