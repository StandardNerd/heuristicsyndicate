# frozen_string_literal: true

require "securerandom"
require "time"

module HeuristicSyndicate
  module Governance
    # Approval Policy defining required approver counts, four-eyes distinctness, and TTL (ADR-006).
    class ApprovalPolicy
      DEFAULT_RISK_LEVELS = {
        low: 0,
        medium: 1,
        high: 2,
        critical: 2
      }.freeze

      attr_reader :risk_levels, :require_distinct_approvers, :expires_in

      def initialize(
        risk_levels: DEFAULT_RISK_LEVELS,
        require_distinct_approvers: true,
        expires_in: 3600
      )
        @risk_levels = DEFAULT_RISK_LEVELS.merge(risk_levels.transform_keys(&:to_sym)).freeze
        @require_distinct_approvers = require_distinct_approvers
        @expires_in = Integer(expires_in)
        freeze
      end

      def required_approvals_for(risk)
        @risk_levels.fetch(risk.to_sym, 1)
      end
    end

    # Manages replay-safe, digest-bound human approvals (ADR-006).
    class ApprovalManager
      attr_reader :store, :policy, :audit_chain, :event_bus

      def initialize(store:, policy: ApprovalPolicy.new, audit_chain: nil, event_bus: nil)
        @store = store
        @policy = policy
        @audit_chain = audit_chain
        @event_bus = event_bus || HeuristicSyndicate.event_bus
        @mutex = Mutex.new
      end

      # Records an approval decision atomically and idempotently.
      # Duplicate approvals by the same approver for the same plan+digest are ignored (ADR-002 / ADR-006).
      def record_approval(plan:, approver_id:, digest:, tenant:, approved_at: Time.now.utc, expires_at: nil)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        raise TenantAccessDeniedError, "Plan tenant mismatch" if plan.tenant_id != tid

        if digest.to_s != plan.digest
          raise ApprovalInvalidError,
                "Approval digest '#{digest}' does not match current plan digest '#{plan.digest}'"
        end

        if plan.expired?(approved_at)
          raise ApprovalInvalidError, "Plan '#{plan.id}' has already expired"
        end

        @mutex.synchronize do
          existing = @store.find_approvals_for_plan(plan.id, tenant: tid)
          duplicate = existing.find do |a|
            a[:approver_id].to_s == approver_id.to_s && a[:digest].to_s == digest.to_s && a[:decision] == "approved"
          end
          return duplicate if duplicate

          exp = expires_at || (approved_at + @policy.expires_in)
          record = {
            id: "appr_#{SecureRandom.hex(6)}",
            tenant_id: tid,
            plan_id: plan.id,
            run_id: plan.run_id,
            digest: digest.to_s,
            approver_id: approver_id.to_s,
            decision: "approved",
            approved_at: approved_at.utc.iso8601(6),
            expires_at: exp.utc.iso8601(6)
          }

          @store.save_approval(record, tenant: tid)
          @audit_chain&.append(
            tenant: tid,
            run_id: plan.run_id,
            actor_id: approver_id.to_s,
            event_type: "approval.granted",
            payload: { plan_id: plan.id, digest: digest.to_s }
          )
          @event_bus&.emit("approval.granted", plan_id: plan.id, approver_id: approver_id.to_s, digest: digest.to_s)
          record
        end
      end

      def verify_authorized!(plan:, current_registry:, tenant:, now: Time.now.utc)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id.to_s : tenant.to_s
        raise TenantAccessDeniedError, "Plan tenant mismatch" if plan.tenant_id != tid

        if plan.expired?(now)
          raise ApprovalInvalidError, "Plan '#{plan.id}' has expired"
        end

        # Verify that no Action version in the registry has drifted from the plan's approved steps (ADR-006)
        plan.steps.each do |step|
          latest_klass = current_registry.fetch!(step[:action])
          if latest_klass.version != step[:version].to_s
            raise ApprovalInvalidError,
                  "Action '#{step[:action]}' version drifted (plan approved v#{step[:version]}, " \
                  "current registry is v#{latest_klass.version})"
          end
        end

        # Recompute canonical digest to detect any tampering with steps, resources, environment, or policy
        recomputed = Digest.compute(
          plan: plan,
          environment: plan.environment,
          policy_version: plan.policy_version,
          resources: plan.resources,
          constraints: plan.constraints,
          expires_at: plan.expires_at
        )
        if recomputed != plan.digest
          raise ApprovalInvalidError, "Plan digest integrity check failed"
        end

        needed = @policy.required_approvals_for(plan.highest_risk)
        return true if needed <= 0

        approvals = @store.find_approvals_for_plan(plan.id, tenant: tid)
        valid_approvals = approvals.select do |a|
          a[:decision] == "approved" &&
            a[:digest].to_s == plan.digest &&
            Time.parse(a[:expires_at]) > now
        end

        approvers = valid_approvals.map { |a| a[:approver_id] }
        approvers.uniq! if @policy.require_distinct_approvers

        if approvers.size < needed
          raise ApprovalInvalidError,
                "Insufficient valid approvals for #{plan.highest_risk}-risk plan '#{plan.id}' " \
                "(got #{approvers.size}, need #{needed})"
        end

        true
      end
    end
  end
end
