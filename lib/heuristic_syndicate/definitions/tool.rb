# frozen_string_literal: true

require "ruby_llm"

module HeuristicSyndicate
  module Definitions
    # Declarative Tool definition (ADR-001, ADR-004 & §4.2).
    # Executed exclusively under HeuristicSyndicate's runtime control.
    class Tool
      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@description_text, @description_text)
          subclass.instance_variable_set(:@access_mode, @access_mode)
          subclass.instance_variable_set(:@required_capability, @required_capability)
          subclass.instance_variable_set(:@tool_scope, @tool_scope)
          subclass.instance_variable_set(:@injected_deps, (@injected_deps || []).dup)
          subclass.instance_variable_set(:@untrusted_output, @untrusted_output || false)
          subclass.instance_variable_set(:@max_output_bytes, @max_output_bytes || 8_000)
          subclass.instance_variable_set(:@requires_approval, @requires_approval || false)
          subclass.instance_variable_set(:@declared_params, (@declared_params || {}).dup)
        end

        def tool_name(value = nil)
          return @explicit_tool_name || default_tool_name if value.nil?

          @explicit_tool_name = value.to_s
        end

        def default_tool_name
          name.to_s.split("::").last
              .gsub(/Tool\z/, "")
              .gsub(/([a-z\d])([A-Z])/, '\1_\2')
              .downcase
        end

        def description(text = nil)
          return @description_text || "" if text.nil?

          @description_text = text.to_s
        end

        def read_only
          @access_mode = :read
        end

        def writes
          @access_mode = :write
        end

        def access_mode
          @access_mode
        end

        def requires_capability(cap_name)
          @required_capability = cap_name.to_sym
        end

        def required_capability
          @required_capability
        end

        def scope(scope_name = nil)
          return @tool_scope if scope_name.nil?

          @tool_scope = scope_name.to_s
        end

        def tool_scope
          @tool_scope
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

        def untrusted_output(enabled = true)
          @untrusted_output = enabled
        end

        def untrusted_output?
          @untrusted_output || false
        end

        def max_output(bytes = nil)
          return @max_output_bytes || 8_000 if bytes.nil?

          @max_output_bytes = Integer(bytes)
        end

        def requires_approval(enabled = true)
          @requires_approval = enabled
        end

        def requires_approval?
          @requires_approval || @access_mode == :write
        end

        def parameter(param_name, type: :string, desc: nil, description: nil, required: true)
          @declared_params ||= {}
          @declared_params[param_name.to_sym] = {
            type: type,
            description: description || desc,
            required: required
          }
        end
        alias param parameter

        def declared_parameters
          @declared_params || {}
        end

        # Builds a schema-only RubyLLM::Tool descriptor so RubyLLM::Chat can advertise
        # tool schemas to providers while HeuristicSyndicate controls actual execution.
        def to_ruby_llm_descriptor
          hs_tool_class = self
          inferred_kw = instance_method(:execute).parameters
          Class.new(RubyLLM::Tool) do
            define_singleton_method(:name) { hs_tool_class.name || hs_tool_class.tool_name }
            define_singleton_method(:tool_name) { hs_tool_class.tool_name }
            description(hs_tool_class.description)

            if hs_tool_class.declared_parameters.any?
              hs_tool_class.declared_parameters.each do |pname, opts|
                parameter(pname, type: opts[:type], desc: opts[:description], required: opts[:required])
              end
            else
              inferred_kw.each do |kind, pname|
                next unless %i[keyreq key].include?(kind)

                parameter(pname, type: :string, required: kind == :keyreq)
              end
            end

            def execute(**_args)
              raise HeuristicSyndicate::SecurityError,
                    "Direct tool execution inside RubyLLM loop is disabled; use HeuristicSyndicate::Runtime"
            end
          end
        end
      end

      attr_reader :resolved_dependencies, :security_context

      def initialize(resolved_dependencies: {}, security_context: nil)
        @resolved_dependencies = resolved_dependencies || {}
        @security_context = security_context
      end

      def call(**arguments)
        sym_args = arguments.transform_keys(&:to_sym)
        raw_result = if method(:execute).arity.zero? && method(:execute).parameters.empty?
                       execute
                     else
                       execute(**sym_args)
                     end

        if self.class.untrusted_output?
          Security::UntrustedData.new(
            raw_content: raw_result,
            source: self.class.tool_name,
            max_bytes: self.class.max_output
          ).to_envelope
        else
          raw_result
        end
      end

      def execute(**_args)
        raise NotImplementedError, "#{self.class.name} must implement #execute"
      end
    end
  end
end
