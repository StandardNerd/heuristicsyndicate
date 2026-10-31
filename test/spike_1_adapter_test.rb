# frozen_string_literal: true

require_relative "test_helper"

class Spike1AdapterTest < Minitest::Test
  class ReadInventoryTool < HeuristicSyndicate::Tool
    tool_name "read_inventory"
    description "Read server inventory by datacenter"
    read_only
    requires_capability :inventory_read

    def execute(datacenter:)
      { datacenter: datacenter, hosts: %w[db-01 db-02], status: "online" }
    end
  end

  class ReadMetricsTool < HeuristicSyndicate::Tool
    tool_name "read_metrics"
    description "Read host CPU metrics"
    read_only
    requires_capability :metrics_read

    def execute(host:)
      { host: host, cpu_load: 0.42 }
    end
  end

  class ApprovalGatedRestartTool < HeuristicSyndicate::Tool
    tool_name "restart_service"
    description "Restart service requiring approval"
    read_only
    requires_capability :service_restart
    requires_approval true

    def execute(service:)
      { restarted: service }
    end
  end

  class InventoryAgent < HeuristicSyndicate::Agent
    goal "Inspect datacenter inventory"
    model "spike1-model", provider: :fake
    permits :read
    capabilities do
      allow :inventory_read
      allow :metrics_read
      allow :service_restart
    end
    tools ReadInventoryTool, ReadMetricsTool, ApprovalGatedRestartTool
  end

  def setup
    HeuristicSyndicate.reset!
    @store = HeuristicSyndicate::Store::Memory.new
    @conv_store = HeuristicSyndicate::Memory::ConversationStore.new(@store)
    @adapter = HeuristicSyndicate::LLM::RubyLLMAdapter.new
    @security_context = HeuristicSyndicate::SecurityContext.new(
      tenant_id: "tenant_alpha",
      actor_id: "user_1",
      capabilities: [
        { name: :inventory_read, resources: ["*"] },
        { name: :metrics_read, resources: ["*"] },
        { name: :service_restart, resources: ["*"] }
      ]
    )
  end

  # LLM-01: Create conversation -> Adapter returns distinct conversation ID
  def test_llm_01_create_conversation
    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool] },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )

    assert_match(/\Aconv_/, conv.id)
    assert_equal "tenant_alpha", conv.tenant_id
    refute @adapter.waiting?(conversation: conv)
  end

  # LLM-02: Simple model call -> Normalized StepResult
  def test_llm_02_simple_model_call
    HeuristicSyndicate::Testing::FakeProvider.script_text(
      "All systems nominal.",
      input_tokens: 12,
      output_tokens: 18
    )

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )
    step = @adapter.execute(conversation: conv, input: "Status check")

    assert_instance_of HeuristicSyndicate::LLM::StepResult, step
    assert_equal :assistant, step.role
    assert_equal "All systems nominal.", step.content
    assert_equal :completed, step.status
    assert_equal 12, step.input_tokens
    assert_equal 18, step.output_tokens
    assert @adapter.complete?(conversation: conv)
  end

  # LLM-03: Request tool call -> Tool call is recognized in structured form without auto-executing
  def test_llm_03_request_tool_call
    HeuristicSyndicate::Testing::FakeProvider.script_tool_call(
      "read_inventory",
      { datacenter: "eu-central-1" },
      id: "call_inv_1"
    )

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool] },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )
    step = @adapter.execute(conversation: conv, input: "List hosts in eu-central-1")

    assert step.tool_call?
    assert_equal :waiting_for_tool, step.status
    assert @adapter.waiting?(conversation: conv)
    refute @adapter.complete?(conversation: conv)

    pending = @adapter.pending_tool_calls(conversation: conv)
    assert_equal 1, pending.size
    assert_equal "call_inv_1", pending.first.id
    assert_equal "read_inventory", pending.first.name
    assert_equal({ datacenter: "eu-central-1" }, pending.first.arguments)
  end

  # LLM-04: Execute tool call -> Result is correlated to call_id and next model step completes
  def test_llm_04_execute_tool_call
    HeuristicSyndicate::Testing::FakeProvider.script_tool_call(
      "read_inventory",
      { datacenter: "eu-central-1" },
      id: "call_inv_4"
    )
    HeuristicSyndicate::Testing::FakeProvider.script_text("Found 2 hosts: db-01, db-02.")

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool] },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )
    @adapter.execute(conversation: conv, input: "Check eu-central-1")

    outcomes = @adapter.execute_tool_calls(conversation: conv) do |tc|
      ReadInventoryTool.new.call(**tc.arguments)
    end

    assert_equal 1, outcomes.size
    assert_equal "call_inv_4", outcomes.first[:tool_call_id]
    assert_empty @adapter.pending_tool_calls(conversation: conv)

    final_step = @adapter.execute_next_step(conversation: conv)
    assert_equal "Found 2 hosts: db-01, db-02.", final_step.content
    assert @adapter.complete?(conversation: conv)
  end

  # LLM-05: Multiple tool calls in one round -> All calls remain distinct and correlated
  def test_llm_05_multiple_tool_calls
    HeuristicSyndicate::Testing::FakeProvider.script_tool_calls([
      { id: "call_a", name: "read_inventory", arguments: { datacenter: "eu-1" } },
      { id: "call_b", name: "read_metrics", arguments: { host: "db-01" } }
    ])
    HeuristicSyndicate::Testing::FakeProvider.script_text("Inventory and metrics correlated.")

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool, ReadMetricsTool] },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )
    @adapter.execute(conversation: conv, input: "Check inventory and db-01 metrics")

    pending = @adapter.pending_tool_calls(conversation: conv)
    assert_equal %w[call_a call_b], pending.map(&:id)

    @adapter.execute_tool_calls(conversation: conv) do |tc|
      { handled: tc.name, id: tc.id }
    end

    assert_empty @adapter.pending_tool_calls(conversation: conv)
    final = @adapter.execute_next_step(conversation: conv)
    assert_equal "Inventory and metrics correlated.", final.content
  end

  # LLM-06: Checkpoint after model answer -> State is reconstructible
  def test_llm_06_checkpoint_after_model_response
    HeuristicSyndicate::Testing::FakeProvider.script_text("Initial analysis complete.")

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool] },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )
    @adapter.execute(conversation: conv, input: "Run initial analysis")

    chk = @adapter.checkpoint(conversation: conv)
    assert_equal 1, chk.schema_version
    assert_equal "ruby_llm", chk.adapter
    assert_equal "completed", chk.status
    assert_nil chk.pending_operation

    restored = @adapter.restore(
      checkpoint: chk,
      context: {
        security_context: @security_context,
        tools: [ReadInventoryTool],
        conversation_store: @conv_store
      }
    )
    assert_equal conv.id, restored.id
    assert @adapter.complete?(conversation: restored)
  end

  # LLM-07 & LLM-08: Checkpoint with open tool call & Restore in a brand-new OS process
  def test_llm_07_and_08_checkpoint_with_pending_tool_call_and_restore_in_new_process
    Dir.mktmpdir("spike1_proc_test") do |dir|
      file_store = HeuristicSyndicate::Store::FileStore.new(path: File.join(dir, "store.json"))
      conv_store = HeuristicSyndicate::Memory::ConversationStore.new(file_store)
      chk_id_file = File.join(dir, "chk_id.txt")

      # Process 1: Start conversation, receive tool call, save ConversationCheckpoint, and exit!
      pid1 = Process.fork do
        HeuristicSyndicate::Testing::FakeProvider.script_tool_call(
          "read_inventory",
          { datacenter: "us-east-1" },
          id: "call_subproc_7"
        )
        conv = @adapter.create_conversation(
          config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool] },
          context: { security_context: @security_context, conversation_store: conv_store }
        )
        @adapter.execute(conversation: conv, input: "Query us-east-1")
        chk = @adapter.checkpoint(conversation: conv)
        conv_store.save_checkpoint(chk, tenant: @security_context.tenant_id)
        File.write(chk_id_file, chk.id)
        Process.exit!(0)
      end
      _, status1 = Process.waitpid2(pid1)
      assert_equal 0, status1.exitstatus

      # Process 2 (current process, fresh memory): Load ConversationCheckpoint from disk, verify pending call,
      # execute tool, advance model, and complete!
      saved_chk_id = File.read(chk_id_file).strip
      loaded_chk = conv_store.find_checkpoint(saved_chk_id, tenant: @security_context.tenant_id)

      assert_equal "waiting_for_tool", loaded_chk.status
      assert_equal "call_subproc_7", loaded_chk.pending_operation[:call_id]
      assert_equal "read_inventory", loaded_chk.pending_operation[:tool_name]

      restored = @adapter.restore(
        checkpoint: loaded_chk,
        context: {
          security_context: @security_context,
          tools: [ReadInventoryTool],
          conversation_store: conv_store
        }
      )

      pending = @adapter.pending_tool_calls(conversation: restored)
      assert_equal 1, pending.size
      assert_equal "call_subproc_7", pending.first.id
      assert_equal({ datacenter: "us-east-1" }, pending.first.arguments)

      HeuristicSyndicate::Testing::FakeProvider.script_text("Restored in new process: us-east-1 has 2 hosts.")
      @adapter.execute_tool_calls(conversation: restored) do |tc|
        ReadInventoryTool.new.call(**tc.arguments)
      end

      final_step = @adapter.execute_next_step(conversation: restored)
      assert_equal "Restored in new process: us-east-1 has 2 hosts.", final_step.content
      assert @adapter.complete?(conversation: restored)
    end
  end

  # LLM-09: Restore with incompatible adapter -> Explicit AdapterCompatibilityError
  def test_llm_09_restore_with_incompatible_adapter_raises
    chk = HeuristicSyndicate::LLM::ConversationCheckpoint.new(
      id: "chk_other",
      tenant_id: "tenant_alpha",
      conversation_id: "conv_1",
      adapter: "other_llm_engine",
      adapter_version: "1.0",
      provider: "fake",
      model: "spike1-model",
      status: "completed",
      transcript_ref: "transcript_1"
    )

    assert_raises(HeuristicSyndicate::AdapterCompatibilityError) do
      @adapter.restore(
        checkpoint: chk,
        context: { security_context: @security_context, conversation_store: @conv_store }
      )
    end
  end

  # LLM-10: Provider error -> Normalized ProviderError (TransientError subclass)
  def test_llm_10_provider_error_normalization
    HeuristicSyndicate::Testing::FakeProvider.script_error("HTTP 503 Upstream overloaded")

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )

    err = assert_raises(HeuristicSyndicate::ProviderError) do
      @adapter.execute(conversation: conv, input: "Trigger provider failure")
    end
    assert_kind_of HeuristicSyndicate::TransientError, err
    assert_match(/HTTP 503/, err.message)
  end

  # LLM-11: Approval interrupt on tool call -> Conversation pauses and saves checkpoint
  def test_llm_11_approval_interrupt_pauses_conversation
    HeuristicSyndicate::Testing::FakeProvider.script_tool_call(
      "restart_service",
      { service: "kasm-proxy" },
      id: "call_appr_11"
    )
    HeuristicSyndicate::Testing::FakeProvider.script_text("Service kasm-proxy restarted after approval.")

    runtime = HeuristicSyndicate::Runtime::AgentRuntime.new(
      adapter: @adapter,
      conversation_store: @conv_store
    )

    outcome = runtime.run(
      agent_class: InventoryAgent,
      input: "Restart kasm-proxy",
      security_context: @security_context
    )

    assert_equal :interrupted, outcome[:status]
    assert_equal :tool_approval_required, outcome[:reason]
    assert_equal "call_appr_11", outcome[:tool_call].id
    assert_equal "waiting_for_approval", outcome[:conversation_checkpoint].status

    # Resume after human approves call_appr_11
    resumed = runtime.resume(
      checkpoint: outcome[:conversation_checkpoint],
      agent_class: InventoryAgent,
      security_context: @security_context,
      approved_tool_call_ids: ["call_appr_11"]
    )

    assert_equal :completed, resumed[:status]
    assert_equal "Service kasm-proxy restarted after approval.", resumed[:output]
  end

  # LLM-12: Tool registry changed before restore -> Old tool permission is rejected
  def test_llm_12_tool_registry_change_revokes_old_tool_permission
    HeuristicSyndicate::Testing::FakeProvider.script_tool_call(
      "read_metrics",
      { host: "db-01" },
      id: "call_revoked_12"
    )

    conv = @adapter.create_conversation(
      config: { model: "spike1-model", provider: :fake, tools: [ReadInventoryTool, ReadMetricsTool] },
      context: { security_context: @security_context, conversation_store: @conv_store }
    )
    @adapter.execute(conversation: conv, input: "Read metrics on db-01")
    chk = @adapter.checkpoint(conversation: conv)

    # Restore with a restricted tool registry that no longer includes ReadMetricsTool
    assert_raises(HeuristicSyndicate::CapabilityDeniedError) do
      @adapter.restore(
        checkpoint: chk,
        context: {
          security_context: @security_context,
          tools: [ReadInventoryTool],
          conversation_store: @conv_store
        }
      )
    end
  end
end
