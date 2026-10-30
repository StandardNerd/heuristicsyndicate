# HeuristicSyndicate 2.1
## Architecture Decision Record (ADR)

**Titel:** Framework Design for Governed, Durable and Observable AI Agents in Ruby  
**Projekt:** `heuristic_syndicate`  
**Namespace:** `HeuristicSyndicate`  
**Status:** Architecture approved – implementation pending technical spikes  
**Version:** 2.1.0  
**Datum:** 30. Oktober 2026  
**Sprache:** Englisch für API, Code und Dokumentation; Architekturentscheidungen hier auf Deutsch  
**Technologie:** Ruby >= 3.4.5, ruby_llm ~> 2.1, MongoDB als bevorzugtes Production-Backend

---

# 1. Executive Summary

## 1.1 Zielsetzung

`heuristic_syndicate` ist ein Ruby-Framework zur Entwicklung, Orchestrierung und kontrollierten Ausführung intelligenter Agenten und Multi-Agent-Workflows.

Das Framework erweitert ruby_llm um vier zentrale Fähigkeiten:

1. **Orchestration:** Graph-basierte Workflows mit parallelen Agenten, deterministischen Components, Routing und Joins.
2. **Durable Execution:** Persistente Runs, Checkpoints, Crash Recovery, Interrupts und Resume.
3. **Governance & Security:** Capability-based Authorization, Human Approval, kontrollierte Actions und manipulationsnachweisbare Audit-Logs.
4. **Observability:** Vollständige Ausführungsnachverfolgung, Budgets, Fehlerdiagnose und reproduzierbare Tests.

Das Framework soll sowohl in Plain Ruby als auch in Rails-Anwendungen funktionieren.

## 1.2 Architekturprinzip

ruby_llm bleibt die bevorzugte LLM-Integrationsschicht.

Das Framework implementiert keine eigenen LLM-Provider, keine konkurrierende Agent-Tool-Loop und keine redundante Prompt-Engine.

Es übernimmt ausschließlich die übergeordneten Verantwortlichkeiten:

- Agent Lifecycle
- Pipeline Execution
- Durable State
- Security Enforcement
- Governance
- Observability
- Persistence Adapters

## 1.3 Strategische Positionierung

Nicht ein weiteres Multi-Agent-Framework, sondern:

**A Ruby Framework for Governed, Durable and Observable AI Workflows.**

Die entscheidende Differenzierung ist nicht die Anzahl der Agenten, sondern die zuverlässige Kontrolle über ihre Fähigkeiten, Entscheidungen, Ausführungen und Ergebnisse.

---

# 2. Architecture Decision Records

## ADR-001: Agent Definition und Agent Runtime werden getrennt

**Status:** Accepted

### Problem

Die ursprüngliche Architektur sieht vor, `HeuristicSyndicate::Agent` direkt von `RubyLLM::Agent` abzuleiten.

Damit würden Agent-Definition, Provider-Integration, Conversation State und Runtime Lifecycle unnötig eng gekoppelt.

Ein Wechsel der LLM-Bibliothek oder eine Änderung ihrer internen APIs könnte große Teile des Frameworks betreffen.

### Entscheidung

Composition statt direkter Vererbung von `RubyLLM::Agent`.

Die öffentliche Agent-DSL bleibt deklarativ und ActiveRecord-inspiriert.

Die Runtime wird separat implementiert.

```text
Agent Definition
      |
      v
Agent Runtime
      |
      v
LLM Adapter Interface
      |
      v
RubyLLM Adapter
      |
      v
RubyLLM::Agent / Chat
```

### Ziel-API

```ruby
class IncidentAgent < HeuristicSyndicate::Agent
  goal "Analyze infrastructure incidents"

  model "configured-model"

  permits :read

  tools KasmTool, PostgresTool

  outputs IncidentAnalysis

  stops_when max_turns: 8
end
```

Die Basisklasse ist eine Framework-eigene Definitionsklasse und keine RubyLLM-Agent-Subklasse.

### Runtime-Verantwortlichkeiten

`AgentRuntime`:

- Erstellt die Provider-Konversation.
- Lädt die Agent-Definition.
- Rendert Instructions und Prompts.
- Übergibt Tools und Capabilities.
- Verarbeitet Tool Calls.
- Verwaltet Conversation State.
- Meldet Ergebnisse und Unterbrechungen an die Pipeline.
- Erfasst Tokenverbrauch und Laufzeit.

### Adapter-Vertrag

```ruby
module HeuristicSyndicate
  module LLM
    class Adapter
      def create_conversation(agent:, context:); end
      def execute(conversation:, input:); end
      def resume(conversation:, decision:); end
      def serialize(conversation:); end
      def restore(state:, agent:, context:); end
    end
  end
end
```

Die tatsächlichen Signaturen werden durch ein verbindliches Adapter-Contract-Testset festgelegt.

### Konsequenzen

- RubyLLM bleibt austauschbar.
- Agent-Definitionen bleiben möglichst zustandslos.
- Conversation State kann unabhängig gespeichert werden.
- Die Framework-API hängt nicht von RubyLLM-Internals ab.
- Der RubyLLM-Adapter ist die einzige Schicht, die RubyLLM-spezifische APIs kennt.

---

## ADR-002: Pipeline Execution mit At-least-once-Semantik

**Status:** Accepted

### Problem

Die ursprüngliche Architektur definiert einen Graph-Scheduler, aber keine ausreichend präzise Semantik für Wiederholungen, Parallelität, Abstürze und externe Side Effects.

Exactly-once-Ausführung über beliebige externe Systeme ist nicht zuverlässig garantierbar.

### Entscheidung

Das Framework verwendet:

**At-least-once Execution mit Idempotency, atomarer Zustandsverwaltung und kontrollierter Wiederaufnahme.**

