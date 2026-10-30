# HeuristicSyndicate 2.1 – Spike 1 und Spike 2

Ich würde beide Spikes parallel, aber mit einem gemeinsamen Integrationsvertrag entwickeln. Spike 1 klärt, ob RubyLLM zuverlässig hinter einer eigenen Adapter-Schnittstelle betrieben und wiederhergestellt werden kann. Spike 2 prüft unabhängig davon, ob die Orchestrierung nach Abstürzen korrekt fortgesetzt werden kann – auch dann, wenn ein externer Seiteneffekt bereits stattgefunden hat, dessen Ergebnis aber noch nicht gespeichert wurde.

Das Ziel ist nicht, zwei isolierte Demos zu bauen, sondern zwei Prototypen, die anschließend zusammengeführt werden können, ohne ihre zentralen Annahmen neu zu entwerfen.

## 1. Gemeinsames Ziel und Abgrenzung

## Zwei parallele Untersuchungen

Spike 1

RubyLLM-Adapter

Provider-unabhängige Conversation-Ausführung, Tool Calls, Checkpointing und Wiederherstellung.

Spike 2

Crash Recovery

Dauerhafte Node-Ausführung, Idempotenz, Lease/Fencing, Wiederanlauf und Side-Effect-Reconciliation.

Gemeinsame Integrationsfrage

Kann ein persistierter Workflow mit einer unterbrochenen LLM-Conversation und einem möglicherweise bereits ausgeführten Tool-Aufruf sicher fortgesetzt werden?

Nicht Bestandteil der Spikes: produktionsreife Benutzeroberfläche, verteilte Multi-Worker-Infrastruktur, vollständige Agenten-Sicherheit, RAG, MCP-Integration oder ein fertiger Rails-Adapter.

Die Spikes sollen technische Risiken reduzieren und belastbare Implementierungsentscheidungen liefern – keine Produktionsreife vortäuschen.

## 2. Gemeinsame Architektur und Integrationsvertrag

Beide Spikes verwenden dieselben fachlichen Begriffe und Datenstrukturen. Die Implementierungen dürfen zunächst getrennte Test-Stores nutzen, müssen aber dieselben Schnittstellen respektieren.

```
                 HeuristicSyndicate
                         |
                +--------+--------+
                |                 |
          Pipeline Engine    Agent Runtime
                |                 |
          Node Executor      Conversation Runtime
                |                 |
          Execution Store    LLM Adapter Interface
                |                 |
          Recovery Manager   RubyLLM Adapter
                |                 |
                +--------+--------+
                         |
                 Shared Contracts
                         |
             Run / Node / Checkpoint
             Idempotency / Interrupt
             Event / Error / Result
```

### Gemeinsame Verträge

| Vertrag                  | Verantwortlichkeit                                                 |
| ------------------------ | ------------------------------------------------------------------ |
| `Run`                    | Workflow-Lebenszyklus und Gesamtstatus                             |
| `NodeExecution`          | Status, Versuch, Input-Digest und Ergebnis eines Nodes             |
| `Checkpoint`             | Persistierter Zustand einer unterbrechbaren Ausführung             |
| `ConversationCheckpoint` | Adapter-Version und serialisierter Conversation-Zustand            |
| `IdempotencyKey`         | Eindeutige Identität einer logischen Operation                     |
| `ExecutionLease`         | Zeitlich begrenztes Ausführungsrecht                               |
| `FencingToken`           | Schutz vor veralteten Workern                                      |
| `Interrupt`              | Persistierte Unterbrechung mit Referenz auf den pausierten Vorgang |
| `ExecutionEvent`         | Nachvollziehbare Zustandsänderungen                                |

Wichtig: Ein `ConversationCheckpoint` ist kein vollständiger Workflow-Checkpoint. Er beschreibt ausschließlich den Zustand der Konversation. Der Pipeline-Zustand bleibt im `RunStateStore`.

### Gemeinsame Fehlerklassen

