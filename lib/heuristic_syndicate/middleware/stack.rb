# frozen_string_literal: true

require "timeout"

module HeuristicSyndicate
  module Middleware
    # Node execution context passed through the pipeline node middleware stack (ADR-011).
    NodeCall = Struct.new(
      :run_id,
      :node_id,
      :node_spec,
      :inputs,
      :security_context,
      :store,
      :audit_chain,
      :budget_manager,
      :event_bus,
      :metadata,
      keyword_init: true
    )

    class Base
      def initialize(app, **options)
        @app = app
        @options = options
      end

      def call(node_call)
        @app.call(node_call)
      end
    end

    class Instrumentation < Base
      def call(node_call)
        node_call.event_bus&.emit("node.started", run_id: node_call.run_id, node_id: node_call.node_id)
        result = @app.call(node_call)
        node_call.event_bus&.emit("node.completed", run_id: node_call.run_id, node_id: node_call.node_id)
        result
      rescue StandardError => e
        node_call.event_bus&.emit("node.failed", run_id: node_call.run_id, node_id: node_call.node_id, error: e.message)
        raise
      end
    end

    class Security < Base
      def call(node_call)
        sec = node_call.security_context
        raise SecurityError, "SecurityContext is required for node '#{node_call.node_id}'" unless sec

        target = node_call.node_spec[:target]
        if target.is_a?(Class) && target < Definitions::Agent
          target.validate_configuration!
          target.tool_classes.each do |tc|
            HeuristicSyndicate::Security::Authorizer.authorize_tool_execution!(
              security_context: sec,
              agent_class: target,
              tool_class: tc
            )
          end
        end
        @app.call(node_call)
      end
    end

    class Audit < Base
      def call(node_call)
        node_call.audit_chain&.append(
          tenant: node_call.security_context.tenant_id,
          run_id: node_call.run_id,
          actor_id: node_call.security_context.actor_id,
          event_type: "node.started",
          payload: { node_id: node_call.node_id.to_s }
        )
        result = @app.call(node_call)
        node_call.audit_chain&.append(
          tenant: node_call.security_context.tenant_id,
          run_id: node_call.run_id,
          actor_id: node_call.security_context.actor_id,
          event_type: "node.completed",
          payload: { node_id: node_call.node_id.to_s }
        )
        result
      end
    end

    class Budget < Base
      def call(node_call)
        node_call.budget_manager&.check_limits!
        @app.call(node_call)
      end
    end

    class Timeout < Base
      def call(node_call)
        seconds = node_call.node_spec[:timeout] || @options[:seconds]
        return @app.call(node_call) unless seconds

        ::Timeout.timeout(seconds, TransientError, "Node '#{node_call.node_id}' timed out after #{seconds}s") do
          @app.call(node_call)
        end
      end
    end

    class Retry < Base
      def call(node_call)
        max_retries = node_call.node_spec[:retries] || @options[:max_retries] || 0
        target = node_call.node_spec[:target]
        idempotent = if target.respond_to?(:idempotent?)
                       target.idempotent?
                     else
                       true
                     end

        attempts = 0
        begin
          attempts += 1
          @app.call(node_call)
        rescue TransientError => e
          # ADR-011: Retry is never automatically applied to non-idempotent operations
          if idempotent && attempts <= max_retries
            node_call.event_bus&.emit("node.retried", run_id: node_call.run_id, node_id: node_call.node_id, attempt: attempts, error: e.message)
            retry
          end
          raise
        end
      end
    end

    class Cache < Base
      def call(node_call)
        return @app.call(node_call) unless node_call.node_spec[:cache] && node_call.store

        sec = node_call.security_context
        target = node_call.node_spec[:target]
        ver = target.respond_to?(:version) ? target.version : "1.0.0"
        input_digest = Execution::Idempotency.digest(node_call.inputs)
        cache_key = "#{sec.tenant_id}:#{node_call.node_id}:#{ver}:#{sec.policy_version}:#{input_digest}"

        cached = node_call.store.read_cache(cache_key, tenant: sec.tenant_id)
        return cached if cached

        fresh = @app.call(node_call)
        node_call.store.write_cache(cache_key, fresh, tenant: sec.tenant_id)
        fresh
      end
    end

    class Guardrail < Base
      def call(node_call)
        result = @app.call(node_call)
        guard = node_call.node_spec[:guardrail] || @options[:validator]
        guard.call(result, node_call) if guard
        result
      end
    end

    class Stack
      DEFAULT_MIDDLEWARES = [
        Instrumentation,
        Security,
        Audit,
        Budget,
        Timeout,
        Retry,
        Cache,
        Guardrail
      ].freeze

      def initialize(entries = nil)
        @entries = entries ? entries.dup : DEFAULT_MIDDLEWARES.map { |m| [m, {}] }
      end

      def use(klass, **options)
        @entries << [klass, options]
        self
      end

      def call(node_call, &final_action)
        app = final_action
        @entries.reverse_each do |klass, opts|
          app = klass.new(app, **opts)
        end
        app.call(node_call)
      end
    end
  end
end
