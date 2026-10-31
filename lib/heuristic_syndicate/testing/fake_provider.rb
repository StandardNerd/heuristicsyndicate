# frozen_string_literal: true

require "json"
require "securerandom"
require "ruby_llm"

module HeuristicSyndicate
  module Testing
    # Offline scriptable FakeProvider for RubyLLM 2.1 (ADR-013 & Spike 1 §3.7).
    # Supports text replies, structured JSON schemas, single & multi-step tool calls,
    # provider errors, timeouts, token accounting, and conversation resume without network access.
    class FakeProvider < RubyLLM::Provider
      class << self
        def local?
          true
        end

        def assume_models_exist?
          true
        end

        def configuration_requirements
          []
        end

        def configuration_options
          []
        end

        def reset!
          @mutex ||= Mutex.new
          @mutex.synchronize do
            @scripts = []
            @call_history = []
            @fallback_handler = nil
          end
        end

        def mutex
          @mutex ||= Mutex.new
        end

        def scripts
          mutex.synchronize { @scripts ||= [] }
        end

        def call_history
          mutex.synchronize { (@call_history ||= []).dup }
        end

        def record_call(entry)
          mutex.synchronize do
            @call_history ||= []
            @call_history << entry
          end
        end

        # Enqueues a scripted response or block matcher.
        # Options:
        #   match: Regexp / String / Proc (optional matcher against latest user/tool message or model)
        #   model: String (optional model match)
        #   content: String or Hash (Hash is JSON-serialized for structured output)
        #   tool_calls: Array of { id:, name:, arguments: }
        #   error: Exception or Class
        #   input_tokens: Integer
        #   output_tokens: Integer
        def enqueue(**rule, &block)
          mutex.synchronize do
            @scripts ||= []
            @scripts << (block || rule)
          end
        end

        def script_text(text, match: nil, model: nil, input_tokens: 15, output_tokens: 25)
          enqueue(content: text, match: match, model: model, input_tokens: input_tokens, output_tokens: output_tokens)
        end

        def script_json(hash, match: nil, model: nil, input_tokens: 20, output_tokens: 40)
          enqueue(
            content: JSON.generate(hash),
            match: match,
            model: model,
            input_tokens: input_tokens,
            output_tokens: output_tokens
          )
        end

        def script_tool_call(name, arguments = {}, id: nil, match: nil, model: nil)
          enqueue(
            tool_calls: [{ id: id || "call_#{SecureRandom.hex(4)}", name: name.to_s, arguments: arguments }],
            match: match,
            model: model
          )
        end

        def script_tool_calls(calls_array, match: nil, model: nil)
          normalized = calls_array.map do |c|
            {
              id: (c[:id] || "call_#{SecureRandom.hex(4)}").to_s,
              name: c[:name].to_s,
              arguments: c[:arguments] || {}
            }
          end
          enqueue(tool_calls: normalized, match: match, model: model)
        end

        def script_error(error_or_message, match: nil, model: nil)
          err = error_or_message.is_a?(Exception) ? error_or_message : RuntimeError.new(error_or_message.to_s)
          enqueue(error: err, match: match, model: model)
        end

        def on_unmatched(&block)
          mutex.synchronize { @fallback_handler = block }
        end

        def next_matching_rule(messages:, model_id:, tools:)
          mutex.synchronize do
            @scripts ||= []
            idx = @scripts.find_index do |rule|
              matches_rule?(rule, messages: messages, model_id: model_id, tools: tools)
            end
            if idx
              @scripts.delete_at(idx)
            elsif @fallback_handler
              @fallback_handler
            end
          end
        end

        private

        def matches_rule?(rule, messages:, model_id:, tools:)
          return true if rule.is_a?(Proc)
          return false if rule[:model] && rule[:model].to_s != model_id.to_s
          return true if rule[:match].nil?

          last_text = messages.reverse.find { |m| m.role != :system }&.content.to_s
          case rule[:match]
          when Regexp
            last_text.match?(rule[:match])
          when String
            last_text.include?(rule[:match])
          when Proc
            rule[:match].call(messages, model_id, tools)
          else
            true
          end
        end
      end

      def api_base
        "http://fake.heuristic-syndicate.local"
      end

      def preprocess_messages(messages, **_kwargs)
        messages
      end

      def complete(messages, tools:, temperature:, model:, **kwargs)
        model_id = model.respond_to?(:id) ? model.id : model.to_s
        self.class.record_call(
          model: model_id,
          messages: messages.map(&:to_h),
          tools: tools.keys.map(&:to_s),
          schema: kwargs[:schema]
        )

        rule = self.class.next_matching_rule(messages: messages, model_id: model_id, tools: tools)
        if rule.is_a?(Proc)
          rule = rule.call(messages, model_id, tools)
        end

        if rule.nil?
          return RubyLLM::Message.new(
            role: :assistant,
            content: JSON.generate({ status: "ok", echo: messages.last&.content.to_s }),
            model: model_id,
            input_tokens: 10,
            output_tokens: 10
          )
        end

        raise rule[:error] if rule[:error]

        if rule[:tool_calls]
          tc_hash = rule[:tool_calls].to_h do |tc|
            cid = (tc[:id] || "call_#{SecureRandom.hex(4)}").to_s
            [
              cid,
              RubyLLM::ToolCall.new(
                id: cid,
                name: tc[:name].to_s,
                arguments: (tc[:arguments] || {}).transform_keys(&:to_s)
              )
            ]
          end

          RubyLLM::Message.new(
            role: :assistant,
            content: rule[:content] || "",
            tool_calls: tc_hash,
            model: model_id,
            input_tokens: rule[:input_tokens] || 20,
            output_tokens: rule[:output_tokens] || 15
          )
        else
          content = rule[:content]
          content = JSON.generate(content) if content.is_a?(Hash) || content.is_a?(Array)
          RubyLLM::Message.new(
            role: :assistant,
            content: content.to_s,
            model: model_id,
            input_tokens: rule[:input_tokens] || 15,
            output_tokens: rule[:output_tokens] || 25
          )
        end
      end

      def embed(text, model:, dimensions: nil, **_kwargs)
        inputs = Array(text)
        dims = dimensions || 8
        vectors = inputs.map do |t|
          bytes = t.to_s.bytes
          Array.new(dims) { |i| ((bytes[i % [bytes.size, 1].max] || 1) % 100) / 100.0 }
        end
        RubyLLM::Embedding.new(
          vectors: text.is_a?(Array) ? vectors : vectors.first,
          model: model.respond_to?(:id) ? model.id : model.to_s,
          input_tokens: inputs.sum { |s| s.to_s.split.size }
        )
      end
    end
  end
end

RubyLLM::Provider.register(:fake, HeuristicSyndicate::Testing::FakeProvider)