Eine Node darf erneut ausgeführt werden, wenn ihr Abschluss nicht zuverlässig persistiert wurde.

Externe Operationen müssen deshalb idempotent sein oder eine explizite Reconciliation-Strategie besitzen.

### NodeExecution Record

```ruby
NodeExecution
  id
  tenant_id
  run_id
  node_id
  attempt
  status
  input_digest
  output
  idempotency_key
  lease_owner
  lease_expires_at
  fencing_token
  started_at
  completed_at
  error
```

### Statusmaschine

```text
Pending
   |
   v
Claimed
   |
   v
Running
   |
   +------> Succeeded
   |
   +------> Failed
   |
   +------> RetryScheduled
   |
   +------> Interrupted
```

Zusätzliche Endzustände:

- `Skipped`
- `Cancelled`

### Scheduler-Regeln

1. Eine Node wird nur ausgeführt, wenn alle erforderlichen Inputs vorhanden sind.
2. Eine Node wird über einen atomaren Claim beansprucht.
3. Jeder Claim erhält ein Fencing Token.
4. Abgelaufene Leases können übernommen werden.
5. Ein alter Worker darf nach einem Claim-Wechsel keine Ergebnisse mehr committen.
6. Node-Output und Execution-Status werden in einer atomaren Storage-Operation gespeichert.
7. Ein Retry benötigt eine definierte Retry-Policy.
8. Side Effects dürfen nicht blind wiederholt werden.
9. Scheduler-Fortschritt wird aus persistierten Execution Records rekonstruiert.

### Fehlerbehandlung

| Fehler | Verhalten |
|---|---|
| LLM Timeout | Retry gemäß Policy |
| Provider Error | Retry oder Agent Failure |
| Tool Timeout | Retry nur bei sicherer Wiederholung |
| Prozessabsturz | Recovery anhand Execution Records |
| Doppelte Job-Zustellung | Idempotenter Claim |
| Doppelte Approval-Nachricht | Bereits angewendete Entscheidung ignorieren |
| Externer Side Effect mit unklarem Ergebnis | Reconciliation statt blindem Retry |

### Transaktionsstrategie

Die Store-Abstraktion muss folgende Operationen unterstützen:

- Atomarer Node Claim.
- Fencing Token Prüfung.
- Atomarer Commit von Output und Status.
- Atomare Run-State-Änderungen.
- Atomare Approval-Entscheidung.
- Eindeutige Idempotency Keys.

MongoDB-Transaktionen können hierfür verwendet werden, sofern die Deployment-Konfiguration sie unterstützt.

Das Core-Framework darf nicht voraussetzen, dass jeder Store dieselben Transaktionseigenschaften besitzt. Adapter müssen ihre unterstützten Guarantees explizit deklarieren.

### Zusätzliche Entscheidung

Eine Outbox wird für zuverlässige externe Benachrichtigungen und Job-Enqueueing eingeführt.

Dadurch wird verhindert, dass eine persistierte Zustandsänderung ohne zugehörige Resume-Nachricht zurückbleibt.

---

## ADR-003: Durable Execution ist unabhängig von Conversation Persistence

**Status:** Accepted

### Problem

Die ursprüngliche Architektur koppelt Pipeline Checkpoints stark an serialisierte RubyLLM-Chats.

Das erschwert Wiederherstellung, Provider-Wechsel und die Integration verschiedener Arten von Interrupts.

### Entscheidung

Zwei voneinander unabhängige Persistenz- und Zustandsmaschinen.

**Pipeline Runtime**

Verantwortlich für:

- Run Status
- Node Execution
- Scheduler State
- Graph Progress
- Inputs und Outputs
- Interrupt References
- Budget State

**Conversation Runtime**

Verantwortlich für:

- Chat Messages
- Tool Calls
- Provider State
- Conversation History
- Agent Turn State
- Pending LLM Operations

### Pipeline-Interrupt

```ruby
Interrupt.new(
  id: "interrupt_123",
  run_id: "run_123",
  type: :approval,
  resource_type: "plan",
  resource_id: "plan_123",
  status: :pending
)
```

Die Pipeline kennt keine RubyLLM-spezifischen Approval-Objekte.

### Conversation Checkpoint

```ruby
ConversationCheckpoint
  id
  tenant_id
  conversation_id
  agent_id
  adapter_name
  adapter_version
  serialized_state
  pending_operation
  created_at
```

### Resume-Prozess

```text
Suspended Run
     |
     v
Load Run Checkpoint
     |
     v
Load Interrupt
     |
     v
Validate Decision
     |
     v
Load Conversation State
     |
     v
Restore via LLM Adapter
     |
     v
Continue Pipeline
```

### Sicherheitsregel

Credentials, Provider Clients und andere injizierte Objekte werden niemals serialisiert.

Nur Dependency-Referenzen und deklarierte Konfigurationsidentitäten dürfen gespeichert werden.

Beim Resume werden Credentials und Dependencies neu aufgelöst und erneut autorisiert.

### Konsequenzen

- Interrupts funktionieren auch ohne LLM.
- Externe Webhooks und manuelle Eingaben können dieselbe Pipeline-Mechanik verwenden.
- RubyLLM kann ausgetauscht werden.
- Conversation und Run können unterschiedliche Aufbewahrungsfristen erhalten.
- Der kritische Chat-Rehydration-Pfad wird isoliert testbar.

---

## ADR-004: Capability-based Security statt einfacher Tool-Kategorien

**Status:** Accepted

### Problem

`read_only` und `writes` reichen nicht aus, um Datenzugriffe und Side Effects sicher zu kontrollieren.

Ein Read-only-Agent kann sensible Daten lesen oder exfiltrieren.

### Entscheidung

Ein Capability-System mit vier Ebenen:

1. Agent Capability Declaration
2. Tool Capability Requirements
3. Resource-level Authorization
4. Runtime Policy Enforcement

### Ziel-API

```ruby
class PostgresAgent < HeuristicSyndicate::Agent
  permits :read

  capabilities do
    allow :database_read,
      resources: [
        "production.metrics",
        "production.incidents"
      ]
  end

  tools QueryPostgres
end
```

Tool:

```ruby
class QueryPostgres < HeuristicSyndicate::Tool
  read_only

  requires_capability :database_read

  scope "postgres"
end
```

### Sicherheitsregeln

- Nicht deklarierte Tools sind standardmäßig verboten.
- Unbekannte Capability-Anforderungen werden abgelehnt.
- Capability-Prüfung erfolgt bei der Agent-Konfiguration und bei jeder Tool-Ausführung.
- Resource Authorization erfolgt unabhängig von der Agent-Entscheidung.
- Tool-Ausgaben werden als potenziell nicht vertrauenswürdig behandelt.
- Credentials werden pro Run und Execution Context aufgelöst.
- Read-only-Clients erhalten keine Schreibrechte.
- Write-Credentials sind ausschließlich im Executor-Kontext verfügbar.

### Run Security Context

```ruby
SecurityContext.new(
  tenant_id: tenant.id,
  actor_id: user.id,
  capabilities: resolved_capabilities,
  environment: :production,
  policy_version: "3"
)
```

Der Security Context ist unveränderlich.

Ein Agent darf weder zusätzliche Capabilities anfordern noch seinen eigenen Security Context verändern.

### Netzwerkgrenzen

Das Framework ergänzt:

- Tool-spezifische Egress Policies.
- Ressourcen-Allowlisting.
- SSRF-Schutz für HTTP-basierte Tools.
- Credential Redaction.
- Keine automatischen Netzwerkzugriffe durch Agenten außerhalb deklarierter Tools.

### Prompt Injection

`Untrusted` wird als Data-Classification-Mechanismus implementiert und nicht als vermeintlicher Prompt-Injection-Schutz.

Untrusted Data erhält:

- Herkunftsmetadaten.
- Vertrauensklassifikation.
- Größenbegrenzung.
- Strukturierte Darstellung.
- Evidence References.
- Validierung vor sicherheitsrelevanter Weiterverarbeitung.

Prompt-Injection-Abwehr basiert auf Capability Enforcement und deterministischer Kontrolle, nicht allein auf Prompt-Text.

---

## ADR-005: Multi-Tenancy wird ein Kernbestandteil

**Status:** Accepted

### Problem

Die ursprüngliche Architektur besitzt noch keine verbindliche Mandantenisolation.

### Entscheidung

Alle persistierten, mandantenbezogenen Objekte erhalten eine `tenant_id`.

Dies betrifft:

- Runs
- Node Executions
- Checkpoints
- Conversations
- Approvals
- Audit Events
- Documents
- Cache Entries
- Traces

### Zugriff

Nicht zulässig:

```ruby
store.runs.find(run_id)
```

Zulässig:

```ruby
store.runs.find(
  run_id,
  tenant: current_tenant
)
```

### Enforcement

Die Isolation wird auf drei Ebenen durchgesetzt:

1. Store Queries.
2. Runtime Security Context.
3. Tool- und Credential-Auflösung.

MongoDB erhält passende zusammengesetzte Indizes.

Cross-Tenant-Zugriffe müssen auch bei erratenen IDs scheitern.

### Konsequenzen

- Agent-Definitionen können global geteilt werden.
- Agent Runs bleiben tenantgebunden.
- Conversation Memory ist tenantgebunden.
- Cache Keys enthalten den Tenant-Kontext.
- Credentials dürfen niemals mandantenübergreifend wiederverwendet werden.

---

## ADR-006: Governance erhält versionierte Action Contracts

**Status:** Accepted

### Problem

Ein formal valider Plan kann trotzdem fachlich oder operativ gefährlich sein.

Ein Approval darf nicht ausschließlich an den JSON-Plan gebunden sein.

### Entscheidung

Actions werden als versionierte, deterministische Verträge implementiert.

### Action Contract

```ruby
class RestartWorkspace < HeuristicSyndicate::Action
  version "1.0.0"

  risk :medium

  idempotent true

  requires_capability :workspace_restart

  params do
    required :workspace_id, :string
  end

  def precondition(context, params)
  end

  def dry_run(context, params)
  end

  def apply(context, params)
  end

  def verify(context, params)
  end

  def rollback(context, params)
  end

  def compensate(context, params)
  end
end
```

### Lifecycle

```text
Drafted
   |
   v
Validated
   |
   v
Preconditions Checked
   |
   v
Dry Run
   |
   v
Approval Required
   |
   v
Approved
   |
   v
Preconditions Rechecked
   |
   v
Capability Check
   |
   v
Apply
   |
   v
Verify
   |
   +----> Verified
   |
   +----> Compensation
```

### Rollback und Compensation

Diese Begriffe werden explizit getrennt:

- `rollback`: Eine noch nicht endgültig abgeschlossene Änderung wird rückgängig gemacht, soweit technisch möglich.
- `compensate`: Eine neue Operation stellt einen möglichst konsistenten fachlichen Zustand her.

Ein Framework darf niemals behaupten, dass eine Aktion vollständig rückgängig gemacht wurde, wenn dies technisch nicht nachweisbar ist.

### Approval Digest

Der Approval Digest enthält:

- Kanonisierten Plan.
- Action-Namen.
- Action-Versionen.
- Vollständige Parameter.
- Zielumgebung.
- Ressourcenidentitäten.
- Policy-Version.
- Ausführungsbeschränkungen.
- Ablaufzeitpunkt.

Die Berechnung erfolgt über SHA-256 auf kanonisiertem JSON.

Jede relevante Änderung invalidiert bestehende Approvals.

