I'll check the current state of the Ruby ecosystem first, since these gems move fast.

# Hybrid RAG agent in Ruby (Pydantic AI + MongoDB + Docling equivalent)

I haven't run the code below. Treat it as a starting skeleton and check gem versions and MongoDB/Docling option names against the docs.

## Stack mapping

| Python stack | Ruby equivalent | Notes |
|---|---|---|
| Pydantic AI (agent, tools, typed output, deps) | **RubyLLM** + **ruby_llm-schema** | RubyLLM covers agents, tools, structured output, embeddings and streaming behind one API. |
| Pydantic models | `RubyLLM::Schema` (LLM output) and `dry-struct` (internal types, optional) | |
| `RunContext[Deps]` | Constructor injection into tool instances | See the tool section below. |
| MongoDB hybrid search | `mongo` driver + `$rankFusion` over `$vectorSearch` and `$search` | |
| Docling | **docling-serve** (Python sidecar) called over HTTP | I found no official Ruby client, only Python and Rust SDKs, so a small Faraday wrapper is the way to go. |

## Architecture

```
PDF/DOCX/PPTX ──► docling-serve ──► Markdown ──► heading-aware chunks
                                                       │
                                        RubyLLM.embed ─┤
                                                       ▼
                                  MongoDB: chunks collection
                                  ├─ vectorSearch index (embedding)
                                  └─ search index (text, BM25)
                                                       ▲
User question ► RubyLLM chat + tool ► $rankFusion ─────┘
                       │
                       ▼
          Structured answer (schema: answer + citations)
```

## 1. Setup

```ruby
# Gemfile
gem "ruby_llm"
gem "ruby_llm-schema"
gem "mongo"
gem "faraday"
gem "faraday-multipart"
```

```ruby
# config/boot.rb
require "ruby_llm"
require "ruby_llm/schema"

RubyLLM.configure do |c|
  c.openai_api_key    = ENV["OPENAI_API_KEY"]     # embeddings
  c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"]  # chat
end
```

Run Docling as a service:

```bash
pip install "docling-serve[ui]"
docling-serve run --port 5001
```

## 2. Docling client

Docling Serve returns a JSON document with fields such as `md_content` and `json_content` for a single file. The endpoint path and form fields vary by version. Older docs show `/v1alpha/convert/file`. Newer clients use `/v1/convert/file`. Check your server's `/docs` page.

```ruby
class DoclingClient
  def initialize(base_url: ENV.fetch("DOCLING_URL", "http://localhost:5001"))
    @conn = Faraday.new(url: base_url) do |f|
      f.request :multipart
      f.response :json
      f.options.timeout = 300
    end
  end

  def to_markdown(path)
    file = Faraday::Multipart::FilePart.new(path, Marcel_or_mime(path))
    res  = @conn.post("/v1/convert/file", { files: file, to_formats: "md" })
    raise "Docling failed: #{res.status} #{res.body}" unless res.success?

    res.body.dig("document", "md_content")
  end

  private

  def Marcel_or_mime(path)
    { ".pdf" => "application/pdf",
      ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
      ".pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    }.fetch(File.extname(path).downcase, "application/octet-stream")
  end
end
```

Docling-serve also exposes chunking endpoints in recent versions. If yours does, use its structure-aware chunker instead of the Ruby one below.

## 3. Chunking

This splits on Markdown headings and keeps the heading path as metadata:

```ruby
module Chunker
  def self.call(markdown, max_chars: 1500, overlap: 200)
    chunks = []
    path   = []

    markdown.split(/^(?=#+\s)/).each do |section|
      if (m = section.match(/\A(#+)\s+(.+)$/))
        level = m[1].size
        path  = path.first(level - 1) + [m[2].strip]
      end

      split_long(section.strip, max_chars, overlap).each do |text|
        chunks << { text: text, headings: path.dup } unless text.empty?
      end
    end
    chunks
  end

  def self.split_long(text, max, overlap)
    return [text] if text.length <= max

    out, i = [], 0
    while i < text.length
      out << text[i, max]
      i += max - overlap
    end
    out
  end
end
```