- `TransientError`: temporärer Fehler, kontrollierter Retry möglich.
- `PermanentError`: nicht automatisch wiederholen.
- `ProviderError`: Fehler des LLM-Providers.
- `SerializationError`: Zustand kann nicht sicher gespeichert oder geladen werden.
- `LeaseLostError`: Worker besitzt keine gültige Ausführungsberechtigung mehr.
- `IdempotencyConflict`: derselbe Schlüssel wurde mit abweichenden Eingaben verwendet.
- `UncertainOutcome`: externe Operation könnte stattgefunden haben, Ergebnis ist aber unbekannt.
- `RecoveryConflict`: gespeicherter Zustand ist widersprüchlich oder nicht sicher rekonstruierbar.

Diese Fehler müssen über die Spikes hinweg dieselbe Semantik haben.

## 3. Spike 1 – RubyLLM-Adapter



Technisches Risiko: hoch

&#x20;Empfohlene Dauer: 3–4 Arbeitstage



### 3.1 Forschungsfrage

Kann HeuristicSyndicate RubyLLM so kapseln, dass:

1. die Orchestrierung keine RubyLLM-Klassen kennen muss,
2. eine Conversation nach Prozessabbruch wiederhergestellt werden kann,
3. Tool Calls einzeln kontrolliert und ausgeführt werden können,
4. Freigabe-Unterbrechungen persistierbar sind,
5. Provider- und RubyLLM-Versionen austauschbar bleiben?

Wichtige Ausgangslage: RubyLLM 2.1 bietet bereits einen schrittweise steuerbaren Agenten-Loop: `generate`, `run_tools`, `step`, `complete` und `complete?`. Die Dokumentation beschreibt auch das Fortsetzen persistierter Chats und das erneute Ausführen nicht gespeicherter Tool-Ergebnisse. Das ist eine gute Grundlage, ersetzt aber nicht den Nachweis, dass unsere eigenen Adapter- und Store-Verträge zuverlässig funktionieren.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://rubyllm.com\&sz=32)

RubyLLM+1



### 3.2 Architektur des Adapters

```
AgentRuntime
    |
ConversationRuntime
    |
LLM::Adapter
    |
    +-- create_conversation
    +-- execute
    +-- execute_next_step
    +-- pending_tool_calls
    +-- execute_tool_calls
    +-- waiting?
    +-- complete?
    +-- checkpoint
    +-- restore
    |
RubyLLMAdapter
    |
RubyLLM::Chat
    |
Provider
```

Die Adapter-Schnittstelle soll bewusst nicht die gesamte RubyLLM-API spiegeln. Sie bildet nur die Fähigkeiten ab, die HeuristicSyndicate benötigt.

### 3.3 Konkreter Interface-Entwurf

```
module HeuristicSyndicate
  module LLM
    class Adapter
      def create_conversation(config:, context:)
        raise NotImplementedError
      end

      def execute(conversation:, input:)
        raise NotImplementedError
      end

      def execute_next_step(conversation:)
        raise NotImplementedError
      end

      def pending_tool_calls(conversation:)
        raise NotImplementedError
      end

      def execute_tool_calls(conversation:)
        raise NotImplementedError
      end

      def waiting?(conversation:)
        raise NotImplementedError
      end

      def complete?(conversation:)
        raise NotImplementedError
      end

      def checkpoint(conversation:)
        raise NotImplementedError
      end

      def restore(checkpoint:, context:)
        raise NotImplementedError
      end
    end
  end
end
```

Das Interface ist ein Spike-Vertrag, noch keine endgültige öffentliche Gem-API. Insbesondere muss der Spike zeigen, ob `execute` und `execute_next_step` getrennt gebraucht werden oder ob eine einheitliche `step`-Operation genügt.

### 3.4 ConversationCheckpoint

Der Checkpoint soll keine Ruby-Objekte serialisieren. Er speichert einen versionierten, validierbaren Datenvertrag.

