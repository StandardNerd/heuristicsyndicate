# frozen_string_literal: true

require "securerandom"
require "json"
require "ruby_llm"

module HeuristicSyndicate
  module LLM
    # Encapsulates RubyLLM::Chat behind the provider-independent LLM::Adapter contract (Spike 1 §3.2-3.5).
    # Uses RubyLLM::Chat#generate for model turns while keeping all tool execution,
    # capability checks, approval pauses, and transcript persistence under HeuristicSyndicate control.
    class RubyLLMAdapter < Adapter
      ADAPTER_NAME = "ruby_llm"
      ADAPTER_VERSION = RubyLLM::VERSION.split(".")[0..1].join(".")

      # Internal handle representing an active conversation managed by RubyLLMAdapter.
      ConversationHandle = Struct.new(
        :id,
        :tenant_id,
        :agent_name,
        :provider,
        :model,
        :instructions,
        :tool_classes,
        :tool_registry_version,
        :schema,
        :chat,
        :conversation_store,
        :transcript_ref,
        :paused_for_approval,
        keyword_init: true
      )

      def adapter_name
        ADAPTER_NAME
      end

      def adapter_version
        ADAPTER_VERSION
      end

      def create_conversation(config:, context:)
        tenant_id = extract_tenant_id!(context)
        conv_id = config[:conversation_id] || "conv_#{SecureRandom.hex(8)}"
        model_id = config[:model] || HeuristicSyndicate.config.default_model
        provider_id = (config[:provider] || HeuristicSyndicate.config.default_provider).to_sym
        tool_classes = Array(config[:tools])
        instructions = config[:instructions]
        schema = config[:schema]
        conv_store = context[:conversation_store]
        transcript_ref = config[:transcript_ref] || "transcript_#{conv_id}"

        chat = build_ruby_llm_chat(
          model_id: model_id,
          provider_id: provider_id,
          instructions: instructions,
          tool_classes: tool_classes,
          schema: schema
        )

        handle = ConversationHandle.new(
          id: conv_id,
          tenant_id: tenant_id,
          agent_name: config[:agent_name]&.to_s,
          provider: provider_id.to_s,
          model: model_id.to_s,
          instructions: instructions,
          tool_classes: tool_classes,
          tool_registry_version: compute_tool_registry_version(tool_classes),
          schema: schema,
          chat: chat,
          conversation_store: conv_store,
          transcript_ref: transcript_ref,
          paused_for_approval: false
        )

        persist_transcript(handle)
        handle
      end

      # Stages user input and executes a single model generation turn (never auto-executes tools).
      def execute(conversation:, input:)
        conversation.chat.ask_later(input.to_s)
        persist_transcript(conversation)
        execute_next_step(conversation: conversation)
      rescue RubyLLM::Error, StandardError => e
        raise translate_error(e, conversation)
      end

      # Advances the model by one generation step if no tool calls are unanswered.
      def execute_next_step(conversation:)
        if pending_tool_calls(conversation: conversation).any?
          return build_step_result(conversation, conversation.chat.messages.last)
        end

        msg = conversation.chat.generate
        persist_transcript(conversation)
        build_step_result(conversation, msg)
      rescue RubyLLM::Error, StandardError => e
        raise translate_error(e, conversation)
      end

      # Returns normalized ToolCallRequest structs for unanswered tool calls in the latest assistant turn.
      def pending_tool_calls(conversation:)
        messages = conversation.chat.messages
        answered_ids = messages.filter_map { |m| m.tool_call_id.to_s if m.role == :tool && m.tool_call_id }
        last_assistant = messages.reverse.find { |m| m.role == :assistant && m.tool_call? }
        return [] unless last_assistant && last_assistant.tool_calls

        last_assistant.tool_calls.filter_map do |call_id, tc|
          cid = (tc.respond_to?(:id) ? tc.id : call_id).to_s
          next if answered_ids.include?(cid)

          args = (tc.respond_to?(:arguments) ? tc.arguments : tc[:arguments]) || {}
          ToolCallRequest.new(
            id: cid,
            name: (tc.respond_to?(:name) ? tc.name : tc[:name]).to_s,
            arguments: args.transform_keys(&:to_sym),
            arguments_digest: Execution::Idempotency.digest(args)
          )
        end
      end

      # Executes pending tool calls via a caller-supplied block (HeuristicSyndicate runtime)
      # or records tool results cleanly into the conversation transcript.
      def execute_tool_calls(conversation:, &executor)
        raise ArgumentError, "Tool executor block is required" unless block_given?

        calls = pending_tool_calls(conversation: conversation)
        results = []

        calls.each do |tool_call|
          outcome = executor.call(tool_call)
          if outcome.is_a?(Hash) && outcome[:status] == :paused_for_approval
            conversation.paused_for_approval = true
            break
          end

          record_tool_result(
            conversation: conversation,
            tool_call_id: tool_call.id,
            result: outcome
          )
          results << { tool_call_id: tool_call.id, name: tool_call.name, result: outcome }
        end

        results
      end

      def record_tool_result(conversation:, tool_call_id:, result:)
        serialized_content = result.is_a?(String) ? result : JSON.generate(result)
        conversation.chat.add_message(
          role: :tool,
          content: serialized_content,
          tool_call_id: tool_call_id.to_s
        )
        conversation.paused_for_approval = false if pending_tool_calls(conversation: conversation).empty?
        persist_transcript(conversation)
      end

      def waiting?(conversation:)
        conversation.paused_for_approval || pending_tool_calls(conversation: conversation).any?
      end

      def complete?(conversation:)
        return false if waiting?(conversation: conversation)

        conversation.chat.complete?
      end

      def checkpoint(conversation:)
        persist_transcript(conversation)
        pending = pending_tool_calls(conversation: conversation).first
        status = if conversation.paused_for_approval
                   "waiting_for_approval"
                 elsif pending
                   "waiting_for_tool"
                 elsif complete?(conversation: conversation)
                   "completed"
                 else
                   "in_progress"
                 end

        pending_op = if pending
                       {
                         type: "tool_call",
                         call_id: pending.id,
                         tool_name: pending.name,
                         arguments_digest: pending.arguments_digest
                       }
                     end

        ConversationCheckpoint.new(
          id: "convchk_#{SecureRandom.hex(8)}",
          tenant_id: conversation.tenant_id,
          conversation_id: conversation.id,
          agent_name: conversation.agent_name,
          adapter: adapter_name,
          adapter_version: adapter_version,
          provider: conversation.provider,
          model: conversation.model,
          status: status,
          transcript_ref: conversation.transcript_ref,
          pending_operation: pending_op,
          tool_registry_version: conversation.tool_registry_version
        )
      end

      def restore(checkpoint:, context:)
        chk = checkpoint.is_a?(ConversationCheckpoint) ? checkpoint : ConversationCheckpoint.from_h(checkpoint)
        tenant_id = extract_tenant_id!(context)

        if chk.tenant_id != tenant_id
          raise TenantAccessDeniedError,
                "Cannot restore ConversationCheckpoint for tenant '#{chk.tenant_id}' in tenant '#{tenant_id}'"
        end

        unless chk.adapter == adapter_name
          raise AdapterCompatibilityError,
                "Checkpoint adapter '#{chk.adapter}' is incompatible with '#{adapter_name}'"
        end

        # Re-authorize and rebuild current tool registry from context (LLM-12)
        tool_classes = Array(context[:tools])
        security_context = context[:security_context]
        agent_class = context[:agent_class]

        if agent_class
          tool_classes = agent_class.tool_classes if tool_classes.empty?
          tool_classes.each do |tc|
            Security::Authorizer.authorize_agent_tool!(agent_class, tc)
            if security_context
              Security::Authorizer.authorize_tool_execution!(
                security_context: security_context,
                agent_class: agent_class,
                tool_class: tc
              )
            end
          end
        end

        # Verify that if a pending tool call exists in the checkpoint, that tool is still authorized!
        if chk.pending_operation && chk.pending_operation[:type] == "tool_call"
          pending_tool_name = chk.pending_operation[:tool_name].to_s
          authorized_names = tool_classes.map(&:tool_name)
          if (context.key?(:tools) || agent_class) && !authorized_names.include?(pending_tool_name)
            raise CapabilityDeniedError,
                  "Pending tool '#{pending_tool_name}' is no longer authorized in current tool registry"
          end
        end

        conv_store = context[:conversation_store]
        raise RecoveryConflict, "conversation_store is required in context to restore transcript" unless conv_store

        transcript_data = conv_store.load_transcript(chk.transcript_ref, tenant: tenant_id)
        if transcript_data.nil?
          raise RecoveryConflict, "Transcript '#{chk.transcript_ref}' not found in ConversationStore"
        end

        chat = build_ruby_llm_chat(
          model_id: chk.model,
          provider_id: chk.provider.to_sym,
          instructions: nil, # instructions are already in persisted transcript messages
          tool_classes: tool_classes,
          schema: context[:schema] || agent_class&.output_schema
        )

        # Rehydrate messages preserving String keys inside tool_calls so RubyLLM::Chat#pending_tool_calls matches!
        rehydrate_messages(chat, transcript_data[:messages] || [])

        ConversationHandle.new(
          id: chk.conversation_id,
          tenant_id: tenant_id,
          agent_name: chk.agent_name,
          provider: chk.provider,
          model: chk.model,
          instructions: nil,
          tool_classes: tool_classes,
          tool_registry_version: compute_tool_registry_version(tool_classes),
          schema: context[:schema] || agent_class&.output_schema,
          chat: chat,
          conversation_store: conv_store,
          transcript_ref: chk.transcript_ref,
          paused_for_approval: chk.status == "waiting_for_approval"
        )
      end

      private

      def extract_tenant_id!(context)
        sec = context[:security_context]
        tenant = sec&.tenant_id || context[:tenant_id] || context[:tenant]
        raise ArgumentError, "tenant_id or security_context is required" if tenant.nil? || tenant.to_s.empty?

        tenant.to_s
      end

      def build_ruby_llm_chat(model_id:, provider_id:, instructions:, tool_classes:, schema:)
        chat = RubyLLM.chat(
          model: model_id.to_s,
          provider: provider_id.to_sym,
          assume_model_exists: true
        )
        chat.with_instructions(instructions) if instructions && !instructions.empty?
        if tool_classes.any?
          descriptors = tool_classes.map { |tc| tc.to_ruby_llm_descriptor.new }
          chat.with_tools(*descriptors)
        end
        chat.with_schema(schema) if schema
        chat
      end

      def compute_tool_registry_version(tool_classes)
        names = Array(tool_classes).map(&:tool_name).sort
        Execution::Idempotency.digest(names)
      end

      def persist_transcript(handle)
        return unless handle.conversation_store

        serialized_messages = handle.chat.messages.map { |m| serialize_message(m) }
        handle.conversation_store.save_transcript(
          handle.transcript_ref,
          tenant: handle.tenant_id,
          data: {
            conversation_id: handle.id,
            provider: handle.provider,
            model: handle.model,
            messages: serialized_messages
          }
        )
      end

      def serialize_message(msg)
        raw = msg.to_h
        tool_calls_hash = if raw[:tool_calls]
                            raw[:tool_calls].to_h do |k, v|
                              [k.to_s, v.is_a?(Hash) ? v : v.to_h]
                            end
                          end
        {
          "role" => raw[:role].to_s,
          "content" => raw[:content],
          "model" => raw[:model],
          "tool_call_id" => raw[:tool_call_id]&.to_s,
          "tool_calls" => tool_calls_hash,
          "input_tokens" => raw[:input_tokens],
          "output_tokens" => raw[:output_tokens]
        }.compact
      end

      def rehydrate_messages(chat, message_hashes)
        chat.messages.clear
        message_hashes.each do |mh|
          h = mh.transform_keys(&:to_sym)
          if h[:tool_calls].is_a?(Hash)
            # Keep outer keys as Strings so RubyLLM::Chat#pending_tool_calls .except(*answered) works!
            h[:tool_calls] = h[:tool_calls].to_h do |call_id, tc_hash|
              tc_sym = tc_hash.transform_keys(&:to_sym)
              [call_id.to_s, tc_sym]
            end
          end
          chat.add_message(h)
        end
      end

      def build_step_result(conversation, msg)
        return nil unless msg

        calls = pending_tool_calls(conversation: conversation)
        parsed_json = begin
          JSON.parse(msg.content) if msg.content.is_a?(String) && msg.content.strip.start_with?("{", "[")
        rescue JSON::ParserError
          nil
        end

        StepResult.new(
          conversation_id: conversation.id,
          role: msg.role,
          content: msg.content,
          parsed: parsed_json,
          tool_calls: calls,
          status: calls.any? ? :waiting_for_tool : :completed,
          input_tokens: msg.tokens&.input || 0,
          output_tokens: msg.tokens&.output || 0,
          model: msg.model || conversation.model
        )
      end

      def translate_error(error, conversation)
        return error if error.is_a?(HeuristicSyndicate::Error)

        ProviderError.new(
          "Provider error (#{conversation&.provider}): #{error.message}",
          provider: conversation&.provider,
          original_error: error
        )
      end
    end
  end
end