### Approval Policy

```ruby
ApprovalPolicy.new(
  risk_levels: {
    low: 0,
    medium: 1,
    high: 2,
    critical: 2
  },
  require_distinct_approvers: true,
  expires_in: 3600
)
```

Approver müssen vom Host-System authentifiziert und autorisiert werden.

Die Approval-Entscheidung wird atomar und replay-sicher persistiert.

---

## ADR-007: Audit Integrity wird von Tracing getrennt

**Status:** Accepted

### Problem

Eine Hash-Chain innerhalb derselben Datenbank reicht nicht aus, um gegen einen privilegierten Datenbankangreifer Manipulationsschutz zu garantieren.

### Entscheidung

Das Audit-System wird in drei Bereiche getrennt:

1. Append-only Event Store.
2. Hash Chain.
3. Externe Integrity Anchors.

### Audit Event

```ruby
AuditEvent
  id
  tenant_id
  run_id
  sequence
  timestamp
  actor_id
  event_type
  payload_digest
  previous_hash
  event_hash
```

### Hash Chain

```text
Event 1
   |
   v
Event 2
   |
   v
Event 3
   |
   v
Event N
   |
   v
Signed Checkpoint
```

### Integrity Anchors

Regelmäßige Checkpoints werden:

- kryptografisch signiert.
- außerhalb des primären Stores abgelegt.
- gegen Überschreiben geschützt.
- unabhängig verifiziert.

Für die externe Speicherung wird ein austauschbarer Adapter vorgesehen, beispielsweise ein Object Store mit aktiviertem Object Lock.

### Rollen

- Application Writer: neue Events hinzufügen.
- Auditor: Events lesen und verifizieren.
- Administrator: Storage verwalten, aber nicht unbemerkt bestehende Audit Records ändern.

### Audit und Trace

Audit Logs und Debug Traces bleiben vollständig getrennt.

Traces dürfen gesampelt und nach Retention gelöscht werden.

Audit Events dürfen nicht stillschweigend verändert oder gelöscht werden.

---

## ADR-008: Drei getrennte Memory-Systeme

**Status:** Accepted

### Problem

Working Memory, Conversation Memory und Knowledge Memory besitzen unterschiedliche Lebenszyklen und Anforderungen.

### Entscheidung

```text
Memory
  |
  +-- RunStateStore
  |
  +-- ConversationStore
  |
  +-- KnowledgeStore
```

### RunStateStore

- Kurzlebiger Run-Kontext.
- Blackboard State.
- Node Outputs.
- Checkpoint Data.
- Budget State.

### ConversationStore

- Nachrichten.
- Tool Calls.
- Conversation IDs.
- Agent History.
- Compaction.

### KnowledgeStore

- Dokumente.
- Metadaten.
- Embeddings.
- Retrieval.
- Versionierung.
- Dokumentenherkunft.

### MVP

- RunStateStore: Memory und MongoDB.
- ConversationStore: RubyLLM-Integration mit eigenem Adaptervertrag.
- KnowledgeStore: zunächst einfache DocumentStore-Schnittstelle.
- Retrieval: Keyword und Vector.
- Hybrid Search und Reranking: spätere Ausbaustufe.

### Sicherheitsanforderung

Knowledge Retrieval muss tenantbezogene Filter vor dem Retrieval erzwingen.

Ein Agent darf keine Dokumente aus anderen Mandanten erhalten.

---

## ADR-009: Zentraler Execution Budget Manager

**Status:** Accepted

### Problem

Unabhängige Parallelitätsmechanismen innerhalb von Pipeline, Agenten und Tools können zu unkontrollierter Ressourcenverwendung führen.

### Entscheidung

Ein zentraler Execution Manager steuert alle Ausführungen eines Runs.

### Execution Policy

```ruby
ExecutionPolicy.new(
  max_parallel_nodes: 4,
  max_parallel_agents: 4,
  max_parallel_tools: 8,
  max_model_requests: 4,
  max_tool_calls: 30,
  max_tokens: 50_000,
  max_cost: 5.00,
  max_total_wall_time: 300
)
```

Die Beispielwerte sind konfigurierbare Startwerte, keine universellen Produktionslimits.

### Verantwortlichkeiten

- Worker Pool.
- Concurrency Limits.
- Budget Accounting.
- Cancellation.
- Timeouts.
- Retry Scheduling.
- Fehlerpropagierung.

### Parallelität

MVP: Bounded Threads.

Spätere Adapter:

- Async/Fibers.
- Distributed Workers.

Nested Executors werden vermieden.

Agenten und Tools teilen sich den zentralen Budget Manager.

---

## ADR-010: Storage wird über explizite Guarantees definiert

**Status:** Accepted

### Problem

Eine gemeinsame Store-Schnittstelle allein garantiert nicht, dass Memory, JSON und MongoDB dieselben Konsistenz- und Wiederherstellungseigenschaften besitzen.

### Entscheidung

Jeder Store-Adapter muss seine technischen Garantien deklarieren.

### Store Capabilities

```ruby
StoreCapabilities.new(
  atomic_claims: true,
  compare_and_swap: true,
  transactions: true,
  durable_writes: true,
  tenant_scoping: true,
  append_only_audit: true
)
```

Die tatsächlichen Werte werden vom Adapter bereitgestellt und beim Start validiert.

### Adapter

| Adapter | Verwendung |
|---|---|
| Memory | Tests |
| JSON File | Entwicklung und Demos, Single Process |
| MongoDB | Bevorzugtes Production Backend |
| ActiveRecord | Rails-Integration |

### Store Interface

```text
Store
  |
  +-- Runs
  +-- NodeExecutions
  +-- Checkpoints
  +-- Conversations
  +-- Approvals
  +-- AuditEvents
  +-- Outbox
  +-- Cache
  +-- Traces
```

