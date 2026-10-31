# frozen_string_literal: true

module HeuristicSyndicate
  module Testing
    class SimulatedCrashError < StandardError
      attr_reader :crash_point, :metadata

      def initialize(crash_point, metadata = {})
        super("Simulated process crash at :#{crash_point}")
        @crash_point = crash_point.to_sym
        @metadata = metadata
      end
    end

    # Deterministic crash injector supporting both in-process exception simulation
    # and real OS subprocess sudden death (exit!(1) inside Process.fork) for Spike 2.
    class CrashInjector
      def initialize(crash_point: nil, mode: :exception, once: true)
        @crash_point = crash_point&.to_sym
        @mode = mode.to_sym # :exception or :kill_process
        @once = once
        @triggered = false
        @mutex = Mutex.new
      end

      def arm!(crash_point, mode: :exception, once: true)
        @mutex.synchronize do
          @crash_point = crash_point.to_sym
          @mode = mode.to_sym
          @once = once
          @triggered = false
        end
        self
      end

      def disarm!
        @mutex.synchronize { @crash_point = nil }
        self
      end

      def check!(point, **metadata)
        should_fire = @mutex.synchronize do
          next false if @crash_point.nil? || @crash_point != point.to_sym
          next false if @once && @triggered

          @triggered = true
          true
        end

        return unless should_fire

        if @mode == :kill_process
          Process.exit!(137)
        else
          raise SimulatedCrashError.new(point, metadata)
        end
      end

      # Runs a block in a forked child process that terminates abruptly via exit!(137)
      # when the armed crash point is reached. Returns the child exit status code.
      def self.run_in_crashing_subprocess(crash_point:, &block)
        injector = new(crash_point: crash_point, mode: :kill_process, once: true)
        pid = Process.fork do
          block.call(injector)
          Process.exit!(0)
        end
        _, status = Process.waitpid2(pid)
        status.exitstatus
      end
    end
  end
end
