# frozen_string_literal: true

module HeuristicSyndicate
  module Governance
    # Registry of versioned Action Contracts (ADR-006).
    class ActionRegistry
      def initialize
        @mutex = Mutex.new
        @actions = {}
      end

      def register(action_class)
        name = action_class.action_name
        ver = action_class.version
        @mutex.synchronize do
          @actions[name] ||= {}
          @actions[name][ver] = action_class
        end
        self
      end

      def fetch!(name, version: nil)
        @mutex.synchronize do
          versions = @actions[name.to_s]
          raise ActionValidationError, "Unregistered action '#{name}' (not in allowlist)" unless versions

          if version
            klass = versions[version.to_s]
            unless klass
              raise ActionValidationError,
                    "Action '#{name}' version '#{version}' is not registered (available: #{versions.keys.join(', ')})"
            end
            klass
          else
            versions.values.last
          end
        end
      end

      def allowlist
        @mutex.synchronize { @actions.keys.sort }
      end
    end
  end
end