## 4. Store and ingest

```ruby
EMBED_MODEL = "text-embedding-3-small" # 1536 dims

class ChunkStore
  def initialize(collection)
    @col = collection
  end

  def ingest(path, docling: DoclingClient.new)
    md     = docling.to_markdown(path)
    chunks = Chunker.call(md)
    texts  = chunks.map { |c| c[:text] }

    vectors = texts.each_slice(64).flat_map do |batch|
      RubyLLM.embed(batch, model: EMBED_MODEL).vectors
    end

    docs = chunks.zip(vectors).each_with_index.map do |(c, v), i|
      { source: File.basename(path), position: i, text: c[:text],
        headings: c[:headings], embedding: v }
    end
    @col.insert_many(docs)
  end
end

client = Mongo::Client.new(ENV.fetch("MONGODB_URI"), database: "rag")
store  = ChunkStore.new(client[:chunks])
```

## 5. Search indexes

Hybrid search needs two indexes on the same collection. Create them in Atlas, with `mongosh`, or with the driver's search-index helpers if your driver version supports `vectorSearch`-type indexes.

```js
// Vector index
db.chunks.createSearchIndex("vector_index", "vectorSearch", {
  fields: [
    { type: "vector", path: "embedding", numDimensions: 1536, similarity: "cosine" },
    { type: "filter", path: "source" }
  ]
})

// Lexical index
db.chunks.createSearchIndex("text_index", "search", {
  mappings: { dynamic: false, fields: {
    text:     { type: "string" },
    headings: { type: "string" }
  }}
})
```

## 6. Hybrid retriever with `$rankFusion`

`$rankFusion` requires MongoDB 8.0 or later; the score-based `$scoreFusion` needs 8.2 or later. All sub-pipelines must run against the same collection, so cross-collection hybrid search needs `$unionWith` instead.

```ruby
class HybridRetriever
  def initialize(collection, embed_model: EMBED_MODEL)
    @col = collection
    @embed_model = embed_model
  end

  def search(query, limit: 5, source: nil, vector_weight: 1.0, text_weight: 1.0)
    qvec = RubyLLM.embed(query, model: @embed_model).vectors

    vector_stage = {
      "$vectorSearch" => {
        index: "vector_index", path: "embedding", queryVector: qvec,
        numCandidates: 200, limit: 20
      }
    }
    vector_stage["$vectorSearch"][:filter] = { source: source } if source

    pipeline = [
      { "$rankFusion" => {
          input: { pipelines: {
            vector: [vector_stage],
            text: [
              { "$search" => { index: "text_index",
                               text: { query: query, path: "text" } } },
              { "$limit" => 20 }
            ]
          }},
          combination: { weights: { vector: vector_weight, text: text_weight } }
      }},
      { "$limit" => limit },
      { "$project" => { text: 1, source: 1, headings: 1, position: 1 } }
    ]

    @col.aggregate(pipeline).to_a
  end
end
```

## 7. Tool with injected dependencies

Pydantic AI passes dependencies through `RunContext`. In Ruby, inject them through the tool's constructor.

```ruby
class SearchKnowledgeBase < RubyLLM::Tool
  description "Hybrid (semantic + keyword) search over ingested documents. " \
              "Use for any question that needs facts from the corpus."
  param :query, desc: "Natural-language search query"
  param :limit, type: :integer, desc: "Max chunks to return (default 5)", required: false

  def initialize(retriever)
    super()
    @retriever = retriever
  end

  def execute(query:, limit: 5)
    hits = @retriever.search(query, limit: limit)
    return "No results." if hits.empty?

    hits.map do |h|
      "[#{h['_id']}] (#{h['source']} › #{Array(h['headings']).join(' › ')})\n#{h['text']}"
    end.join("\n\n---\n\n")
  end
end
```

