# frozen_string_literal: true

require "time"

module HeuristicSyndicate
  module Execution
    class ExecutionLease
      attr_reader :owner, :expires_at, :fencing_token

      def initialize(owner:, expires_at:, fencing_token:)
        @owner = owner&.to_s
        @expires_at = expires_at.is_a?(String) ? Time.parse(expires_at) : expires_at
        @fencing_token = fencing_token.is_a?(FencingToken) ? fencing_token : FencingToken.new(fencing_token || 0)
        freeze
      end

      def expired?(now = Time.now.utc)
        return true if @owner.nil? || @expires_at.nil?

        now >= @expires_at
      end

      def active?(now = Time.now.utc)
        !expired?(now)
      end

      def to_h
        {
          owner: @owner,
          expires_at: @expires_at&.utc&.iso8601(6),
          fencing_token: @fencing_token.to_i
        }
      end

      def self.from_h(hash)
        return new(owner: nil, expires_at: nil, fencing_token: 0) if hash.nil?

        h = hash.transform_keys(&:to_sym)
        new(
          owner: h[:owner],
          expires_at: h[:expires_at],
          fencing_token: h[:fencing_token] || 0
        )
      end
    end
  end
end
