# frozen_string_literal: true

module HeuristicSyndicate
  module Testing
    module Assertions
      def assert_run_completed(run)
        assert_equal :completed, run.status, "Expected run #{run.id} to be :completed, got :#{run.status} (#{run.error})"
      end

      def assert_run_suspended(run)
        assert_equal :suspended, run.status, "Expected run #{run.id} to be :suspended, got :#{run.status}"
        refute_empty run.interrupt_ids, "Expected suspended run #{run.id} to have at least one pending interrupt_id"
      end

      def assert_audit_chain_valid(store:, run_id:, tenant:, anchor_store: nil)
        assert Audit::Verifier.verify!(
          store: store,
          anchor_store: anchor_store,
          tenant: tenant,
          run_id: run_id
        )
      end
    end
  end
end
