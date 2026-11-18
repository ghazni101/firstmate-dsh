/**
 * Durable records for the per-interactive-session supervision engine.
 *
 * One interactive (root) DSH session gets at most one headless engine child,
 * forked from that session's completed turns. The plugin owns four durable
 * records under the home:
 *
 *   state/engines/<parent>.json             the engine record (identity, status,
 *                                           resolved model, and the last
 *                                           observed fleet fingerprint)
 *   state/engines/<parent>.inbox.json       routine traffic batches the plugin
 *                                           has routed to that engine
 *   state/engines/<parent>.escalations.json engine-to-parent escalations and
 *                                           their delivery state
 *
 * `<parent>` is the interactive session id when it is file-name safe, otherwise
 * a stable hash of it. Everything here is home-local operational state; the
 * engine and its parent are the only readers, and losing a record costs at most
 * one engine recreation.
 *
 * The record also carries the explicit engine marker. DSH exposes no
 * plugin-writable custom session metadata, so the marker is this record
 * (written by the plugin immediately before the child exists, status
 * `creating`) matched against the child's own lineage: `origin: 'subagent'`,
 * `delegationDepth: 1`, and `parentSession` equal to the record's
 * `parent_session`. A session cannot claim the engine surface without both.
 *
 * Contract: docs/dsh-native-architecture.md section 6.
 *
 * @module @local/dsh-plugin-firstmate-native/src/engine-records
 */
import { createHash, randomUUID } from 'node:crypto'
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

/** Engine record schema id. */
export const ENGINE_SCHEMA = 'fm-native-engine.v1'

/** Home config marker that gates the engine for one home. */
export const ENGINE_MARKER_FILE = 'config/dsh-engine'

/** Catalog label recorded on the engine child. Names are per-parent unique. */
export const ENGINE_LABEL = 'firstmate-engine'

/** Registered in-process subagent provider that seeds a child from completed turns. */
export const ENGINE_PROVIDER = 'fork'

/** Default deterministic tick interval. */
export const ENGINE_DEFAULT_TICK_MS = 15000

/** Most inbox batches retained per parent (pending batches are never dropped). */
export const ENGINE_MAX_INBOX_RECORDS = 100

/** Most escalation records retained per parent (pending records are never dropped). */
export const ENGINE_MAX_ESCALATION_RECORDS = 200

/** Most changed task events carried by one batch. */
export const ENGINE_MAX_BATCH_ITEMS = 40

/** Longest escalation outcome the tool accepts. */
export const ENGINE_MAX_OUTCOME_CHARS = 4000

/** Base and capped delay before retrying an undelivered escalation. */
export const ENGINE_RETRY_BASE_MS = 15000
export const ENGINE_RETRY_MAX_MS = 300000

/** Tag that marks escalation text arriving in the interactive session. */
export const ESCALATION_TAG = 'firstmate engine escalation'

/** Tag that marks a traffic batch steering an engine. */
export const TRAFFIC_TAG = 'firstmate engine traffic'

/** A parent session id usable directly as a file name. */
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

/**
 * Whether a value is a plain object.
 * @param value - candidate.
 * @returns true for a non-array object.
 */
function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}

/**
 * Stable file stem for one parent session id.
 * @param parentSession - interactive session id.
 * @returns a file-name-safe stem.
 */
export function parentFileStem(parentSession) {
  const value = String(parentSession ?? '')
  if (SAFE_ID.test(value)) return value
  return `s-${createHash('sha256').update(value).digest('hex').slice(0, 20)}`
}

/**
 * Directory holding every engine record for one home.
 * @param home - Firstmate home.
 * @returns the absolute directory path.
 */
export function engineStateDir(home) {
  return join(home, 'state', 'engines')
}

/**
 * Engine record path for one parent session.
 * @param home - Firstmate home.
 * @param parentSession - interactive session id.
 * @returns the absolute path.
 */
export function engineRecordPath(home, parentSession) {
  return join(engineStateDir(home), `${parentFileStem(parentSession)}.json`)
}

