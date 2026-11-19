/**
 * The per-interactive-session supervision engine host.
 *
 * One root DSH session gets at most one engine child, created lazily after the
 * session first claims or dispatches a task. The child is a `fork` subagent
 * activation: seeded once from that session's completed turns, continuable
 * through `sendMessage`, and owned by the subagent manager for execution,
 * result delivery, and release.
 *
 * The host is the deterministic half of the mechanism. Its interval tick and
 * status-file signal run only local readers and classification output (never a
 * model turn): they reap nothing, mutate no task, and either find no traffic or
 * route one batch to the engine. The engine is the judgment half; it is woken
 * for a batch, decides what the captain must see, and escalates through its own
 * tool.
 *
 * Failure containment: creating, closing, or restarting an engine never
 * closes, resets, or steers the parent. A crashed engine marks its durable
 * record, leaves the parent and every worker untouched, and the next tick
 * creates a fresh fork.
 *
 * Contract: docs/dsh-native-architecture.md section 6.
 *
 * @module @local/dsh-plugin-firstmate-native/src/engine
 */
import { randomUUID } from 'node:crypto'
import { readFileSync, watch } from 'node:fs'
import { join } from 'node:path'
import { listLeases, readLease, releaseLease } from './lease.js'
import { observeHome } from './reconcile.js'
import {
  buildBootstrapPrompt,
  buildTrafficMessage,
  completedTurnBoundary,
  diffFleetEvents,
  ENGINE_AGENT_NAME,
  ENGINE_DEFAULT_TICK_MS,
  ENGINE_LABEL,
  ENGINE_MAX_BATCH_ITEMS,
  ENGINE_PROVIDER,
  ENGINE_SCHEMA,
  appendEngineBatch,
  markBatchDelivered,
  markEscalationNudged,
  observeFleetEvents,
  ownerIsLive,
  pendingEscalations,
  processStartTime,
  readEngineRecord,
  resetEngineInboxDeliveries,
  resolveEngineConfig,
  updateEngineRecord,
  withdrawEngineBatch,
  writeEngineRecord,
} from './engine-records.js'

/** Signal debounce for status/meta changes in the home's state directory. */
const SIGNAL_DEBOUNCE_MS = 250

/**
 * Render one error as a short message.
 * @param error - anything thrown.
 * @returns the message.
 */
function messageOf(error) {
  return error instanceof Error ? error.message : String(error)
}

/**
 * The engine's seed boundary in the parent session, when the accessor exists.
 *
 * The installed fork provider reads the same completed-turn prefix; this call
 * only decides whether forking now would seed a completed turn. `undefined`
 * means the platform did not expose history, so the provider decides.
 * @param parentAgent - the interactive session's live agent.
 * @returns a boundary seq, null before the first completed turn, or undefined.
 */
function seedBoundary(parentAgent) {
  try {
    const snapshot = parentAgent?.session
    if (snapshot === undefined || typeof snapshot.snapshotEvents !== 'function') return undefined
    const events = snapshot.snapshotEvents()
    if (!Array.isArray(events)) return undefined
    return completedTurnBoundary(events)
  } catch {
    return undefined
  }
}

/**
 * Compact task events for the durable batch record.
 * @param event - observed task event.
 * @returns the batch item.
 */
function batchItem(event) {
  return {
    id: event.id,
    class: event.class,
    state: event.state ?? null,
    removed: event.removed === true,
    last_event: event.last_event ?? '',
    last_verb: event.last_verb ?? '',
    pending_decision: event.pending_decision === true,
    blocked_event: event.blocked_event === true,
    open_decisions: event.open_decisions ?? [],
    pr_url: event.pr_url ?? null,
    captain_actionable: event.captain_actionable === true,
  }
}

/**
 * Compact escalation records for a batch retry list.
 * @param record - escalation record.
 * @returns the retry summary.
 */
function retryItem(record) {
  return { id: record.id, task: record.task ?? null, outcome: record.outcome ?? '' }
}

/**
 * Owns one parent session's engine child and its deterministic tick.
 */
