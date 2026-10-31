# frozen_string_literal: true

module HeuristicSyndicate
  module Runtime
    # Bounded thread executor for parallel pipeline nodes (ADR-009).
    class ExecutionManager
      attr_reader :max_parallel

      def initialize(max_parallel: 4)
        @max_parallel = [Integer(max_parallel), 1].max
      end

      def map_parallel(items, &block)
        return [] if items.empty?
        return items.map(&block) if items.size == 1 || @max_parallel == 1

        queue = Queue.new
        items.each_with_index { |item, idx| queue << [item, idx] }
        results = Array.new(items.size)
        errors = Queue.new

        worker_count = [@max_parallel, items.size].min
        threads = Array.new(worker_count) do
          Thread.new do
            loop do
              item, idx = begin
                queue.pop(true)
              rescue ThreadError
                break
              end
              begin
                results[idx] = block.call(item)
              rescue StandardError => e
                errors << e
                break
              end
            end
          end
        end

        threads.each(&:join)
        raise errors.pop unless errors.empty?

        results
      end
    end
  end
end
