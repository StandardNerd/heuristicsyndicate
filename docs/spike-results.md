# HeuristicSyndicate 2.1 — Spike 1 & Spike 2 Results and Architectural Decisions

## 1. Alignment Analysis: `architecture_decision_record.md` & `spike1_spike2.md`

Both documents form a cohesive, production-grade specification:
- **`architecture_decision_record.md` (ADRs 001–013)** establishes the macro-architecture: composition over inheritance (`ADR-001`), at-least-once node execution with leases and fencing tokens (`ADR-002`), separation of `Pipeline Runtime` checkpoints from `Conversation Runtime` checkpoints (`ADR-003`), 4-layer capability-based security (`ADR-004`), strict `tenant_id` isolation (`ADR-005`), versioned deterministic `Action` contracts with digest-bound approvals (`ADR-006`), append-only hash-chained audit logs with external signed integrity anchors (`ADR-007`), separated memory stores (`ADR-008`), central execution budgets (`ADR-009`), explicit `StoreCapabilities` (`ADR-010`), node-scoped middleware (`ADR-011`), public observability events (`ADR-012`), and test-first verification (`ADR-013`).
- **`spike1_spike2.md`** translates the two highest-risk areas (`RubyLLMAdapter` conversation rehydration/tool interception and `NodeExecutor` crash recovery/side-effect reconciliation) into a shared contract, 24 concrete test scenarios (`LLM-01..12` and `REC-01..12`), and an integrated multi-process end-to-end recovery scenario (§5).

---

## 2. Spike 1 Findings (`RubyLLMAdapter`)

### Key Technical Findings from `ruby_llm` 2.1.0 Source Verification
1. **Step-wise Generation without Uncontrolled Tool Loops:**
   `RubyLLM::Chat#ask` automatically runs `#complete` (which loops through `#run_tools`). However, calling `chat.ask_later(input)` followed by `chat.generate` performs **exactly one model turn** and appends the assistant `RubyLLM::Message` (including any requested `tool_calls`) **without** executing tools.
2. **Schema-Only Tool Descriptors:**
   By generating a lightweight `RubyLLM::Tool` descriptor class (`HeuristicSyndicate::Tool.to_ruby_llm_descriptor`) whose `#execute` raises `SecurityError`, `RubyLLM::Chat` advertises accurate JSON schemas to the LLM provider while making accidental tool execution inside `RubyLLM` impossible. All tool execution goes through `HeuristicSyndicate::Runtime::AgentRuntime` and `RubyLLMAdapter#execute_tool_calls`.
3. **Critical Rehydration Subtlety (`tool_calls` Key Types):**
   In `RubyLLM::Chat#pending_tool_calls(response)`, `RubyLLM` computes:
   ```ruby
   answered = messages.filter_map { |message| message.tool_call_id if message.tool_result? }
   response.tool_calls.except(*answered)
   ```
   When transcripts are serialized to JSON and parsed back with `symbolize_names: true`, the outer keys of `response.tool_calls` become `Symbol`s (`:"call_123"`) while `message.tool_call_id` remains a `String` (`"call_123"`), causing `except(*answered)` to fail to match answered tool calls. `RubyLLMAdapter#rehydrate_messages` explicitly normalizes outer `tool_calls` keys to `String`s, making cross-process conversation restoration 100% reliable.
4. **Custom Offline `FakeProvider`:**
   `RubyLLM::Provider` calls `#preprocess_messages` before `#complete`. Overriding both `#preprocess_messages` and `#complete` on `HeuristicSyndicate::Testing::FakeProvider` (with `local? = true` and `assume_models_exist? = true`) enables full offline testing through `RubyLLM::Chat` without network calls or API keys.

### Spike 1 Test Matrix Results (`test/spike_1_adapter_test.rb`)

| ID | Scenario | Status |
|---|---|---|
| `LLM-01` | Create conversation & return normalized ID | Passed |
| `LLM-02` | Simple model call & normalized `StepResult` with token accounting | Passed |
| `LLM-03` | Structured tool call extraction without auto-execution | Passed |
| `LLM-04` | Controlled tool execution & result correlation | Passed |
| `LLM-05` | Multiple concurrent tool calls in one round | Passed |
| `LLM-06` | `ConversationCheckpoint` after model response | Passed |
| `LLM-07` | `ConversationCheckpoint` with open pending tool call | Passed (via `Process.fork`) |
| `LLM-08` | Restore conversation in a brand-new OS process and continue | Passed (via `Process.fork`) |
| `LLM-09` | Reject incompatible adapter checkpoint (`AdapterCompatibilityError`) | Passed |
| `LLM-10` | Provider error normalization (`ProviderError < TransientError`) | Passed |
| `LLM-11` | Tool-level human approval pause & resume | Passed |
| `LLM-12` | Reject revoked tool permissions when tool registry changes on restore | Passed |