```
{
  schema_version: 1,
  adapter: "ruby_llm",
  adapter_version: "2.1",
  conversation_id: "conv_123",
  provider: "openai",
  model: "configured-model",
  status: "waiting_for_tool",
  transcript_ref: "conversation_store_123",
  pending_operation: {
    type: "tool_call",
    call_id: "call_456",
    tool_name: "read_inventory",
    arguments_digest: "sha256:..."
  },
  tool_registry_version: "tools-v3",
  created_at: "2026-10-31T10:00:00Z"
}
```

Nicht speichern:

- API-Schlüssel und Provider-Credentials,
- offene HTTP-Verbindungen,
- RubyLLM-Chat-Instanzen,
- Tool-Instanzen mit laufenden Ressourcen,
- Datenbankverbindungen,
- unkontrollierte Ruby-Objekt-Dumps.

Die `transcript_ref` verweist auf den dauerhaft gespeicherten Conversation-Verlauf. Der Adapter muss beim Wiederherstellen die aktuelle, autorisierte Tool-Registry erneut laden und darf keine früheren Berechtigungen implizit übernehmen.

### 3.5 Tool-Call-Behandlung

Der Adapter darf Tool-Aufrufe nicht unkontrolliert innerhalb eines großen `ask`-Aufrufs ausführen, wenn HeuristicSyndicate deren Ausführung überwachen, unterbrechen oder genehmigen muss.

RubyLLM stellt dafür die schrittweise Steuerung bereit. Ein `generate`-Schritt erzeugt die nächste Modellantwort; `run_tools` führt ausstehende Tool Calls aus; `step` wählt den jeweils nächsten Schritt.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://rubyllm.com\&sz=32)

RubyLLM+1



Für den Spike wird daher dieser Ablauf getestet:

```
1. Conversation anlegen
2. User Input persistieren
3. Modellantwort erzeugen
4. Modell fordert Tool Call an
5. Tool Call extrahieren und persistieren
6. Ausführungsberechtigung prüfen
7. Tool über HeuristicSyndicate ausführen
8. Tool-Ergebnis persistieren
9. Ergebnis der Conversation hinzufügen
10. Nächsten Modellschritt ausführen
11. Finale Antwort persistieren
```

Der kritische Punkt ist Schritt 7: Wir müssen herausfinden, ob die gewünschte Kontrolle über lokale Tools mit der RubyLLM-Tool-Ausführung sauber umgesetzt werden kann. Falls RubyLLM die Tools selbst ausführt, ist zu prüfen, wie wir unsere Capability-Prüfung, Idempotenz und Auditierung davor schalten. Der Spike soll diese Frage experimentell entscheiden.

### 3.6 Testfälle für Spike 1

| ID     | Test                             | Erwartetes Ergebnis                          |
| ------ | -------------------------------- | -------------------------------------------- |
| LLM-01 | Conversation anlegen             | Adapter liefert eigene ID                    |
| LLM-02 | Einfacher Modellaufruf           | Antwort wird normalisiert                    |
| LLM-03 | Tool Call anfordern              | Tool-Aufruf wird strukturiert erkannt        |
| LLM-04 | Tool Call ausführen              | Ergebnis wird korrekt zugeordnet             |
| LLM-05 | Mehrere Tool Calls               | Alle Aufrufe bleiben eindeutig               |
| LLM-06 | Checkpoint nach Modellantwort    | Zustand ist rekonstruierbar                  |
| LLM-07 | Checkpoint mit offenem Tool Call | Pending Call bleibt erhalten                 |
| LLM-08 | Restore in neuem Prozess         | Conversation kann weiterlaufen               |
| LLM-09 | Restore mit anderem Adapter      | Expliziter Kompatibilitätsfehler             |
| LLM-10 | Provider-Fehler                  | Einheitliche Fehlerklasse                    |
| LLM-11 | Freigabe-Unterbrechung           | Conversation bleibt pausiert                 |
| LLM-12 | Tool-Registry geändert           | Alte Tool-Berechtigung wird nicht übernommen |

Besonders wichtig: LLM-07 und LLM-08 müssen mit einem echten Prozessneustart getestet werden. Ein einfacher Ruby-Objekt-Roundtrip im selben Prozess ist kein ausreichender Nachweis.

