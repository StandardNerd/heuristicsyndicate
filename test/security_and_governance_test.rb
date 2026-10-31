# frozen_string_literal: true

require_relative "test_helper"

class SecurityAndGovernanceTest < Minitest::Test
  class SecretQueryTool < HeuristicSyndicate::Tool
    tool_name "query_postgres"
    description "Query PostgreSQL metrics"
    read_only
    requires_capability :database_read
    scope "postgres"
    untrusted_output
    max_output 500

    def execute(table:)
      "row=1 api_key=sk_live_999999999999 table=#{table}"
    end
  end

  class DangerousWriteTool < HeuristicSyndicate::Tool
    tool_name "drop_database"
    description "Dangerous write operation"
    writes
    requires_capability :database_admin
    scope "postgres"

    def execute
      "dropped"
    end
  end

  class ReadOnlyPostgresAgent < HeuristicSyndicate::Agent
    goal "Read metrics safely"
    model "sec-model", provider: :fake
    permits :read
    scope "postgres"
    capabilities do
      allow :database_read, resources: ["production.metrics", "production.incidents"]
    end
    tools SecretQueryTool
  end

  class SampleRestartAction < HeuristicSyndicate::Action
    action_name "restart_workspace"
    version "1.0.0"
    risk :high
    idempotent true
    requires_capability :workspace_restart

    params do
      required :workspace_id, :string
    end

    def precondition(ctx, params)
      ctx[:state][:online] != false && !params[:workspace_id].empty?
    end

    def apply(ctx, params, idempotency_key: nil)
      ctx[:state][:restarted] << params[:workspace_id]
      { restarted: params[:workspace_id], key: idempotency_key }
    end

    def verify(ctx, _params)
      ctx[:state][:verify_ok] != false
    end

    def compensate(ctx, params)
      ctx[:state][:compensated] << params[:workspace_id]
      "restored_previous_workspace_state"
    end
  end

  def setup
    HeuristicSyndicate.reset!
    @store = HeuristicSyndicate::Store::Memory.new
    @anchor_store = HeuristicSyndicate::Audit::InMemoryAnchorStore.new
    @audit_chain = HeuristicSyndicate::Audit::HashChain.new(store: @store, anchor_store: @anchor_store)
  end

  def test_capability_enforcement_blocks_write_tools_on_read_only_agent
    assert_raises(HeuristicSyndicate::CapabilityDeniedError) do
      Class.new(HeuristicSyndicate::Agent) do
        permits :read
        capabilities { allow :database_admin }
        tools DangerousWriteTool
      end
    end
  end

  def test_resource_level_authorization_and_untrusted_secret_redaction
    sec_allowed = HeuristicSyndicate::SecurityContext.new(
      tenant_id: "t1",
      actor_id: "u1",
      capabilities: [{ name: :database_read, resources: ["production.metrics"] }]
    )

    assert HeuristicSyndicate::Security::Authorizer.authorize_tool_execution!(
      security_context: sec_allowed,
      agent_class: ReadOnlyPostgresAgent,
      tool_class: SecretQueryTool,
      resource: "production.metrics"
    )

    assert_raises(HeuristicSyndicate::CapabilityDeniedError) do
      HeuristicSyndicate::Security::Authorizer.authorize_tool_execution!(
        security_context: sec_allowed,
        agent_class: ReadOnlyPostgresAgent,
        tool_class: SecretQueryTool,
        resource: "production.payroll_secrets"
      )
    end

    # Verify UntrustedData wraps tool output and redacts leaked credentials
    out = SecretQueryTool.new.call(table: "production.metrics")
    assert_equal "untrusted_external_data", out[:_classification]
    assert_includes out[:data], "[REDACTED]"
    refute_includes out[:data], "sk_live_999999999999"
  end

  def test_ssrf_protection_blocks_private_and_loopback_hosts
    assert_raises(HeuristicSyndicate::SecurityError) do
      HeuristicSyndicate::Security::Authorizer.validate_egress_url!("http://169.254.169.254/latest/meta-data/")
    end

    assert_raises(HeuristicSyndicate::SecurityError) do
      HeuristicSyndicate::Security::Authorizer.validate_egress_url!("http://127.0.0.1:5001/admin")
    end

    assert HeuristicSyndicate::Security::Authorizer.validate_egress_url!(
      "https://api.gitlab.example.com/v4/projects",
      allowed_hosts: ["api.gitlab.example.com"]
    )
  end

  def test_credential_resolver_blocks_write_credentials_in_analysis_mode
    resolver = HeuristicSyndicate::Security::CredentialResolver.new
    resolver.register(:pg_writer, mode: :write) { "WRITE_CONN" }

    analysis_ctx = HeuristicSyndicate::SecurityContext.new(
      tenant_id: "t1",
      actor_id: "u1",
      execution_mode: :analysis
    )
    executor_ctx = analysis_ctx.with_execution_mode(:executor)

    assert_raises(HeuristicSyndicate::CapabilityDeniedError) do
      resolver.resolve(:pg_writer, security_context: analysis_ctx)
    end

    assert_equal "WRITE_CONN", resolver.resolve(:pg_writer, security_context: executor_ctx)
  end

  def test_checkpoint_refuses_to_serialize_credentials_or_clients
    assert_raises(HeuristicSyndicate::SerializationError) do
      HeuristicSyndicate::Execution::Checkpoint.new(
        id: "chk_bad",
        tenant_id: "t1",
        run_id: "r1",
        node_outputs: { leak: { api_key: "secret_123" } }
      )
    end
  end

  def test_governance_digest_binding_four_eyes_policy_and_compensation
    registry = HeuristicSyndicate::Governance::ActionRegistry.new.register(SampleRestartAction)
    policy = HeuristicSyndicate::ApprovalPolicy.new(
      risk_levels: { low: 0, medium: 1, high: 2 },
      require_distinct_approvers: true,
      expires_in: 3600
    )
    appr_mgr = HeuristicSyndicate::Governance::ApprovalManager.new(
      store: @store,
      policy: policy,
      audit_chain: @audit_chain
    )

    plan = HeuristicSyndicate::Governance::Plan.new(
      id: "plan_gov_1",
      tenant_id: "t1",
      run_id: "run_gov_1",
      title: "Restart workspace ws-9",
      rationale: "Workspace frozen",
      steps: [{ action: "restart_workspace", version: "1.0.0", params: { workspace_id: "ws-9" }, resource: "kasm.ws-9" }],
      registry: registry,
      environment: :production,
      policy_version: "1.0"
    )

    # Wrong digest rejected
    assert_raises(HeuristicSyndicate::ApprovalInvalidError) do
      appr_mgr.record_approval(plan: plan, approver_id: "admin_1", digest: "sha256:wrong", tenant: "t1")
    end

    # Single approver is not enough for high-risk (needs 2 distinct approvers)
    appr_mgr.record_approval(plan: plan, approver_id: "admin_1", digest: plan.digest, tenant: "t1")
    # Duplicate approval by same admin_1 is idempotent and doesn't count as second distinct approver
    appr_mgr.record_approval(plan: plan, approver_id: "admin_1", digest: plan.digest, tenant: "t1")

    assert_raises(HeuristicSyndicate::ApprovalInvalidError) do
      appr_mgr.verify_authorized!(plan: plan, current_registry: registry, tenant: "t1")
    end

    # Second distinct approver satisfies four-eyes policy
    appr_mgr.record_approval(plan: plan, approver_id: "admin_2", digest: plan.digest, tenant: "t1")
    assert appr_mgr.verify_authorized!(plan: plan, current_registry: registry, tenant: "t1")

    # If Action version in registry changes to 2.0.0 after approval, execution is rejected!
    drifted_action = Class.new(SampleRestartAction) do
      action_name "restart_workspace"
      version "2.0.0"
    end
    drifted_registry = HeuristicSyndicate::Governance::ActionRegistry.new.register(drifted_action)

    assert_raises(HeuristicSyndicate::ApprovalInvalidError) do
      appr_mgr.verify_authorized!(plan: plan, current_registry: drifted_registry, tenant: "t1")
    end

    # Test compensation when verification fails
    shared_state = { online: true, restarted: [], compensated: [], verify_ok: false }
    comp_action = Class.new(SampleRestartAction) do
      action_name "restart_workspace"
      version "1.0.0"
      define_method(:precondition) { |_ctx, _p| shared_state[:online] }
      define_method(:apply) do |_ctx, p, idempotency_key: nil|
        shared_state[:restarted] << p[:workspace_id]
        { key: idempotency_key }
      end
      define_method(:verify) { |_ctx, _p| shared_state[:verify_ok] }
      define_method(:compensate) do |_ctx, p|
        shared_state[:compensated] << p[:workspace_id]
        "compensated_ws"
      end
    end
    comp_reg = HeuristicSyndicate::Governance::ActionRegistry.new.register(comp_action)
    executor = HeuristicSyndicate::Governance::Executor.new(
      registry: comp_reg,
      approval_manager: appr_mgr,
      audit_chain: @audit_chain
    )

    exec_sec = HeuristicSyndicate::SecurityContext.new(
      tenant_id: "t1",
      actor_id: "executor_bot",
      capabilities: [{ name: :workspace_restart, resources: ["kasm.*"] }],
      environment: :production,
      policy_version: "1.0",
      execution_mode: :executor
    )

    assert_raises(HeuristicSyndicate::VerificationFailedError) do
      executor.execute!(plan: plan, security_context: exec_sec)
    end

    assert_equal ["ws-9"], shared_state[:restarted]
    assert_equal ["ws-9"], shared_state[:compensated]
  end

  def test_audit_hash_chain_and_external_signed_anchor_detect_tampering
    @audit_chain.append(tenant: "t1", run_id: "r_audit", actor_id: "u1", event_type: "run.started", payload: { a: 1 })
    @audit_chain.append(tenant: "t1", run_id: "r_audit", actor_id: "u1", event_type: "action.applied", payload: { a: 2 })
    anchor = @audit_chain.create_anchor!(tenant: "t1", run_id: "r_audit")

    assert_equal 2, anchor.up_to_sequence
    assert @audit_chain.verify!(tenant: "t1", run_id: "r_audit")

    # Object lock prevents overwriting existing anchor sequence
    assert_raises(HeuristicSyndicate::AuditIntegrityError) do
      @anchor_store.write_anchor!(anchor)
    end

    # Simulate privileged DB attacker mutating payload in @store
    raw_events = @store.instance_variable_get(:@audit_events)
    raw_events.first[:payload][:a] = 999

    assert_raises(HeuristicSyndicate::AuditIntegrityError) do
      @audit_chain.verify!(tenant: "t1", run_id: "r_audit")
    end
  end

  def test_knowledge_store_enforces_tenant_isolation_before_retrieval
    ks = HeuristicSyndicate::Memory::KnowledgeStore.new
    ks.ingest(
      { id: "doc_1", content: "Postgres deadlock runbook for production", embedding: [1.0, 0.0, 0.0] },
      tenant: "tenant_a"
    )
    ks.ingest(
      { id: "doc_2", content: "Postgres deadlock secret notes", embedding: [1.0, 0.0, 0.0] },
      tenant: "tenant_b"
    )

    hits_a = ks.search_keyword("deadlock", tenant: "tenant_a")
    assert_equal ["doc_1"], hits_a.map(&:id)

    vec_hits_b = ks.search_vector([1.0, 0.0, 0.0], tenant: "tenant_b")
    assert_equal ["doc_2"], vec_hits_b.map(&:id)
  end

  def test_budget_manager_and_store_capabilities_enforcement
    policy = HeuristicSyndicate::ExecutionPolicy.new(max_tokens: 100, max_tool_calls: 2)
    budget = HeuristicSyndicate::Runtime::BudgetManager.new(policy: policy)

    budget.record_model_request!(tokens: 60)
    assert_raises(HeuristicSyndicate::BudgetExceededError) do
      budget.record_model_request!(tokens: 50)
    end

    mem_store = HeuristicSyndicate::Store::Memory.new
    assert mem_store.capabilities.verify_requirements!(atomic_claims: true, tenant_scoping: true)
    assert_raises(HeuristicSyndicate::StoreCapabilityError) do
      mem_store.capabilities.verify_requirements!(durable_writes: true)
    end
  end
end
