# frozen_string_literal: true

require "json"
require "fileutils"

module HeuristicSyndicate
  module Store
    # File-backed store using OS file locking (flock) so multi-process crash-recovery tests
    # (Process.fork / Process.kill) and development runs persist atomically on disk.
    class FileStore < Memory
      attr_reader :path

      def initialize(path:)
        @path = path.to_s
        FileUtils.mkdir_p(::File.dirname(@path))
        @lock_path = "#{@path}.lock"
        super()
        @capabilities = StoreCapabilities.new(
          atomic_claims: true,
          compare_and_swap: true,
          transactions: true,
          durable_writes: true,
          multi_process: true,
          tenant_scoping: true,
          append_only_audit: true
        )
      end

      def reset!
        synchronize do
          init_empty_state!
          flush_to_disk!
        end
      end

      private

      def synchronize
        if @in_file_lock
          return yield
        end

        @mutex.synchronize do
          ::File.open(@lock_path, ::File::RDWR | ::File::CREAT, 0o600) do |lock_file|
            lock_file.flock(::File::LOCK_EX)
            begin
              @in_file_lock = true
              load_from_disk!
              result = yield
              flush_to_disk!
              result
            ensure
              @in_file_lock = false
              lock_file.flock(::File::LOCK_UN)
            end
          end
        end
      end

      def init_empty_state!
        @runs = {}
        @node_executions = {}
        @idempotency_keys = {}
        @checkpoints = {}
        @conversation_checkpoints = {}
        @conversations = {}
        @interrupts = {}
        @approvals = {}
        @audit_events = []
        @execution_events = []
        @outbox = []
        @cache = {}
        @traces = []
        @documents = {}
      end

      def load_from_disk!
        init_empty_state!
        return unless ::File.exist?(@path) && ::File.size(@path).positive?

        raw = JSON.parse(::File.read(@path), symbolize_names: true)
        @runs = deserialize_pair_map(raw[:runs])
        @node_executions = deserialize_pair_map(raw[:node_executions])
        @idempotency_keys = deserialize_pair_map(raw[:idempotency_keys])
        @checkpoints = deserialize_pair_map(raw[:checkpoints])
        @conversation_checkpoints = deserialize_pair_map(raw[:conversation_checkpoints])
        @conversations = deserialize_pair_map(raw[:conversations])
        @interrupts = deserialize_pair_map(raw[:interrupts])
        @approvals = deserialize_pair_map(raw[:approvals])
        @cache = deserialize_pair_map(raw[:cache])
        @audit_events = Array(raw[:audit_events])
        @execution_events = Array(raw[:execution_events])
        @outbox = Array(raw[:outbox])
      end

      def flush_to_disk!
        payload = {
          runs: serialize_pair_map(@runs),
          node_executions: serialize_pair_map(@node_executions),
          idempotency_keys: serialize_pair_map(@idempotency_keys),
          checkpoints: serialize_pair_map(@checkpoints),
          conversation_checkpoints: serialize_pair_map(@conversation_checkpoints),
          conversations: serialize_pair_map(@conversations),
          interrupts: serialize_pair_map(@interrupts),
          approvals: serialize_pair_map(@approvals),
          cache: serialize_pair_map(@cache),
          audit_events: @audit_events,
          execution_events: @execution_events,
          outbox: @outbox
        }
        tmp = "#{@path}.tmp.#{Process.pid}"
        ::File.write(tmp, JSON.generate(payload))
        ::File.rename(tmp, @path)
      end

      def serialize_pair_map(map)
        (map || {}).map { |(t, id), val| { tenant_id: t.to_s, key_id: id.to_s, value: val } }
      end

      def deserialize_pair_map(list)
        (list || []).to_h { |entry| [[entry[:tenant_id].to_s, entry[:key_id].to_s], entry[:value]] }
      end
    end
  end
end