## 8. Agent with typed output

```ruby
class AnswerSchema < RubyLLM::Schema
  string :answer, description: "Answer grounded only in retrieved context"
  array :citations, description: "Chunks that support the answer" do
    object do
      string :chunk_id
      string :source
    end
  end
  boolean :answerable, description: "False if the context did not contain the answer"
end

class RagAgent
  INSTRUCTIONS = <<~TXT
    You answer questions using the search_knowledge_base tool.
    Search before answering. Refine the query and search again if results are weak.
    Never use facts that did not come from tool results. Cite chunk ids.
    If the context is insufficient, set answerable=false.
  TXT

  def initialize(retriever:, model: "claude-sonnet-4-5")
    @retriever = retriever
    @model = model
  end

  def ask(question, retries: 2)
    chat = RubyLLM.chat(model: @model)
                  .with_instructions(INSTRUCTIONS)
                  .with_tool(SearchKnowledgeBase.new(@retriever))
                  .with_schema(AnswerSchema)

    result = chat.ask(question).content
    validate!(result)
  rescue ArgumentError, JSON::ParserError
    retry if (retries -= 1) >= 0
    raise
  end

  private

  def validate!(h)
    raise ArgumentError, "missing keys" unless h.is_a?(Hash) && h.key?("answer") && h.key?("citations")
    h
  end
end

agent = RagAgent.new(retriever: HybridRetriever.new(client[:chunks]))
pp agent.ask("What does the 2024 report say about churn drivers?")
```

Two things to check here. First, not every provider supports tools and a response schema in the same call. If yours doesn't, run the tool loop first, then make a second schema-only call that formats the answer. Second, the model name is a placeholder, so use whatever your RubyLLM model registry lists.

## 9. Production tips

- **Run ingestion as a background job.** Docling conversion is slow, so use Sidekiq or Active Job rather than the request cycle.
- **Tune hybrid weights per query type.** Raise `text_weight` for identifiers, error codes and part numbers. Raise `vector_weight` for conceptual questions.
- **Add reranking if precision matters.** Fetch 20 to 30 candidates, rerank with a hosted reranker, then pass the top 5 to the LLM.
- **Add tracing.** The ecosystem has an OpenTelemetry instrumentation gem for RubyLLM (`opentelemetry-instrumentation-ruby_llm`), which fills the role of Logfire in the Pydantic AI world.
- **Test with a stub retriever.** Because the retriever is injected, you can pass a fake object returning canned hits and assert on the agent's structured output.
- **Evaluate separately.** Build a small gold set of questions with expected chunk ids and measure recall@k for retrieval before you tune prompts.

## Alternatives

If you're in Rails, `acts_as_chat` from RubyLLM persists conversations in ActiveRecord. Active Agent is a separate Rails-oriented framework that treats agents like controllers with ERB prompt templates. For the data layer, Mongoid works, but you'll still use raw `aggregate` for `$rankFusion`.

---


# AI Sysadmin Agent mit RubyLLM, MongoDB und optional Haystack

Die Rollen sind klar verteilt, aber ein Punkt ist wichtiger als jede Komponente: **Die LLM-gestützte Analyse bekommt nur Lesezugriff. Schreibende Änderungen führt ausschließlich ein deterministischer, freigegebener Executor aus, nie das LLM selbst.** Die Architektur dreht sich darum.

Konkrete API-Details zu KASM, vSphere und den Gem-Signaturen habe ich nicht gegen die aktuellen Docs geprüft. Der Code ist ein Gerüst.

## 1. Rollenverteilung

