# frozen_string_literal: true

require_relative "test_helper"
require_relative "../examples/werkbank/incident_workflow"

class WerkbankWorkflowTest < Minitest::Test
  include HeuristicSyndicate::Testing::Assertions

  # Fake infrastructure readers (read-only) and writers (executor-only)
  class FakeKasmReader
    def workspace_status(incident_id)
      { incident_id: incident_id, workspace_id: "ws-kasm-01", status: "degraded", active_sessions: 42 }
    end
  end

  class FakePostgresReader
    def blocking_locks(incident_id)
      { incident_id: incident_id, blocking_pid: 4711, waiting_sessions: 18, query: "LOCK TABLE sessions" }
    end
  end

  class FakeGitlabReader
    def recent_deployments(incident_id)
      { incident_id: incident_id, mr_id: "mr-123", deployed_at: "2026-10-31T00:05:00Z" }
    end
  end

  class FakeVsphereReader
    def vm_metrics(incident_id)
      { incident_id: incident_id, vm_id: "vm-db-01", cpu_pct: 91, ram_pct: 78 }
    end
  end

  class FakePostgresWriter
    attr_reader :terminated_pids

    def initialize
      @blocked_pids = [4711]
      @terminated_pids = []
    end

    def pid_blocked?(pid)
      @blocked_pids.include?(pid)
    end

    def terminate_backend!(pid, idempotency_key: nil)
      @blocked_pids.delete(pid)
      @terminated_pids << { pid: pid, idempotency_key: idempotency_key }
      { terminated_pid: pid }
    end

    def reconcile_termination(pid, idempotency_key: nil)
      { reconciled_pid: pid, idempotency_key: idempotency_key }
    end
  end

  class FakeKasmWriter
    attr_reader :restarted_workspaces

    def initialize
      @restarted_workspaces = []
    end

    def workspace_exists?(ws_id)
      ws_id == "ws-kasm-01"
    end

    def restart_workspace!(ws_id, idempotency_key: nil)
      @restarted_workspaces << { workspace_id: ws_id, idempotency_key: idempotency_key }
      { restarted: ws_id }
    end

    def workspace_healthy?(_ws_id)
      true
    end
  end

  def setup
    HeuristicSyndicate.reset!
    @store = HeuristicSyndicate::Store::Memory.new
    @anchor_store = HeuristicSyndicate::Audit::InMemoryAnchorStore.new
    @audit_chain = HeuristicSyndicate::Audit::HashChain.new(store: @store, anchor_store: @anchor_store)

    @action_registry = HeuristicSyndicate::Governance::ActionRegistry.new
    @action_registry.register(Werkbank::PgTerminateBackendAction)
    @action_registry.register(Werkbank::KasmRestartWorkspaceAction)

    @approval_policy = HeuristicSyndicate::ApprovalPolicy.new(
      risk_levels: { low: 0, medium: 1, high: 2 },
      require_distinct_approvers: true,
      expires_in: 3600
    )
    @approval_manager = HeuristicSyndicate::Governance::ApprovalManager.new(
      store: @store,
      policy: @approval_policy,
      audit_chain: @audit_chain
    )

    @pg_writer = FakePostgresWriter.new
    @kasm_writer = FakeKasmWriter.new

    @resolver = HeuristicSyndicate::Security::CredentialResolver.new
    @resolver.register_value(:kasm_reader, FakeKasmReader.new, mode: :read)
    @resolver.register_value(:pg_reader, FakePostgresReader.new, mode: :read)
    @resolver.register_value(:gitlab_reader, FakeGitlabReader.new, mode: :read)
    @resolver.register_value(:vsphere_reader, FakeVsphereReader.new, mode: :read)
    @resolver.register_value(:action_registry, @action_registry, mode: :read)
    @resolver.register_value(:approval_manager, @approval_manager, mode: :read)
    @resolver.register_value(:audit_chain, @audit_chain, mode: :read)
    @resolver.register_value(:credential_resolver_ref, @resolver, mode: :read)

    # Write credentials available ONLY in :executor mode
    @resolver.register_value(:pg_writer, @pg_writer, mode: :write)
    @resolver.register_value(:kasm_writer, @kasm_writer, mode: :write)

    @security_context = HeuristicSyndicate::SecurityContext.new(
      tenant_id: "werkbank_prod",
      actor_id: "alertmanager_webhook",
      capabilities: [
        { name: :kasm_read, resources: ["production.*"] },
        { name: :postgres_read, resources: ["production.*"] },
        { name: :gitlab_read, resources: ["production.*"] },
        { name: :vsphere_read, resources: ["production.*"] },
        { name: :postgres_terminate, resources: ["production.*"] },
        { name: :kasm_restart, resources: ["production.*"] }
      ],
      environment: :production,
      policy_version: "1.0",
      execution_mode: :analysis
    )
  end

  def script_werkbank_llm_responses
    fp = HeuristicSyndicate::Testing::FakeProvider

    # 4 Parallel specialist agents
    fp.script_json(
      {
        system: "kasm",
        health: "degraded",
        summary: "Workspace ws-kasm-01 sessions stalled",
        evidence: [{ ref: "kasm:ws:ws-kasm-01", observation: "42 stalled sessions", timestamp: "2026-10-31T00:08:00Z" }]
      },
      model: "werkbank-kasm"
    )

    fp.script_json(
      {
        system: "postgres",
        health: "failing",
        summary: "PID 4711 holding exclusive lock on sessions",
        evidence: [{ ref: "pg:pid:4711", observation: "18 queries blocked by PID 4711", timestamp: "2026-10-31T00:06:00Z" }]
      },
      model: "werkbank-postgres"
    )

    fp.script_json(
      {
        system: "gitlab",
        health: "ok",
        summary: "MR-123 deployed 1 minute before lock spike",
        evidence: [{ ref: "gitlab:mr:123", observation: "Migration deployed", timestamp: "2026-10-31T00:05:00Z" }]
      },
      model: "werkbank-gitlab"
    )

    fp.script_json(
      {
        system: "vsphere",
        health: "degraded",
        summary: "VM vm-db-01 CPU at 91%",
        evidence: [{ ref: "vsphere:vm:vm-db-01", observation: "CPU 91%", timestamp: "2026-10-31T00:07:00Z" }]
      },
      model: "werkbank-vsphere"
    )

    # Correlation agent cites valid evidence_refs from the findings
    fp.script_json(
      {
        hypotheses: [
          {
            description: "GitLab MR-123 migration left uncommitted lock in Postgres PID 4711, stalling KASM sessions",
            confidence: 0.94,
            evidence_refs: %w[gitlab:mr:123 pg:pid:4711 kasm:ws:ws-kasm-01]
          }
        ],
        needs_more_data: false
      },
      model: "werkbank-correlation"
    )

    # Planner agent drafts allowlisted remediation steps
    fp.script_json(
      {
        id: "plan_inc_42",
        title: "Terminate blocking Postgres PID 4711 and restart KASM workspace",
        rationale: "Clears exclusive lock from MR-123 and recovers stalled sessions",
        steps: [
          {
            action: "pg_terminate_backend",
            version: "1.0.0",
            params: { pid: 4711, database: "production" },
            risk: "medium",
            resource: "production.postgres"
          },
          {
            action: "kasm_restart_workspace",
            version: "1.0.0",
            params: { workspace_id: "ws-kasm-01" },
            risk: "low",
            resource: "production.kasm"
          }
        ],
        test_strategy: ["Verify pg_blocking_pids is empty", "Verify ws-kasm-01 health"]
      },
      model: "werkbank-planner"
    )

    # Final report agent
    fp.script_json(
      {
        incident_id: "inc_42",
        status: "resolved",
        root_cause: "Blocking lock PID 4711 after MR-123",
        actions_taken: %w[pg_terminate_backend kasm_restart_workspace]
      },
      model: "werkbank-report"
    )
  end

  def test_complete_werkbank_governed_incident_workflow_offline
    script_werkbank_llm_responses

    # Phase A: Run pipeline until it suspends at the human approval interrupt
    suspended_run = Werkbank::IncidentPipeline.run(
      { incident_id: "inc_42", title: "KASM workspace freeze" },
      security_context: @security_context,
      store: @store,
      credential_resolver: @resolver,
      audit_chain: @audit_chain,
      approval_manager: @approval_manager,
      action_registry: @action_registry
    )

    assert_run_suspended(suspended_run)
    assert_empty @pg_writer.terminated_pids, "No write action may execute before human approval"
    assert_empty @kasm_writer.restarted_workspaces

    plan = suspended_run.outputs[:plan_compiler][:plan]
    assert_instance_of HeuristicSyndicate::Governance::Plan, plan
    assert_match(/\Asha256:/, plan.digest)

    # Phase B: Human administrator reviews evidence & plan and grants digest-bound approval
    @approval_manager.record_approval(
      plan: plan,
      approver_id: "senior_sysadmin_anna",
      digest: plan.digest,
      tenant: "werkbank_prod"
    )

    # Phase C: Resume pipeline (simulating background job pickup after approval)
    completed_run = Werkbank::IncidentPipeline.resume(
      run_id: suspended_run.id,
      decision: { approved: true, approver_id: "senior_sysadmin_anna", digest: plan.digest },
      security_context: @security_context,
      store: @store,
      credential_resolver: @resolver,
      audit_chain: @audit_chain,
      approval_manager: @approval_manager,
      action_registry: @action_registry
    )

    assert_run_completed(completed_run)

    # Verify deterministic Executor applied both approved actions
    assert_equal 1, @pg_writer.terminated_pids.size
    assert_equal 4711, @pg_writer.terminated_pids.first[:pid]
    assert_equal 1, @kasm_writer.restarted_workspaces.size
    assert_equal "ws-kasm-01", @kasm_writer.restarted_workspaces.first[:workspace_id]

    # Verify final ReportAgent output
    report = completed_run.outputs[:report][:report]
    assert_equal "resolved", report[:status]

    # Verify tamper-evident Audit Chain + External Signed Anchor Checkpoint
    assert_audit_chain_valid(
      store: @store,
      anchor_store: @anchor_store,
      tenant: "werkbank_prod",
      run_id: completed_run.id
    )
    assert_audit_chain_valid(
      store: @store,
      anchor_store: @anchor_store,
      tenant: "werkbank_prod",
      run_id: plan.run_id
    )
  end

  def test_werkbank_evidence_loop_reanalyzes_up_to_max_visits
    fp = HeuristicSyndicate::Testing::FakeProvider

    # Initial 4 specialist agents
    fp.script_json(
      { system: "kasm", health: "degraded", summary: "stalled", evidence: [{ ref: "kasm:ws:1", observation: "stalled", timestamp: "2026-10-31T00:08:00Z" }] },
      model: "werkbank-kasm"
    )
    fp.script_json(
      { system: "postgres", health: "failing", summary: "lock", evidence: [{ ref: "pg:pid:4711", observation: "lock", timestamp: "2026-10-31T00:06:00Z" }] },
      model: "werkbank-postgres"
    )
    fp.script_json(
      { system: "gitlab", health: "ok", summary: "mr", evidence: [{ ref: "gitlab:mr:123", observation: "mr", timestamp: "2026-10-31T00:05:00Z" }] },
      model: "werkbank-gitlab"
    )
    fp.script_json(
      { system: "vsphere", health: "ok", summary: "vm", evidence: [{ ref: "vsphere:vm:1", observation: "vm", timestamp: "2026-10-31T00:07:00Z" }] },
      model: "werkbank-vsphere"
    )

    # First correlation pass asks for more data -> triggers loop back to PostgresAgent (visit 2)
    fp.script_json(
      { hypotheses: [], needs_more_data: true },
      model: "werkbank-correlation"
    )

    # Second PostgresAgent pass (visit 2)
    fp.script_json(
      { system: "postgres", health: "failing", summary: "deeper lock detail", evidence: [{ ref: "pg:pid:4711", observation: "deadlock confirmed", timestamp: "2026-10-31T00:06:30Z" }] },
      model: "werkbank-postgres"
    )

    # Second correlation pass succeeds
    fp.script_json(
      {
        hypotheses: [{ description: "Confirmed lock on PID 4711", confidence: 0.98, evidence_refs: ["pg:pid:4711"] }],
        needs_more_data: false
      },
      model: "werkbank-correlation"
    )

    fp.script_json(
      {
        id: "plan_loop_1",
        title: "Terminate PID 4711",
        rationale: "Confirmed after second pass",
        steps: [{ action: "pg_terminate_backend", version: "1.0.0", params: { pid: 4711 }, risk: "medium", resource: "production.postgres" }]
      },
      model: "werkbank-planner"
    )

    suspended = Werkbank::IncidentPipeline.run(
      { incident_id: "inc_loop" },
      security_context: @security_context,
      store: @store,
      credential_resolver: @resolver,
      audit_chain: @audit_chain,
      approval_manager: @approval_manager,
      action_registry: @action_registry
    )

    assert_run_suspended(suspended)
    assert_equal 2, suspended.visit_counts["postgres"]
    assert_equal 2, suspended.visit_counts["correlation"]
  end
end