### 3.7 Ergebnisartefakte

Am Ende von Spike 1 müssen vorliegen:

- `RubyLLMAdapter` als lauffähiger Prototyp,
- Adapter-Interface und normalisierte Ergebnistypen,
- `ConversationCheckpoint`-Schema,
- Fake-Adapter für Offline-Tests,
- reproduzierbare Testfälle mit Prozessneustart,
- dokumentierte Grenzen der RubyLLM-Persistenz,
- Entscheidung: RubyLLM-eigene ActiveRecord-Persistenz nutzen oder ConversationStore vollständig selbst kontrollieren.

Entscheidungskriterium: Wenn sich die Conversation nicht zuverlässig und ohne interne RubyLLM-Objektserialisierung wiederherstellen lässt, darf der Adapter diese Einschränkung nicht kaschieren. Dann wird die Persistenzstrategie angepasst oder der betreffende Wiederherstellungsfall als nicht unterstützt klassifiziert.

## 4. Spike 2 – Crash-Recovery-Prototyp



Architekturentscheidend

&#x20;Empfohlene Dauer: 4–5 Arbeitstage



### 4.1 Forschungsfrage

Kann ein Workflow nach einem Prozessabbruch zuverlässig weiterlaufen, ohne bereits abgeschlossene Arbeit unnötig zu wiederholen oder externe Seiteneffekte unkontrolliert doppelt auszuführen?

Das Ziel ist ausdrücklich At-least-once Execution mit Idempotenz und Reconciliation – keine Behauptung von Exactly-once Execution.

### 4.2 Testarchitektur

```
                 Recovery Test Runner
                         |
                    Run Scheduler
                         |
                   Node Executor
                         |
              +----------+----------+
              |                     |
        Execution Store       External System
              |                     |
        NodeExecution        Side Effect Simulator
              |
        Lease Manager
              |
        Recovery Manager
              |
        Event / Audit Log
```

Für den Prototyp empfehle ich MongoDB als primären Store, weil die ADR-Zielarchitektur MongoDB als bevorzugten Produktionsadapter vorsieht. Der Test muss mit einem MongoDB Replica Set laufen, damit Transaktionen tatsächlich geprüft werden können. Ein einfacher Einzelknoten ohne Transaktionsunterstützung wäre ein irreführender Test.

### 4.3 Datenmodell

NodeExecution

```
{
  id: "nodeexec_123",
  tenant_id: "tenant_a",
  run_id: "run_123",
  node_id: "deploy_application",

  status: "running",
  attempt: 2,

  input_digest: "sha256:...",
  idempotency_key: "run_123:deploy_application:v1",

  lease: {
    owner: "worker_2",
    expires_at: "2026-10-31T10:05:00Z",
    fencing_token: 42
  },

  result: nil,
  error: nil,

  started_at: "2026-10-31T10:00:00Z",
  completed_at: nil
}
```

ExecutionEvent

```
{
  id: "event_123",
  tenant_id: "tenant_a",
  run_id: "run_123",
  node_execution_id: "nodeexec_123",
  sequence: 12,

  event_type: "node_claimed",
  fencing_token: 42,

  occurred_at: "2026-10-31T10:00:00Z",
  payload: {
    worker_id: "worker_2"
  }
}
```

Die Events sind für die Rekonstruktion und Diagnose wichtig. Der maßgebliche Ausführungsstatus muss jedoch transaktional im Execution Store liegen. Ein Event-Log darf nicht als Ersatz für atomare Statusänderungen dienen.

### 4.4 Zustandsmaschine

## NodeExecution Lifecycle

PENDING

CLAIMED – Lease und Fencing Token vergeben

RUNNING – Operation wird ausgeführt

SUCCEEDED

FAILED

RETRY_SCHEDULED

INTERRUPTED

Zusätzliche Endzustände: SKIPPED und CANCELLED. Wiederanlauf erfolgt nur über explizite, geprüfte Übergänge.

Die Übergänge müssen zentral validiert werden. Ein Worker darf beispielsweise einen `SUCCEEDED`-Node nicht wieder auf `RUNNING` setzen.