| Komponente | Rolle im Use Case |
|---|---|
| **RubyLLM** | Orchestrierung: Spezialisten-Agenten pro System, Korrelations- und Planungs-Agent, Tools, strukturierte Ausgaben (Findings, Root Cause, Plan, Report) |
| **MongoDB** | Incident-Zustand, Findings, Pläne, Freigaben, **Audit-Log**. Außerdem die Wissensbasis (Runbooks, frühere Incidents) mit Hybrid-Suche (`$rankFusion`) |
| **Deterministischer Ruby-Code** | Zeitleisten-Aufbau, Executor, Freigabelogik, Rollback, Validierung |
| **Haystack (optional)** | Nur Ingestion der Wissensbasis (Runbooks, Hersteller-PDFs, Wikis über Docling), nicht der Agent-Kern |
| **Sidekiq / Active Job** | Trigger, parallele Läufe, Ausführung im Hintergrund |
| **Slack / Web-UI / Rails** | Freigabe-Oberfläche für den Admin |

Für diesen Use Case ist RAG nur Zubehör, denn Tool-Calling gegen Live-Systeme und Governance sind der Kern. Haystack würde ich daher erst einführen, wenn die Dokumenten-Ingestion wirklich komplex wird. Anfangs reicht der Ruby-Ingest aus meiner ersten Antwort.

## 2. Schichtenmodell

```
┌─────────────────────────────────────────────────────────────┐
│ Trigger: Alertmanager-Webhook / Admin-Meldung → Incident     │
├─────────────────────────────────────────────────────────────┤
│ ANALYSE (LLM, nur LESEN)                                     │
│  KASM-Agent │ PG-Agent │ GitLab-Agent │ vSphere-Agent        │
│        └────── Findings (Schema) ──────┘                     │
│  Zeitleiste (Ruby, deterministisch) → Korrelations-Agent     │
│  + Wissensbasis (Hybrid-Suche in MongoDB)                    │
├─────────────────────────────────────────────────────────────┤
│ PLANUNG (LLM → Plan-Schema, nur Aktionen aus Allowlist)      │
├─────────────────────────────────────────────────────────────┤
│ FREIGABE (Mensch) – bindet an Plan-Digest                    │
├─────────────────────────────────────────────────────────────┤
│ EXECUTOR (kein LLM): Precondition → Dry-Run → Apply →        │
│ Verify → ggf. Rollback                                       │
├─────────────────────────────────────────────────────────────┤
│ REPORTING (LLM aus Audit-Trail) → MongoDB + Wissensbasis     │
└─────────────────────────────────────────────────────────────┘
        Alles schreibt in den append-only Audit-Log
```

## 3. Umsetzung pro Workflow-Schritt

### Schritt 1: Trigger

Ein Webhook (z. B. Alertmanager) oder eine Admin-Meldung legt einen Incident in MongoDB an und startet einen Job.

```ruby
class IncidentsController < ApplicationController
  def create
    id = Incidents.insert_one(
      title: params[:title], source: params[:source],
      started_at: Time.parse(params[:started_at]), status: "analyzing"
    ).inserted_id
    AnalyzeIncidentJob.perform_later(id.to_s)
    head :accepted
  end
end
```

### Schritt 2: Parallele Analyse mit Spezialisten-Agenten

Jedes System bekommt einen eigenen Agenten mit **nur lesenden Tools**. Das hält Kontexte klein, Rechte minimal und Fehler isoliert.

```ruby
module Tools
  class PgBlockingLocks < RubyLLM::Tool
    description "Nur lesend: Sessions, die auf Locks warten, inkl. blockierender PIDs"

    def initialize(pg)
      super()
      @pg = pg   # Verbindung mit read-only Rolle, statement_timeout gesetzt
    end

    def execute
      @pg.exec(<<~SQL).to_a.to_json
        SELECT a.pid, a.usename, left(a.query, 200) AS query,
               pg_blocking_pids(a.pid) AS blocked_by,
               now() - a.query_start AS waiting
        FROM pg_stat_activity a
        WHERE cardinality(pg_blocking_pids(a.pid)) > 0
      SQL
    end
  end
  # analog: PgConnectionStats, GitlabRecentDeployments, VsphereVmStats,
  #         KasmSessions, ...
end

class FindingsSchema < RubyLLM::Schema
  string :system
  string :health, enum: %w[ok degraded failing unknown]
  string :summary
  array :evidence do
    object do
      string :ref          # z. B. "pg:pid:4711", "gitlab:mr:123"
      string :observation
      string :timestamp
    end
  end
end

class SpecialistAgent
  def initialize(system:, instructions:, tools:, model: "claude-sonnet-4-5")
    @system, @instructions, @tools, @model = system, instructions, tools, model
  end

  def investigate(incident)
    RubyLLM.chat(model: @model)
           .with_instructions(@instructions + UNTRUSTED_DATA_RULE)
           .with_tools(*@tools)
           .with_schema(FindingsSchema)
           .ask("Incident: #{incident['title']} (seit #{incident['started_at']}). " \
                "Untersuche ausschließlich #{@system}.")
           .content
  end
end
```

