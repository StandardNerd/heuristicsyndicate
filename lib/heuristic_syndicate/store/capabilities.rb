# frozen_string_literal: true

module HeuristicSyndicate
  module Store
    # Explicit store guarantee declarations (ADR-010).
    class StoreCapabilities
      attr_reader :atomic_claims, :compare_and_swap, :transactions,
                  :durable_writes, :multi_process, :tenant_scoping, :append_only_audit

      def initialize(
        atomic_claims:,
        compare_and_swap:,
        transactions:,
        durable_writes:,
        multi_process: false,
        tenant_scoping: true,
        append_only_audit: true
      )
        @atomic_claims = atomic_claims
        @compare_and_swap = compare_and_swap
        @transactions = transactions
        @durable_writes = durable_writes
        @multi_process = multi_process
        @tenant_scoping = tenant_scoping
        @append_only_audit = append_only_audit
        freeze
      end

      def verify_requirements!(**required)
        required.each do |cap, expected|
          next unless expected

          actual = public_send(cap)
          unless actual
            raise StoreCapabilityError,
                  "Store adapter does not satisfy required capability :#{cap}"
          end
        end
        true
      end

      def to_h
        {
          atomic_claims: @atomic_claims,
          compare_and_swap: @compare_and_swap,
          transactions: @transactions,
          durable_writes: @durable_writes,
          multi_process: @multi_process,
          tenant_scoping: @tenant_scoping,
          append_only_audit: @append_only_audit
        }
      end
    end
  end
end