### 4.5 Atomare Claim-Operation

Die wichtigste Operation ist das atomare Beanspruchen eines Nodes.

Vereinfachtes Pseudocode-Beispiel:

```
def claim(node_execution_id:, worker_id:)
  store.transaction do
    execution = store.find_for_update(node_execution_id)

    return nil unless claimable?(execution)

    token = execution.lease.fencing_token + 1

    execution.update!(
      status: :claimed,
      lease_owner: worker_id,
      lease_expires_at: clock.now + lease_duration,
      fencing_token: token
    )

    execution
  end
end
```

Das ist bewusst nur Pseudocode. Die tatsächliche MongoDB-Implementierung muss zeigen, wie atomare Compare-and-Set-Operationen, Lease-Ablauf und Token-Inkrementierung umgesetzt werden.

Fencing-Regel: Jeder schreibende Vorgang muss das aktuelle Fencing Token berücksichtigen. Ein Worker mit Token 41 darf nicht mehr schreiben, sobald Token 42 vergeben wurde.

Eine Lease allein verhindert nicht, dass ein alter Worker nach einem Netzwerkproblem weiterarbeitet. Erst die Kombination aus Lease und Fencing schützt den Zustand vor veralteten Workern.

### 4.6 Idempotenz und externe Seiteneffekte

Der schwierigste Fall:

```
Worker führt externen API-Aufruf aus
          |
          v
Externer Seiteneffekt erfolgreich
          |
          v
Worker stürzt ab
          |
          v
Ergebnis wurde nicht persistiert
```

Nach dem Neustart kann der Scheduler nicht wissen, ob die Operation erfolgreich war.

Daher benötigt jede Action eine explizite Ausführungsstrategie:

| Strategie       | Verwendung                                            |
| --------------- | ----------------------------------------------------- |
| `idempotent`    | Wiederholung mit demselben Schlüssel ist sicher       |
| `reconcile`     | Externen Zustand abfragen und Ergebnis rekonstruieren |
| `manual_review` | Ausgang nicht sicher bestimmbar; menschliche Klärung  |
| `non_retryable` | Wiederholung ohne explizite Freigabe verboten         |

Beispielvertrag:

```
class DeployAction
  def idempotency_key(context)
    "#{context.run_id}:deploy:#{context.target_id}:v1"
  end

  def precondition(context)
    # Zielzustand und Berechtigung prüfen
  end

  def apply(context, idempotency_key:)
    # Externe Operation mit Idempotenzschlüssel
  end

  def verify(context)
    # Tatsächlichen Zielzustand prüfen
  end

  def reconcile(context, idempotency_key:)
    # Ergebnis einer möglicherweise bereits ausgeführten
    # Operation rekonstruieren
  end
end
```

Die Operation darf nicht allein deshalb wiederholt werden, weil das lokale Ergebnis fehlt. Fehlt eine sichere Idempotenz- oder Reconciliation-Möglichkeit, muss der Node in einen Zustand wie `INTERRUPTED` oder `UNCERTAIN_OUTCOME` wechseln und darf nicht blind erneut ausgeführt werden.

### 4.7 Crash-Injection-Testmatrix

Dies ist das Herzstück von Spike 2.

| ID     | Absturzzeitpunkt                       | Erwartetes Verhalten                               |
| ------ | -------------------------------------- | -------------------------------------------------- |
| REC-01 | Vor Claim                              | Node bleibt ausführbar                             |
| REC-02 | Nach Claim, vor Start                  | Lease läuft ab, Node wird neu beansprucht          |
| REC-03 | Während Ausführung                     | Node wird als unterbrochen erkannt                 |
| REC-04 | Vor externem Side Effect               | Sicherer Neustart möglich                          |
| REC-05 | Nach Side Effect, vor Result-Commit    | Reconciliation statt Blind-Retry                   |
| REC-06 | Nach Result-Commit, vor Event-Publish  | Outbox liefert Event nach                          |
| REC-07 | Nach Erfolg, vor Scheduler-Fortsetzung | Folgeprozess wird genau einmal logisch fortgesetzt |
| REC-08 | Zwei Worker beanspruchen gleichzeitig  | Nur ein gültiger Claim                             |
| REC-09 | Alte Lease, neuer Worker               | Altes Fencing Token wird abgelehnt                 |
| REC-10 | Wiederholtes Resume                    | Keine unkontrollierte doppelte Ausführung          |
| REC-11 | Abweichender Input-Digest              | Idempotency Conflict                               |
| REC-12 | Tenant-ID manipuliert                  | Zugriff wird abgewiesen                            |