Parallel laufen die Agenten mit dem `async`-Gem, das RubyLLM fiberbasiert unterstützt, oder mit Threads:

```ruby
findings = Sync do
  specialists.map { |s| Async { s.investigate(incident) } }.map(&:wait)
end
```

Zu den Systemen: Für **PostgreSQL** reichen `pg_stat_activity`, `pg_locks`, `pg_blocking_pids` und `pg_stat_statements` mit einer Read-only-Rolle. Für **GitLab** nutzt du die REST-API für Commits, Deployments, Merge Requests und Pipelines, begrenzt auf das Zeitfenster vor dem Incident. Für **vSphere** ist die REST-API gut für Inventar und VM-Status, Performance-Metriken kommen eher über `rbvmomi2` und den Performance Manager (bitte prüfen). Für **KASM** gibt es die Developer-API mit API-Key und Secret. Bei Logs musst du klären, ob sie über die API verfügbar sind oder besser aus einer zentralen Log-Plattform kommen.

### Schritt 3: Korrelation

**Zeitleisten baust du in Ruby, nicht im LLM.** Zeitarithmetik und Sortierung sind Code-Aufgaben, und das LLM soll nur schlussfolgern.

```ruby
Event = Struct.new(:ts, :system, :kind, :summary, :ref, keyword_init: true)

timeline = TimelineBuilder.call(
  window: (incident["started_at"] - 24.hours)..Time.now,
  sources: [gitlab, vsphere_events, pg_log, kasm]
).sort_by(&:ts)
```

Der Korrelations-Agent erhält die Findings und die Zeitleiste und kann zusätzlich die Wissensbasis befragen. Dafür nutzt du `HybridRetriever` und `SearchKnowledgeBase` aus meiner ersten Antwort, ergänzt um einen Filter auf `kind: "incident"` für ähnliche frühere Vorfälle.

```ruby
class RootCauseSchema < RubyLLM::Schema
  array :hypotheses do
    object do
      string :description
      number :confidence                 # 0..1
      array(:evidence_refs) { string }   # muss auf Findings/Timeline verweisen
      array(:disconfirming_checks) { string }
    end
  end
  boolean :needs_more_data
end
```

Wichtig ist, dass jede Hypothese `evidence_refs` haben muss. Prüfe in Ruby, dass diese Refs in den Findings existieren, und verwirf Hypothesen mit erfundenen Verweisen.

### Schritt 4: Maßnahmenplan

Der Plan darf **nur Aktionen aus einer festen Allowlist** enthalten. Jede Aktion hat im Code ein Handler-Objekt mit Parameter-Validierung, Rollback und Verifikation.

```ruby
ALLOWED_ACTIONS = %w[
  pg_terminate_backend kasm_restart_workspace
  vsphere_vm_reconfigure gitlab_revert_merge_request
].freeze

class PlanSchema < RubyLLM::Schema
  string :title
  string :rationale
  array :steps do
    object do
      string :action, enum: ALLOWED_ACTIONS
      string :params_json              # wird pro Aktion in Ruby validiert
      string :risk, enum: %w[low medium high]
      string :rollback_description
      string :verification_description
    end
  end
  array(:test_strategy) { string }
end
```