export class EngineHost {
  /**
   * @param options - host inputs.
   * @param options.home - resolved Firstmate home.
   * @param options.parentAgent - the interactive session's live agent.
   * @param options.identity - the root supervisor identity.
   * @param options.subagents - the subagent service, when available.
   * @param options.getSubagents - live reader for a service that may load after the host.
   * @param options.agents - the plugin-owned agent registry, used for coordinator wakes.
   * @param options.getAgents - live reader for the agent registry.
   * @param options.tickMs - tick interval; 0 disables the timer for tests.
   * @param options.now - clock function.
   * @param options.logger - optional warning sink.
   */
  constructor({ home, parentAgent, identity, subagents, agents, getSubagents, getAgents, tickMs = ENGINE_DEFAULT_TICK_MS, now = Date.now, logger } = {}) {
    this.home = home
    this.parentAgent = parentAgent
    this.identity = { ...identity, kind: 'root' }
    this.subagents = subagents
    this.resolveSubagents = typeof getSubagents === 'function' ? getSubagents : () => subagents
    this.agents = agents
    this.resolveAgents = typeof getAgents === 'function' ? getAgents : () => agents
    this.tickMs = Number.isFinite(tickMs) ? tickMs : ENGINE_DEFAULT_TICK_MS
    this.now = now
    this.logger = logger
    this.timer = null
    this.signalTimer = null
    this.watcher = null
    this.closed = false
    this.ticking = false
    this.activation = null
    this.engineSession = undefined
    this.engineHandle = undefined
    this.lastReport = null
  }

  /** @returns the interactive session id this engine belongs to. */
  get parentSession() {
    return this.identity.sessionId
  }

  /**
   * Read the subagent service at use time, so a late-loading service is usable.
   * @returns the service, or undefined.
   */
  service() {
    try {
      return this.resolveSubagents()
    } catch {
      return undefined
    }
  }

  /**
   * Read this parent's engine record.
   * @returns the record, or null.
   */
  record() {
    return readEngineRecord({ home: this.home, parentSession: this.parentSession })
  }

  /**
   * Start the deterministic interval and status-file signal.
   */
  start() {
    if (this.closed || this.timer !== null) return
    if (this.tickMs > 0) {
      this.timer = setInterval(() => {
        void this.tick({ reason: 'interval' })
      }, this.tickMs)
      this.timer.unref?.()
    }
    this.watchState()
  }

  /**
   * Watch the home's state directory for status and metadata appends.
   */
  watchState() {
    if (typeof watch !== 'function') return
    try {
      this.watcher = watch(join(this.home, 'state'), { persistent: false }, (_event, filename) => {
        const name = typeof filename === 'string' ? filename : ''
        if (name.length > 0 && !/\.(status|meta)$/.test(name)) return
        if (this.signalTimer !== null || this.closed) return
        this.signalTimer = setTimeout(() => {
          this.signalTimer = null
          void this.tick({ reason: 'signal' })
        }, SIGNAL_DEBOUNCE_MS)
        this.signalTimer.unref?.()
      })
      this.watcher.on?.('error', () => {})
    } catch {
      this.watcher = null
    }
  }

  /**
   * Stop the timers and the watcher without touching the engine or parent.
   */
  stop() {
    if (this.timer !== null) {
      clearInterval(this.timer)
      this.timer = null
    }
    if (this.signalTimer !== null) {
      clearTimeout(this.signalTimer)
      this.signalTimer = null
    }
    if (this.watcher !== null) {
      try {
        this.watcher.close()
      } catch {
        // Already closed.
      }
      this.watcher = null
    }
  }