Die Tests sollen tatsächliche Prozessabbrüche simulieren – beispielsweise über separate Worker-Prozesse, die gezielt an definierten Crash-Punkten beendet werden. Exceptions im selben Prozess reichen für die wichtigsten Recovery-Nachweise nicht aus.

### 4.8 Outbox und zuverlässige Folgeaktionen

Ein weiterer kritischer Fehlerfall ist der Absturz zwischen Datenbank-Commit und Job-Enqueue.

Beispiel:

```
NodeExecution = SUCCEEDED
       |
       v
DB Commit erfolgreich
       |
       v
Prozess stürzt ab
       |
       v
Next Node wurde nie eingeplant
```

Deshalb muss die Zustandsänderung gemeinsam mit einem Outbox-Eintrag gespeichert werden:

```
store.transaction do
  node_execution.mark_succeeded!(result)

  outbox.insert!(
    event_type: "node_succeeded",
    aggregate_id: node_execution.id,
    deduplication_key: "node_succeeded:#{node_execution.id}"
  )
end
```

Ein separater Dispatcher publiziert die Outbox-Einträge und markiert sie als zugestellt. Die Zustellung kann mehrfach erfolgen; der Empfänger muss deshalb deduplizieren.

### 4.9 Ergebnisartefakte

- MongoDB-basierter `ExecutionStore`-Prototyp,
- `NodeExecution`- und `ExecutionEvent`-Modelle,
- atomare Claim-Operation,
- Lease- und Fencing-Implementierung,
- Idempotency-Key-Verwaltung,
- Outbox-Prototyp,
- Crash-Injection-Test-Harness,
- Recovery-Report mit allen 12 Tests,
- dokumentierte Grenzen und offene Race Conditions.

Entscheidungskriterium: Der Prototyp muss alle definierten Crash-Szenarien reproduzierbar bestehen. Ein nicht sicher rekonstruierbarer externer Seiteneffekt muss als unsicher markiert werden – nicht als Erfolg oder automatisch wiederholbarer Fehler.

## 5. Gemeinsame Integration: der entscheidende End-to-End-Test

Beide Spikes sollten nicht nur einzeln bestehen. Am Ende muss ein integrierter Test beweisen, dass eine Conversation mit Tool Call und Workflow-State gemeinsam wiederhergestellt werden kann.

### Szenario: Agent führt einen Tool Call aus

```
Run gestartet
    |
    v
Agent fragt RubyLLM
    |
    v
RubyLLM fordert Tool Call an
    |
    v
ConversationCheckpoint gespeichert
    |
    v
NodeExecution beansprucht
    |
    v
Tool führt externe Operation aus
    |
    v
Worker stürzt ab
    |
    v
Recovery Manager erkennt abgelaufene Lease
    |
    v
Neuer Worker übernimmt mit neuem Fencing Token
    |
    v
Action.reconcile()
    |
    v
Tool-Ergebnis wird persistiert
    |
    v
Conversation wird wiederhergestellt
    |
    v
RubyLLM erhält Tool-Ergebnis
    |
    v
Modell erzeugt finale Antwort
    |
    v
Run wird abgeschlossen
```

Integrationsnachweis

Der End-to-End-Test ist erfolgreich, wenn:

- die Conversation im neuen Prozess wiederhergestellt wird,
- der Tool Call eindeutig identifiziert bleibt,
- der externe Seiteneffekt nicht unkontrolliert wiederholt wird,
- das Tool-Ergebnis der richtigen Conversation zugeordnet wird,
- die alte Worker-Instanz keine gültigen Schreibrechte mehr besitzt,
- der Workflow nach dem Neustart genau einen logischen Abschluss erreicht.

