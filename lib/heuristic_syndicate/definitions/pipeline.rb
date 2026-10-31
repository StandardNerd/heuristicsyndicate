# frozen_string_literal: true

require "securerandom"

module HeuristicSyndicate
  module Definitions
    # Haystack-inspired Graph Pipeline with durable checkpoints, parallel waves,
    # conditional routing, loops with max_visits, and human-in-the-loop interrupts (ADR-002, ADR-003, §4.4).
    class Pipeline
      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@graph, (@graph || Graph.new).dup)
          subclass.instance_variable_set(:@middleware_stack, Middleware::Stack.new)
        end

        def graph
          @graph ||= Graph.new
        end

        def middleware_stack
          @middleware_stack ||= Middleware::Stack.new
        end

        def use(middleware_klass, **options)
          middleware_stack.use(middleware_klass, **options)
        end

        def node(id, target, **options)
          graph.add_node(id, target, **options)
        end

        def connect(from_socket, to_socket, condition: nil, loop_back: false)
          graph.add_edge(from_socket, to_socket, condition: condition, loop_back: loop_back)
        end

        def validate!
          graph.validate!
        end

        def to_mermaid
          graph.to_mermaid
        end

        def nodes
          graph.nodes
        end

        def edges
          graph.edges
        end

        def run(
          inputs = {},
          security_context:,
          store: HeuristicSyndicate.store,
          credential_resolver: nil,
          audit_chain: nil,
          approval_manager: nil,
          action_registry: nil,
          execution_policy: Runtime::ExecutionPolicy.new,
          llm_adapter: HeuristicSyndicate.llm_adapter,
          run_id: nil
        )
          new(
            store: store,
            credential_resolver: credential_resolver,
            audit_chain: audit_chain,
            approval_manager: approval_manager,
            action_registry: action_registry,
            execution_policy: execution_policy,
            llm_adapter: llm_adapter
          ).run(inputs, security_context: security_context, run_id: run_id)
        end

        def resume(
          run_id:,
          decision:,
          security_context:,
          store: HeuristicSyndicate.store,
          credential_resolver: nil,
          audit_chain: nil,
          approval_manager: nil,
          action_registry: nil,
          execution_policy: Runtime::ExecutionPolicy.new,
          llm_adapter: HeuristicSyndicate.llm_adapter
        )
          new(
            store: store,
            credential_resolver: credential_resolver,
            audit_chain: audit_chain,
            approval_manager: approval_manager,
            action_registry: action_registry,
            execution_policy: execution_policy,
            llm_adapter: llm_adapter
          ).resume(run_id: run_id, decision: decision, security_context: security_context)
        end
      end

      attr_reader :store, :credential_resolver, :audit_chain, :approval_manager,
                  :action_registry, :execution_policy, :llm_adapter, :event_bus

      def initialize(
        store: HeuristicSyndicate.store,
        credential_resolver: nil,
        audit_chain: nil,
        approval_manager: nil,
        action_registry: nil,
        execution_policy: Runtime::ExecutionPolicy.new,
        llm_adapter: HeuristicSyndicate.llm_adapter,
        event_bus: HeuristicSyndicate.event_bus
      )
        @store = store
        @credential_resolver = credential_resolver
        @audit_chain = audit_chain || Audit::HashChain.new(store: @store)
        @approval_manager = approval_manager || Governance::ApprovalManager.new(store: @store, audit_chain: @audit_chain)
        @action_registry = action_registry
        @execution_policy = execution_policy
        @llm_adapter = llm_adapter
        @event_bus = event_bus
      end

      def run(inputs = {}, security_context:, run_id: nil)
        self.class.validate!
        rid = (run_id || "run_#{SecureRandom.hex(8)}").to_s
        tid = security_context.tenant_id
        budget = Runtime::BudgetManager.new(policy: @execution_policy)

        run_record = Execution::Run.new(
          id: rid,
          tenant_id: tid,
          pipeline_name: self.class.name || "Pipeline",
          status: :running,
          inputs: inputs.transform_keys(&:to_sym),
          outputs: {},
          visit_counts: {},
          budget_state: budget.snapshot
        )
        @store.save_run(run_record, tenant: tid)
        @event_bus&.emit("run.started", run_id: rid, tenant_id: tid)
        @audit_chain.append(
          tenant: tid,
          run_id: rid,
          actor_id: security_context.actor_id,
          event_type: "run.started",
          payload: { pipeline: run_record.pipeline_name }
        )

        execute_graph_loop(
          run_record: run_record,
          node_outputs: {},
          visit_counts: Hash.new(0),
          initial_inputs: inputs.transform_keys(&:to_sym),
          security_context: security_context,
          budget: budget
        )
      end

      def resume(run_id:, decision:, security_context:)
        self.class.validate!
        tid = security_context.tenant_id
        run_record = @store.find_run(run_id, tenant: tid)
        raise RecoveryConflict, "Run '#{run_id}' not found" unless run_record

        # Idempotent duplicate resume handling (ADR-002 / REC-10):
        return run_record if run_record.completed?

        checkpoint = @store.latest_checkpoint_for_run(run_id, tenant: tid)
        raise RecoveryConflict, "No checkpoint found for suspended run '#{run_id}'" unless checkpoint

        interrupt = @store.find_interrupt(checkpoint.pending_interrupt_id, tenant: tid)
        raise RecoveryConflict, "Pending interrupt '#{checkpoint.pending_interrupt_id}' not found" unless interrupt

        # If interrupt decision was already applied, return current state idempotently
        if !interrupt.pending? && interrupt.decision == decision
          return @store.find_run(run_id, tenant: tid)
        end

        status = decision[:approved] == false || decision[:status] == :rejected ? :rejected : :approved
        resolved_interrupt = Interrupts::Interrupt.new(
          id: interrupt.id,
          tenant_id: tid,
          run_id: run_record.id,
          node_id: interrupt.node_id,
          type: interrupt.type,
          resource_type: interrupt.resource_type,
          resource_id: interrupt.resource_id,
          resource_digest: interrupt.resource_digest,
          status: status,
          decision: decision,
          decided_by: decision[:approver_id] || security_context.actor_id,
          decided_at: Time.now.utc,
          created_at: interrupt.created_at,
          metadata: interrupt.metadata
        )
        @store.save_interrupt(resolved_interrupt, tenant: tid)

        node_outputs = checkpoint.node_outputs.transform_keys(&:to_sym).transform_values do |v|
          v.is_a?(Hash) ? v.transform_keys(&:to_sym) : v
        end
        node_outputs[interrupt.node_id.to_sym] = {
          decision: decision.merge(status: status, interrupt_id: interrupt.id)
        }

        visits = Hash.new(0)
        checkpoint.visit_counts.each { |k, v| visits[k.to_sym] = Integer(v) }
        budget = Runtime::BudgetManager.new(policy: @execution_policy, initial_state: checkpoint.budget_snapshot)

        execute_graph_loop(
          run_record: run_record,
          node_outputs: node_outputs,
          visit_counts: visits,
          initial_inputs: run_record.inputs.transform_keys(&:to_sym),
          security_context: security_context,
          budget: budget
        )
      end

      private

      def execute_graph_loop(run_record:, node_outputs:, visit_counts:, initial_inputs:, security_context:, budget:)
        graph = self.class.graph
        tid = security_context.tenant_id
        exec_mgr = Runtime::ExecutionManager.new(max_parallel: @execution_policy.max_parallel_nodes)

        loop do
          ready_nodes = find_ready_nodes(graph, node_outputs, visit_counts)
          break if ready_nodes.empty?

          # Check if any ready node is an Interrupt node
          interrupt_node_id = ready_nodes.find { |nid| graph.nodes[nid][:type] == :interrupt }
          if interrupt_node_id
            return suspend_at_interrupt_node(
              run_record: run_record,
              node_id: interrupt_node_id,
              node_outputs: node_outputs,
              visit_counts: visit_counts,
              initial_inputs: initial_inputs,
              security_context: security_context,
              budget: budget
            )
          end

          wave_results = exec_mgr.map_parallel(ready_nodes) do |nid|
            spec = graph.nodes[nid]
            next_visit = visit_counts[nid] + 1
            if next_visit > spec[:max_visits]
              raise MaxVisitsExceededError,
                    "Node :#{nid} exceeded max_visits (#{spec[:max_visits]})"
            end

            node_input = gather_node_inputs(graph, nid, node_outputs, initial_inputs)
            out = execute_single_node(
              run_id: run_record.id,
              node_id: nid,
              spec: spec,
              attempt: next_visit,
              inputs: node_input,
              security_context: security_context,
              budget: budget
            )
            [nid, next_visit, out]
          end

          loop_reset_targets = []
          wave_results.each do |nid, visit_num, out|
            visit_counts[nid] = visit_num
            node_outputs[nid] = out

            # Check if outgoing conditional edges trigger a loop back to earlier nodes
            graph.outgoing_edges(nid).each do |edge|
              next unless edge.condition
              next unless edge.condition.call(out)

              # If target node has already executed, clear downstream state so it can run again
              if node_outputs.key?(edge.to_node)
                loop_reset_targets << edge.to_node
              end
            end
          end

          loop_reset_targets.uniq.each do |reset_nid|
            clear_Subgraph_from(graph, reset_nid, node_outputs)
          end
        end

        completed_run = Execution::Run.new(
          id: run_record.id,
          tenant_id: tid,
          pipeline_name: run_record.pipeline_name,
          status: :completed,
          inputs: run_record.inputs,
          outputs: node_outputs,
          visit_counts: visit_counts.transform_keys(&:to_s),
          interrupt_ids: run_record.interrupt_ids,
          budget_state: budget.snapshot
        )
        @store.save_run(completed_run, tenant: tid)
        @audit_chain.append(
          tenant: tid,
          run_id: completed_run.id,
          actor_id: security_context.actor_id,
          event_type: "run.completed",
          payload: { status: "completed" }
        )
        @event_bus&.emit("run.completed", run_id: completed_run.id, tenant_id: tid)
        completed_run
      rescue StandardError => e
        failed_run = Execution::Run.new(
          id: run_record.id,
          tenant_id: tid,
          pipeline_name: run_record.pipeline_name,
          status: :failed,
          inputs: run_record.inputs,
          outputs: node_outputs,
          visit_counts: visit_counts.transform_keys(&:to_s),
          interrupt_ids: run_record.interrupt_ids,
          budget_state: budget.snapshot,
          error: e.message
        )
        @store.save_run(failed_run, tenant: tid)
        @event_bus&.emit("run.failed", run_id: failed_run.id, error: e.message)
        raise
      end

      def find_ready_nodes(graph, node_outputs, _visit_counts)
        graph.nodes.keys.select do |nid|
          next false if node_outputs.key?(nid)

          inc = graph.incoming_edges(nid).reject(&:loop_back)
          next true if inc.empty?

          inc.all? do |edge|
            next false unless node_outputs.key?(edge.from_node)

            src_out = node_outputs[edge.from_node]
            if edge.condition
              edge.condition.call(src_out)
            else
              src_out.is_a?(Hash) && src_out.key?(edge.from_socket) && !src_out[edge.from_socket].nil?
            end
          end
        end
      end

      def gather_node_inputs(graph, nid, node_outputs, initial_inputs)
        inc = graph.incoming_edges(nid).reject { |e| e.loop_back && !node_outputs.key?(e.from_node) }
        return initial_inputs.dup if inc.empty?

        gathered = initial_inputs.dup
        inc.each do |edge|
          src = node_outputs[edge.from_node] || {}
          val = src[edge.from_socket]
          gathered[edge.to_socket] = val unless val.nil?
        end
        gathered
      end

      def clear_Subgraph_from(graph, start_nid, node_outputs)
        queue = [start_nid]
        visited = {}
        until queue.empty?
          curr = queue.shift
          next if visited[curr]

          visited[curr] = true
          node_outputs.delete(curr)
          graph.outgoing_edges(curr).each do |edge|
            next if edge.loop_back

            queue << edge.to_node unless visited[edge.to_node]
          end
        end
      end

      def execute_single_node(run_id:, node_id:, spec:, attempt:, inputs:, security_context:, budget:)
        tid = security_context.tenant_id
        node_exec = Execution::NodeExecution.new(
          id: "ne_#{run_id}_#{node_id}_#{attempt}",
          tenant_id: tid,
          run_id: run_id,
          node_id: node_id.to_s,
          status: :pending,
          attempt: attempt - 1,
          input_digest: Execution::Idempotency.digest(inputs),
          idempotency_key: "#{run_id}:#{node_id}:attempt_#{attempt}"
        )
        @store.create_node_execution(node_exec, tenant: tid)

        node_call = Middleware::NodeCall.new(
          run_id: run_id,
          node_id: node_id,
          node_spec: spec,
          inputs: inputs,
          security_context: security_context,
          store: @store,
          audit_chain: @audit_chain,
          budget_manager: budget,
          event_bus: @event_bus,
          metadata: {}
        )

        executor = Runtime::NodeExecutor.new(store: @store, lease_duration: HeuristicSyndicate.config.lease_duration)
        completed_ne = executor.execute_node(
          node_execution_id: node_exec.id,
          worker_id: "pipeline_worker_#{Thread.current.object_id}",
          tenant: tid,
          inputs: inputs
        ) do
          self.class.middleware_stack.call(node_call) do |nc|
            invoke_target(nc.node_spec, nc.inputs, nc.security_context, nc.budget_manager)
          end
        end

        completed_ne.output
      end

      def invoke_target(spec, inputs, security_context, budget)
        target = spec[:target]
        case spec[:type]
        when :agent
          conv_store = Memory::ConversationStore.new(@store)
          agent_rt = Runtime::AgentRuntime.new(
            adapter: @llm_adapter,
            conversation_store: conv_store,
            credential_resolver: @credential_resolver,
            budget_manager: budget,
            event_bus: @event_bus
          )
          res = agent_rt.run(agent_class: target, input: inputs, security_context: security_context)
          { res[:socket] => res[:output] }
        when :component
          deps = resolve_component_dependencies(target, security_context)
          comp = target.new(resolved_dependencies: deps, security_context: security_context)
          comp.execute_node(inputs)
        when :callable
          target.call(inputs, security_context)
        else
          if target.respond_to?(:call)
            target.call(inputs)
          else
            raise ValidationError, "Unsupported node target for :#{spec[:id]}: #{target.inspect}"
          end
        end
      end

      def resolve_component_dependencies(comp_class, security_context)
        return {} if comp_class.injected_dependencies.empty?
        raise SecurityError, "CredentialResolver required for #{comp_class.name}" unless @credential_resolver

        comp_class.injected_dependencies.to_h do |dep_name|
          [dep_name, @credential_resolver.resolve(dep_name, security_context: security_context)]
        end
      end

      def suspend_at_interrupt_node(run_record:, node_id:, node_outputs:, visit_counts:, initial_inputs:, security_context:, budget:)
        tid = security_context.tenant_id
        spec = self.class.graph.nodes[node_id]
        inputs = gather_node_inputs(self.class.graph, node_id, node_outputs, initial_inputs)
        resource = inputs[:resource] || inputs.values.first
        res_id = resource.is_a?(Hash) ? (resource[:id] || resource["id"]) : (resource.respond_to?(:id) ? resource.id : nil)
        res_digest = resource.is_a?(Hash) ? (resource[:digest] || resource["digest"]) : (resource.respond_to?(:digest) ? resource.digest : nil)

        interrupt = Interrupts::Interrupt.new(
          id: "interrupt_#{SecureRandom.hex(6)}",
          tenant_id: tid,
          run_id: run_record.id,
          node_id: node_id.to_s,
          type: spec[:options][:type] || :approval,
          resource_type: "plan",
          resource_id: res_id.to_s,
          resource_digest: res_digest.to_s,
          status: :pending
        )
        @store.save_interrupt(interrupt, tenant: tid)

        dep_names = @credential_resolver ? @credential_resolver.registered_names(tenant_id: tid).map(&:to_s) : []
        checkpoint = Execution::Checkpoint.new(
          id: "chk_#{SecureRandom.hex(6)}",
          tenant_id: tid,
          run_id: run_record.id,
          node_id: node_id.to_s,
          status: :suspended,
          node_outputs: sanitize_outputs_for_checkpoint(node_outputs),
          visit_counts: visit_counts.transform_keys(&:to_s),
          pending_interrupt_id: interrupt.id,
          dependency_refs: dep_names,
          budget_snapshot: budget.snapshot
        )
        @store.save_checkpoint(checkpoint, tenant: tid)

        suspended_run = Execution::Run.new(
          id: run_record.id,
          tenant_id: tid,
          pipeline_name: run_record.pipeline_name,
          status: :suspended,
          inputs: run_record.inputs,
          outputs: node_outputs,
          visit_counts: visit_counts.transform_keys(&:to_s),
          interrupt_ids: run_record.interrupt_ids + [interrupt.id],
          budget_state: budget.snapshot
        )
        @store.save_run(suspended_run, tenant: tid)
        @audit_chain.append(
          tenant: tid,
          run_id: suspended_run.id,
          actor_id: security_context.actor_id,
          event_type: "approval.requested",
          payload: { interrupt_id: interrupt.id, node_id: node_id.to_s, resource_digest: res_digest.to_s }
        )
        @event_bus&.emit("approval.requested", run_id: suspended_run.id, interrupt_id: interrupt.id)
        @event_bus&.emit("run.suspended", run_id: suspended_run.id, interrupt_id: interrupt.id)
        suspended_run
      end

      def sanitize_outputs_for_checkpoint(val)
        case val
        when Hash
          val.to_h { |k, v| [k.to_s, sanitize_outputs_for_checkpoint(v)] }
        when Array
          val.map { |v| sanitize_outputs_for_checkpoint(v) }
        when nil, TrueClass, FalseClass, Numeric, String, Symbol
          val
        else
          val.respond_to?(:to_h) ? sanitize_outputs_for_checkpoint(val.to_h) : val.to_s
        end
      end
    end
  end
end
