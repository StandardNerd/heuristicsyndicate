# frozen_string_literal: true

require "json"

module HeuristicSyndicate
  module Runtime
    # Executes HeuristicSyndicate::Agent definitions via the provider-independent LLM::Adapter (ADR-001 & Spike 1).
    # Enforces capabilities, resolves dependencies per SecurityContext, tracks budgets,
    # and persists/restores ConversationCheckpoints when interrupted.
    class AgentRuntime
      attr_reader :adapter, :conversation_store, :credential_resolver, :budget_manager, :event_bus

      def initialize(
        adapter: HeuristicSyndicate.llm_adapter,
        conversation_store: nil,
        credential_resolver: nil,
        budget_manager: nil,
        event_bus: HeuristicSyndicate.event_bus
      )
        @adapter = adapter
        @conversation_store = conversation_store
        @credential_resolver = credential_resolver
        @budget_manager = budget_manager
        @event_bus = event_bus
      end

      def run(agent_class:, input:, security_context:, conversation_id: nil, on_before_tool: nil, on_after_tool: nil)
        agent_class.validate_configuration!
        prompt = format_input_prompt(input)
        instructions = agent_class.resolve_instructions(input.is_a?(Hash) ? input : {})

        conversation = @adapter.create_conversation(
          config: {
            conversation_id: conversation_id,
            agent_name: agent_class.name,
            model: agent_class.model,
            provider: agent_class.provider,
            instructions: instructions,
            tools: agent_class.tool_classes,
            schema: agent_class.output_schema
          },
          context: {
            security_context: security_context,
            conversation_store: @conversation_store
          }
        )

        @event_bus&.emit("agent.started", agent: agent_class.name, conversation_id: conversation.id)

        step_result = @adapter.execute(conversation: conversation, input: prompt)
        record_model_budget!(step_result)

        drive_tool_loop(
          agent_class: agent_class,
          conversation: conversation,
          last_step: step_result,
          security_context: security_context,
          on_before_tool: on_before_tool,
          on_after_tool: on_after_tool
        )
      end

      def resume(
        checkpoint:,
        agent_class:,
        security_context:,
        approved_tool_call_ids: [],
        precomputed_tool_results: {},
        on_before_tool: nil,
        on_after_tool: nil
      )
        agent_class.validate_configuration!
        conversation = @adapter.restore(
          checkpoint: checkpoint,
          context: {
            security_context: security_context,
            agent_class: agent_class,
            tools: agent_class.tool_classes,
            schema: agent_class.output_schema,
            conversation_store: @conversation_store
          }
        )

        # If a tool result was already reconciled externally after a crash, record it directly
        precomputed_tool_results.each do |call_id, result|
          @adapter.record_tool_result(
            conversation: conversation,
            tool_call_id: call_id.to_s,
            result: result
          )
        end

        last_step = if @adapter.pending_tool_calls(conversation: conversation).any?
                      nil
                    else
                      res = @adapter.execute_next_step(conversation: conversation)
                      record_model_budget!(res)
                      res
                    end

        drive_tool_loop(
          agent_class: agent_class,
          conversation: conversation,
          last_step: last_step,
          security_context: security_context,
          approved_tool_call_ids: Array(approved_tool_call_ids).map(&:to_s),
          on_before_tool: on_before_tool,
          on_after_tool: on_after_tool
        )
      end

      private

      def drive_tool_loop(
        agent_class:,
        conversation:,
        last_step:,
        security_context:,
        approved_tool_call_ids: [],
        on_before_tool: nil,
        on_after_tool: nil
      )
        max_turns = agent_class.stop_conditions[:max_turns] || 8
        turns = 0

        while @adapter.pending_tool_calls(conversation: conversation).any?
          turns += 1
          if turns > max_turns
            raise BudgetExceededError,
                  "Agent #{agent_class.name} exceeded max_turns (#{max_turns})"
          end

          paused_call = nil
          @adapter.execute_tool_calls(conversation: conversation) do |tool_call|
            tool_class = find_tool_class!(agent_class, tool_call.name)

            # Check if tool requires human approval and hasn't been approved yet (LLM-11)
            if tool_class.requires_approval? && !approved_tool_call_ids.include?(tool_call.id.to_s)
              paused_call = tool_call
              next { status: :paused_for_approval, tool_call: tool_call }
            end

            resource = tool_call.arguments[:resource]
            begin
              Security::Authorizer.authorize_tool_execution!(
                security_context: security_context,
                agent_class: agent_class,
                tool_class: tool_class,
                resource: resource
              )
            rescue CapabilityDeniedError => e
              @event_bus&.emit("tool.denied", agent: agent_class.name, tool: tool_call.name, error: e.message)
              raise
            end

            @budget_manager&.record_tool_call!
            on_before_tool&.call(tool_call, conversation)
            @event_bus&.emit("tool.called", agent: agent_class.name, tool: tool_call.name, call_id: tool_call.id)

            deps = resolve_tool_dependencies(tool_class, security_context)
            tool_instance = tool_class.new(resolved_dependencies: deps, security_context: security_context)
            result = tool_instance.call(**tool_call.arguments)

            on_after_tool&.call(tool_call, result, conversation)
            @event_bus&.emit("tool.completed", agent: agent_class.name, tool: tool_call.name, call_id: tool_call.id)
            result
          end

          if paused_call
            chk = @adapter.checkpoint(conversation: conversation)
            @conversation_store&.save_checkpoint(chk, tenant: security_context.tenant_id)
            return {
              status: :interrupted,
              reason: :tool_approval_required,
              tool_call: paused_call,
              conversation_id: conversation.id,
              conversation_checkpoint: chk
            }
          end

          last_step = @adapter.execute_next_step(conversation: conversation)
          record_model_budget!(last_step)
        end

        @event_bus&.emit("agent.completed", agent: agent_class.name, conversation_id: conversation.id)
        output_value = last_step&.parsed || last_step&.content
        {
          status: :completed,
          conversation_id: conversation.id,
          output: coerce_symbol_keys(output_value),
          socket: agent_class.output_socket_name,
          raw_step: last_step
        }
      end

      def find_tool_class!(agent_class, tool_name)
        tc = agent_class.tool_classes.find { |klass| klass.tool_name == tool_name.to_s }
        return tc if tc

        raise CapabilityDeniedError,
              "Agent #{agent_class.name} attempted to invoke undeclared tool '#{tool_name}'"
      end

      def resolve_tool_dependencies(tool_class, security_context)
        return {} if tool_class.injected_dependencies.empty?
        raise SecurityError, "CredentialResolver required for tool #{tool_class.name}" unless @credential_resolver

        tool_class.injected_dependencies.to_h do |dep_name|
          [dep_name, @credential_resolver.resolve(dep_name, security_context: security_context)]
        end
      end

      def record_model_budget!(step_result)
        return unless @budget_manager && step_result

        tokens = (step_result.input_tokens || 0) + (step_result.output_tokens || 0)
        @budget_manager.record_model_request!(tokens: tokens, cost: tokens * 0.00001)
      end

      def format_input_prompt(input)
        case input
        when String then input
        when Hash then JSON.generate(input)
        else input.to_s
        end
      end

      def coerce_symbol_keys(val)
        case val
        when Hash
          val.to_h { |k, v| [k.to_sym, coerce_symbol_keys(v)] }
        when Array
          val.map { |v| coerce_symbol_keys(v) }
        else
          val
        end
      end
    end
  end
end