Wichtig: „Genau ein logischer Abschluss“ ist nicht dasselbe wie „genau ein physischer Aufruf“. Bei einem externen System ohne Idempotenz oder Abfragemöglichkeit kann das Framework Exactly-once nicht garantieren.

## 6. Paralleler Arbeitsplan

Ich würde die beiden Spikes in einem gemeinsamen Arbeitszyklus von etwa einer Woche durchführen.

## 5-Tage-Plan

1. Tag 1 – Verträge und Testumgebung
   - Gemeinsame Datenverträge definieren
   - RubyLLM 2.1.x und FakeProvider einrichten
   - MongoDB Replica Set bereitstellen
   - Crash-Injection-Testumgebung aufbauen
2. Tag 2 – Parallelimplementierung
   - Spike 1: Adapter, Conversation, Tool Calls
   - Spike 2: NodeExecution, Store, atomarer Claim
3. Tag 3 – Persistenz und Wiederherstellung
   - Spike 1: Checkpoint, Restore, Tool-Call-Fortsetzung
   - Spike 2: Lease, Fencing, Idempotenz, Outbox
4. Tag 4 – Fehler- und Crash-Tests
   - Spike 1: Providerfehler, Toolfehler, Prozessneustart
   - Spike 2: Crash-Injection und konkurrierende Worker
5. Tag 5 – Integration und Entscheidung
   - End-to-End-Test durchführen
   - Fehler und Einschränkungen dokumentieren
   - Architekturentscheidungen für Implementierungsphase 0.1–0.3 treffen

Schätzung: ein Entwickler pro Spike plus eine gemeinsame Integrationsverantwortung. Bei nur einer Person eher 8–10 Arbeitstage.

## 7. Vorgeschlagene Projektstruktur

Die Prototypen sollten bereits der geplanten Gem-Struktur folgen, damit erfolgreiche Teile später übernommen werden können.

```
heuristic_syndicate/
├── lib/
│   └── heuristic_syndicate/
│       ├── llm/
│       │   ├── adapter.rb
│       │   ├── ruby_llm_adapter.rb
│       │   ├── conversation_runtime.rb
│       │   └── conversation_checkpoint.rb
│       │
│       ├── runtime/
│       │   ├── agent_runtime.rb
│       │   ├── node_executor.rb
│       │   └── recovery_manager.rb
│       │
│       ├── execution/
│       │   ├── node_execution.rb
│       │   ├── execution_lease.rb
│       │   ├── idempotency.rb
│       │   └── fencing_token.rb
│       │
│       ├── store/
│       │   ├── execution_store.rb
│       │   ├── conversation_store.rb
│       │   ├── outbox_store.rb
│       │   └── mongo/
│       │       └── execution_store.rb
│       │
│       └── actions/
│           ├── action_contract.rb
│           └── recovery_strategy.rb
│
├── spec/
│   ├── spike_1/
│   │   ├── adapter_spec.rb
│   │   ├── checkpoint_spec.rb
│   │   └── restore_spec.rb
│   │
│   ├── spike_2/
│   │   ├── claim_spec.rb
│   │   ├── fencing_spec.rb
│   │   ├── idempotency_spec.rb
│   │   └── crash_recovery_spec.rb
│   │
│   └── integration/
│       └── conversation_recovery_spec.rb
│
└── docs/
    ├── spike-1-rubyllm-adapter.md
    ├── spike-2-crash-recovery.md
    └── spike-results.md
```

## 8. Verbindliche Abnahmekriterien

Ich würde die Spikes nicht anhand der Anzahl implementierter Klassen bewerten, sondern anhand nachweisbarer Eigenschaften.