### Wichtige Regel

Ein Adapter darf keine stärkeren Garantien behaupten, als seine tatsächliche Implementierung bietet.

Ein Single-Process-JSON-Store darf beispielsweise nicht als verteilter Durable Store verwendet werden.

---

## ADR-011: Middleware bleibt auf Pipeline Nodes begrenzt

**Status:** Accepted

Die ursprüngliche Middleware-Idee bleibt erhalten.

Die Framework-Middleware umschließt Node-Ausführungen.

LLM-spezifische Hooks bleiben im LLM-Adapter.

### Standard Stack

```text
Instrumentation
      |
      v
Security
      |
      v
Audit
      |
      v
Budget
      |
      v
Timeout
      |
      v
Retry
      |
      v
Cache
      |
      v
Guardrail
      |
      v
Node.call
```

### Änderungen

- Security wird vor jedem Tool- und Action-Aufruf erneut durchgesetzt.
- Retry wird nicht automatisch auf nicht-idempotente Operationen angewendet.
- Cache Keys enthalten Tenant, Agent-/Node-Version, Input Digest und relevante Policy-Kontexte.
- Redaction verändert nicht stillschweigend die Audit-Evidenz.
- Guardrails sind deterministische Validierungskomponenten und keine Garantie gegen alle fehlerhaften Modellantworten.

---

## ADR-012: Öffentliche Observability statt Abhängigkeit von RubyLLM-Internals

**Status:** Accepted

### Entscheidung

Das Framework besitzt ein eigenes Event- und Trace-Modell.

RubyLLM-Instrumentierung wird über einen isolierten Adapter integriert.

Nicht öffentliche APIs wie interne Subscriber-Klassen dürfen nicht zur stabilen Framework-Grundlage werden.

### Events

```text
run.started
run.completed
run.failed
run.suspended

node.started
node.completed
node.failed
node.retried

agent.started
agent.completed

tool.called
tool.completed
tool.denied

approval.requested
approval.granted
approval.rejected

action.started
action.applied
action.verified
action.compensated
```

OpenTelemetry wird als Exportziel unterstützt.

Traces und Audit Events bleiben getrennte Datenmodelle.

---

## ADR-013: Testing ist ein Architekturbestandteil

**Status:** Accepted

Das Framework wird test-first entwickelt.

### FakeProvider

Der FakeProvider bleibt ein Bestandteil des Testing Kits.

Er muss folgende Fälle unterstützen:

- Textantworten.
- Strukturierte Antworten.
- Tool Calls.
- Mehrstufige Tool Calls.
- Provider Errors.
- Timeouts.
- Token Usage.
- Pending Approvals.
- Conversation Resume.

### Zusätzliche Tests

**Crash Recovery Tests**

- Absturz nach Node Claim.
- Absturz während der Node-Ausführung.
- Absturz nach externem Side Effect.
- Absturz nach Output-Erzeugung.
- Absturz während Approval.

**Concurrency Tests**

- Zwei Worker beanspruchen dieselbe Node.
- Abgelaufene Leases.
- Veraltete Fencing Tokens.
- Doppelte Job-Ausführung.

**Security Tests**

- Cross-Tenant Access.
- Capability Escalation.
- Unauthorized Tool Calls.
- Credential Leakage.
- SSRF.
- Prompt Injection über Tool Outputs.

**Governance Tests**

- Veralteter Plan Digest.
- Geänderte Action-Version.
- Wiederholtes Approval.
- Abgelaufene Genehmigung.
- Geänderte Ressourcenidentität.
- Fehlgeschlagene Verification.
- Compensation nach Fehler.

---

# 3. Zielarchitektur

## 3.1 Schichtenmodell

```text
┌─────────────────────────────────────────────┐
│              APPLICATION LAYER              │
│                                             │
│  Agents | Tools | Components | Pipelines    │
│  Actions | Prompts | Presenters             │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│             ORCHESTRATION LAYER             │
│                                             │
│  Pipeline Engine                            │
│  Agent Runtime                              │
│  Execution Manager                          │
│  Interrupt Manager                          │
│  Scheduler                                  │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│           GOVERNANCE & SECURITY             │
│                                             │
│  Capability Engine                          │
│  Policy Engine                              │
│  Approval Manager                           │
│  Action Executor                            │
│  Audit Engine                               │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│             STATE & PERSISTENCE             │
│                                             │
│  Run Store                                  │
│  Node Execution Store                       │
│  Checkpoint Store                           │
│  Conversation Store                         │
│  Knowledge Store                            │
│  Audit Store                                │
│  Outbox                                     │
└──────────────────────┬──────────────────────┘
                       │
┌──────────────────────▼──────────────────────┐
│                 ADAPTERS                    │
│                                             │
│  RubyLLM | MongoDB | ActiveRecord           │
│  JSON | Async | OpenTelemetry               │
└─────────────────────────────────────────────┘
```

## 3.2 Verantwortungsgrenzen

| Komponente | Darf | Darf nicht |
|---|---|---|
| Agent | Analysieren und Vorschläge machen | Eigenständig privilegierte Actions ausführen |
| Tool | Deklarierte Operationen ausführen | Eigene Berechtigungen erweitern |
| Component | Deterministisch verarbeiten | Unkontrollierte LLM-Aufrufe verstecken |
| Pipeline | Kontrollfluss steuern | Security Policies umgehen |
| Runtime | Agent-Ausführung verwalten | Governance umgehen |
| Planner | Plans erstellen | Plans selbst autorisieren |
| Approval Manager | Genehmigungen verwalten | Actions selbst ausführen |
| Executor | Genehmigte Actions ausführen | Ungeprüfte LLM-Entscheidungen akzeptieren |
| Store | Zustände persistieren | Tenant Isolation umgehen |

---