Nach der Generierung validierst du jeden Step gegen das Parameter-Schema seines Handlers (z. B. mit `dry-schema`). Außerdem berechnest du einen **Digest** des kanonischen Plans:

```ruby
plan[:digest] = Digest::SHA256.hexdigest(JSON.generate(canonicalize(plan)))
Plans.insert_one(plan.merge(status: "pending_approval", incident_id: incident["_id"]))
```

### Schritt 5: Freigabe

Der Admin sieht Plan, Evidenz, Risiko und Rollback in Slack oder in einer UI. Die Freigabe bindet an den Digest. Wird der Plan danach geändert, ist die Freigabe ungültig. Für `high`-Risiko empfiehlt sich das Vier-Augen-Prinzip.

```ruby
Approvals.insert_one(plan_id: plan["_id"], digest: plan["digest"],
                     approver: current_user.id, approved_at: Time.now.utc)
ExecutePlanJob.perform_later(plan["_id"].to_s)
```

### Schritt 6: Ausführung und Validierung (ohne LLM)

```ruby
class Executor
  def run(plan_id)
    plan     = Plans.find(_id: plan_id).first
    approval = Approvals.find(plan_id: plan_id, digest: plan["digest"]).first
    raise "Keine gültige Freigabe" unless approval

    done = []
    plan["steps"].each_with_index do |step, i|
      handler = Handlers.fetch(step["action"]).new(JSON.parse(step["params_json"]))
      handler.precondition!          # Zustand wie erwartet?
      handler.dry_run                # soweit möglich
      audit.append(type: "step_start", payload: { i:, action: step["action"] })
      handler.apply
      raise "Verifikation fehlgeschlagen" unless handler.verify
      done << handler
      audit.append(type: "step_ok", payload: { i: })
    end
    audit.append(type: "plan_done", payload: {})
  rescue => e
    audit.append(type: "plan_failed", payload: { error: e.message })
    done.reverse_each(&:rollback)    # automatischer Rollback
    raise
  end
end
```

Die Schreib-Credentials leben nur im Executor-Prozess, am besten aus einem Secret-Store. Die Analyse-Agenten kommen nie an sie heran.

### Schritt 7: Reporting und Audit

Der Audit-Log ist **append-only und hash-verkettet**. Das ist das Rückgrat der Nachvollziehbarkeit:

```ruby
class AuditLog
  def append(incident_id:, actor:, type:, payload:)
    prev = @col.find.sort(seq: -1).limit(1).first
    doc = { "seq" => (prev ? prev["seq"] + 1 : 1), "ts" => Time.now.utc,
            "incident_id" => incident_id, "actor" => actor, "type" => type,
            "payload" => payload, "prev_hash" => prev&.dig("hash") }
    doc["hash"] = Digest::SHA256.hexdigest(JSON.generate(doc))
    @col.insert_one(doc)   # unique Index auf "seq" gegen Race Conditions
  end
end
```

Dazu bekommt der MongoDB-User der App nur `insert` und `find` auf dieser Collection, kein `update` oder `delete`. Ein LLM erzeugt den Bericht aus dem Audit-Trail (Ursache, Maßnahmen, Ergebnis). Der Bericht wird gespeichert und in `knowledge_chunks` eingebettet. Damit lernt die Wissensbasis aus jedem gelösten Incident.

## 4. MongoDB-Collections

| Collection | Inhalt |
|---|---|
| `incidents` | Status, Zeitfenster, Trigger |
| `findings` | Ergebnisse der Spezialisten pro Incident |
| `plans` | Pläne mit Digest, Status |
| `approvals` | Freigaben (Wer, Wann, welcher Digest) |
| `audit_events` | Append-only, hash-verkettet |
| `knowledge_chunks` | Runbooks, Doku, frühere Incident-Reports mit Embeddings und Text-Index (Hybrid-Suche) |

## 5. Wo Haystack sinnvoll wird

