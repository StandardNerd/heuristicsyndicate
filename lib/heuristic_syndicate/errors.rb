# frozen_string_literal: true

module HeuristicSyndicate
  class Error < StandardError; end

  # Shared error hierarchy defined in Spike 1 & Spike 2 (§2)
  class TransientError < Error; end
  class PermanentError < Error; end

  class ProviderError < TransientError
    attr_reader :provider, :original_error

    def initialize(message, provider: nil, original_error: nil)
      super(message)
      @provider = provider
      @original_error = original_error
    end
  end

  class SerializationError < PermanentError; end
  class LeaseLostError < PermanentError; end
  class IdempotencyConflict < PermanentError; end
  class UncertainOutcome < Error; end
  class RecoveryConflict < PermanentError; end
  class AdapterCompatibilityError < PermanentError; end

  # Security, Governance, Budget, and Pipeline errors (ADR-004..012)
  class SecurityError < PermanentError; end
  class CapabilityDeniedError < SecurityError; end
  class TenantAccessDeniedError < SecurityError; end
  class ResourceDeniedError < SecurityError; end

  class GovernanceError < PermanentError; end
  class ApprovalRequiredError < GovernanceError; end
  class ApprovalInvalidError < GovernanceError; end
  class ActionValidationError < GovernanceError; end
  class PreconditionFailedError < GovernanceError; end
  class VerificationFailedError < GovernanceError; end

  class BudgetExceededError < PermanentError; end
  class MaxVisitsExceededError < PermanentError; end
  class ValidationError < PermanentError; end
  class AuditIntegrityError < PermanentError; end
  class StoreCapabilityError < PermanentError; end
end
