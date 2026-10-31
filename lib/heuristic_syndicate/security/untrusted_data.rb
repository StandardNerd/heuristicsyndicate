# frozen_string_literal: true

require "json"

module HeuristicSyndicate
  module Security
    # Data classification and structured wrapping for untrusted external tool outputs (ADR-004).
    class UntrustedData
      SECRET_PATTERNS = [
        /(?:api[_-]?key|secret|password|token|authorization)\s*[:=]\s*["']?([A-Za-z0-9_\-\.]{8,})["']?/i,
        /Bearer\s+[A-Za-z0-9_\-\.]+/i,
        /postgres:\/\/[^:\s]+:[^@\s]+@/i
      ].freeze

      attr_reader :content, :source, :evidence_ref, :classification, :truncated

      def initialize(raw_content:, source:, evidence_ref: nil, max_bytes: 8_000)
        @source = source.to_s
        @evidence_ref = evidence_ref || "evidence:#{@source}:#{ object_id }"
        @classification = :untrusted

        serialized = raw_content.is_a?(String) ? raw_content : JSON.generate(raw_content)
        redacted = self.class.redact_secrets(serialized)

        if redacted.bytesize > max_bytes
          @content = "#{redacted.byteslice(0, max_bytes)}...[TRUNCATED]"
          @truncated = true
        else
          @content = redacted
          @truncated = false
        end
        freeze
      end

      def self.redact_secrets(text)
        result = text.to_s.dup
        result.gsub!(/(api[_-]?key|secret|password|token|authorization)(\s*[:=]\s*["']?)[^\s"',}]+/i, '\1\2[REDACTED]')
        result.gsub!(/Bearer\s+[A-Za-z0-9_\-\.]+/i, "Bearer [REDACTED]")
        result.gsub!(/(postgres:\/\/[^:\s]+:)[^@\s]+(@)/i, '\1[REDACTED]\2')
        result
      end

      def to_envelope
        {
          _classification: "untrusted_external_data",
          source: @source,
          evidence_ref: @evidence_ref,
          truncated: @truncated,
          data: @content
        }
      end

      def to_prompt_json
        JSON.generate(to_envelope)
      end
    end
  end
end
