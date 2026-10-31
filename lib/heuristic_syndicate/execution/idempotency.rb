# frozen_string_literal: true

require "digest"
require "json"

module HeuristicSyndicate
  module Execution
    module Idempotency
      module_function

      def canonical_json(obj)
        case obj
        when Hash
          entries = obj.keys.map(&:to_s).sort.map do |k|
            orig_key = obj.key?(k) ? k : k.to_sym
            "#{JSON.generate(k)}:#{canonical_json(obj[orig_key])}"
          end
          "{#{entries.join(',')}}"
        when Array
          "[#{obj.map { |v| canonical_json(v) }.join(',')}]"
        when Symbol
          JSON.generate(obj.to_s)
        else
          JSON.generate(obj)
        end
      end

      def digest(obj)
        "sha256:#{Digest::SHA256.hexdigest(canonical_json(obj))}"
      end

      def build_key(run_id:, node_id:, version: "v1", extra: nil)
        parts = [run_id, node_id, version, extra].compact.map(&:to_s)
        parts.join(":")
      end
    end

    class IdempotencyKey
      attr_reader :value, :input_digest

      def initialize(value:, input_digest:)
        @value = value.to_s
        @input_digest = input_digest.to_s
        freeze
      end

      def verify_digest!(other_digest)
        return true if @input_digest == other_digest.to_s

        raise IdempotencyConflict,
              "Idempotency key '#{@value}' reused with conflicting input digest " \
              "(expected #{@input_digest}, got #{other_digest})"
      end

      def to_h
        { value: @value, input_digest: @input_digest }
      end
    end
  end
end