  /**
   * Stop supervision for this parent.
   *
   * The engine child is disposed when this host still owns its live activation;
   * the parent is never disposed, reset, or steered.
   * @param options - close inputs.
   * @param options.terminal - mark the durable record closed (parent ended).
   * @param options.reason - short reason recorded for diagnostics.
   */
  async close({ terminal = false, reason = 'closed' } = {}) {
    if (this.closed) return
    this.closed = true
    this.stop()
    const activation = this.activation
    this.activation = undefined
    if (activation !== undefined && activation !== null) {
      try {
        await activation.dispose()
      } catch {
        // Disposal failure never reaches the parent.
      }
    }
    const handle = this.engineHandle
    this.engineHandle = undefined
    if (handle !== undefined && typeof handle.dispose === 'function') {
      try {
        await handle.dispose()
      } catch {
        // Plugin-owned coordinator cleanup never reaches the parent.
      }
    }
    if (!terminal) return
    const releasedLeases = this.releaseOwnedLeases()
    const record = this.record()
    if (record === null) return
    if (record.owner_pid !== process.pid && ownerIsLive(record)) return
    updateEngineRecord({
      home: this.home,
      parentSession: this.parentSession,
      now: this.now,
      mutate(next) {
        next.status = 'closed'
        next.closed_reason = reason
        if (releasedLeases.length > 0) next.released_leases = releasedLeases
        return next
      },
    })
  }

  /**
   * Release this session's live task leases on terminal close.
   *
   * A lease is only a write claim. Releasing one never kills a worker, removes
   * a worktree, or discards a branch or PR. Only leases held by this parent or
   * its engine, and tasks whose spawn marker names this parent, are touched.
   * @returns the task ids whose leases were released.
   */
  releaseOwnedLeases() {
    const sessions = new Set([this.parentSession, this.engineSession]
      .filter((value) => typeof value === 'string' && value.length > 0))
    const released = []
    for (const row of listLeases({ home: this.home })) {
      if (row.state !== 'held' || row.live !== true) continue
      const { record, corrupt } = readLease(this.home, row.task)
      if (corrupt || record === null || record.state !== 'held') continue
      if (!sessions.has(record.session) && !this.taskOwnedByParent(row.task)) continue
      try {
        releaseLease({
          home: this.home,
          task: row.task,
          identity: { home: this.home, sessionId: record.session, ownerLabel: record.owner },
          token: record.token,
        })
        released.push(row.task)
      } catch {
        // A concurrent holder won the race; cleanup never escalates to teardown.
      }
    }
    return released
  }

  /**
   * Whether this interactive session's spawn marker names one task.
   * @param task - task id from a live lease record.
   * @returns true when the task belongs to this session's crew.
   */
  taskOwnedByParent(task) {
    try {
      const meta = readFileSync(join(this.home, 'state', `${task}.meta`), 'utf8')
      return meta.split('\n').includes(`dsh_session=${this.parentSession}`)
    } catch {
      return false
    }
  }

  /**
   * Run one deterministic tick, serialized against itself.
   * @param options - tick inputs.
   * @param options.reason - interval, signal, or manual.
   * @param options.signal - cancellation.
   * @returns a tick report.
   */
  async tick({ reason = 'manual', signal } = {}) {
    if (this.closed) return this.remember({ ok: false, skipped: 'closed', reason })
    if (this.ticking) return { ok: true, skipped: 'busy', reason }
    this.ticking = true
    try {
      return await this.runTick({ reason, signal })
    } catch (error) {
      return this.remember({ ok: false, skipped: 'error', reason, error: messageOf(error) })
    } finally {
      this.ticking = false
    }
  }