# 4. Überarbeitete Core API

## 4.1 Agent

```ruby
class KasmAgent < HeuristicSyndicate::Agent
  goal "Inspect KASM workspaces"

  model "configured-model"

  permits :read

  capabilities do
    allow :workspace_read
  end

  tools WorkspaceStatusTool, WorkspaceLogsTool

  outputs WorkspaceAnalysis

  stops_when max_turns: 6
end
```

## 4.2 Tool

```ruby
class WorkspaceStatusTool < HeuristicSyndicate::Tool
  description "Read workspace status"

  read_only

  requires_capability :workspace_read

  scope "kasm"

  inject :kasm_reader

  untrusted_output
  max_output 8_000

  def execute(workspace_id:)
    kasm_reader.status(workspace_id)
  end
end
```

## 4.3 Component

```ruby
class TimelineBuilder < HeuristicSyndicate::Component
  input :events, type: Array

  output :timeline, type: Array

  def call(events:)
    {
      timeline: events.sort_by { |event| event[:timestamp] }
    }
  end
end
```

## 4.4 Pipeline

```ruby
class IncidentPipeline < HeuristicSyndicate::Pipeline
  node :kasm, KasmAgent
  node :postgres, PostgresAgent
  node :gitlab, GitlabAgent

  node :timeline, TimelineBuilder
  node :correlation, CorrelationAgent
  node :planner, PlannerAgent

  node :approval, HeuristicSyndicate::Interrupt,
    type: :approval

  node :executor, IncidentExecutor

  connect "kasm.analysis", "timeline.kasm"
  connect "postgres.analysis", "timeline.postgres"
  connect "gitlab.analysis", "timeline.gitlab"

  connect "timeline.timeline", "correlation.events"

  connect "correlation.findings", "planner.findings"

  connect "planner.plan", "approval.resource"

  connect "approval.decision", "executor.decision"

  validate!
end
```

Die endgültige DSL wird erst nach dem Core-Scheduler-Spike festgelegt.

---

# 5. Worked Example: Governed Incident Workflow

Der ursprüngliche Werkbank-Workflow bleibt das Referenzszenario.

```text
Incident Input
      |
      v
Parallel Read-only Agents
      |
      +---- KASM
      +---- PostgreSQL
      +---- GitLab
      +---- vSphere
      |
      v
Join
      |
      v
Deterministic Timeline Builder
      |
      v
Correlation Agent
      |
      v
Evidence Validation
      |
      +---- Insufficient Evidence
      |           |
      |           v
      |      Additional Analysis
      |           |
      |           └──── Max 2 Visits
      |
      v
Planner Agent
      |
      v
Plan Schema Validation
      |
      v
Action Version Validation
      |
      v
Plan Digest
      |
      v
Approval
      |
      v
Persist + Suspend
      |
      v
Process Restart
      |
      v
Resume
      |
      v
Revalidate Approval
      |
      v
Capability Check
      |
      v
Deterministic Executor
      |
      v
Precondition / Dry Run / Apply / Verify
      |
      +----> Compensation if required
      |
      v
Audit Integrity Checkpoint
      |
      v
Report Agent
      |
      v
Completed
```

### Referenzanforderung

Der komplette Workflow muss offline mit FakeProvider und injizierten Fake Dependencies ausführbar sein.

Alle sicherheitsrelevanten Entscheidungen und Ausführungszustände müssen deterministisch testbar sein.

---

# 6. Überarbeitete Gem-Struktur

```text
heuristic_syndicate/
├── heuristic_syndicate.gemspec
├── lib/
│   ├── heuristic_syndicate.rb
│   └── heuristic_syndicate/
│       ├── version.rb
│       ├── configuration.rb
│       ├── errors.rb
│       │
│       ├── definitions/
│       │   ├── agent.rb
│       │   ├── tool.rb
│       │   ├── component.rb
│       │   ├── pipeline.rb
│       │   └── action.rb
│       │
│       ├── runtime/
│       │   ├── agent_runtime.rb
│       │   ├── llm_adapter.rb
│       │   ├── execution_manager.rb
│       │   ├── budget_manager.rb
│       │   └── dependency_resolver.rb
│       │
│       ├── pipeline/
│       │   ├── graph.rb
│       │   ├── scheduler.rb
│       │   ├── node_execution.rb
│       │   ├── router.rb
│       │   ├── joiner.rb
│       │   ├── validator.rb
│       │   ├── checkpoint.rb
│       │   └── recovery.rb
│       │
│       ├── interrupts/
│       │   ├── interrupt.rb
│       │   ├── manager.rb
│       │   └── resume.rb
│       │
│       ├── security/
│       │   ├── capability.rb
│       │   ├── policy.rb
│       │   ├── security_context.rb
│       │   ├── authorizer.rb
│       │   └── credential_resolver.rb
│       │
│       ├── governance/
│       │   ├── plan.rb
│       │   ├── digest.rb
│       │   ├── approval.rb
│       │   ├── approval_policy.rb
│       │   ├── executor.rb
│       │   └── action_registry.rb
│       │
│       ├── audit/
│       │   ├── event.rb
│       │   ├── hash_chain.rb
│       │   ├── checkpoint.rb
│       │   └── verifier.rb
│       │
│       ├── memory/
│       │   ├── run_state_store.rb
│       │   ├── conversation_store.rb
│       │   └── knowledge_store.rb
│       │
│       ├── retrieval/
│       │   ├── document.rb
│       │   ├── document_store.rb
│       │   ├── retriever.rb
│       │   └── embedder.rb
│       │
│       ├── middleware/
│       ├── presenters/
│       ├── instrumentation/
│       ├── store/
│       ├── adapters/
│       │   ├── ruby_llm/
│       │   ├── mongo/
│       │   ├── active_record/
│       │   ├── async/
│       │   └── json/
│       │
│       ├── testing/
│       │   ├── fake_provider.rb
│       │   ├── fake_dependencies.rb
│       │   ├── assertions.rb
│       │   └── recovery_harness.rb
│       │
│       └── rails/
│           ├── railtie.rb
│           ├── jobs/
│           └── generators/
│
├── examples/
│   └── werkbank/
│
├── test/
│   ├── unit/
│   ├── integration/
│   ├── security/
│   ├── concurrency/
│   └── recovery/
│
└── docs/
    ├── architecture/
    ├── decisions/
    ├── security/
    └── guides/
```

