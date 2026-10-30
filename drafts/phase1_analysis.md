# Phase 1: Analysis for `heuristic_syndicate`

## 1. Repository inventory

| File | Purpose | Abstractions it implies | Gaps |
|---|---|---|---|
| `README.md` | Project manifesto: orchestration, cross-system correlation, human approval (HITL), governance/audit | none (principles only) | No code, no gem layout |
| `use_case_werkbank.md` | German business use case: 7-step incident workflow across KASM, PostgreSQL, GitLab and vSphere | Parallel analysis → correlation → plan → approval → execute → report | No technical spec |
| `hybrid_rag.md` *(untracked)* | Two earlier LLM answers: (1) hybrid RAG using RubyLLM, MongoDB `$rankFusion` and Docling; (2) a German architecture for the Werkbank agent | `HybridRetriever`, `SearchKnowledgeBase` tool, schema-typed output, `SpecialistAgent`, `TimelineBuilder`, `PlanSchema` + allowlist, plan digest, `Approvals`, `Executor` with handlers (precondition → dry-run → apply → verify → rollback), hash-chained `AuditLog` | Snippets assume a RubyLLM 1.x API, use ad-hoc Mongo collections, have no shared base classes or tests, and are untested ("I haven't run the code") |
| `LICENSE` | MIT | — | — |

**There is no Ruby code yet.** The existing abstractions are design snippets. Their strongest idea is the **governance split**: LLM agents only read, and a deterministic, approved `Executor` performs every write.

## 2. Verified versions (RubyGems/PyPI, 2026-10-30)

| Component | Latest | Local machine |
|---|---|---|
| Ruby | 4.0.x (web search, not verified by me) | **3.4.5** |
| Rails | 8.1.4 | not checked |
| ruby_llm | **2.1.1** (requires Ruby ≥ 3.2) | 2.1.0 installed |
| ruby_llm-mcp | 1.0.1 | — |
| mongo (driver) | 2.26.0 | — |
| async | 2.46.0 | — |
| activeagent | 1.9.6 (competing Rails agent framework) | — |
| haystack-ai | 3.4.1 | — |

## 3. What RubyLLM 2.1 already provides (read from the installed gem source)

This is the most important finding. Large parts of the original prompt are **already in ruby_llm**, so the framework must build on them, not duplicate them.

| Prompt requirement | Already in ruby_llm 2.1? | Where |
|---|---|---|
| Declarative agent class | ✅ `RubyLLM::Agent` with `model`, `instructions`, `tools`, `schema`, `inputs`, `fallbacks`, `rescue_from`, `thinking`, `caching`, `compaction`, `mcp`, `chat_model` | `agent.rb` |
| Prompt templates by convention | ✅ ERB at `app/prompts/<agent_name>/instructions.txt.erb`, with an engine-root lookup chain (`RubyLLM::Prompt.roots`) | `prompt.rb` |
| Tool interface + schema generation | ✅ `RubyLLM::Tool` with `description`, `parameter(s)`, and parameters inferred from `execute` keywords | `tool.rb` |
| Human approval for a single tool call | ✅ `requires_approval { resolver }`; the chat pauses and exposes `awaiting_approval?`, `pending_approvals`, `approve`, `deny`, `complete` | `tool.rb`, `chat.rb` |
| Running tool calls in parallel | ✅ `tool_options concurrency: :threads \| :fibers` | `chat/tool_concurrency.rb` |
| Retries / model fallback | ✅ `fallbacks`, `with_fallbacks(on:)`, `before_fallback`/`after_fallback` | `fallback.rb` |
| Lifecycle hooks | ✅ `before_request`, `before_message`, `after_message`, `before_tool_call`, `after_tool_result` | `chat.rb` |
| Tracing | ✅ `RubyLLM.instrument` events (`chat`, `request`, `tool_call`, `embedding`, `rerank`, `workflow`, `workflow_step` …), subscriber chain (`Support::Instrumentation.subscribe`), OpenTelemetry integration | `support/instrumentation.rb`, `open_telemetry.rb` |
| Workflow | ⚠️ `RubyLLM.workflow { |w| w.step(...) }` only labels events for tracing. It has **no graph, branching, joins, persistence or resume** | `workflow.rb` (91 lines) |
| Persistence | ⚠️ ActiveRecord only (`acts_as_chat`, `acts_as_message`, `acts_as_tool_call`). `Message#to_h` round-trips, so non-AR persistence is possible but must be built | `active_record/`, `message.rb` |
| Embeddings / rerank | ✅ `RubyLLM.embed`, `RubyLLM.rerank` | — |
| Evaluation | ✅ `RubyLLM::Evaluation` with Minitest and RSpec integrations, plus a judge | `evaluation/` |
| Fake LLM provider for tests | ❌ none found | — |

