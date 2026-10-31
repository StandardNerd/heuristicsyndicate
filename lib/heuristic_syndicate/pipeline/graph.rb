# frozen_string_literal: true

module HeuristicSyndicate
  module Definitions
    class Pipeline
      Edge = Struct.new(
        :from_node,
        :from_socket,
        :to_node,
        :to_socket,
        :condition,
        :loop_back,
        keyword_init: true
      )

      # Directed Graph representation with validation and Mermaid generation (ADR §4.4).
      class Graph
        attr_reader :nodes, :edges

        def initialize
          @nodes = {}
          @edges = []
        end

        def initialize_copy(other)
          super
          @nodes = other.nodes.transform_values(&:dup)
          @edges = other.edges.map(&:dup)
        end

        def add_node(id, target, **options)
          nid = id.to_sym
          @nodes[nid] = {
            id: nid,
            target: target,
            max_visits: options[:max_visits] || 1,
            type: infer_node_type(target),
            options: options
          }
        end

        def add_edge(from_spec, to_spec, condition: nil, loop_back: false)
          from_node, from_socket = parse_socket(from_spec)
          to_node, to_socket = parse_socket(to_spec)
          is_back_edge = loop_back || reachable?(to_node.to_sym, from_node.to_sym)
          @edges << Edge.new(
            from_node: from_node.to_sym,
            from_socket: from_socket.to_sym,
            to_node: to_node.to_sym,
            to_socket: to_socket.to_sym,
            condition: condition,
            loop_back: is_back_edge
          )
        end

        def reachable?(source_node, target_node, visited = {})
          return true if source_node == target_node
          return false if visited[source_node]

          visited[source_node] = true
          outgoing_edges(source_node).any? do |e|
            !e.loop_back && reachable?(e.to_node, target_node, visited)
          end
        end

        def incoming_edges(node_id)
          @edges.select { |e| e.to_node == node_id.to_sym }
        end

        def outgoing_edges(node_id)
          @edges.select { |e| e.from_node == node_id.to_sym }
        end

        def entry_nodes
          @nodes.keys.select { |nid| incoming_edges(nid).empty? }
        end

        def validate!
          raise ValidationError, "Pipeline graph has no nodes" if @nodes.empty?

          @edges.each do |edge|
            unless @nodes.key?(edge.from_node)
              raise ValidationError, "Edge references unknown source node :#{edge.from_node}"
            end
            unless @nodes.key?(edge.to_node)
              raise ValidationError, "Edge references unknown target node :#{edge.to_node}"
            end
          end

          @nodes.each_value do |spec|
            target = spec[:target]
            if target.is_a?(Class) && target < Definitions::Agent
              target.validate_configuration!
            end
          end

          true
        end

        def to_mermaid
          lines = ["flowchart TD"]
          @nodes.each do |id, spec|
            label = spec[:target].respond_to?(:name) && spec[:target].name ? spec[:target].name.split("::").last : id
            lines << "  #{id}[\"#{id}: #{label}\"]"
          end
          @edges.each do |e|
            lines << "  #{e.from_node} -->|#{e.from_socket} -> #{e.to_socket}| #{e.to_node}"
          end
          lines.join("\n")
        end

        private

        def parse_socket(spec_str)
          parts = spec_str.to_s.split(".", 2)
          if parts.size != 2 || parts.any?(&:empty?)
            raise ValidationError, "Invalid socket specification '#{spec_str}' (expected 'node.socket')"
          end
          parts
        end

        def infer_node_type(target)
          if target == Interrupts::Interrupt
            :interrupt
          elsif target.is_a?(Class) && target < Definitions::Agent
            :agent
          elsif target.is_a?(Class) && target < Definitions::Component
            :component
          elsif target.respond_to?(:call)
            :callable
          else
            :custom
          end
        end
      end
    end
  end
end
