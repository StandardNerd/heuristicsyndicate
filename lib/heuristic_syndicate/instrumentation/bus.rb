# frozen_string_literal: true

module HeuristicSyndicate
  module Instrumentation
    # Public framework observability event bus (ADR-012).
    # Decoupled from RubyLLM private subscriber internals.
    class Bus
      VALID_EVENTS = %w[
        run.started run.completed run.failed run.suspended
        node.started node.completed node.failed node.retried
        agent.started agent.completed
        tool.called tool.completed tool.denied
        approval.requested approval.granted approval.rejected
        action.started action.applied action.verified action.compensated
      ].freeze

      def initialize
        @mutex = Mutex.new
        @subscribers = []
        @events = []
      end

      def subscribe(&block)
        raise ArgumentError, "Subscriber block required" unless block_given?

        @mutex.synchronize { @subscribers << block }
        block
      end

      def unsubscribe(subscriber)
        @mutex.synchronize { @subscribers.delete(subscriber) }
      end

      def emit(event_name, payload = {})
        event = {
          event: event_name.to_s,
          timestamp: Time.now.utc.iso8601(6),
          payload: payload.freeze
        }.freeze

        listeners = @mutex.synchronize do
          @events << event
          @subscribers.dup
        end

        listeners.each { |sub| sub.call(event) }
        event
      end

      def recorded_events(filter_type = nil)
        @mutex.synchronize do
          return @events.dup unless filter_type

          @events.select { |e| e[:event] == filter_type.to_s }
        end
      end

      def clear!
        @mutex.synchronize { @events.clear }
      end
    end
  end
end