| Kriterium                         | Spike 1    | Spike 2 |
| --------------------------------- | ---------- | ------- |
| Ohne produktiven LLM-Key testbar  | Ja         | Ja      |
| Prozessneustart getestet          | Ja         | Ja      |
| Persistenzvertrag dokumentiert    | Ja         | Ja      |
| Fehlerzustände normalisiert       | Ja         | Ja      |
| Wiederherstellung reproduzierbar  | Ja         | Ja      |
| Mehrfachausführung kontrolliert   | Tool Calls | Actions |
| Nebenläufigkeit getestet          | –          | Ja      |
| Sicherheitsgrenzen berücksichtigt | Ja         | Ja      |

Ein Spike gilt nur dann als bestanden, wenn seine Tests automatisiert, wiederholbar und dokumentiert sind. Nicht unterstützte Fälle müssen explizit benannt werden.

## 9. Technische Risiken und offene Entscheidungen

| Risiko                                   | Konsequenz                                  | Entscheidung, die der Spike liefern muss              |
| ---------------------------------------- | ------------------------------------------- | ----------------------------------------------------- |
| RubyLLM-Chat-Zustand nicht portabel      | Adapter hängt an internen Implementierungen | Eigener ConversationStore oder RubyLLM-Persistenz     |
| Tool Call nach Absturz erneut ausgeführt | Doppelte Seiteneffekte                      | Tool-Ausführung außerhalb unkontrollierter Chat-Loops |
| MongoDB Claim nicht atomar               | Zwei Worker führen denselben Node aus       | Atomare Operation und Race-Test                       |
| Fencing nur lokal geprüft                | Alter Worker kann extern weiterschreiben    | Fencing auch am schreibenden Zielsystem               |
| Provider-Request ohne Antwort            | Unklarer Conversation-Zustand               | Unsicherer Ausgang und definierte Recovery-Strategie  |
| Outbox-Zustellung mehrfach               | Doppelte Folgeaktionen                      | Deduplizierung über stabile Event-IDs                 |

Ein wichtiger Punkt für Spike 1: RubyLLM dokumentiert inzwischen sowohl persistierte Conversations als auch die Fortsetzung von unterbrochenen Agenten-Loops. Das spricht für die Nutzung der vorhandenen Fähigkeiten statt einer eigenen Chat-Engine. Trotzdem muss der Spike prüfen, welche Persistenzmechanismen außerhalb von Rails verfügbar sind und wie gut sie sich in den eigenen `ConversationStore` integrieren lassen.&#x20;

[image](https://www.google.com/s2/favicons?domain=https://rubyllm.com\&sz=32)

RubyLLM+2



Für Spike 2 gilt: MongoDB-Transaktionen und atomare Operationen müssen unter realistischen Konkurrenzbedingungen getestet werden. Eine erfolgreiche Einzelprozess-Demo reicht nicht.

## 10. Ergebnis: Welche Architekturentscheidungen fallen danach?

Nach den Spikes sollten sechs Entscheidungen verbindlich getroffen werden:

1. LLM-Adapter: Welche minimale Adapter-API wird Teil der öffentlichen Gem-Schnittstelle?
2. Conversation-Persistenz: Nutzt HeuristicSyndicate RubyLLM-Persistenz oder eine eigene Abstraktion darüber?
3. Tool-Ausführung: Führt ausschließlich der HeuristicSyndicate Runtime Executor lokale Tools aus?
4. Recovery: Welche Statusübergänge und Recovery-Regeln werden verbindlich?
5. Idempotenz: Welche Garantien muss jede Action deklarieren?
6. Storage: Reicht MongoDB für Claims, Fencing, Outbox und Recovery unter der geplanten Last?

Meine Empfehlung: Die Tool-Ausführung sollte vollständig unter Kontrolle des HeuristicSyndicate Runtime Executors liegen. RubyLLM sollte Modellinteraktion und Conversation-Management übernehmen, aber nicht eigenständig sicherheitskritische Actions ausführen. Das ist die sauberste Grenze zwischen LLM und Workflow-Engine.

Damit entsteht ein belastbarer Kern für HeuristicSyndicate 2.1: RubyLLM als austauschbarer Conversation-Adapter und eine eigenständige, crash-resistente Ausführungsmaschine.
