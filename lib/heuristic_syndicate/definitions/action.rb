# frozen_string_literal: true

module HeuristicSyndicate
  module Definitions
    # Versioned deterministic Action Contract (ADR-006 & Spike 2 §4.6).
    class Action
      VALID_RISKS = %i[low medium high critical].freeze
      VALID_STRATEGIES = %i[idempotent reconcile manual_review non_retryable].freeze

      class ParamsSchema
        attr_reader :fields

        def initialize
          @fields = {}
        end

        def required(name, type = :string)
          @fields[name.to_sym] = { type: type.to_sym, required: true }
        end

        def optional(name, type = :string, default: nil)
          @fields[name.to_sym] = { type: type.to_sym, required: false, default: default }
        end

        def validate!(params_hash)
          raise ActionValidationError, "Action params must be a Hash" unless params_hash.is_a?(Hash)

          sym = params_hash.transform_keys(&:to_sym)
          validated = {}

          @fields.each do |fname, spec|
            if sym.key?(fname) && !sym[fname].nil?
              check_type!(fname, sym[fname], spec[:type])
              validated[fname] = sym[fname]
            elsif spec[:required]
              raise ActionValidationError, "Missing required action parameter :#{fname}"
            elsif !spec[:default].nil?
              validated[fname] = spec[:default]
            end
          end

          extra_keys = sym.keys - @fields.keys
          if extra_keys.any? && @fields.any?
            raise ActionValidationError, "Unknown action parameters: #{extra_keys.join(', ')}"
          end

          @fields.empty? ? sym : validated
        end

        private

        def check_type!(name, val, type)
          valid = case type
                  when :string then val.is_a?(String)
                  when :integer then val.is_a?(Integer)
                  when :number, :float then val.is_a?(Numeric)
                  when :boolean then val == true || val == false
                  when :array then val.is_a?(Array)
                  when :hash then val.is_a?(Hash)
                  else true
                  end
          raise ActionValidationError, "Parameter :#{name} expected #{type}, got #{val.class}" unless valid
        end
      end

      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@action_version, @action_version || "1.0.0")
          subclass.instance_variable_set(:@risk_level, @risk_level || :medium)
          subclass.instance_variable_set(:@idempotent, @idempotent || false)
          subclass.instance_variable_set(:@recovery_strategy, @recovery_strategy)
          subclass.instance_variable_set(:@required_capability, @required_capability)
          subclass.instance_variable_set(:@params_schema, ParamsSchema.new)
        end

        def action_name(val = nil)
          return @explicit_action_name || default_action_name if val.nil?

          @explicit_action_name = val.to_s
        end

        def default_action_name
          name.to_s.split("::").last
              .gsub(/Action\z/, "")
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
        end

        def version(val = nil)
          return @action_version || "1.0.0" if val.nil?

          @action_version = val.to_s
        end

        def risk(level = nil)
          return @risk_level || :medium if level.nil?

          lvl = level.to_sym
          raise ArgumentError, "Invalid risk level: #{lvl}" unless VALID_RISKS.include?(lvl)

          @risk_level = lvl
        end

        def idempotent(val = true)
          @idempotent = val
          @recovery_strategy ||= :idempotent if val
        end

        def idempotent?
          @idempotent || false
        end

        def recovery_strategy(strategy = nil)
          if strategy.nil?
            return @recovery_strategy || (@idempotent ? :idempotent : :non_retryable)
          end

          strat = strategy.to_sym
          unless VALID_STRATEGIES.include?(strat)
            raise ArgumentError, "Invalid recovery_strategy: #{strat}. Valid: #{VALID_STRATEGIES.join(', ')}"
          end

          @recovery_strategy = strat
        end

        def requires_capability(cap_name)
          @required_capability = cap_name.to_sym
        end

        def required_capability
          @required_capability
        end

        def params(&block)
          @params_schema ||= ParamsSchema.new
          @params_schema.instance_eval(&block) if block_given?
          @params_schema
        end

        def validate_params!(raw_params)
          (@params_schema || ParamsSchema.new).validate!(raw_params)
        end
      end

      def idempotency_key(context, params = {})
        run_id = context.respond_to?(:[]) ? context[:run_id] : context.run_id
        Execution::Idempotency.build_key(
          run_id: run_id,
          node_id: self.class.action_name,
          version: self.class.version,
          extra: Execution::Idempotency.digest(params)
        )
      end

      def precondition(_context, _params)
        true
      end

      def dry_run(_context, _params)
        { ok: true }
      end

      def apply(_context, _params, idempotency_key: nil)
        raise NotImplementedError, "#{self.class.name} must implement #apply"
      end

      def verify(_context, _params)
        true
      end

      def reconcile(_context, _params, idempotency_key: nil)
        raise UncertainOutcome,
              "Action #{self.class.name} does not implement #reconcile for uncertain side effect (#{idempotency_key})"
      end

      def rollback(_context, _params)
        nil
      end

      def compensate(_context, _params)
        nil
      end
    end
  end
end
