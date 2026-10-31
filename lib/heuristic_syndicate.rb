# frozen_string_literal: true

require "ruby_llm"

require_relative "heuristic_syndicate/version"
require_relative "heuristic_syndicate/errors"
require_relative "heuristic_syndicate/configuration"
require_relative "heuristic_syndicate/instrumentation/bus"

# Shared Contracts & Execution Models
require_relative "heuristic_syndicate/execution/fencing_token"
require_relative "heuristic_syndicate/execution/execution_lease"
require_relative "heuristic_syndicate/execution/idempotency"
require_relative "heuristic_syndicate/execution/node_execution"
require_relative "heuristic_syndicate/execution/execution_event"
require_relative "heuristic_syndicate/execution/run"
require_relative "heuristic_syndicate/execution/checkpoint"
require_relative "heuristic_syndicate/interrupts/interrupt"

# Security & Capabilities
require_relative "heuristic_syndicate/security/capability"
require_relative "heuristic_syndicate/security/security_context"
require_relative "heuristic_syndicate/security/authorizer"
require_relative "heuristic_syndicate/security/credential_resolver"
require_relative "heuristic_syndicate/security/untrusted_data"

# Core Definitions
require_relative "heuristic_syndicate/definitions/tool"
require_relative "heuristic_syndicate/definitions/agent"
require_relative "heuristic_syndicate/definitions/component"
require_relative "heuristic_syndicate/definitions/action"

# Stores & Memory
require_relative "heuristic_syndicate/store/capabilities"
require_relative "heuristic_syndicate/store/memory"
require_relative "heuristic_syndicate/store/file"
require_relative "heuristic_syndicate/memory/stores"
require_relative "heuristic_syndicate/adapters/mongo/store"

# LLM Adapter & Testing
require_relative "heuristic_syndicate/llm/adapter"
require_relative "heuristic_syndicate/llm/conversation_checkpoint"
require_relative "heuristic_syndicate/llm/ruby_llm_adapter"
require_relative "heuristic_syndicate/testing/fake_provider"
require_relative "heuristic_syndicate/testing/crash_injector"
require_relative "heuristic_syndicate/testing/assertions"

# Governance & Audit
require_relative "heuristic_syndicate/audit/event"
require_relative "heuristic_syndicate/audit/checkpoint"
require_relative "heuristic_syndicate/audit/hash_chain"
require_relative "heuristic_syndicate/governance/action_registry"
require_relative "heuristic_syndicate/governance/plan"
require_relative "heuristic_syndicate/governance/approval"
require_relative "heuristic_syndicate/governance/executor"

# Runtime, Middleware & Pipeline
require_relative "heuristic_syndicate/runtime/budget_manager"
require_relative "heuristic_syndicate/runtime/execution_manager"
require_relative "heuristic_syndicate/runtime/agent_runtime"
require_relative "heuristic_syndicate/runtime/node_executor"
require_relative "heuristic_syndicate/middleware/stack"
require_relative "heuristic_syndicate/pipeline/graph"
require_relative "heuristic_syndicate/definitions/pipeline"
require_relative "heuristic_syndicate/rails/railtie"

module HeuristicSyndicate
  # Top-level Core API aliases (ADR §4)
  Agent = Definitions::Agent
  Tool = Definitions::Tool
  Component = Definitions::Component
  Action = Definitions::Action
  Pipeline = Definitions::Pipeline
  Interrupt = Interrupts::Interrupt
  SecurityContext = Security::SecurityContext
  ExecutionPolicy = Runtime::ExecutionPolicy
  ApprovalPolicy = Governance::ApprovalPolicy
  StoreCapabilities = Store::StoreCapabilities

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config if block_given?
      config
    end

    def store
      config.store ||= Store::Memory.new
    end

    def llm_adapter
      config.llm_adapter ||= LLM::RubyLLMAdapter.new
    end

    def event_bus
      config.event_bus ||= Instrumentation::Bus.new
    end

    def reset!
      @config = Configuration.new
      Testing::FakeProvider.reset!
    end
  end
end
