# frozen_string_literal: true

require "uri"

module HeuristicSyndicate
  module Security
    # Enforces the 4-layer capability & resource authorization model (ADR-004).
    class Authorizer
      PRIVATE_HOST_PATTERNS = [
        /\Alocalhost\z/i,
        /\A127\./,
        /\A10\./,
        /\A172\.(1[6-9]|2\d|3[0-1])\./,
        /\A192\.168\./,
        /\A169\.254\./,
        /\A\[?::1\]?\z/
      ].freeze

      def self.authorize_agent_tool!(agent_class, tool_class)
        # Layer 1 & 2: Agent Capability Declaration vs Tool Capability Requirement
        tool_access = tool_class.access_mode
        if tool_access.nil?
          raise CapabilityDeniedError,
                "Tool #{tool_class.name} has not declared read_only or writes access mode"
        end

        unless agent_class.permitted_modes.include?(tool_access)
          raise CapabilityDeniedError,
                "Agent #{agent_class.name} permits #{agent_class.permitted_modes.inspect}, " \
                "cannot use #{tool_access} tool #{tool_class.name}"
        end

        req_cap = tool_class.required_capability
        if req_cap.nil?
          raise CapabilityDeniedError,
                "Tool #{tool_class.name} must declare requires_capability"
        end

        unless agent_class.capability_set.allowed?(req_cap)
          raise CapabilityDeniedError,
                "Agent #{agent_class.name} does not declare capability :#{req_cap} required by #{tool_class.name}"
        end

        if agent_class.allowed_scopes.any? && tool_class.tool_scope &&
           !agent_class.allowed_scopes.include?(tool_class.tool_scope)
          raise CapabilityDeniedError,
                "Agent #{agent_class.name} scopes #{agent_class.allowed_scopes.inspect} " \
                "exclude tool scope '#{tool_class.tool_scope}'"
        end

        true
      end

      def self.authorize_tool_execution!(security_context:, agent_class:, tool_class:, resource: nil)
        raise SecurityError, "SecurityContext required" unless security_context.is_a?(SecurityContext)

        authorize_agent_tool!(agent_class, tool_class) if agent_class

        req_cap = tool_class.required_capability
        unless security_context.capabilities.allowed?(req_cap, resource: resource)
          raise CapabilityDeniedError,
                "SecurityContext for tenant '#{security_context.tenant_id}' denies capability " \
                ":#{req_cap}#{resource ? " on resource '#{resource}'" : ""}"
        end

        if tool_class.access_mode == :write && !security_context.executor_mode?
          raise CapabilityDeniedError,
                "Write tool #{tool_class.name} cannot execute in #{security_context.execution_mode} mode"
        end

        true
      end

      def self.authorize_action!(security_context:, action_class:, resource: nil)
        raise SecurityError, "SecurityContext required" unless security_context.is_a?(SecurityContext)

        unless security_context.executor_mode?
          raise CapabilityDeniedError,
                "Action #{action_class.name} requires :executor SecurityContext mode"
        end

        req_cap = action_class.required_capability
        if req_cap.nil? || !security_context.capabilities.allowed?(req_cap, resource: resource)
          raise CapabilityDeniedError,
                "SecurityContext denies action #{action_class.name} (requires :#{req_cap} on #{resource || '*'})"
        end

        true
      end

      def self.validate_egress_url!(url_str, allowed_hosts: [])
        uri = URI.parse(url_str.to_s)
        unless %w[http https].include?(uri.scheme)
          raise SecurityError, "Disallowed egress URI scheme: #{uri.scheme}"
        end

        host = uri.host.to_s
        if PRIVATE_HOST_PATTERNS.any? { |pat| host.match?(pat) } && !allowed_hosts.include?(host)
          raise SecurityError, "SSRF protection blocked private/loopback host: #{host}"
        end

        if allowed_hosts.any? && !allowed_hosts.include?(host)
          raise SecurityError, "Egress host '#{host}' is not in allowed_hosts #{allowed_hosts.inspect}"
        end

        true
      end
    end
  end
end