Die Ordnerstruktur ist ein Zielbild. Die Implementierung soll zunächst nur tatsächlich benötigte Komponenten enthalten.

---

# 7. Überarbeitete MVP-Roadmap

| Release | Umfang | Ergebnis |
|---|---|---|
| 0.1 | Agent, Tool, Component, RubyLLM Adapter, FakeProvider, Sequential Pipeline | Funktionierender Core |
| 0.2 | Graph Scheduler, Threads, Routing, Join, Middleware, Budget | Multi-Agent Runtime |
| 0.3 | Run Store, NodeExecution, Checkpoints, Leases, Recovery, Idempotenz | Durable Execution |
| 0.4 | Interrupts, Approval, Capabilities, Actions, Executor, Audit | Governed Execution |
| 0.5 | MongoDB, Multi-Tenancy, Conversation Store, Outbox | Production Persistence |
| 0.6 | Rails Railtie, ActiveJob, Generators, Approval UI | Rails Integration |
| 0.7 | Knowledge Store, Retrieval, Hybrid Search, Reranking, Evaluation | Knowledge Layer |
| 0.8 | Async, Distributed Execution, MCP Governance, Replay | Advanced Operations |

## Priorisierung

P0: 0.1 bis 0.4.

P1: 0.5 und 0.6.

P2: 0.7 und 0.8.

Es wird keine Retrieval- oder UI-Komplexität in den MVP aufgenommen, bevor die Durable Runtime stabil ist.

---

# 8. Verbindliche Definition of Done für Version 0.4

Version 0.4 ist erst abgeschlossen, wenn folgende Anforderungen erfüllt sind.

## Runtime

- [ ] Agent-Definition und Runtime sind getrennt.
- [ ] Agenten können als Pipeline Nodes ausgeführt werden.
- [ ] Parallele Nodes werden begrenzt ausgeführt.
- [ ] Routing und Joins funktionieren deterministisch.
- [ ] Budgets werden zentral durchgesetzt.
- [ ] Cancellation wird unterstützt.

## Durable Execution

- [ ] Runs können persistiert werden.
- [ ] Node Executions haben eigene Zustände.
- [ ] Doppelte Worker Claims werden verhindert.
- [ ] Fencing Tokens verhindern veraltete Commits.
- [ ] Prozessabstürze können erkannt und behandelt werden.
- [ ] Wiederaufnahme erfolgt anhand persistierter Zustände.
- [ ] Externe Side Effects besitzen Idempotenz- oder Reconciliation-Strategien.

## Security

- [ ] Tools müssen explizit deklariert werden.
- [ ] Capability Enforcement funktioniert zur Laufzeit.
- [ ] Read-only und Write Credentials sind getrennt.
- [ ] Credentials werden niemals persistiert.
- [ ] Tenant-Kontext ist unveränderlich.
- [ ] Cross-Tenant-Zugriffe werden abgelehnt.
- [ ] Untrusted Tool Outputs werden gekennzeichnet und validiert.

## Governance

- [ ] Action Contracts sind versioniert.
- [ ] Plans werden gegen die Action Registry validiert.
- [ ] Approval Digests berücksichtigen Action-Versionen.
- [ ] Approvals sind zeitlich begrenzt.
- [ ] Doppelte Approvals sind idempotent.
- [ ] Preconditions werden unmittelbar vor der Ausführung geprüft.
- [ ] Executor benötigt gültige Berechtigungen.
- [ ] Verification ist Bestandteil des Action Lifecycle.
- [ ] Compensation wird bei geeigneten Fehlern unterstützt.

## Audit

- [ ] Audit Events sind append-only.
- [ ] Hash-Chain ist verifizierbar.
- [ ] Sequenznummern sind eindeutig.
- [ ] Integrity Checkpoints können extern gespeichert werden.
- [ ] Audit und Tracing sind getrennt.

## Testing

- [ ] FakeProvider funktioniert ohne Netzwerk.
- [ ] Crash-Recovery-Tests bestehen.
- [ ] Concurrency-Tests bestehen.
- [ ] Security-Tests bestehen.
- [ ] Approval- und Replay-Tests bestehen.
- [ ] Der komplette Werkbank-Workflow funktioniert offline.

---

# 9. Technische Spikes vor dem Coding

Diese Fragen sind noch keine Architekturentscheidungen, sondern konkrete Verifikationsaufgaben.

## Spike 1: RubyLLM Adapter

Zu untersuchen:

- Agent-Instanziierung.
- Chat-Erstellung.
- Tool Registration.
- Tool Approval.
- Pending Tool Calls.
- Conversation Serialization.
- Conversation Rehydration.
- Provider Error Handling.

Ergebnis: Funktionsfähiger Prototyp und Adapter Contract Tests.

## Spike 2: Crash Recovery

Prototyp mit zwei parallelen Nodes.

Gezielt simulieren:

- Worker-Absturz nach Claim.
- Worker-Absturz während Tool-Ausführung.
- Absturz nach externem Side Effect.
- Absturz nach Output-Erzeugung.
- Doppelte Resume-Nachricht.

Ergebnis: Nachweisbare Recovery-Semantik.

## Spike 3: MongoDB Consistency

Verifizieren:

- Atomare Claims.
- Compare-and-Swap.
- Lease Expiration.
- Fencing Tokens.
- Transaktionen.
- Unique Indexes.
- Tenant Scoping.
- Outbox.

Ergebnis: Dokumentierte Store Guarantees.

## Spike 4: Capability Enforcement

Prototyp mit zwei Mandanten und drei Berechtigungsstufen.

Ergebnis: Nachweis, dass ein Agent auch bei manipulierten Tool-Aufrufen keine zusätzlichen Rechte erhält.

## Spike 5: Audit Integrity

Implementieren:

- Hash Chain.
- Signierte Checkpoints.
- Externe Ablage.
- Unabhängige Verifikation.
- Manipulationstests.

Ergebnis: Nachweisbare Manipulationserkennung.

## Spike 6: Ruby- und Rails-Kompatibilität

Verifizieren:

- Ruby >= 3.4.5.
- Ruby 4.0.x, sobald alle Abhängigkeiten kompatibel sind.
- ruby_llm ~> 2.1.
- Rails 8.1+ als optionale Integration.
- Minitest.
- Zeitwerk.

Ergebnis: CI-Matrix und dokumentierte Kompatibilitätsgrenzen.

---

# 10. Nicht-Ziele des MVP

Folgende Funktionen werden ausdrücklich nicht in den Core-MVP aufgenommen:

- Visueller Pipeline Editor.
- Dynamische Agent-Generierung.
- Beliebige Agent-zu-Agent-Delegation.
- Verteilte Node Execution.
- Automatische Kubernetes-Orchestrierung.
- Eigenes LLM Provider Framework.
- Eigene Prompt-Engine.
- Vollständiges RAG-System.
- Vollautomatische Prompt-Injection-Erkennung.
- Automatischer Rollback beliebiger externer Operationen.
- Automatische Rechteerweiterung durch Agenten.

Diese Funktionen können später über klar definierte Adapter und Erweiterungspunkte ergänzt werden.

---

# 11. Verbindliche Architekturprinzipien

Alle zukünftigen Implementierungen müssen folgende Regeln einhalten:

1. **Composition over inheritance:** Framework Runtime und LLM Provider bleiben entkoppelt.
2. **Deterministic execution:** Sicherheitsrelevante Operationen werden deterministisch ausgeführt.
3. **At-least-once with idempotency:** Wiederholungen sind Teil der Runtime-Semantik.
4. **Explicit capabilities:** Keine impliziten Berechtigungen.
5. **Least privilege:** Jeder Agent erhält nur die erforderlichen Rechte.
6. **Tenant isolation:** Mandantentrennung ist eine Sicherheitsgrenze.
7. **Separation of state:** Runs, Conversations und Knowledge haben getrennte Lebenszyklen.
8. **Durable by design:** Kritischer Fortschritt wird persistent und atomar verwaltet.
9. **Human authorization:** Kritische Aktionen benötigen explizite Genehmigung.
10. **Auditability:** Sicherheitsrelevante Entscheidungen sind nachvollziehbar.
11. **Provider independence:** RubyLLM ist ein Adapter, keine Framework-Grundlage.
12. **Testability:** Kritische Workflows funktionieren offline.
13. **No hidden side effects:** Components, Tools und Actions deklarieren ihre Wirkung.
14. **Fail closed:** Unbekannte Berechtigungen, Ressourcen und Policy-Zustände werden abgelehnt.
15. **Explicit guarantees:** Store- und Adapter-Eigenschaften werden nicht vorausgesetzt, sondern deklariert und getestet.

---

# 12. Verbleibende offene Entscheidungen

Die folgenden Punkte sind bewusst noch nicht endgültig festgelegt:

| Thema | Vorläufige Entscheidung | Verifikation |
|---|---|---|
| RubyLLM Conversation Restore | Adapter-basiert | Spike 1 |
| MongoDB Transactions | Bevorzugt | Spike 3 |
| Lease Duration | Konfigurierbar | Lasttests |
| Audit Anchor Storage | Externer Object Store | Spike 5 |
| Capability Policy DSL | Ruby DSL | Security-Prototyp |
| Approval UI | Rails-Integration ab 0.6 | UX-Konzept |
| Async Execution | Optional ab 0.8 | Benchmark |
| Action Compensation | Pro Action | Fachliche Tests |
| Agent Delegation | Nicht im MVP | Eigenes ADR |
| Retrieval | Separater Knowledge Layer | Evaluation |

---

# 13. Abschließende Entscheidung

Die ursprüngliche Phase-2-Architektur wird nicht verworfen.

Sie wird durch Phase 2.1 an den Stellen korrigiert, an denen die ursprüngliche Spezifikation noch keine ausreichend belastbaren technischen Garantien definiert.

Die grundlegenden Entscheidungen bleiben:

- Ruby und ruby_llm als technologische Basis.
- Haystack-inspirierte Pipeline-Orchestrierung.
- Plain Ruby Core mit optionaler Rails Integration.
- MongoDB als bevorzugtes Production Backend.
- Durable Human-in-the-Loop.
- Deterministische Governance.
- Persistente Lern- und Knowledge-Artefakte.
- Offline-fähiges Testing.

Die entscheidenden Änderungen sind die Entkopplung der Runtime, explizite Execution-Semantik, Capability Security, Tenant Isolation und eine belastbare Governance-Schicht.

**Freigabeempfehlung:**

Phase 2.1 wird als neue Architekturgrundlage angenommen.

Die Implementierung beginnt mit den technischen Spikes und anschließend mit Version 0.1.

Der erste vollständige Meilenstein ist nicht ein funktionsreicher Agent-Schwarm, sondern ein absturzsicherer, nachvollziehbarer und kontrolliert ausführbarer Multi-Agent-Workflow.

**Ende der Architekturentscheidung.**