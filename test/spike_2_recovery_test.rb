# frozen_string_literal: true

require_relative "test_helper"

class Spike2RecoveryTest < Minitest::Test
  # Simulated external system persisted on disk so child processes and recovery workers
  # share realistic external side-effect state.
  class DiskExternalSimulator
    def initialize(path)
      @path = path
      File.write(@path, JSON.generate({ invocations: 0, records: {} })) unless File.exist?(@path)
    end

    def apply!(idempotency_key:, payload:)
      mutate do |state|
        state[:invocations] += 1
        state[:records][idempotency_key.to_sym] ||= {
          applied_at: Time.now.utc.iso8601,
          payload: payload,
          invocation_number: state[:invocations]
        }
      end
    end

    def query(idempotency_key)
      read[:records][idempotency_key.to_sym]
    end

    def invocation_count
      read[:invocations]
    end

    private

    def read
      JSON.parse(File.read(@path), symbolize_names: true)
    end

    def mutate
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |f|
        f.flock(File::LOCK_EX)
        state = read
        res = yield state
        File.write(@path, JSON.generate(state))
        f.flock(File::LOCK_UN)
        res
      end
    end
  end

  class ReconcilableDeployAction < HeuristicSyndicate::Action
    action_name "deploy_application"
    version "1.0.0"
    risk :high
    recovery_strategy :reconcile
    requires_capability :deploy

    def initialize(simulator)
      super()
      @simulator = simulator
    end

    def apply(_context, params, idempotency_key:)
      record = @simulator.apply!(idempotency_key: idempotency_key, payload: params)
      { status: "deployed", record: record }
    end

    def reconcile(_context, _params, idempotency_key:)
      existing = @simulator.query(idempotency_key)
      raise HeuristicSyndicate::UncertainOutcome, "No external record found for #{idempotency_key}" unless existing

      { status: "reconciled", record: existing }
    end
  end

  class NonRetryableAction < HeuristicSyndicate::Action
    action_name "non_retryable_op"
    version "1.0.0"
    risk :high
    recovery_strategy :non_retryable
    requires_capability :op

    def apply(_context, _params, idempotency_key: nil)
      { ok: true, key: idempotency_key }
    end
  end

  def setup
    HeuristicSyndicate.reset!
    @tenant = "tenant_beta"
  end

  def build_node_execution(store, id: "ne_1", run_id: "run_1", node_id: "deploy", inputs: { app: "web" })
    ne = HeuristicSyndicate::Execution::NodeExecution.new(
      id: id,
      tenant_id: @tenant,
      run_id: run_id,
      node_id: node_id,
      status: :pending,
      attempt: 0,
      input_digest: HeuristicSyndicate::Execution::Idempotency.digest(inputs),
      idempotency_key: "#{run_id}:#{node_id}:v1"
    )
    store.create_node_execution(ne, tenant: @tenant)
  end

  # REC-01: Crash before claim -> Node remains pending and claimable
  def test_rec_01_crash_before_claim
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)
    injector = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :before_claim)
    executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, crash_injector: injector)

    assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
      executor.execute_node(node_execution_id: "ne_1", worker_id: "w1", tenant: @tenant, inputs: { app: "web" })
    end

    ne = store.find_node_execution("ne_1", tenant: @tenant)
    assert_equal :pending, ne.status
    assert ne.claimable?

    completed = executor.execute_node(node_execution_id: "ne_1", worker_id: "w2", tenant: @tenant, inputs: { app: "web" }) { { done: true } }
    assert_equal :succeeded, completed.status
  end

  # REC-02: Crash after claim, before start -> Lease expires, node is reclaimed with incremented fencing token
  def test_rec_02_crash_after_claim_before_start
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)
    t0 = Time.now.utc
    injector = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :after_claim_before_start)
    executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, lease_duration: 30, crash_injector: injector)

    assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
      executor.execute_node(node_execution_id: "ne_1", worker_id: "w1", tenant: @tenant, inputs: { app: "web" }, now: t0)
    end

    claimed = store.find_node_execution("ne_1", tenant: @tenant)
    assert_equal :claimed, claimed.status
    assert_equal 1, claimed.fencing_token
    refute claimed.claimable?(t0 + 10)
    assert claimed.claimable?(t0 + 31)

    recovered = executor.execute_node(
      node_execution_id: "ne_1",
      worker_id: "w2",
      tenant: @tenant,
      inputs: { app: "web" },
      now: t0 + 31
    ) { { recovered: true } }

    assert_equal :succeeded, recovered.status
    assert_equal 2, recovered.fencing_token
    assert_equal "w2", recovered.lease_owner
  end

  # REC-03: Crash during execution -> Node detected as interrupted/expired and recovered
  def test_rec_03_crash_during_execution
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)
    t0 = Time.now.utc
    injector = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :during_execution)
    executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, lease_duration: 20, crash_injector: injector)

    assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
      executor.execute_node(node_execution_id: "ne_1", worker_id: "w1", tenant: @tenant, inputs: { app: "web" }, now: t0)
    end

    running = store.find_node_execution("ne_1", tenant: @tenant)
    assert_equal :running, running.status
    assert_equal 1, running.attempt

    recovered = executor.execute_node(
      node_execution_id: "ne_1",
      worker_id: "w2",
      tenant: @tenant,
      inputs: { app: "web" },
      now: t0 + 25
    ) { { ok: true } }
    assert_equal :succeeded, recovered.status
    assert_equal 2, recovered.attempt
  end

  # REC-04: Crash before external side effect -> Safe restart executes side effect once
  def test_rec_04_crash_before_external_side_effect
    Dir.mktmpdir("rec04") do |dir|
      store = HeuristicSyndicate::Store::Memory.new
      sim = DiskExternalSimulator.new(File.join(dir, "ext.json"))
      action = ReconcilableDeployAction.new(sim)
      build_node_execution(store)
      t0 = Time.now.utc

      injector = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :before_side_effect)
      executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, lease_duration: 10, crash_injector: injector)

      assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
        executor.execute_node(
          node_execution_id: "ne_1",
          worker_id: "w1",
          tenant: @tenant,
          inputs: { app: "web" },
          action_contract: action,
          now: t0
        )
      end

      assert_equal 0, sim.invocation_count

      completed = executor.execute_node(
        node_execution_id: "ne_1",
        worker_id: "w2",
        tenant: @tenant,
        inputs: { app: "web" },
        action_contract: action,
        now: t0 + 15
      )
      assert_equal :succeeded, completed.status
      assert_equal 1, sim.invocation_count
    end
  end

  # REC-05: Real OS Subprocess Crash AFTER external side effect, BEFORE result commit ->
  # Reconciliation recovers result without blind retry! Also verifies non_retryable marks UNCERTAIN_OUTCOME.
  def test_rec_05_real_subprocess_crash_after_side_effect_uses_reconciliation
    Dir.mktmpdir("rec05") do |dir|
      store = HeuristicSyndicate::Store::FileStore.new(path: File.join(dir, "store.json"))
      sim = DiskExternalSimulator.new(File.join(dir, "ext.json"))
      action = ReconcilableDeployAction.new(sim)
      build_node_execution(store)

      # Worker 1 runs in a real child process and dies abruptly (exit!(137)) AFTER executing the side effect!
      exit_code = HeuristicSyndicate::Testing::CrashInjector.run_in_crashing_subprocess(
        crash_point: :after_side_effect_before_commit
      ) do |injector|
        exec1 = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, lease_duration: 1, crash_injector: injector)
        exec1.execute_node(
          node_execution_id: "ne_1",
          worker_id: "worker_proc_1",
          tenant: @tenant,
          inputs: { app: "web" },
          action_contract: action
        )
      end

      assert_equal 137, exit_code
      assert_equal 1, sim.invocation_count

      interrupted_ne = store.find_node_execution("ne_1", tenant: @tenant)
      assert_equal :running, interrupted_ne.status
      assert interrupted_ne.side_effect_recorded
      assert_nil interrupted_ne.output

      # Worker 2 claims after lease expiration and reconciles without re-invoking apply!
      exec2 = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, lease_duration: 30)
      recovered = exec2.execute_node(
        node_execution_id: "ne_1",
        worker_id: "worker_proc_2",
        tenant: @tenant,
        inputs: { app: "web" },
        action_contract: action,
        now: Time.now.utc + 5
      )

      assert_equal :succeeded, recovered.status
      assert_equal "reconciled", recovered.output[:status]
      assert_equal 1, sim.invocation_count, "External side effect must NOT be executed a second time"

      # Also verify that an action without reconciliation (non_retryable) enters :uncertain_outcome
      build_node_execution(store, id: "ne_non_retry")
      inj2 = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :after_side_effect_before_commit)
      exec_nr = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, lease_duration: 1, crash_injector: inj2)
      non_retry_action = NonRetryableAction.new

      assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
        exec_nr.execute_node(
          node_execution_id: "ne_non_retry",
          worker_id: "w1",
          tenant: @tenant,
          inputs: { app: "web" },
          action_contract: non_retry_action
        )
      end

      uncertain = exec_nr.execute_node(
        node_execution_id: "ne_non_retry",
        worker_id: "w2",
        tenant: @tenant,
        inputs: { app: "web" },
        action_contract: non_retry_action,
        now: Time.now.utc + 5
      )
      assert_equal :uncertain_outcome, uncertain.status
    end
  end

  # REC-06: Crash after result commit, before outbox publish -> Outbox delivers event on recovery
  def test_rec_06_crash_after_commit_before_outbox_publish
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)
    injector = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :after_commit_before_publish)
    executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, crash_injector: injector)

    assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
      executor.execute_node(node_execution_id: "ne_1", worker_id: "w1", tenant: @tenant, inputs: { app: "web" }) { { ok: 1 } }
    end

    ne = store.find_node_execution("ne_1", tenant: @tenant)
    assert_equal :succeeded, ne.status

    pending_outbox = store.pending_outbox_entries(tenant: @tenant)
    assert_equal 1, pending_outbox.size
    assert_equal "node_succeeded:ne_1", pending_outbox.first[:deduplication_key]

    delivered = []
    executor.publish_outbox!(tenant: @tenant) { |entry| delivered << entry[:deduplication_key] }
    assert_equal ["node_succeeded:ne_1"], delivered
    assert_empty store.pending_outbox_entries(tenant: @tenant)
  end

  # REC-07: Crash after success, before scheduler continuation -> Downstream continues logically once
  def test_rec_07_crash_after_success_before_scheduler_continuation
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)
    injector = HeuristicSyndicate::Testing::CrashInjector.new(crash_point: :after_success_before_continue)
    executor = HeuristicSyndicate::Runtime::NodeExecutor.new(store: store, crash_injector: injector)

    assert_raises(HeuristicSyndicate::Testing::SimulatedCrashError) do
      executor.execute_node(node_execution_id: "ne_1", worker_id: "w1", tenant: @tenant, inputs: { app: "web" }) { { step1: "done" } }
    end

    # Node 1 is already terminal (:succeeded), so re-claiming it returns nil and does not re-run it
    reclaim = store.claim_node_execution(node_execution_id: "ne_1", worker_id: "w2", tenant: @tenant)
    assert_nil reclaim

    ne1 = store.find_node_execution("ne_1", tenant: @tenant)
    assert_equal :succeeded, ne1.status
    assert_equal({ step1: "done" }, ne1.output)
  end

  # REC-08: Two workers claim simultaneously -> Only one worker gets a valid claim
  def test_rec_08_concurrent_worker_claims_allow_only_one_winner
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)

    barrier = Queue.new
    results = Queue.new

    threads = Array.new(8) do |i|
      Thread.new do
        barrier.pop
        claimed = store.claim_node_execution(
          node_execution_id: "ne_1",
          worker_id: "worker_#{i}",
          tenant: @tenant
        )
        results << claimed if claimed
      end
    end

    8.times { barrier << true }
    threads.each(&:join)

    assert_equal 1, results.size
    winner = results.pop
    assert_equal 1, winner.fencing_token
  end

  # REC-09: Expired lease, new worker claims -> Old worker's stale fencing token is rejected
  def test_rec_09_stale_fencing_token_rejected
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store)
    t0 = Time.now.utc

    claim1 = store.claim_node_execution(
      node_execution_id: "ne_1",
      worker_id: "slow_worker_1",
      tenant: @tenant,
      lease_duration: 10,
      now: t0
    )
    assert_equal 1, claim1.fencing_token

    # Lease expires and worker 2 claims the node (token = 2)
    claim2 = store.claim_node_execution(
      node_execution_id: "ne_1",
      worker_id: "fast_worker_2",
      tenant: @tenant,
      lease_duration: 30,
      now: t0 + 15
    )
    assert_equal 2, claim2.fencing_token

    # Slow worker 1 wakes up from GC/network pause and tries to commit with token 1 -> LeaseLostError!
    assert_raises(HeuristicSyndicate::LeaseLostError) do
      store.transition_node_execution!(
        node_execution_id: "ne_1",
        fencing_token: claim1.fencing_token,
        to_status: :succeeded,
        output: { stale: true },
        tenant: @tenant
      )
    end

    # Fast worker 2 commits with token 2 -> Succeeded!
    updated = store.transition_node_execution!(
      node_execution_id: "ne_1",
      fencing_token: claim2.fencing_token,
      to_status: :running,
      tenant: @tenant
    )
    succeeded = store.transition_node_execution!(
      node_execution_id: "ne_1",
      fencing_token: updated.fencing_token,
      to_status: :succeeded,
      output: { fresh: true },
      tenant: @tenant
    )
    assert_equal :succeeded, succeeded.status
    assert_equal({ fresh: true }, succeeded.output)
  end

  # REC-10: Repeated resume -> Idempotent; no duplicate execution
  def test_rec_10_repeated_resume_is_idempotent
    exec_count = 0
    step_comp = Class.new(HeuristicSyndicate::Component) do
      input :decision, type: Hash
      output :done, type: String
      define_method(:call) do |decision:, **_rest|
        exec_count += 1
        { done: "approved_by_#{decision[:approver_id]}" }
      end
    end

    pipe_klass = Class.new(HeuristicSyndicate::Pipeline) do
      node :gate, HeuristicSyndicate::Interrupt, type: :approval
      node :finish, step_comp
      connect "gate.decision", "finish.decision"
    end

    store = HeuristicSyndicate::Store::Memory.new
    sec = HeuristicSyndicate::SecurityContext.new(tenant_id: @tenant, actor_id: "admin_1")

    suspended = pipe_klass.run({ resource: { id: "plan_1", digest: "sha256:abc" } }, security_context: sec, store: store)
    assert_equal :suspended, suspended.status

    resumed1 = pipe_klass.resume(
      run_id: suspended.id,
      decision: { approved: true, approver_id: "admin_1" },
      security_context: sec,
      store: store
    )
    assert_equal :completed, resumed1.status
    assert_equal 1, exec_count

    # Second identical resume call is a no-op
    resumed2 = pipe_klass.resume(
      run_id: suspended.id,
      decision: { approved: true, approver_id: "admin_1" },
      security_context: sec,
      store: store
    )
    assert_equal :completed, resumed2.status
    assert_equal 1, exec_count
  end

  # REC-11: Divergent input digest with same idempotency key -> IdempotencyConflict
  def test_rec_11_divergent_input_digest_raises_idempotency_conflict
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store, id: "ne_1", inputs: { env: "staging" })

    assert_raises(HeuristicSyndicate::IdempotencyConflict) do
      build_node_execution(store, id: "ne_2", inputs: { env: "production" })
    end
  end

  # REC-12: Tenant ID manipulated -> TenantAccessDeniedError
  def test_rec_12_tenant_isolation_blocks_cross_tenant_access
    store = HeuristicSyndicate::Store::Memory.new
    build_node_execution(store, id: "ne_secret")

    assert_raises(HeuristicSyndicate::TenantAccessDeniedError) do
      store.find_node_execution("ne_secret", tenant: "attacker_tenant")
    end

    assert_raises(HeuristicSyndicate::TenantAccessDeniedError) do
      store.claim_node_execution(node_execution_id: "ne_secret", worker_id: "w_evil", tenant: "attacker_tenant")
    end
  end
end
