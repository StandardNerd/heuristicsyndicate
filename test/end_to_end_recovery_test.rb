# frozen_string_literal: true

require_relative "test_helper"

# Section 5 of spike1_spike2.md:
# End-to-End Integration Test proving that a Conversation with a pending Tool Call
# and Workflow NodeExecution state can be recovered across a real process crash
# without duplicating external side effects or allowing stale worker writes.
class EndToEndRecoveryTest < Minitest::Test
  class ExternalSnapshotTool < HeuristicSyndicate::Tool
    tool_name "create_vm_snapshot"
    description "Creates a VM snapshot in vSphere with an idempotency key"
    read_only
    requires_capability :vsphere_snapshot

    def execute(vm_id:)
      { snapshot_id: "snap_#{vm_id}_01", vm_id: vm_id }
    end
  end

  class SnapshotAgent < HeuristicSyndicate::Agent
    goal "Take diagnostic snapshot of affected VM"
    model "e2e-model", provider: :fake
    permits :read
    capabilities { allow :vsphere_snapshot }
    tools ExternalSnapshotTool
  end

  class SnapshotActionContract < HeuristicSyndicate::Action
    action_name "create_vm_snapshot"
    version "1.0.0"
    risk :medium
    recovery_strategy :reconcile
    requires_capability :vsphere_snapshot

    def initialize(ext_file)
      super()
      @ext_file = ext_file
      File.write(@ext_file, JSON.generate({ calls: 0, snapshots: {} })) unless File.exist?(@ext_file)
    end

    def apply(_context, params, idempotency_key:)
      state = JSON.parse(File.read(@ext_file), symbolize_names: true)
      state[:calls] += 1
      vm_id = params[:vm_id] || "vm-42"
      snap = { snapshot_id: "snap_#{vm_id}_01", vm_id: vm_id, idempotency_key: idempotency_key }
      state[:snapshots][idempotency_key.to_sym] = snap
      File.write(@ext_file, JSON.generate(state))
      snap
    end

    def reconcile(_context, _params, idempotency_key:)
      state = JSON.parse(File.read(@ext_file), symbolize_names: true)
      snap = state[:snapshots][idempotency_key.to_sym]
      raise HeuristicSyndicate::UncertainOutcome, "Snapshot not found" unless snap

      snap
    end

    def call_count
      JSON.parse(File.read(@ext_file), symbolize_names: true)[:calls]
    end
  end

  def test_section_5_end_to_end_conversation_and_node_crash_recovery
    HeuristicSyndicate.reset!
    tenant = "tenant_e2e"
    sec = HeuristicSyndicate::SecurityContext.new(
      tenant_id: tenant,
      actor_id: "sysadmin_1",
      capabilities: [{ name: :vsphere_snapshot, resources: ["*"] }]
    )

    Dir.mktmpdir("e2e_spike_1_2") do |dir|
      file_store = HeuristicSyndicate::Store::FileStore.new(path: File.join(dir, "store.json"))
      conv_store = HeuristicSyndicate::Memory::ConversationStore.new(file_store)
      ext_sim = SnapshotActionContract.new(File.join(dir, "vsphere_ext.json"))
      meta_path = File.join(dir, "crash_meta.json")
      adapter = HeuristicSyndicate::LLM::RubyLLMAdapter.new

      # --- Worker 1 (runs in a separate OS process and crashes after external side effect) ---
      pid1 = Process.fork do
        HeuristicSyndicate::Testing::FakeProvider.script_tool_call(
          "create_vm_snapshot",
          { vm_id: "vm-prod-09" },
          id: "call_snap_99"
        )

        # 1. Start Run & Agent asks RubyLLM -> RubyLLM requests tool call
        conv = adapter.create_conversation(
          config: {
            conversation_id: "conv_e2e_1",
            agent_name: SnapshotAgent.name,
            model: SnapshotAgent.model,
            provider: :fake,
            tools: SnapshotAgent.tool_classes
          },
          context: { security_context: sec, conversation_store: conv_store }
        )
        adapter.execute(conversation: conv, input: "Snapshot vm-prod-09")

        # 2. Save ConversationCheckpoint with pending tool call
        conv_chk = adapter.checkpoint(conversation: conv)
        conv_store.save_checkpoint(conv_chk, tenant: tenant)

        # 3. Create & Claim NodeExecution for the tool side effect
        tool_call = adapter.pending_tool_calls(conversation: conv).first
        ne = HeuristicSyndicate::Execution::NodeExecution.new(
          id: "ne_tool_call_snap_99",
          tenant_id: tenant,
          run_id: "run_e2e_1",
          node_id: "tool:create_vm_snapshot",
          status: :pending,
          attempt: 0,
          input_digest: tool_call.arguments_digest,
          idempotency_key: "run_e2e_1:call_snap_99:v1"
        )
        file_store.create_node_execution(ne, tenant: tenant)

        File.write(meta_path, JSON.generate({ conv_chk_id: conv_chk.id, ne_id: ne.id, tool_call_id: tool_call.id }))

        # 4. Execute tool external operation, then CRASH before committing result!
        injector = HeuristicSyndicate::Testing::CrashInjector.new(
          crash_point: :after_side_effect_before_commit,
          mode: :kill_process
        )
        node_exec = HeuristicSyndicate::Runtime::NodeExecutor.new(
          store: file_store,
          lease_duration: 1,
          crash_injector: injector
        )
        node_exec.execute_node(
          node_execution_id: ne.id,
          worker_id: "worker_1",
          tenant: tenant,
          inputs: tool_call.arguments,
          action_contract: ext_sim
        )
      end

      _, status1 = Process.waitpid2(pid1)
      assert_equal 137, status1.exitstatus
      assert_equal 1, ext_sim.call_count, "Worker 1 executed external snapshot once before crashing"

      meta = JSON.parse(File.read(meta_path), symbolize_names: true)
      crashed_ne = file_store.find_node_execution(meta[:ne_id], tenant: tenant)
      assert_equal :running, crashed_ne.status
      assert_equal 1, crashed_ne.fencing_token
      assert_nil crashed_ne.output

      # --- Worker 2 (Recovery Process): Reclaims expired lease, reconciles side effect, restores Conversation, completes Run ---
      recovery_executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: file_store, lease_duration: 30)
      reconciled_ne = recovery_executor.execute_node(
        node_execution_id: meta[:ne_id],
        worker_id: "worker_2",
        tenant: tenant,
        inputs: { vm_id: "vm-prod-09" },
        action_contract: ext_sim,
        now: Time.now.utc + 5
      )

      assert_equal :succeeded, reconciled_ne.status
      assert_equal 2, reconciled_ne.fencing_token
      assert_equal 1, ext_sim.call_count, "External side effect must NOT be duplicated during recovery"
      assert_equal "snap_vm-prod-09_01", reconciled_ne.output[:snapshot_id]

      # Prove old Worker 1 (fencing_token = 1) is blocked from writing
      assert_raises(HeuristicSyndicate::LeaseLostError) do
        file_store.transition_node_execution!(
          node_execution_id: meta[:ne_id],
          fencing_token: 1,
          to_status: :succeeded,
          output: { corrupted: true },
          tenant: tenant
        )
      end

      # Restore Conversation from ConversationCheckpoint in the new process, supply reconciled tool result, and complete!
      HeuristicSyndicate::Testing::FakeProvider.script_text(
        "Snapshot snap_vm-prod-09_01 created and verified.",
        match: /snap_vm-prod-09_01/
      )

      loaded_conv_chk = conv_store.find_checkpoint(meta[:conv_chk_id], tenant: tenant)
      agent_runtime = HeuristicSyndicate::Runtime::AgentRuntime.new(
        adapter: adapter,
        conversation_store: conv_store
      )

      final_outcome = agent_runtime.resume(
        checkpoint: loaded_conv_chk,
        agent_class: SnapshotAgent,
        security_context: sec,
        precomputed_tool_results: { meta[:tool_call_id] => reconciled_ne.output }
      )

      assert_equal :completed, final_outcome[:status]
      assert_equal "Snapshot snap_vm-prod-09_01 created and verified.", final_outcome[:output]
    end
  end
end