/**
 * Engine inbox path for one parent session.
 * @param home - Firstmate home.
 * @param parentSession - interactive session id.
 * @returns the absolute path.
 */
export function engineInboxPath(home, parentSession) {
  return join(engineStateDir(home), `${parentFileStem(parentSession)}.inbox.json`)
}

/**
 * Escalation record path for one parent session.
 * @param home - Firstmate home.
 * @param parentSession - interactive session id.
 * @returns the absolute path.
 */
export function engineEscalationPath(home, parentSession) {
  return join(engineStateDir(home), `${parentFileStem(parentSession)}.escalations.json`)
}

/**
 * Whether a home has opted in to the supervision engine.
 * @param home - Firstmate home.
 * @returns true when `config/dsh-engine` exists.
 */
export function isEngineHome(home) {
  if (typeof home !== 'string' || home.length === 0) return false
  return existsSync(join(home, ENGINE_MARKER_FILE))
}

/**
 * Read one JSON file, returning null when it is absent or unreadable.
 * @param path - absolute path.
 * @returns the parsed value, or null.
 */
function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'))
  } catch {
    return null
  }
}

/**
 * Atomically replace one JSON file.
 * @param path - destination.
 * @param value - serializable value.
 */
function writeJsonAtomic(path, value) {
  mkdirSync(dirname(path), { recursive: true })
  const temporary = `${path}.tmp.${process.pid}.${randomUUID()}`
  writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`)
  renameSync(temporary, path)
}

/**
 * The default crew-dispatch profile translated to DSH agent options.
 *
 * The home's `config/crew-dispatch.json` default is the single source for the
 * engine's model and effort. A `provider/model` model string is split because
 * DSH takes the route as separate `provider` and `model` fields.
 *
 * @param home - Firstmate home.
 * @returns `{ profile, error }`; profile is null when no default is declared.
 */
export function readCrewDispatchDefault(home) {
  const path = join(home, 'config', 'crew-dispatch.json')
  if (!existsSync(path)) return { profile: null, error: null }
  let parsed
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    return { profile: null, error: `config/crew-dispatch.json is not valid JSON: ${error.message}` }
  }
  if (!isPlainObject(parsed)) {
    return { profile: null, error: 'config/crew-dispatch.json must be a JSON object' }
  }
  const declared = parsed.default
  if (declared === undefined) return { profile: null, error: null }
  const profile = Array.isArray(declared) ? declared[0] : declared
  if (!isPlainObject(profile)) {
    return { profile: null, error: 'config/crew-dispatch.json default must be a profile object or a non-empty array of profiles' }
  }
  const declaredProvider = typeof profile.provider === 'string' && profile.provider.length > 0
    ? profile.provider
    : undefined
  let model = typeof profile.model === 'string' && profile.model.length > 0 ? profile.model : undefined
  let provider = declaredProvider
  if (model !== undefined && model.includes('/')) {
    const slash = model.indexOf('/')
    const head = model.slice(0, slash)
    const tail = model.slice(slash + 1)
    if (declaredProvider === undefined || declaredProvider === head) {
      provider = head
      model = tail
    }
  }
  const effort = typeof profile.effort === 'string' && profile.effort.length > 0 ? profile.effort : undefined
  return {
    profile: {
      harness: typeof profile.harness === 'string' ? profile.harness : null,
      model: model ?? null,
      provider: provider ?? null,
      effort: effort ?? null,
    },
    error: null,
  }
}

/**
 * Resolve the engine configuration for one home.
 * @param options - resolution inputs.
 * @param options.home - Firstmate home.
 * @param options.tickMs - plugin-level interval override, when set.
 * @returns `{ enabled, tick_ms, model, provider, effort, config_error }`.
 */
export function resolveEngineConfig({ home, tickMs } = {}) {
  const dispatch = readCrewDispatchDefault(home)
  const interval = Number.isFinite(tickMs) && tickMs >= 0 ? tickMs : ENGINE_DEFAULT_TICK_MS
  return {
    enabled: isEngineHome(home),
    tick_ms: interval,
    model: dispatch.profile === null ? null : dispatch.profile.model,
    provider: dispatch.profile === null ? null : dispatch.profile.provider,
    effort: dispatch.profile === null ? null : dispatch.profile.effort,
    config_error: dispatch.error,
  }
}

/**
 * Read one parent's engine record.
 * @param options - read inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @returns the record, or null when absent, malformed, or owned by another parent.
 */
export function readEngineRecord({ home, parentSession } = {}) {
  const record = readJson(engineRecordPath(home, parentSession))
  if (!isPlainObject(record)) return null
  if (record.v !== 1 || record.schema !== ENGINE_SCHEMA) return null
  if (record.parent_session !== parentSession) return null
  return record
}

/**
 * Write one parent's engine record, stamping the update time.
 * @param options - write inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @param options.record - record body.
 * @param options.now - clock function.
 * @returns the written record.
 */
export function writeEngineRecord({ home, parentSession, record, now = Date.now } = {}) {
  const next = {
    ...record,
    v: 1,
    schema: ENGINE_SCHEMA,
    parent_session: parentSession,
    home,
    updated_at: now(),
  }
  writeJsonAtomic(engineRecordPath(home, parentSession), next)
  return next
}

/**
 * Read-modify-write one parent's engine record.
 * @param options - update inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @param options.mutate - mutation returning the next record, or mutating in place.
 * @param options.now - clock function.
 * @returns the updated record, or null when there is no record.
 */
export function updateEngineRecord({ home, parentSession, mutate, now = Date.now } = {}) {
  const record = readEngineRecord({ home, parentSession })
  if (record === null) return null
  const next = mutate(record) ?? record
  return writeEngineRecord({ home, parentSession, record: next, now })
}

/**
 * Linux process start time, used to tell a stale pid from a live one.
 * @param pid - process id.
 * @returns the start-time field, or null when unknown.
 */
export function processStartTime(pid) {
  if (!Number.isSafeInteger(pid) || pid <= 0) return null
  try {
    const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
    const close = stat.lastIndexOf(')')
    if (close < 0) return null
    // After "comm)" fields start at state (field 3); starttime is field 22.
    return stat.slice(close + 2).split(' ')[19] ?? null
  } catch {
    return null
  }
}

/**
 * Whether the process that wrote an engine record is still the same process.
 *
 * A different process with the same pid after reuse is not the owner. On hosts
 * without `/proc` the pid cannot be verified, so a foreign pid is treated as
 * dead; DSH keeps one live process per session id, which keeps that safe.
 * @param record - engine record.
 * @param options - test seams.
 * @param options.pid - current process id.
 * @param options.readStart - process start-time reader.
 * @returns true when the recorded owner is this live process.
 */
export function ownerIsLive(record, { pid = process.pid, readStart = processStartTime } = {}) {
  if (!isPlainObject(record)) return false
  const ownerPid = record.owner_pid
  if (!Number.isSafeInteger(ownerPid) || ownerPid <= 0) return false
  if (ownerPid === pid) return true
  const start = readStart(ownerPid)
  if (start === null || start === undefined) return false
  return record.owner_started === null || record.owner_started === undefined || String(record.owner_started) === String(start)
}

/**
 * Whether a session header is a direct child of another session.
 * @param header - session header.
 * @returns `{ parentSession }` for a direct subagent child, else null.
 */
export function engineLineage(header) {
  if (!isPlainObject(header)) return null
  if (header.origin !== 'subagent') return null
  const depth = Number(header.delegationDepth ?? 0)
  if (!Number.isFinite(depth) || depth !== 1) return null
  if (typeof header.parentSession !== 'string' || header.parentSession.length === 0) return null
  return { parentSession: header.parentSession }
}

/**
 * The inclusive source seq of the parent's last completed turn.
 *
 * The fork provider seeds a child with exactly this prefix: every event through
 * the last `turn/end`, never the in-flight turn. Sequence numbers equal array
 * indexes for a live session log, which is how the provider slices it.
 * @param events - parent session events, contiguous from seq 0.
 * @returns the boundary seq, or null before the first completed turn.
 */
export function completedTurnBoundary(events) {
  if (!Array.isArray(events)) return null
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event?.type === 'turn/end' && Number.isSafeInteger(event.seq)) return event.seq
  }
  return null
}

/**
 * The completed-turn prefix the fork provider seeds a child with.
 * @param events - parent session events, contiguous from seq 0.
 * @returns the prefix events, empty before the first completed turn.
 */
export function completedTurnPrefix(events) {
  const boundary = completedTurnBoundary(events)
  if (boundary === null) return []
  return events.slice(0, boundary + 1)
}

/**
 * Classify one observed task event.
 *
 * This reads only fields the engine's existing readers already classified
 * (`fm-fleet-snapshot.sh` and `bin/fm-classify-lib.sh`): pending decisions,
 * blocked events, open decisions, held captain work, and the classified last
 * verb. The engine still decides whether an item is worth escalating.
 * @param event - observed task event.
 * @returns `captain` or `routine`.
 */
export function classifyEvent(event) {
  if (
    event.pending_decision
    || event.blocked_event
    || event.open_decisions.length > 0
    || event.captain_actionable
    || ['done', 'needs-decision', 'blocked', 'failed'].includes(event.last_verb)
    || ['failed', 'blocked', 'needs-decision'].includes(event.state)
  ) return 'captain'
  return 'routine'
}

/**
 * Fold one fleet snapshot into task events keyed by task id.
 * @param snapshot - `fm-fleet-snapshot.sh --json` output.
 * @returns a Map of task id to event.
 */
export function observeFleetEvents(snapshot) {
  const tasks = Array.isArray(snapshot?.tasks) ? snapshot.tasks : []
  const events = new Map()
  for (const task of tasks) {
    if (!isPlainObject(task) || typeof task.id !== 'string' || task.id.length === 0) continue
    const hints = isPlainObject(task.hints) ? task.hints : {}
    const last = isPlainObject(task.paths?.status_log?.last_event) ? task.paths.status_log.last_event : {}
    const backlog = isPlainObject(task.backlog) ? task.backlog : {}
    const current = isPlainObject(task.current_state) ? task.current_state : {}
    const event = {
      id: task.id,
      state: typeof current.state === 'string' && current.state.length > 0 ? current.state : 'unknown',
      last_event: typeof last.raw === 'string' ? last.raw : '',
      last_verb: typeof last.state === 'string' ? last.state : '',
      pending_decision: hints.pending_decision === true,
      blocked_event: hints.blocked_event === true,
      open_decisions: Array.isArray(hints.open_decisions) ? hints.open_decisions.map(String) : [],
      pr_url: typeof task.pr?.url === 'string' && task.pr.url.length > 0 ? task.pr.url : null,
      captain_actionable: backlog.captain_actionable === true,
      hold_bucket: typeof backlog.hold_bucket === 'string' ? backlog.hold_bucket : null,
    }
    event.signature = JSON.stringify([
      event.state,
      event.last_event,
      event.pending_decision,
      event.blocked_event,
      event.open_decisions,
      event.pr_url,
      event.captain_actionable,
      event.hold_bucket,
    ])
    event.class = classifyEvent(event)
    events.set(event.id, event)
  }
  return events
}

/**
 * Diff the current task events against the engine's last observation.
 * @param options - diff inputs.
 * @param options.seen - task id to signature map from the last tick.
 * @param options.events - current events.
 * @returns changed events, captain-class first, then task id.
 */
export function diffFleetEvents({ seen = {}, events } = {}) {
  const changed = []
  for (const [id, event] of events) {
    if (seen[id] !== event.signature) changed.push(event)
  }
  for (const id of Object.keys(seen)) {
    if (!events.has(id)) {
      changed.push({ id, removed: true, signature: 'removed', class: 'routine', state: 'gone', last_event: '', last_verb: '', pending_decision: false, blocked_event: false, open_decisions: [], pr_url: null, captain_actionable: false, hold_bucket: null })
    }
  }
  return changed.sort((left, right) => {
    const rank = (item) => (item.class === 'captain' ? 0 : 1)
    return rank(left) - rank(right) || left.id.localeCompare(right.id)
  })
}

/**
 * Read one parent's engine inbox.
 * @param options - read inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @returns `{ v, parent_session, records }`.
 */
export function readEngineInbox({ home, parentSession } = {}) {
  const inbox = readJson(engineInboxPath(home, parentSession))
  if (!isPlainObject(inbox) || inbox.v !== 1 || !Array.isArray(inbox.records)) {
    return { v: 1, parent_session: parentSession, records: [] }
  }
  return { v: 1, parent_session: parentSession, records: inbox.records.filter(isPlainObject) }
}

/**
 * Append one traffic batch and return it.
 * @param options - append inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @param options.items - changed task events.
 * @param options.retries - pending escalated records to retry.
 * @param options.class - batch class.
 * @param options.now - clock function.
 * @returns the appended batch record.
 */
export function appendEngineBatch({ home, parentSession, items = [], retries = [], class: batchClass = 'routine', now = Date.now } = {}) {
  const inbox = readEngineInbox({ home, parentSession })
  const record = {
    id: `batch-${randomUUID()}`,
    at: now(),
    class: batchClass,
    items,
    retries,
    delivered_at: null,
    acked_at: null,
  }
  inbox.records.push(record)
  const pending = inbox.records.filter((entry) => entry.acked_at === null || entry.acked_at === undefined)
  const settled = inbox.records.filter((entry) => entry.acked_at !== null && entry.acked_at !== undefined)
  const keep = new Set(pending.map((entry) => entry.id))
  const settledBudget = Math.max(0, ENGINE_MAX_INBOX_RECORDS - pending.length)
  for (const entry of settledBudget === 0 ? [] : settled.slice(-settledBudget)) keep.add(entry.id)
  const trimmed = inbox.records.filter((entry) => keep.has(entry.id))
  writeJsonAtomic(engineInboxPath(home, parentSession), { v: 1, parent_session: parentSession, records: trimmed })
  return record
}

/**
 * Read the unacknowledged traffic batches for one engine.
 * @param options - read inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @returns the batches, oldest first.
 */
export function pendingEngineInbox({ home, parentSession } = {}) {
  return readEngineInbox({ home, parentSession }).records
    .filter((entry) => entry.acked_at === null || entry.acked_at === undefined)
    .sort((left, right) => (left.at ?? 0) - (right.at ?? 0))
}

/**
 * Mutate one parent's inbox under a single read-modify-write.
 * @param options - mutation inputs.
 * @returns the mutated inbox.
 */
function mutateInbox({ home, parentSession, mutate, now = Date.now }) {
  const inbox = readEngineInbox({ home, parentSession })
  mutate(inbox.records, now())
  writeJsonAtomic(engineInboxPath(home, parentSession), inbox)
  return inbox
}

/**
 * Mark one batch as delivered to the engine.
 * @param options - delivery inputs.
 * @returns true when the batch existed.
 */
export function markBatchDelivered({ home, parentSession, id, now = Date.now } = {}) {
  let found = false
  mutateInbox({
    home,
    parentSession,
    now,
    mutate(records, at) {
      for (const record of records) {
        if (record.id !== id) continue
        found = true
        if (record.delivered_at === null || record.delivered_at === undefined) record.delivered_at = at
      }
    },
  })
  return found
}

/**
 * Clear delivery marks on unacknowledged batches so a fresh engine reads them.
 * @param options - reset inputs.
 * @returns the reset record count.
 */
export function resetEngineInboxDeliveries({ home, parentSession, now = Date.now } = {}) {
  let reset = 0
  mutateInbox({
    home,
    parentSession,
    now,
    mutate(records) {
      for (const record of records) {
        if (record.acked_at !== null && record.acked_at !== undefined) continue
        if (record.delivered_at === null || record.delivered_at === undefined) continue
        record.delivered_at = null
        reset += 1
      }
    },
  })
  return reset
}

/**
 * Acknowledge batches the engine has read.
 * @param options - acknowledge inputs.
 * @param options.ids - batch ids; when omitted every pending batch is acknowledged.
 * @returns the number acknowledged.
 */
export function ackEngineInbox({ home, parentSession, ids, now = Date.now } = {}) {
  const wanted = Array.isArray(ids) ? new Set(ids.map(String)) : null
  let acknowledged = 0
  mutateInbox({
    home,
    parentSession,
    now,
    mutate(records, at) {
      for (const record of records) {
        if (record.acked_at !== null && record.acked_at !== undefined) continue
        if (wanted !== null && !wanted.has(record.id)) continue
        record.acked_at = at
        if (record.delivered_at === null || record.delivered_at === undefined) record.delivered_at = at
        acknowledged += 1
      }
    },
  })
  return acknowledged
}

/**
 * Read one parent's escalation records.
 * @param options - read inputs.
 * @returns `{ v, parent_session, records }`.
 */
export function readEscalations({ home, parentSession } = {}) {
  const store = readJson(engineEscalationPath(home, parentSession))
  if (!isPlainObject(store) || store.v !== 1 || !Array.isArray(store.records)) {
    return { v: 1, parent_session: parentSession, records: [] }
  }
  return { v: 1, parent_session: parentSession, records: store.records.filter(isPlainObject) }
}

/**
 * Mutate one parent's escalation store.
 * @param options - mutation inputs.
 * @returns the mutated store.
 */
function mutateEscalations({ home, parentSession, mutate, now = Date.now }) {
  const store = readEscalations({ home, parentSession })
  mutate(store.records, now())
  const pending = store.records.filter((record) => record.delivered_at === null || record.delivered_at === undefined)
  const settled = store.records.filter((record) => record.delivered_at !== null && record.delivered_at !== undefined)
  const keep = new Set(pending.map((record) => record.id))
  const settledBudget = Math.max(0, ENGINE_MAX_ESCALATION_RECORDS - pending.length)
  for (const record of settledBudget === 0 ? [] : settled.slice(-settledBudget)) keep.add(record.id)
  store.records = store.records.filter((record) => keep.has(record.id))
  writeJsonAtomic(engineEscalationPath(home, parentSession), store)
  return store
}

/**
 * Stable dedupe key for one escalation.
 * @param options - escalation fields.
 * @returns the dedupe key.
 */
export function escalationDedupeKey({ task, key, outcome } = {}) {
  if (typeof key === 'string' && key.length > 0) return `key:${key}`
  return `body:${typeof task === 'string' ? task : ''}\n${String(outcome ?? '')}`
}

/**
 * Deterministic escalation record id for one parent and dedupe key.
 * @param parentSession - interactive session id.
 * @param dedupe - dedupe key.
 * @returns the record id.
 */
export function escalationId(parentSession, dedupe) {
  return `esc-${createHash('sha256').update(`${parentSession}\n${dedupe}`).digest('hex').slice(0, 24)}`
}

/**
 * Record one escalation, deduplicating identical outcomes.
 * @param options - escalation inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @param options.engineSession - engine child session id.
 * @param options.task - task id, when the outcome is about one task.
 * @param options.key - optional caller key that identifies the decision.
 * @param options.outcome - short captain-facing outcome.
 * @param options.now - clock function.
 * @returns `{ record, duplicate }`.
 */
export function recordEscalation({ home, parentSession, engineSession, task, key, outcome, now = Date.now } = {}) {
  const dedupe = escalationDedupeKey({ task, key, outcome })
  const id = escalationId(parentSession, dedupe)
  const existing = readEscalations({ home, parentSession }).records.find((record) => record.id === id)
  if (existing !== undefined) return { record: existing, duplicate: true }
  const at = now()
  const record = {
    id,
    at,
    parent_session: parentSession,
    engine_session: engineSession ?? null,
    task: typeof task === 'string' && task.length > 0 ? task : null,
    key: typeof key === 'string' && key.length > 0 ? key : null,
    outcome: String(outcome ?? ''),
    dedupe,
    delivered_at: null,
    delivery_attempts: 0,
    next_retry_at: at,
    last_error: null,
  }
  mutateEscalations({
    home,
    parentSession,
    now,
    mutate(records) {
      records.push(record)
    },
  })
  return { record, duplicate: false }
}

/**
 * Find one escalation record for a parent.
 * @param options - lookup inputs.
 * @returns the record, or null.
 */
export function findEscalation({ home, parentSession, id } = {}) {
  return readEscalations({ home, parentSession }).records.find((record) => record.id === id) ?? null
}

/**
 * Mark one escalation delivered.
 * @param options - delivery inputs.
 * @returns the updated record, or null.
 */
export function markEscalationDelivered({ home, parentSession, id, now = Date.now } = {}) {
  let updated = null
  mutateEscalations({
    home,
    parentSession,
    now,
    mutate(records, at) {
      for (const record of records) {
        if (record.id !== id) continue
        record.delivered_at = at
        record.next_retry_at = null
        record.last_error = null
        updated = { ...record }
      }
    },
  })
  return updated
}

/**
 * Record one failed delivery attempt and schedule the next retry.
 * @param options - attempt inputs.
 * @returns the updated record, or null.
 */
export function markEscalationAttempt({ home, parentSession, id, error, now = Date.now } = {}) {
  let updated = null
  mutateEscalations({
    home,
    parentSession,
    now,
    mutate(records, at) {
      for (const record of records) {
        if (record.id !== id) continue
        record.delivery_attempts = Number.isSafeInteger(record.delivery_attempts) ? record.delivery_attempts + 1 : 1
        record.next_retry_at = at + Math.min(ENGINE_RETRY_MAX_MS, ENGINE_RETRY_BASE_MS * 2 ** Math.min(record.delivery_attempts, 5))
        record.last_error = error ?? 'delivery failed'
        updated = { ...record }
      }
    },
  })
  return updated
}

/**
 * Undelivered escalations whose retry is due.
 * @param options - read inputs.
 * @returns the records, oldest first.
 */
export function pendingEscalations({ home, parentSession, now = Date.now, nudgeWindowMs = ENGINE_RETRY_MAX_MS } = {}) {
  const at = typeof now === 'function' ? now() : now
  return readEscalations({ home, parentSession }).records
    .filter((record) => record.delivered_at === null || record.delivered_at === undefined)
    .filter((record) => !Number.isFinite(record.next_retry_at) || record.next_retry_at <= at)
    .filter((record) => !Number.isFinite(record.nudged_at) || record.nudged_at + nudgeWindowMs <= at)
    .sort((left, right) => (left.at ?? 0) - (right.at ?? 0))
}

/**
 * Mark escalations as handed to the engine for a retry, bounding repeat nudges.
 * @param options - nudge inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @param options.ids - escalation ids included in a batch.
 * @param options.now - clock function.
 * @returns the number marked.
 */
export function markEscalationNudged({ home, parentSession, ids = [], now = Date.now } = {}) {
  const wanted = new Set(ids.map(String))
  let marked = 0
  mutateEscalations({
    home,
    parentSession,
    now,
    mutate(records, at) {
      for (const record of records) {
        if (!wanted.has(record.id)) continue
        record.nudged_at = at
        marked += 1
      }
    },
  })
  return marked
}

/**
 * Truncate one line for a model-facing batch.
 * @param text - input text.
 * @param max - maximum characters.
 * @returns the bounded text.
 */
function clip(text, max) {
  const value = String(text ?? '').replace(/\s+/g, ' ').trim()
  return value.length <= max ? value : `${value.slice(0, max)}...`
}

/**
 * One compact event line for a traffic batch.
 * @param item - changed task event.
 * @returns the line.
 */
function renderEvent(item) {
  if (item.removed === true) return `- ${item.id} [removed]`
  const parts = [`- ${item.id} [${item.class}] state=${item.state}`]
  if (item.last_event.length > 0) parts.push(`last=${clip(item.last_event, 320)}`)
  if (item.open_decisions.length > 0) parts.push(`open=${item.open_decisions.join(',')}`)
  if (item.pr_url !== null) parts.push(`pr=${item.pr_url}`)
  return parts.join(' ')
}

/**
 * One compact retry line for an undelivered escalation.
 * @param record - escalation record.
 * @returns the line.
 */
function renderRetry(record) {
  return `- id=${record.id}${record.task === null ? '' : ` task=${record.task}`} outcome=${clip(record.outcome, 320)}`
}

/**
 * Build the text that steers an engine with one traffic batch.
 * @param options - message inputs.
 * @param options.home - Firstmate home.
 * @param options.batchId - durable batch id.
 * @param options.items - changed task events.
 * @param options.pending - undelivered escalations to retry.
 * @returns the message body.
 */
export function buildTrafficMessage({ home, batchId, items = [], pending = [], omitted = 0 } = {}) {
  const lines = [
    `[${TRAFFIC_TAG}]`,
    `home: ${home}`,
    `batch: ${batchId}`,
    `new fleet notifications: ${items.length}${omitted > 0 ? ` (+${omitted} more; read firstmate_native_status for the rest)` : ''}`,
    ...items.map(renderEvent),
  ]
  if (pending.length > 0) {
    lines.push(`pending escalation retries: ${pending.length}`)
    lines.push(...pending.map(renderRetry))
    lines.push('Retry each listed escalation with firstmate_native_escalate retry_id=<id>.')
  }
  lines.push('Read the durable inbox with firstmate_native_engine_inbox, decide what the captain must see, escalate only that with firstmate_native_escalate, and end the turn without acting if nothing does.')
  return lines.join('\n')
}

/**
 * Build the engine's creation prompt.
 *
 * The creation turn is the engine's bootstrap: it already has the forked
 * completed-turn prefix, and this prompt points it at the durable inbox.
 * @param options - prompt inputs.
 * @param options.home - Firstmate home.
 * @param options.parentSession - interactive session id.
 * @param options.itemCount - pending batch item count.
 * @param options.retryCount - pending escalation retry count.
 * @returns the prompt text.
 */
export function buildBootstrapPrompt({ home, parentSession, itemCount = 0, retryCount = 0 } = {}) {
  return [
    `You are the headless Firstmate supervision engine for interactive session ${parentSession} in home ${home}.`,
    'You were forked from that session\'s completed turns. Absorb routine supervision traffic here so the interactive session only sees what the captain must.',
    '',
    'Rules:',
    '- Read pending notifications with firstmate_native_engine_inbox.',
    '- Inspect durable state with firstmate_native_status, firstmate_native_tasks, and firstmate_native_inbox; re-derive every decision from durable records rather than memory.',
    '- Act on a task only while you hold its lease: firstmate_native_lease acquire, then firstmate_native_run with that token, or firstmate_native_reconcile to select authored actions. Contention is normal: another session or engine holds the task; skip it.',
    '- Escalate only a captain-relevant outcome with firstmate_native_escalate, as a short outcome. Never address the captain yourself and never include internal records or paths in an escalation.',
    '- Never kill or interrupt a worker, tear down or discard work, merge outside a resolved yolo posture, or steer the interactive session by any other channel.',
    '- Ordinary subagents and further delegation from you are refused; do not attempt them.',
    '- If nothing needs judgment, end the turn without acting.',
    '',
    `Pending notification batches: ${itemCount > 0 ? 'at least one' : 'none'}${retryCount > 0 ? `; pending escalation retries: ${retryCount}` : ''}.`,
  ].join('\n')
}

/**
 * Build the text delivered into the interactive session for one escalation.
 * @param record - escalation record.
 * @returns the message body.
 */
export function buildEscalationMessage(record) {
  const lines = [`[${ESCALATION_TAG}]`]
  if (record.task !== null) lines.push(`task: ${record.task}`)
  lines.push('', record.outcome)
  return lines.join('\n')
}