---

## 3. Spike 2 Findings (Crash Recovery & Side-Effect Reconciliation)

### Key Technical Findings
1. **Lease + Monotonic Fencing Token Enforcement:**
   Every `claim_node_execution` increments `lease.fencing_token` atomically. Every subsequent `transition_node_execution!` verifies `fencing_token == current.fencing_token`, raising `LeaseLostError` if a slow/zombie worker attempts to write after its lease expired and another worker claimed the node (`REC-09`).
2. **Pre-Recording Side-Effect Intent (`side_effect_recorded`):**
   Before invoking an external `Action`, `NodeExecutor` transitions the `NodeExecution` with `side_effect_recorded: true`. If the worker process dies (`exit!(137)` / `SIGKILL`) after the external side effect succeeds but before the result is committed (`REC-05`), the recovery worker sees `attempt > 1 && side_effect_recorded == true` and dispatches according to `action_class.recovery_strategy`:
   - `:reconcile` -> calls `action.reconcile(context, params, idempotency_key:)` to reconstruct the outcome without re-executing `#apply`.
   - `:idempotent` -> safely re-invokes `action.apply` with the deterministic `idempotency_key`.
   - `:manual_review` / `:non_retryable` -> transitions the node to `:uncertain_outcome` instead of blind retry.
3. **Transactional Outbox:**
   `transition_node_execution!` atomically records `outbox_event` entries keyed by `deduplication_key` (`node_succeeded:<node_execution_id>`), ensuring crashes between DB commit and downstream scheduling (`REC-06`) are recovered without duplicate dispatch.

### Spike 2 Test Matrix Results (`test/spike_2_recovery_test.rb` & `test/end_to_end_recovery_test.rb`)

| ID | Scenario | Status |
|---|---|---|
| `REC-01` | Crash before claim | Passed |
| `REC-02` | Crash after claim, before start (lease expiry + reclaim) | Passed |
| `REC-03` | Crash during execution | Passed |
| `REC-04` | Crash before external side effect | Passed |
| `REC-05` | Real OS subprocess crash (`Process.fork` + `exit!(137)`) after side effect, before commit -> `reconcile` & `:uncertain_outcome` | Passed |
| `REC-06` | Crash after commit, before outbox publish | Passed |
| `REC-07` | Crash after success, before scheduler continuation | Passed |
| `REC-08` | 8 concurrent worker threads claiming simultaneously (1 winner) | Passed |
| `REC-09` | Expired lease + new worker -> stale fencing token rejected (`LeaseLostError`) | Passed |
| `REC-10` | Repeated pipeline resume is idempotent | Passed |
| `REC-11` | Divergent input digest with same idempotency key raises `IdempotencyConflict` | Passed |
| `REC-12` | Cross-tenant access blocked (`TenantAccessDeniedError`) | Passed |
| `E2E (§5)` | Full multi-process crash recovery of Conversation + Tool Call + NodeExecution + Reconciliation | Passed |

---

## 4. Definitive Answers to the 6 Architectural Questions (§10 of `spike1_spike2.md`)

1. **LLM-Adapter API:** `HeuristicSyndicate::LLM::Adapter` is finalized with `create_conversation`, `execute`, `execute_next_step`, `pending_tool_calls`, `execute_tool_calls`, `record_tool_result`, `waiting?`, `complete?`, `checkpoint`, and `restore`.
2. **Conversation Persistence:** `HeuristicSyndicate` controls its own `ConversationStore` + `ConversationCheckpoint` (JSON-safe schema v1) rather than relying on `RubyLLM`'s ActiveRecord-coupled `acts_as_chat`, keeping Plain Ruby, FileStore, and MongoDB first-class.
3. **Tool Execution Boundary:** **Exclusively** `HeuristicSyndicate::Runtime` executes local tools and actions. `RubyLLM` is given schema-only descriptors whose `#execute` raises `SecurityError` if ever called directly.
4. **Recovery State Machine:** `NodeExecution::VALID_TRANSITIONS` is strictly enforced on every store write, with explicit `:uncertain_outcome` and `:interrupted` states when side effects cannot be automatically reconciled.
5. **Action Idempotency Contract:** Every `HeuristicSyndicate::Action` declares `version`, `risk`, `requires_capability`, and `recovery_strategy` (`:idempotent`, `:reconcile`, `:manual_review`, or `:non_retryable`), plus deterministic `idempotency_key`.
6. **Storage Guarantees:** Stores declare `StoreCapabilities` (`ADR-010`). `Adapters::Mongo::Store` uses atomic `find_one_and_update` with `$inc` fencing tokens and composite `{ tenant_id: 1, ... }` unique indexes; `Store::FileStore` provides `flock`-backed multi-process durability for local/CLI workflows; `Store::Memory` provides fast Mutex-synchronized atomic semantics for unit tests.