  /**
   * One tick body.
   * @param options - tick inputs.
   * @returns a tick report.
   */
  async runTick({ reason, signal }) {
    const config = resolveEngineConfig({ home: this.home, tickMs: this.tickMs })
    if (!config.enabled) return this.remember({ ok: true, skipped: 'disabled', reason })
    if (config.config_error !== null) {
      return this.remember({ ok: false, skipped: 'config', reason, error: config.config_error })
    }

    let record = this.record()
    if (record !== null && record.owner_pid !== process.pid && ownerIsLive(record)) {
      return this.remember({ ok: true, skipped: 'foreign-owner', reason, engine_session: record.engine_session })
    }

    const adoptable = record !== null
      && record.status === 'live'
      && record.owner_pid === process.pid
      && typeof record.engine_session === 'string'

    // Observe before creating: a quiet fleet with no engine must cost nothing.
    if (this.closed) return this.remember({ ok: false, skipped: 'closed', reason })
    const observation = await observeHome({ home: this.home, signal, ownerSession: this.parentSession })
    if (observation.degraded !== null) {
      return this.remember({ ok: false, skipped: 'degraded', reason, error: observation.degraded, engine_session: this.engineSession })
    }
    const events = observeFleetEvents(observation.snapshot)
    const seen = record !== null && record.seen !== null && typeof record.seen === 'object' ? record.seen : {}
    const changed = diffFleetEvents({ seen, events, ownerSession: this.parentSession })
    const pending = pendingEscalations({ home: this.home, parentSession: this.parentSession, now: this.now() })
    const nextSeen = Object.fromEntries([...events].map(([id, event]) => [id, event.signature]))
    const visible = changed.slice(0, ENGINE_MAX_BATCH_ITEMS)
    const omitted = changed.length - visible.length

    if (!adoptable) {
      // A brand-new session's engine waits for its first real traffic. An
      // existing but crashed/closed/superseded engine is recreated even while
      // quiet, because the session had already asked for supervision.
      if (record === null && changed.length === 0 && pending.length === 0) {
        return this.remember({ ok: true, quiet: true, idle: true, reason })
      }
      const boundary = seedBoundary(this.parentAgent)
      if (boundary === null) {
        return this.remember({ ok: true, skipped: 'awaiting-completed-turn', reason })
      }
      // Write the first batch before the child starts, so its bootstrap turn
      // can never race an empty inbox.
      const batchClass = pending.length > 0 || changed.some((item) => item.class === 'captain')
        ? 'captain'
        : 'routine'
      const batch = appendEngineBatch({
        home: this.home,
        parentSession: this.parentSession,
        items: visible.map(batchItem),
        retries: pending.map(retryItem),
        class: batchClass,
        now: this.now,
      })
      const creation = await this.createEngine({
        config,
        previous: record,
        boundary,
        itemCount: changed.length,
        retryCount: pending.length,
        signal,
      })
      if (!creation.ok) {
        // No engine exists to read this batch, and the next tick re-diffs the
        // same changes into a fresh creation batch; leaving it would stack one
        // undelivered duplicate per failed creation.
        withdrawEngineBatch({ home: this.home, parentSession: this.parentSession, id: batch.id, now: this.now })
        return this.remember({ ...creation, reason })
      }
      this.writeSeen(nextSeen)
      markBatchDelivered({ home: this.home, parentSession: this.parentSession, id: batch.id, now: this.now })
      if (pending.length > 0) {
        markEscalationNudged({ home: this.home, parentSession: this.parentSession, ids: pending.map((record) => record.id), now: this.now })
      }
      return this.remember({
        ok: true,
        created: true,
        delivered: true,
        reason,
        engine_session: this.engineSession,
        batch: batch.id,
        items: changed.length,
        retries: pending.length,
      })
    }

    if (this.engineSession !== record.engine_session) this.engineSession = record.engine_session
    if (changed.length === 0 && pending.length === 0) {
      this.writeSeen(nextSeen)
      return this.remember({ ok: true, quiet: true, reason, engine_session: this.engineSession })
    }

    const batchClass = pending.length > 0 || changed.some((item) => item.class === 'captain')
      ? 'captain'
      : 'routine'
    const batch = appendEngineBatch({
      home: this.home,
      parentSession: this.parentSession,
      items: visible.map(batchItem),
      retries: pending.map(retryItem),
      class: batchClass,
      now: this.now,
    })
    this.writeSeen(nextSeen)

    const delivery = await this.wake({
      text: buildTrafficMessage({ home: this.home, batchId: batch.id, items: visible, pending, omitted }),
      record,
      signal,
    })
    if (!delivery.ok) {
      return this.remember({
        ok: false,
        crashed: true,
        reason,
        engine_session: this.engineSession,
        error: delivery.error,
      })
    }
    markBatchDelivered({ home: this.home, parentSession: this.parentSession, id: batch.id, now: this.now })
    if (pending.length > 0) {
      markEscalationNudged({ home: this.home, parentSession: this.parentSession, ids: pending.map((record) => record.id), now: this.now })
    }
    return this.remember({
      ok: true,
      delivered: true,
      reason,
      engine_session: this.engineSession,
      batch: batch.id,
      items: changed.length,
      retries: pending.length,
    })
  }