## 4. Gaps that `heuristic_syndicate` should fill

1. **Graph orchestration (Haystack-style `Pipeline`).** Named nodes, typed input/output connections, branching (routers), fan-out/fan-in (joiners), loops with visit limits, and nested pipelines (like Haystack's SuperComponent). Every run is wrapped in `RubyLLM.workflow`/`step`, so the existing tracing keeps working.
2. **Durable runs (checkpoints).** Save the whole pipeline run (node outputs, chat messages, pending approvals) when it pauses, then resume it from a job. ruby_llm's approval pause only works **in memory, within one chat**.
3. **Storage adapters.** A single store interface for runs, checkpoints, audit events and chats: Memory (tests), JSON file (dev), **MongoDB (first-class)**, ActiveRecord (it can reuse ruby_llm's `acts_as_chat`).
4. **Retrieval & memory.** A `DocumentStore` / `Retriever` interface (missing in ruby_llm), with Mongo hybrid search (`$vectorSearch` + `$search` + `$rankFusion`) as the reference adapter, and an in-memory cosine store for tests.
5. **Governance.** Tools marked read-only vs. writing, per-agent permission scopes, `Plan` + allowlisted `Action` handlers, `Approval` tied to the plan digest, a deterministic `Executor` (precondition, dry-run, apply, verify, rollback) and a hash-chained `AuditLog`.
6. **Node middleware.** A Rack-style stack *around pipeline nodes* (guardrails, budgets, caching, redaction, audit). LLM-call-level hooks and retries are already in ruby_llm and are reused, not rebuilt.
7. **Testing kit.** A fake provider registered with ruby_llm that returns scripted replies and tool calls, plus pipeline assertions for Minitest.
8. **Rails layer.** A Railtie, generators (`agent`, `tool`, `pipeline`, `action`), an ActiveJob resume job, and AR migrations for runs/audit.

## 5. Things the design has to work around

- **Name clashes:** `RubyLLM::Agent` and `RubyLLM::Workflow` already exist. The framework should **subclass** `RubyLLM::Agent` (adding concerns such as `Scoped`, `Delegating`, `Audited`) and call its graph **`Pipeline`**, as Haystack does.
- **Prompt path convention:** follow ruby_llm's `app/prompts/<agent>/instructions.txt.erb`, not the `app/agents/...md.erb` I suggested earlier.
- **Dependencies:** ruby_llm already pulls in Faraday, zeitwerk and schematist. "Core = ruby_llm + stdlib" therefore means *adding no new runtime gems*. Using zeitwerk (already present) for autoloading is allowed under that rule.
- **Approval scope:** ruby_llm approves individual tool calls inside one chat. Werkbank approves a **plan** across the whole pipeline. Both are supported: per-tool approval is delegated to ruby_llm, and plan approval is a pipeline interrupt.
- **Haystack 3.x specifics:** the concept mapping (Pipeline, Component, sockets, Router, Joiner, Agent, Breakpoint/Snapshot, SuperComponent, DocumentStore, Retriever) uses stable concepts. Web search summaries say Haystack 3.0 removed `ToolInvoker` (the `Agent` now owns the tool loop) and merged `AsyncPipeline` into `Pipeline`. This still needs checking against the official 3.4 docs.
