# frozen_string_literal: true

require "digest"
require "time"

module HeuristicSyndicate
  module Governance
    # Canonical SHA-256 Plan & Approval Digest (ADR-006).
    # Binds plan steps, action names, action versions, parameters, target environment,
    # resource identities, policy version, execution constraints, and expiration.
    module Digest
      module_function

      def compute(
        plan:,
        environment:,
        policy_version:,
        resources: [],
        constraints: {},
        expires_at: nil
      )
        canonical_payload = {
          plan_id: plan.id,
          tenant_id: plan.tenant_id,
          title: plan.title,
          rationale: plan.rationale,
          environment: environment.to_s,
          policy_version: policy_version.to_s,
          resources: Array(resources).map(&:to_s).sort,
          constraints: constraints || {},
          expires_at: expires_at.is_a?(Time) ? expires_at.utc.iso8601 : expires_at&.to_s,
          steps: plan.steps.map do |step|
            {
              action: step[:action].to_s,
              version: step[:version].to_s,
              params: step[:params] || {},
              risk: step[:risk].to_s,
              resource: step[:resource].to_s
            }
          end
        }
        "sha256:#{::Digest::SHA256.hexdigest(Execution::Idempotency.canonical_json(canonical_payload))}"
      end
    end

    # Governed Plan validated against ActionRegistry (ADR-006).
    class Plan
      RISK_ORDER = { low: 0, medium: 1, high: 2, critical: 3 }.freeze

      attr_reader :id, :tenant_id, :run_id, :title, :rationale, :steps,
                  :test_strategy, :environment, :policy_version, :resources,
                  :constraints, :expires_at, :digest

      def initialize(
        id:,
        tenant_id:,
        run_id:,
        title:,
        rationale:,
        steps:,
        registry: nil,
        test_strategy: [],
        environment: :production,
        policy_version: "1.0",
        resources: nil,
        constraints: {},
        expires_at: nil
      )
        raise ArgumentError, "tenant_id is required" if tenant_id.nil? || tenant_id.to_s.empty?

        @id = id.to_s
        @tenant_id = tenant_id.to_s
        @run_id = run_id.to_s
        @title = title.to_s
        @rationale = rationale.to_s
        @test_strategy = Array(test_strategy).map(&:to_s)
        @environment = environment.to_sym
        @policy_version = policy_version.to_s
        @constraints = constraints || {}
        @expires_at = expires_at.is_a?(String) ? Time.parse(expires_at).utc : expires_at&.utc

        @steps = normalize_and_validate_steps!(steps, registry)
        @resources = if resources
                       Array(resources).map(&:to_s).uniq.sort
                     else
                       @steps.filter_map { |s| s[:resource]&.to_s }.uniq.sort
                     end

        @digest = Digest.compute(
          plan: self,
          environment: @environment,
          policy_version: @policy_version,
          resources: @resources,
          constraints: @constraints,
          expires_at: @expires_at
        )
        freeze
      end

      def highest_risk
        @steps.map { |s| s[:risk].to_sym }.max_by { |r| RISK_ORDER.fetch(r, 0) } || :low
      end

      def expired?(now = Time.now.utc)
        !@expires_at.nil? && now >= @expires_at
      end

      def to_h
        {
          id: @id,
          tenant_id: @tenant_id,
          run_id: @run_id,
          title: @title,
          rationale: @rationale,
          steps: @steps,
          test_strategy: @test_strategy,
          environment: @environment.to_s,
          policy_version: @policy_version,
          resources: @resources,
          constraints: @constraints,
          expires_at: @expires_at&.utc&.iso8601,
          digest: @digest
        }
      end

      def self.from_h(hash)
        return hash if hash.is_a?(Plan)

        h = hash.transform_keys(&:to_sym)
        new(
          id: h[:id],
          tenant_id: h[:tenant_id],
          run_id: h[:run_id],
          title: h[:title],
          rationale: h[:rationale],
          steps: h[:steps],
          test_strategy: h[:test_strategy] || [],
          environment: (h[:environment] || :production).to_sym,
          policy_version: h[:policy_version] || "1.0",
          resources: h[:resources],
          constraints: h[:constraints] || {},
          expires_at: h[:expires_at]
        )
      end

      private

      def normalize_and_validate_steps!(raw_steps, registry)
        raise ActionValidationError, "Plan must contain at least one step" if Array(raw_steps).empty?

        Array(raw_steps).map do |raw|
          s = raw.transform_keys(&:to_sym)
          action_name = s[:action].to_s
          version = (s[:version] || "1.0.0").to_s
          params = s[:params] || {}

          if registry
            action_klass = registry.fetch!(action_name, version: version)
            params = action_klass.validate_params!(params)
            risk = (s[:risk] || action_klass.risk).to_sym
          else
            risk = (s[:risk] || :medium).to_sym
          end

          {
            action: action_name,
            version: version,
            params: params,
            risk: risk,
            resource: s[:resource]&.to_s,
            rollback_description: s[:rollback_description].to_s,
            verification_description: s[:verification_description].to_s
          }
        end
      end
    end
  end
end
