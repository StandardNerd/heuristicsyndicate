# frozen_string_literal: true

module HeuristicSyndicate
  module Memory
    # Three separated Memory systems with independent lifecycles and tenant isolation (ADR-008).

    # 1. RunStateStore: Short-lived run context, blackboard state, node outputs, checkpoint & budget state.
    class RunStateStore
      attr_reader :backing_store

      def initialize(backing_store)
        @backing_store = backing_store
      end

      def save_run(run, tenant:)
        @backing_store.save_run(run, tenant: tenant)
      end

      def find_run(run_id, tenant:)
        @backing_store.find_run(run_id, tenant: tenant)
      end

      def save_checkpoint(checkpoint, tenant:)
        @backing_store.save_checkpoint(checkpoint, tenant: tenant)
      end

      def find_checkpoint(checkpoint_id, tenant:)
        @backing_store.find_checkpoint(checkpoint_id, tenant: tenant)
      end

      def latest_checkpoint_for_run(run_id, tenant:)
        @backing_store.latest_checkpoint_for_run(run_id, tenant: tenant)
      end
    end

    # 2. ConversationStore: Messages, tool calls, conversation IDs, agent history, ConversationCheckpoints.
    class ConversationStore
      attr_reader :backing_store

      def initialize(backing_store)
        @backing_store = backing_store
      end

      def save_transcript(transcript_ref, tenant:, data:)
        @backing_store.save_transcript(transcript_ref, tenant: tenant, data: data)
      end

      def load_transcript(transcript_ref, tenant:)
        @backing_store.load_transcript(transcript_ref, tenant: tenant)
      end

      def save_checkpoint(conv_checkpoint, tenant:)
        @backing_store.save_conversation_checkpoint(conv_checkpoint, tenant: tenant)
      end

      def find_checkpoint(checkpoint_id, tenant:)
        @backing_store.find_conversation_checkpoint(checkpoint_id, tenant: tenant)
      end
    end

    # 3. KnowledgeStore: Documents, metadata, embeddings, provenance, and tenant-enforced retrieval.
    Document = Struct.new(
      :id,
      :tenant_id,
      :content,
      :metadata,
      :embedding,
      :version,
      :source,
      :score,
      keyword_init: true
    )

    class KnowledgeStore
      def initialize
        @mutex = Mutex.new
        @documents = {}
      end

      def ingest(document, tenant:)
        tid = extract_tenant!(tenant)
        doc = document.is_a?(Document) ? document : Document.new(**document.transform_keys(&:to_sym))
        if doc.tenant_id && doc.tenant_id.to_s != tid
          raise TenantAccessDeniedError, "Cannot ingest document for tenant '#{doc.tenant_id}' into tenant '#{tid}'"
        end

        stored = Document.new(
          id: (doc.id || "doc_#{@documents.size + 1}").to_s,
          tenant_id: tid,
          content: doc.content.to_s,
          metadata: doc.metadata || {},
          embedding: doc.embedding,
          version: doc.version || 1,
          source: doc.source || "unknown"
        )

        @mutex.synchronize do
          @documents[[tid, stored.id]] = stored
        end
        stored
      end

      # Enforces tenant filtering PRIOR to retrieval (ADR-008 Security requirement).
      def search_keyword(query, tenant:, limit: 5, metadata_filter: {})
        tid = extract_tenant!(tenant)
        terms = query.to_s.downcase.scan(/\w+/).uniq

        candidates = @mutex.synchronize do
          @documents.filter_map do |(doc_tenant, _), doc|
            next unless doc_tenant == tid
            next unless matches_filter?(doc.metadata, metadata_filter)

            score = terms.count { |term| doc.content.downcase.include?(term) }.to_f
            next unless score.positive?

            Document.new(**doc.to_h.merge(score: score))
          end
        end

        candidates.sort_by { |d| -d.score }.first(limit)
      end

      def search_vector(query_vector, tenant:, limit: 5, metadata_filter: {})
        tid = extract_tenant!(tenant)
        qvec = Array(query_vector).map(&:to_f)

        candidates = @mutex.synchronize do
          @documents.filter_map do |(doc_tenant, _), doc|
            next unless doc_tenant == tid
            next unless doc.embedding && !doc.embedding.empty?
            next unless matches_filter?(doc.metadata, metadata_filter)

            sim = cosine_similarity(qvec, doc.embedding)
            Document.new(**doc.to_h.merge(score: sim))
          end
        end

        candidates.sort_by { |d| -d.score }.first(limit)
      end

      private

      def extract_tenant!(tenant)
        tid = tenant.respond_to?(:tenant_id) ? tenant.tenant_id : tenant
        raise TenantAccessDeniedError, "tenant is required for KnowledgeStore retrieval" if tid.nil? || tid.to_s.empty?

        tid.to_s
      end

      def matches_filter?(metadata, filter)
        return true if filter.nil? || filter.empty?

        filter.all? { |k, v| metadata[k] == v || metadata[k.to_s] == v || metadata[k.to_sym] == v }
      end

      def cosine_similarity(vec_a, vec_b)
        dot = vec_a.zip(vec_b).sum { |a, b| (a || 0.0) * (b || 0.0) }
        norm_a = Math.sqrt(vec_a.sum { |a| (a || 0.0)**2 })
        norm_b = Math.sqrt(vec_b.sum { |b| (b || 0.0)**2 })
        return 0.0 if norm_a.zero? || norm_b.zero?

        dot / (norm_a * norm_b)
      end
    end
  end
end
