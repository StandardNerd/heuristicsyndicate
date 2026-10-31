# frozen_string_literal: true

module HeuristicSyndicate
  module LLM
    # Normalized ToolCall request returned by LLM::Adapter#pending_tool_calls
    ToolCallRequest = Struct.new(
      :id,
      :name,
      :arguments,
      :arguments_digest,
      keyword_init: true
    )

    # Normalized step response returned by LLM::Adapter#execute / #execute_next_step
    StepResult = Struct.new(
      :conversation_id,
      :role,
      :content,
      :parsed,
      :tool_calls,
      :status,
      :input_tokens,
      :output_tokens,
      :model,
      keyword_init: true
    ) do
      def tool_call?
        Array(tool_calls).any?
      end
    end

    # Provider-independent LLM Adapter contract (ADR-001 & Spike 1 §3.3)
    class Adapter
      def adapter_name
        raise NotImplementedError
      end

      def adapter_version
        raise NotImplementedError
      end

      def create_conversation(config:, context:)
        raise NotImplementedError
      end

      def execute(conversation:, input:)
        raise NotImplementedError
      end

      def execute_next_step(conversation:)
        raise NotImplementedError
      end

      def pending_tool_calls(conversation:)
        raise NotImplementedError
      end

      def execute_tool_calls(conversation:, &executor)
        raise NotImplementedError
      end

      def record_tool_result(conversation:, tool_call_id:, result:)
        raise NotImplementedError
      end

      def waiting?(conversation:)
        raise NotImplementedError
      end

      def complete?(conversation:)
        raise NotImplementedError
      end

      def checkpoint(conversation:)
        raise NotImplementedError
      end

      def restore(checkpoint:, context:)
        raise NotImplementedError
      end
    end
  end
end