Ein Haystack-Sidecar lohnt sich, wenn die Wissensbasis wächst, etwa durch viele PDFs von VMware, KASM und PostgreSQL, Confluence-Exporte oder gescannte Runbooks. Dann übernimmt eine Hayhooks-Pipeline (Docling, Splitten, Embedden, Schreiben nach MongoDB), und Ruby ruft nur `search` auf. Die Retriever-Schnittstelle bleibt gleich, wie ich es in meiner letzten Antwort gezeigt habe. Den Agent-Kern, die Tools und die Governance würde ich in Ruby behalten.

## 6. Sicherheit und Governance

**Prompt Injection ist hier das Hauptrisiko.** Log-Zeilen, Commit-Messages, MR-Beschreibungen und VM-Namen sind fremde Eingaben. Jemand kann dort Anweisungen hinterlegen. Gegenmaßnahmen:

- Analyse-Agenten haben **keine Schreib-Tools**. Selbst eine erfolgreiche Injection kann nichts ändern.
- Ein fester Systemprompt-Zusatz (`UNTRUSTED_DATA_RULE`) markiert Tool-Ausgaben als Daten, nicht als Anweisungen. Er ist hilfreich, ersetzt aber nicht die technischen Grenzen.
- Strukturierte Ausgaben und die Allowlist begrenzen, was ein manipulierter Plan enthalten kann.
- Der Mensch sieht den Plan **und** die Evidenz. Zeige im UI auch die Rohbelege, nicht nur die LLM-Zusammenfassung.

Weitere Punkte:

- **Least Privilege:** pro System ein eigenes Service-Konto, Read-only für die Analyse, getrennte Write-Konten nur im Executor. Auf PostgreSQL zusätzlich `statement_timeout`, `default_transaction_read_only` und begrenzte Zeilenanzahl.
- **Datenminimierung:** Logs vor dem LLM-Aufruf von Secrets, Tokens und personenbezogenen Daten bereinigen. Prüfe, ob ein On-Prem-Modell (RubyLLM unterstützt z. B. Ollama) für sensible Umgebungen nötig ist. Das hängt von eurer Datenschutz-Bewertung ab.
- **Rate Limits und Budgets:** maximale Tool-Aufrufe pro Incident, Token-Budget, Timeouts, Kill-Switch.
- **Idempotenz und Preconditions:** Jeder Handler prüft vor der Änderung den Ist-Zustand, denn zwischen Plan und Freigabe kann sich viel ändern.
- **MCP:** Es gibt MCP-Server für GitLab oder PostgreSQL, die du über `ruby_llm-mcp` anbinden könntest. Für schreibfähige Systeme würde ich eigene schmale Tools bevorzugen, weil du nur so die Rechte exakt begrenzen kannst.

## 7. Empfohlene Einführung in Phasen

1. **Nur Analyse:** Findings, Zeitleiste und Root-Cause-Vorschlag, ohne jede Schreibfähigkeit. Der Admin vergleicht mit seiner eigenen Diagnose.
2. **Pläne vorschlagen:** Der Plan wird erzeugt, der Admin führt ihn selbst aus. So kannst du die Planqualität messen.
3. **Low-Risk-Aktionen ausführen:** z. B. einen Workspace neu starten, mit Freigabe und Rollback.
4. **Proaktiv:** Monitoring-Trigger, Mustererkennung, Vorschläge vor dem Ausfall.

Baue von Anfang an eine **Replay-Evaluation**: Historische Incidents mit bekannter Ursache dienen als Testfälle, und du misst, ob der Agent die richtige Ursache findet und welche Pläne er vorschlägt.

Als Nächstes kann ich dir ein lauffähiges Grundgerüst für Phase 1 skizzieren (Rails oder reines Ruby mit Sidekiq, einem Postgres-Tool und dem Audit-Log) oder die Handler-Schnittstelle für den Executor ausarbeiten. Sag mir, womit du anfangen möchtest.