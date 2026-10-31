# frozen_string_literal: true

module HeuristicSyndicate
  module Security
    # Capability grant with optional resource patterns (ADR-004).
    class Capability
      attr_reader :name, :resources

      def initialize(name:, resources: ["*"])
        @name = name.to_sym
        @resources = Array(resources).map(&:to_s).freeze
        freeze
      end

      def matches_resource?(resource)
        return true if @resources.include?("*")
        return false if resource.nil?

        res_str = resource.to_s
        @resources.any? do |pattern|
          if pattern.end_with?(".*")
            prefix = pattern.chomp(".*")
            res_str == prefix || res_str.start_with?("#{prefix}.")
          else
            File.fnmatch?(pattern, res_str, File::FNM_DOTMATCH)
          end
        end
      end

      def to_h
        { name: @name.to_s, resources: @resources }
      end
    end

    class CapabilitySet
      def initialize(capabilities = [])
        @grants = {}
        Array(capabilities).each { |c| add(c) }
      end

      def allow(name, resources: ["*"])
        add(Capability.new(name: name, resources: resources))
        self
      end

      def add(capability)
        cap = capability.is_a?(Capability) ? capability : Capability.new(**capability.transform_keys(&:to_sym))
        existing = @grants[cap.name]
        @grants[cap.name] = if existing
                              Capability.new(name: cap.name, resources: (existing.resources + cap.resources).uniq)
                            else
                              cap
                            end
        self
      end

      def allowed?(capability_name, resource: nil)
        return false if capability_name.nil?

        cap = @grants[capability_name.to_sym]
        return false unless cap

        resource.nil? ? true : cap.matches_resource?(resource)
      end

      def names
        @grants.keys
      end

      def to_a
        @grants.values.map(&:to_h)
      end
    end
  end
end