  /**
   * Create a fresh engine fork for this parent.
   * @param options - creation inputs.
   * @param options.config - resolved engine configuration.
   * @param options.previous - the existing record, when replacing one.
   * @param options.boundary - completed-turn boundary seq, when known.
   * @param options.signal - cancellation.
   * @returns `{ ok, record }` or `{ ok: false, error }`.
   */
  async createEngine({ config, previous = null, boundary, itemCount = 0, retryCount = 0, signal } = {}) {
    const subagents = this.service()
    if (subagents === undefined || typeof subagents.startActivation !== 'function') {
      return { ok: false, skipped: 'no-subagent-service', error: 'the subagent service is unavailable, so the supervision engine cannot be created' }
    }
    const at = this.now()
    const engineSession = randomUUID()
    const record = {
      v: 1,
      schema: ENGINE_SCHEMA,
      parent_session: this.parentSession,
      home: this.home,
      engine_session: engineSession,
      status: 'creating',
      subagent_provider: ENGINE_PROVIDER,
      label: ENGINE_LABEL,
      model: config.model,
      model_provider: config.provider,
      effort: config.effort,
      created_at: at,
      updated_at: at,
      owner_pid: process.pid,
      owner_started: processStartTime(process.pid),
      crashes: previous === null || previous.status !== 'crashed'
        ? (previous !== null && Number.isSafeInteger(previous.crashes) ? previous.crashes : 0)
        : (Number.isSafeInteger(previous.crashes) ? previous.crashes + 1 : 1),
      seed_boundary: boundary === undefined ? null : boundary,
      seen: {},
      last_tick_at: null,
      last_error: null,
    }
    // Written before the child exists so the child's first tool call resolves
    // its engine identity from lineage plus this explicit marker.
    writeEngineRecord({ home: this.home, parentSession: this.parentSession, record, now: this.now })
    const prompt = [{
      type: 'text',
      text: buildBootstrapPrompt({ home: this.home, parentSession: this.parentSession, itemCount, retryCount }),
    }]
    const agentOptions = {}
    if (config.provider !== null) agentOptions.provider = config.provider
    if (config.model !== null) agentOptions.model = config.model
    if (config.effort !== null) agentOptions.reasoningEffort = config.effort
    const abort = signal ?? new AbortController().signal
    try {
      const activation = await subagents.startActivation({
        provider: ENGINE_PROVIDER,
        label: ENGINE_LABEL,
        name: ENGINE_AGENT_NAME,
        prompt,
        parent: this.parentAgent,
        delivery: 'caller',
        childId: engineSession,
        signal: abort,
        ...(Object.keys(agentOptions).length === 0 ? {} : { agentOptions }),
      })
      if (this.closed) {
        record.status = 'closed'
        record.closed_reason = 'parent-session-ended'
        writeEngineRecord({ home: this.home, parentSession: this.parentSession, record, now: this.now })
        await activation.dispose().catch(() => undefined)
        return { ok: false, skipped: 'closed', error: 'the parent session ended during engine creation' }
      }
      record.status = 'live'
      record.engine_name = typeof activation.name === 'string' ? activation.name : null
      record.started_at = this.now()
      const written = writeEngineRecord({ home: this.home, parentSession: this.parentSession, record, now: this.now })
      this.engineSession = engineSession
      this.activation = activation
      this.observeActivation(activation)
      resetEngineInboxDeliveries({ home: this.home, parentSession: this.parentSession, now: this.now })
      return { ok: true, record: written }
    } catch (error) {
      record.status = 'crashed'
      record.last_error = messageOf(error)
      writeEngineRecord({ home: this.home, parentSession: this.parentSession, record, now: this.now })
      return { ok: false, skipped: 'create-failed', error: `engine creation failed: ${record.last_error}` }
    }
  }

  /**
   * Follow one activation so a failed engine turn marks the record.
   * @param activation - the engine activation.
   */
  observeActivation(activation) {
    Promise.resolve(activation.result).then(
      (result) => {
        if (this.activation !== activation) return
        this.activation = null
        if (result?.stopReason === 'error') this.markCrashed('the supervision engine turn failed')
      },
      (error) => {
        if (this.activation !== activation) return
        this.activation = null
        this.markCrashed(`the supervision engine ended unexpectedly: ${messageOf(error)}`)
      },
    )
  }

