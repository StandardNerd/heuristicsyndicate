# frozen_string_literal: true

module HeuristicSyndicate
  module Runtime
    # Central Execution Policy & Budget Manager (ADR-009).
    class ExecutionPolicy
      attr_reader :max_parallel_nodes, :max_parallel_agents, :max_parallel_tools,
                  :max_model_requests, :max_tool_calls, :max_tokens, :max_cost,
                  :max_total_wall_time

      def initialize(
        max_parallel_nodes: 4,
        max_parallel_agents: 4,
        max_parallel_tools: 8,
        max_model_requests: 30,
        max_tool_calls: 50,
        max_tokens: 50_000,
        max_cost: 5.00,
        max_total_wall_time: 300
      )
        @max_parallel_nodes = Integer(max_parallel_nodes)
        @max_parallel_agents = Integer(max_parallel_agents)
        @max_parallel_tools = Integer(max_parallel_tools)
        @max_model_requests = Integer(max_model_requests)
        @max_tool_calls = Integer(max_tool_calls)
        @max_tokens = Integer(max_tokens)
        @max_cost = Float(max_cost)
        @max_total_wall_time = Float(max_total_wall_time)
        freeze
      end
    end

    class BudgetManager
      attr_reader :policy, :started_at

      def initialize(policy: ExecutionPolicy.new, initial_state: {}, started_at: Time.now.utc)
        @policy = policy
        @started_at = started_at
        @mutex = Mutex.new
        @model_requests = Integer(initial_state[:model_requests] || 0)
        @tool_calls = Integer(initial_state[:tool_calls] || 0)
        @tokens = Integer(initial_state[:tokens] || 0)
        @cost = Float(initial_state[:cost] || 0.0)
        @cancelled = initial_state[:cancelled] || false
      end

      def cancel!
        @mutex.synchronize { @cancelled = true }
      end

      def cancelled?
        @mutex.synchronize { @cancelled }
      end

      def check_limits!(now = Time.now.utc)
        @mutex.synchronize do
          raise BudgetExceededError, "Run execution was cancelled" if @cancelled

          elapsed = now - @started_at
          if elapsed > @policy.max_total_wall_time
            raise BudgetExceededError,
                  "Wall time budget exceeded (#{elapsed.round(2)}s > #{@policy.max_total_wall_time}s)"
          end
        end
        true
      end

      def record_model_request!(tokens: 0, cost: 0.0, now: Time.now.utc)
        check_limits!(now)
        @mutex.synchronize do
          if @model_requests + 1 > @policy.max_model_requests
            raise BudgetExceededError, "max_model_requests (#{@policy.max_model_requests}) exceeded"
          end
          if @tokens + Integer(tokens) > @policy.max_tokens
            raise BudgetExceededError, "max_tokens (#{@policy.max_tokens}) exceeded"
          end
          if @cost + Float(cost) > @policy.max_cost
            raise BudgetExceededError, "max_cost (#{@policy.max_cost}) exceeded"
          end

          @model_requests += 1
          @tokens += Integer(tokens)
          @cost += Float(cost)
        end
      end

      def record_tool_call!(now: Time.now.utc)
        check_limits!(now)
        @mutex.synchronize do
          if @tool_calls + 1 > @policy.max_tool_calls
            raise BudgetExceededError, "max_tool_calls (#{@policy.max_tool_calls}) exceeded"
          end

          @tool_calls += 1
        end
      end

      def snapshot
        @mutex.synchronize do
          {
            model_requests: @model_requests,
            tool_calls: @tool_calls,
            tokens: @tokens,
            cost: @cost.round(6),
            cancelled: @cancelled
          }
        end
      end
    end
  end
end
