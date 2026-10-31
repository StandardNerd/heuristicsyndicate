# frozen_string_literal: true

module HeuristicSyndicate
  module Execution
    class FencingToken
      include Comparable

      attr_reader :value

      def initialize(value = 0)
        @value = Integer(value)
      end

      def next_token
        self.class.new(@value + 1)
      end

      def <=>(other)
        other_val = other.is_a?(FencingToken) ? other.value : Integer(other)
        @value <=> other_val
      end

      def to_i
        @value
      end

      def to_s
        @value.to_s
      end
    end
  end
end
