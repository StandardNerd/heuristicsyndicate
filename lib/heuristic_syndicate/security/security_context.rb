# frozen_string_literal: true

module HeuristicSyndicate
  module Security
    # Immutable Run Security Context (ADR-004 & ADR-005).
    class SecurityContext
      attr_reader :tenant_id, :actor_id, :capabilities, :environment, :policy_version, :execution_mode

      def initialize(
        tenant_id:,
        actor_id:,
        capabilities: [],
        environment: :production,
        policy_version: "1.0",
        execution_mode: :analysis
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?
        raise ArgumentError, "actor_id is required" if actor_id.nil? || actor_id.to_s.empty?

        @tenant_id = tenant_id.to_s.freeze
        @actor_id = actor_id.to_s.freeze
        @capabilities = if capabilities.is_a?(CapabilitySet)
                          capabilities
                        else
                          CapabilitySet.new(capabilities)
                        end.freeze
        @environment = environment.to_sym
        @policy_version = policy_version.to_s.freeze
        @execution_mode = execution_mode.to_sym # :analysis (read-only) or :executor (write-enabled)
        freeze
      end

      def executor_mode?
        @execution_mode == :executor
      end

      def with_execution_mode(mode)
        self.class.new(
          tenant_id: @tenant_id,
          actor_id: @actor_id,
          capabilities: @capabilities,
          environment: @environment,
          policy_version: @policy_version,
          execution_mode: mode
        )
      end

      def verify_tenant!(target_tenant_id)
        if target_tenant_id.nil? || target_tenant_id.to_s != @tenant_id
          raise TenantAccessDeniedError,
                "Cross-tenant access denied: context tenant '#{@tenant_id}' cannot access '#{target_tenant_id}'"
        end
        true
      end
    end
  end
end
