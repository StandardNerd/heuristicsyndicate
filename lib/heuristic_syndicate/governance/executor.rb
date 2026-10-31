# frozen_string_literal: true

module HeuristicSyndicate
  module Governance
    # Deterministic Action Executor (ADR-006 & §3.2).
    # Never invokes an LLM. Enforces approval validity, action version matching,
    # executor-mode SecurityContext, preconditions, dry_run, apply, verify, and rollback/compensation.
    class Executor
      attr_reader :registry, :approval_manager, :audit_chain, :credential_resolver, :event_bus

      def initialize(
        registry:,
        approval_manager:,
        audit_chain:,
        credential_resolver: nil,
        event_bus: nil
      )
        @registry = registry
        @approval_manager = approval_manager
        @audit_chain = audit_chain
        @credential_resolver = credential_resolver
        @event_bus = event_bus || HeuristicSyndicate.event_bus
      end

      def execute!(plan:, security_context:, now: Time.now.utc)
        security_context.verify_tenant!(plan.tenant_id)

        unless security_context.executor_mode?
          raise CapabilityDeniedError, "Governance::Executor requires a SecurityContext in :executor mode"
        end

        if security_context.environment != plan.environment
          raise ApprovalInvalidError,
                "Environment mismatch: plan approved for '#{plan.environment}', executor running in '#{security_context.environment}'"
        end

        if security_context.policy_version != plan.policy_version
          raise ApprovalInvalidError,
                "Policy version mismatch: plan approved under v#{plan.policy_version}, current is v#{security_context.policy_version}"
        end

        # Step 1: Verify valid, non-expired approvals bound to the current plan digest & action versions
        @approval_manager.verify_authorized!(
          plan: plan,
          current_registry: @registry,
          tenant: security_context.tenant_id,
          now: now
        )

        applied_steps = []
        results = []

        begin
          plan.steps.each_with_index do |step, idx|
            action_class = @registry.fetch!(step[:action], version: step[:version])
            params = action_class.validate_params!(step[:params])
            resource = step[:resource]

            # Step 2: Capability & Resource Authorization check immediately before execution
            Security::Authorizer.authorize_action!(
              security_context: security_context,
              action_class: action_class,
              resource: resource
            )

            action = action_class.new
            exec_ctx = build_execution_context(plan, security_context, step)

            # Step 3: Immediate Precondition Recheck
            unless action.precondition(exec_ctx, params)
              raise PreconditionFailedError,
                    "Precondition failed for step #{idx} (#{step[:action]} v#{step[:version]})"
            end

            # Step 4: Dry Run
            action.dry_run(exec_ctx, params)

            # Step 5: Apply with Idempotency Key
            idem_key = action.idempotency_key(exec_ctx, params)
            @audit_chain.append(
              tenant: plan.tenant_id,
              run_id: plan.run_id,
              actor_id: security_context.actor_id,
              event_type: "action.started",
              payload: { step_index: idx, action: step[:action], version: step[:version], idempotency_key: idem_key }
            )
            @event_bus&.emit("action.started", action: step[:action], step_index: idx)

            apply_result = action.apply(exec_ctx, params, idempotency_key: idem_key)
            applied_steps << { index: idx, action: action, step: step, context: exec_ctx, params: params }

            @audit_chain.append(
              tenant: plan.tenant_id,
              run_id: plan.run_id,
              actor_id: security_context.actor_id,
              event_type: "action.applied",
              payload: { step_index: idx, action: step[:action], result: apply_result }
            )
            @event_bus&.emit("action.applied", action: step[:action], step_index: idx)

            # Step 6: Verify
            unless action.verify(exec_ctx, params)
              raise VerificationFailedError,
                    "Verification failed after applying step #{idx} (#{step[:action]})"
            end

            @audit_chain.append(
              tenant: plan.tenant_id,
              run_id: plan.run_id,
              actor_id: security_context.actor_id,
              event_type: "action.verified",
              payload: { step_index: idx, action: step[:action] }
            )
            @event_bus&.emit("action.verified", action: step[:action], step_index: idx)

            results << { step_index: idx, action: step[:action], status: :verified, output: apply_result }
          end

          { status: :completed, plan_id: plan.id, steps: results }
        rescue StandardError => e
          compensate_applied_steps(applied_steps, plan: plan, security_context: security_context, error: e)
          raise
        end
      end

      private

      def build_execution_context(plan, security_context, step)
        {
          run_id: plan.run_id,
          plan_id: plan.id,
          tenant_id: plan.tenant_id,
          security_context: security_context,
          credential_resolver: @credential_resolver,
          resource: step[:resource]
        }
      end

      def compensate_applied_steps(applied_steps, plan:, security_context:, error:)
        applied_steps.reverse_each do |entry|
          action = entry[:action]
          ctx = entry[:context]
          params = entry[:params]

          comp_outcome = action.compensate(ctx, params) || action.rollback(ctx, params)
          @audit_chain.append(
            tenant: plan.tenant_id,
            run_id: plan.run_id,
            actor_id: security_context.actor_id,
            event_type: "action.compensated",
            payload: {
              step_index: entry[:index],
              action: entry[:step][:action],
              reason: error.message,
              compensation: comp_outcome
            }
          )
          @event_bus&.emit("action.compensated", action: entry[:step][:action], step_index: entry[:index])
        end
      end
    end
  end
end
