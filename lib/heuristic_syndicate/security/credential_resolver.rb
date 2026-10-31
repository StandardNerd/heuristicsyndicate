# frozen_string_literal: true

module HeuristicSyndicate
  module Security
    # Resolves tenant-scoped credentials and client dependencies at runtime (ADR-003 & ADR-004).
    # Never persists or serializes resolved objects. Write credentials are only resolved in :executor mode.
    class CredentialResolver
      def initialize
        @mutex = Mutex.new
        @providers = {}
      end

      def register(name, mode: :read, tenant_id: :any, &factory)
        raise ArgumentError, "Factory block or callable required" unless block_given?

        @mutex.synchronize do
          @providers[[name.to_sym, tenant_id.to_s]] = { mode: mode.to_sym, factory: factory }
        end
        self
      end

      def register_value(name, value, mode: :read, tenant_id: :any)
        register(name, mode: mode, tenant_id: tenant_id) { value }
      end

      def resolve(name, security_context:)
        raise SecurityError, "SecurityContext is required to resolve dependencies" unless security_context

        entry = @mutex.synchronize do
          @providers[[name.to_sym, security_context.tenant_id]] ||
            @providers[[name.to_sym, "any"]]
        end

        raise SecurityError, "Unregistered dependency '#{name}' for tenant '#{security_context.tenant_id}'" unless entry

        if entry[:mode] == :write && !security_context.executor_mode?
          raise CapabilityDeniedError,
                "Write credential/dependency '#{name}' cannot be resolved outside :executor mode"
        end

        entry[:factory].call(security_context)
      end

      def registered_names(tenant_id: nil)
        @mutex.synchronize do
          @providers.keys
                    .select { |(_, t)| tenant_id.nil? || t == "any" || t == tenant_id.to_s }
                    .map(&:first)
                    .uniq
        end
      end
    end
  end
end
