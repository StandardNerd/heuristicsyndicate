# frozen_string_literal: true

module HeuristicSyndicate
  module Definitions
    # Deterministic pipeline node component (ADR §4.3).
    class Component
      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@declared_inputs, (@declared_inputs || {}).dup)
          subclass.instance_variable_set(:@declared_outputs, (@declared_outputs || {}).dup)
          subclass.instance_variable_set(:@injected_deps, (@injected_deps || []).dup)
          subclass.instance_variable_set(:@component_version, @component_version || "1.0.0")
          subclass.instance_variable_set(:@idempotent, @idempotent.nil? ? true : @idempotent)
        end

        def version(val = nil)
          return @component_version || "1.0.0" if val.nil?

          @component_version = val.to_s
        end

        def idempotent(val = true)
          @idempotent = val
        end

        def idempotent?
          @idempotent.nil? ? true : @idempotent
        end

        def input(name, type: nil, required: true, default: nil)
          @declared_inputs ||= {}
          @declared_inputs[name.to_sym] = { type: type, required: required, default: default }
        end

        def declared_inputs
          @declared_inputs || {}
        end

        def output(name, type: nil)
          @declared_outputs ||= {}
          @declared_outputs[name.to_sym] = { type: type }
        end

        def declared_outputs
          @declared_outputs || {}
        end

        def inject(*dep_names)
          @injected_deps ||= []
          dep_names.each do |dep|
            dep_sym = dep.to_sym
            @injected_deps << dep_sym unless @injected_deps.include?(dep_sym)
            define_method(dep_sym) { @resolved_dependencies.fetch(dep_sym) }
          end
        end

        def injected_dependencies
          @injected_deps || []
        end
      end

      attr_reader :resolved_dependencies, :security_context

      def initialize(resolved_dependencies: {}, security_context: nil)
        @resolved_dependencies = resolved_dependencies || {}
        @security_context = security_context
      end

      def execute_node(inputs = {})
        sym_inputs = inputs.transform_keys(&:to_sym)
        coerced = {}

        self.class.declared_inputs.each do |name, spec|
          if sym_inputs.key?(name)
            val = sym_inputs[name]
            if spec[:type] && !val.nil? && !val.is_a?(spec[:type])
              raise ValidationError,
                    "Component #{self.class.name} input :#{name} expected #{spec[:type]}, got #{val.class}"
            end
            coerced[name] = val
          elsif !spec[:default].nil?
            coerced[name] = spec[:default].respond_to?(:call) ? spec[:default].call : spec[:default]
          elsif spec[:required]
            raise ValidationError, "Component #{self.class.name} missing required input :#{name}"
          end
        end

        # Pass additional connected inputs if no inputs were strictly declared or if call accepts **kwargs
        call_inputs = self.class.declared_inputs.empty? ? sym_inputs : sym_inputs.merge(coerced)
        result = call(**call_inputs)
        raise ValidationError, "Component #{self.class.name}#call must return a Hash" unless result.is_a?(Hash)

        result.transform_keys(&:to_sym)
      end

      def call(**_inputs)
        raise NotImplementedError, "#{self.class.name} must implement #call"
      end
    end
  end
end