  /**
   * Wake the coordinator without a subagent-tree round trip.
   *
   * DSH's subagent manager cold-resumes a non-resident child with parent
   * delivery, posting a settlement notice into the interactive session on
   * every routine turn. The coordinator is plugin-owned: the plugin resumes
   * its persisted session through the agent registry and steers the batch as
   * an ordinary user message. No manager activation settles on a routine
   * turn, so nothing reaches the parent except an escalation.
   * @param options - wake inputs.
   * @param options.text - message body.
   * @param options.record - current engine record.
   * @param options.signal - cancellation.
   * @returns `{ ok, error?, messageId?, ownership }`.
   */
  async wake({ text, record, signal } = {}) {
    let agents
    try {
      agents = this.resolveAgents()
    } catch {
      agents = undefined
    }
    if (agents === undefined || typeof agents.resume !== 'function') {
      const reason = 'the agent registry is unavailable, so the coordinator cannot be woken'
      this.markCrashed(reason)
      return { ok: false, error: reason }
    }
    const abort = signal ?? new AbortController().signal
    try {
      if (this.engineHandle === undefined) {
        const config = resolveEngineConfig({ home: this.home })
        if (config.config_error !== null) throw new Error(config.config_error)
        const agentOptions = {}
        if (config.provider !== null) agentOptions.provider = config.provider
        if (config.model !== null) agentOptions.model = config.model
        if (config.effort !== null) agentOptions.reasoningEffort = config.effort
        this.engineHandle = await agents.resume({
          resumeSessionId: record.engine_session,
          ...(Object.keys(agentOptions).length === 0 ? {} : { agentOptions }),
          signal: abort,
        })
      }
      const agent = this.engineHandle?.agent
      if (agent === undefined || typeof agent.steer !== 'function') {
        throw new Error('the resumed coordinator has no steering surface')
      }
      const message = {
        id: randomUUID(),
        role: 'user',
        content: [{ type: 'text', text }],
        source: { kind: 'user' },
      }
      agent.steer(message)
      return { ok: true, messageId: message.id, ownership: 'plugin' }
    } catch (error) {
      const reason = messageOf(error)
      this.markCrashed(`engine wake failed: ${reason}`)
      return { ok: false, error: reason }
    }
  }

  /**
   * Mark the current engine crashed and release its live activation.
   * @param reason - short diagnostic.
   */
  markCrashed(reason) {
    const record = this.record()
    if (record !== null && record.engine_session === this.engineSession) {
      updateEngineRecord({
        home: this.home,
        parentSession: this.parentSession,
        now: this.now,
        mutate(next) {
          next.status = 'crashed'
          next.last_error = reason
          return next
        },
      })
    }
    const activation = this.activation
    this.activation = null
    if (activation !== undefined && activation !== null) {
      Promise.resolve(activation.dispose()).catch(() => undefined)
    }
    const handle = this.engineHandle
    this.engineHandle = undefined
    if (handle !== undefined && typeof handle.dispose === 'function') {
      Promise.resolve(handle.dispose()).catch(() => undefined)
    }
    this.logger?.warn?.(`firstmate supervision engine for ${this.parentSession}: ${reason}`)
  }

  /**
   * Persist the latest observed task signatures on this engine's record.
   * @param seen - task id to signature map.
   */
  writeSeen(seen) {
    const record = this.record()
    if (record === null || record.engine_session !== this.engineSession) return
    if (JSON.stringify(record.seen ?? {}) === JSON.stringify(seen)) return
    const at = this.now()
    updateEngineRecord({
      home: this.home,
      parentSession: this.parentSession,
      now: this.now,
      mutate(next) {
        next.seen = seen
        next.last_tick_at = at
        return next
      },
    })
  }

  /**
   * Keep the last report for diagnostics.
   * @param report - tick report.
   * @returns the same report.
   */
  remember(report) {
    this.lastReport = report
    return report
  }
}
