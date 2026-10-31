# frozen_string_literal: true

module HeuristicSyndicate
  class Configuration
    attr_accessor :default_model,
                  :default_provider,
                  :lease_duration,
                  :audit_secret,
                  :environment,
                  :policy_version,
                  :store,
                  :llm_adapter,
                  :event_bus,
                  :anchor_store

    def initialize
      @default_model = "fake-default"
      @default_provider = :fake
      @lease_duration = 60 # seconds
      @audit_secret = "heuristic-syndicate-default-signing-key"
      @environment = :development
      @policy_version = "1.0"
      @store = nil
      @llm_adapter = nil
      @event_bus = nil
      @anchor_store = nil
    end
  end
end
