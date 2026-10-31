# frozen_string_literal: true

require_relative "../../lib/heuristic_syndicate"

module Werkbank
  # --- 1. Read-Only Infrastructure Tools (ADR §4.2) ---

  class KasmStatusTool < HeuristicSyndicate::Tool
    description "Inspect KASM workspace sessions and status"
    read_only
    requires_capability :kasm_read
    scope "kasm"
    inject :kasm_reader
    untrusted_output
    max_output 4_000

    def execute(incident_id:)
      kasm_reader.workspace_status(incident_id)
    end
  end

  class PostgresLocksTool < HeuristicSyndicate::Tool
    description "Inspect PostgreSQL blocking locks and active sessions"
    read_only
    requires_capability :postgres_read
    scope "postgres"
    inject :pg_reader
    untrusted_output
    max_output 4_000

    def execute(incident_id:)
      pg_reader.blocking_locks(incident_id)
    end
  end

  class GitlabDeploymentsTool < HeuristicSyndicate::Tool
    description "Inspect recent GitLab deployments and merge requests"
    read_only
    requires_capability :gitlab_read
    scope "gitlab"
    inject :gitlab_reader
    untrusted_output
    max_output 4_000

    def execute(incident_id:)
      gitlab_reader.recent_deployments(incident_id)
    end
  end

  class VsphereVmMetricsTool < HeuristicSyndicate::Tool
    description "Inspect VMware vSphere VM CPU, RAM, and storage metrics"
    read_only
    requires_capability :vsphere_read
    scope "vsphere"
    inject :vsphere_reader
    untrusted_output
    max_output 4_000

    def execute(incident_id:)
      vsphere_reader.vm_metrics(incident_id)
    end
  end

  # --- 2. Read-Only Specialist & Analysis Agents (ADR §4.1) ---

  class KasmAgent < HeuristicSyndicate::Agent
    goal "Analyze KASM workspace health for incident"
    model "werkbank-kasm"
    permits :read
    scope "kasm"
    capabilities { allow :kasm_read, resources: ["production.*"] }
    tools KasmStatusTool
    outputs :kasm_analysis
    stops_when max_turns: 4
  end

  class PostgresAgent < HeuristicSyndicate::Agent
    goal "Analyze PostgreSQL locks and connections for incident"
    model "werkbank-postgres"
    permits :read
    scope "postgres"
    capabilities { allow :postgres_read, resources: ["production.*"] }
    tools PostgresLocksTool
    outputs :postgres_analysis
    stops_when max_turns: 4
  end

  class GitlabAgent < HeuristicSyndicate::Agent
    goal "Analyze recent GitLab deployments and config changes"
    model "werkbank-gitlab"
    permits :read
    scope "gitlab"
    capabilities { allow :gitlab_read, resources: ["production.*"] }
    tools GitlabDeploymentsTool
    outputs :gitlab_analysis
    stops_when max_turns: 4
  end

  class VsphereAgent < HeuristicSyndicate::Agent
    goal "Analyze VMware vSphere VM metrics"
    model "werkbank-vsphere"
    permits :read
    scope "vsphere"
    capabilities { allow :vsphere_read, resources: ["production.*"] }
    tools VsphereVmMetricsTool
    outputs :vsphere_analysis
    stops_when max_turns: 4
  end

  class CorrelationAgent < HeuristicSyndicate::Agent
    goal "Correlate cross-system findings and timeline into root-cause hypotheses with evidence_refs"
    model "werkbank-correlation"
    permits :read
    outputs :correlation_findings
    stops_when max_turns: 3
  end

  class PlannerAgent < HeuristicSyndicate::Agent
    goal "Draft a remediation plan using only allowlisted actions"
    model "werkbank-planner"
    permits :read
    outputs :raw_plan
    stops_when max_turns: 3
  end

  class ReportAgent < HeuristicSyndicate::Agent
    goal "Generate an audit-backed incident resolution report"
    model "werkbank-report"
    permits :read
    outputs :report
    stops_when max_turns: 2
  end

  # --- 3. Deterministic Components (ADR §4.3 & §5) ---

  class TimelineBuilder < HeuristicSyndicate::Component
    input :kasm, type: Hash
    input :postgres, type: Hash
    input :gitlab, type: Hash
    input :vsphere, type: Hash

    output :timeline, type: Array
    output :known_evidence_refs, type: Array

    def call(kasm:, postgres:, gitlab:, vsphere:, **_rest)
      findings = [kasm, postgres, gitlab, vsphere]
      events = findings.flat_map do |f|
        sys = f[:system] || "unknown"
        Array(f[:evidence]).map do |ev|
          {
            timestamp: ev[:timestamp] || "2026-10-31T00:00:00Z",
            system: sys,
            ref: ev[:ref],
            observation: ev[:observation]
          }
        end
      end.sort_by { |e| e[:timestamp].to_s }

      refs = events.filter_map { |e| e[:ref] }.uniq
      {
        timeline: events,
        known_evidence_refs: refs
      }
    end
  end

  class EvidenceValidationComponent < HeuristicSyndicate::Component
    input :findings, type: Hash
    input :known_evidence_refs, type: Array

    output :validated_findings, type: Hash
    output :needs_more_data, type: Object

    def call(findings:, known_evidence_refs:, **_rest)
      hypotheses = Array(findings[:hypotheses]).select do |h|
        refs = Array(h[:evidence_refs])
        refs.any? && (refs - known_evidence_refs).empty?
      end

      if hypotheses.empty? && !findings[:needs_more_data]
        raise HeuristicSyndicate::ValidationError,
              "All root-cause hypotheses were rejected due to missing or fabricated evidence_refs"
      end

      needs_more = findings[:needs_more_data] == true
      {
        validated_findings: findings.merge(hypotheses: hypotheses),
        needs_more_data: needs_more
      }
    end
  end

  class PlanCompilerComponent < HeuristicSyndicate::Component
    inject :action_registry

    input :raw_plan, type: Hash

    output :plan, type: HeuristicSyndicate::Governance::Plan

    def call(raw_plan:, incident_id: "inc_1", **_rest)
      plan = HeuristicSyndicate::Governance::Plan.new(
        id: raw_plan[:id] || "plan_#{incident_id}",
        tenant_id: security_context.tenant_id,
        run_id: "run_#{incident_id}",
        title: raw_plan[:title] || "Remediation Plan",
        rationale: raw_plan[:rationale] || "Automated remediation",
        steps: raw_plan[:steps] || [],
        registry: action_registry,
        test_strategy: raw_plan[:test_strategy] || ["verify_locks_cleared"],
        environment: security_context.environment,
        policy_version: security_context.policy_version,
        expires_at: Time.now.utc + 3600
      )
      { plan: plan }
    end
  end

  # --- 4. Versioned Deterministic Action Contracts (ADR-006) ---

  class PgTerminateBackendAction < HeuristicSyndicate::Action
    action_name "pg_terminate_backend"
    version "1.0.0"
    risk :medium
    idempotent true
    recovery_strategy :reconcile
    requires_capability :postgres_terminate

    params do
      required :pid, :integer
      optional :database, :string, default: "production"
    end

    def precondition(context, params)
      pg_writer = resolve_writer(context)
      pg_writer.pid_blocked?(params[:pid])
    end

    def dry_run(_context, params)
      { would_terminate_pid: params[:pid] }
    end

    def apply(context, params, idempotency_key: nil)
      pg_writer = resolve_writer(context)
      pg_writer.terminate_backend!(params[:pid], idempotency_key: idempotency_key)
    end

    def verify(context, params)
      pg_writer = resolve_writer(context)
      !pg_writer.pid_blocked?(params[:pid])
    end

    def reconcile(context, params, idempotency_key: nil)
      pg_writer = resolve_writer(context)
      pg_writer.reconcile_termination(params[:pid], idempotency_key: idempotency_key)
    end

    def compensate(context, params)
      pg_writer = resolve_writer(context)
      pg_writer.record_compensation(params[:pid])
    end

    private

    def resolve_writer(context)
      resolver = context[:credential_resolver]
      sec = context[:security_context]
      resolver.resolve(:pg_writer, security_context: sec)
    end
  end

  class KasmRestartWorkspaceAction < HeuristicSyndicate::Action
    action_name "kasm_restart_workspace"
    version "1.0.0"
    risk :low
    idempotent true
    recovery_strategy :idempotent
    requires_capability :kasm_restart

    params do
      required :workspace_id, :string
    end

    def precondition(context, params)
      writer = context[:credential_resolver].resolve(:kasm_writer, security_context: context[:security_context])
      writer.workspace_exists?(params[:workspace_id])
    end

    def apply(context, params, idempotency_key: nil)
      writer = context[:credential_resolver].resolve(:kasm_writer, security_context: context[:security_context])
      writer.restart_workspace!(params[:workspace_id], idempotency_key: idempotency_key)
    end

    def verify(context, params)
      writer = context[:credential_resolver].resolve(:kasm_writer, security_context: context[:security_context])
      writer.workspace_healthy?(params[:workspace_id])
    end

    def compensate(context, params)
      writer = context[:credential_resolver].resolve(:kasm_writer, security_context: context[:security_context])
      writer.restore_snapshot!(params[:workspace_id])
    end
  end

  class IncidentExecutorComponent < HeuristicSyndicate::Component
    inject :action_registry, :approval_manager, :audit_chain, :credential_resolver_ref

    input :plan
    input :decision, type: Hash

    output :execution_result, type: Hash

    def call(plan:, decision:, **_rest)
      plan_obj = HeuristicSyndicate::Governance::Plan.from_h(plan)
      if decision[:status] == :rejected || decision[:approved] == false
        return {
          execution_result: {
            status: :rejected,
            plan_id: plan_obj.id,
            reason: decision[:reason] || "Rejected by administrator"
          }
        }
      end

      executor_context = security_context.with_execution_mode(:executor)
      gov_executor = HeuristicSyndicate::Governance::Executor.new(
        registry: action_registry,
        approval_manager: approval_manager,
        audit_chain: audit_chain,
        credential_resolver: credential_resolver_ref
      )
      outcome = gov_executor.execute!(plan: plan_obj, security_context: executor_context)
      audit_chain.create_anchor!(tenant: security_context.tenant_id, run_id: plan_obj.run_id)
      { execution_result: outcome }
    end
  end

  # --- 5. Governed Incident Pipeline (ADR §4.4 & §5) ---

  class IncidentPipeline < HeuristicSyndicate::Pipeline
    node :kasm, KasmAgent, max_visits: 2
    node :postgres, PostgresAgent, max_visits: 2
    node :gitlab, GitlabAgent, max_visits: 2
    node :vsphere, VsphereAgent, max_visits: 2

    node :timeline, TimelineBuilder, max_visits: 2
    node :correlation, CorrelationAgent, max_visits: 2
    node :evidence_check, EvidenceValidationComponent, max_visits: 2

    node :planner, PlannerAgent
    node :plan_compiler, PlanCompilerComponent

    node :approval, HeuristicSyndicate::Interrupt, type: :approval

    node :executor, IncidentExecutorComponent
    node :report, ReportAgent

    connect "kasm.kasm_analysis", "timeline.kasm"
    connect "postgres.postgres_analysis", "timeline.postgres"
    connect "gitlab.gitlab_analysis", "timeline.gitlab"
    connect "vsphere.vsphere_analysis", "timeline.vsphere"

    connect "timeline.timeline", "correlation.events"
    connect "correlation.correlation_findings", "evidence_check.findings"
    connect "timeline.known_evidence_refs", "evidence_check.known_evidence_refs"

    # Loop back to Postgres specialist analysis if correlation requests more data (up to max_visits: 2)
    connect "evidence_check.needs_more_data", "postgres.reanalyze",
            condition: ->(out) { out[:needs_more_data] == true }

    connect "evidence_check.validated_findings", "planner.findings",
            condition: ->(out) { out[:needs_more_data] == false }

    connect "planner.raw_plan", "plan_compiler.raw_plan"
    connect "plan_compiler.plan", "approval.resource"

    connect "plan_compiler.plan", "executor.plan"
    connect "approval.decision", "executor.decision"

    connect "executor.execution_result", "report.execution_result"

    validate!
  end
end
