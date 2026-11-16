/**
 * The N-owner per-task lease: atomic acquire, TTL, heartbeat, fencing tokens,
 * and stale-lease reaping, scoped to one Firstmate home.
 *
 * This is the only task ownership primitive below the home. It answers exactly
 * one question: "may this actor mutate this task now, and with which token?" It
 * never kills, signals, tears down, or discards anything.
 *
 * Contract: docs/dsh-native-architecture.md section 4.
 *
 * Files:
 *   $FM_HOME/state/leases/<task>.lease     one JSON record, atomically renamed
 *   $FM_HOME/state/leases/.<task>.lock/    mkdir mutex, held for milliseconds
 *
 * All exports are synchronous except {@link withLease}, which needs an
 * asynchronous heartbeat timer.
 *
 * @module @local/dsh-plugin-firstmate-native/src/lease
 */
import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { randomBytes } from 'node:crypto'
import { join } from 'node:path'
import { LeaseError } from './errors.js'
import { isFirstmateHome } from './home.js'
import { assertSameHome } from './identity.js'

/** Default hold validity. */
export const DEFAULT_TTL_MS = 120000

/** Default bound for taking the per-task mutex. */
export const DEFAULT_LOCK_WAIT_MS = 2000

/** A mutex directory older than this is abandoned. */
export const LOCK_STALE_MS = 5000

/** Default validity of the narrow maintenance lease. */
export const MAINTENANCE_TTL_MS = 300000

/** The reserved lease id for the narrow maintenance scope. */
export const MAINTENANCE_TASK = 'maintenance'

/** Record format version this module reads and writes. */
const RECORD_VERSION = 1

/** Task id shape: a leading dot is refused so the mutex namespace cannot collide. */
const TASK_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

/**
 * Validate a task id.
 * @param task - candidate id.
 * @returns the id.
 * @throws {LeaseError} when unusable.
 */
export function validateTaskId(task) {
  if (typeof task !== 'string' || !TASK_ID.test(task)) {
    throw new LeaseError(
      'usage',
      `invalid task id ${JSON.stringify(task)}: expected ${TASK_ID.source}`,
      { task: typeof task === 'string' ? task : null },
    )
  }
  return task
}

/**
 * Resolve the file paths for one lease.
 * @param home - Firstmate home.
 * @param task - task id.
 * @returns `{ dir, file, lockDir }`.
 */
export function leasePaths(home, task) {
  validateTaskId(task)
  const dir = join(home, 'state', 'leases')
  return {
    dir,
    file: join(dir, `${task}.lease`),
    lockDir: join(dir, `.${task}.lock`),
  }
}

/**
 * Require an existing Firstmate home.
 * @param home - candidate home.
 * @returns the home unchanged.
 * @throws {LeaseError} when the path is not a home.
 */
export function requireHome(home) {
  if (typeof home !== 'string' || home.length === 0 || !isFirstmateHome(home)) {
    throw new LeaseError('usage', `not a Firstmate home: ${String(home)}`, { home: home ?? null })
  }
  return home
}

/**
 * A free record for a task that has never been claimed.
 * @param home - Firstmate home.
 * @param task - task id.
 * @returns the free record.
 */
function freeRecord(home, task) {
  return {
    v: RECORD_VERSION,
    task,
    state: 'free',
    token: 0,
    owner: '',
    session: '',
    home,
    pid: 0,
    purpose: '',
    acquired_at: 0,
    renewed_at: 0,
    ttl: 0,
    released_at: null,
    reaped_at: null,
  }
}

/**
 * Read one lease record.
 * @param home - Firstmate home.
 * @param task - task id.
 * @returns `{ record, corrupt }`; `record` is null when the file is absent.
 */
export function readLease(home, task) {
  const { file } = leasePaths(home, task)
  let text
  try {
    text = readFileSync(file, 'utf8')
  } catch (error) {
    if (error?.code === 'ENOENT') return { record: null, corrupt: false }
    return { record: null, corrupt: true }
  }
  try {
    const parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== 'object') return { record: null, corrupt: true }
    if (parsed.v !== RECORD_VERSION) return { record: null, corrupt: true }
    if (parsed.task !== task || parsed.home !== home) return { record: null, corrupt: true }
    if (parsed.state !== 'held' && parsed.state !== 'free') return { record: null, corrupt: true }
    if (!Number.isSafeInteger(parsed.token) || parsed.token < 0) return { record: null, corrupt: true }
    return { record: parsed, corrupt: false }
  } catch {
    return { record: null, corrupt: true }
  }
}

/**
 * Atomically replace one lease record.
 * @param home - Firstmate home.
 * @param task - task id.
 * @param record - the complete record to write.
 */
export function writeLease(home, task, record) {
  const { dir, file } = leasePaths(home, task)
  mkdirSync(dir, { recursive: true })
  const tmp = `${file}.tmp.${process.pid}.${randomBytes(4).toString('hex')}`
  writeFileSync(tmp, `${JSON.stringify(record)}\n`)
  try {
    renameSync(tmp, file)
  } catch (error) {
    try {
      rmSync(tmp, { force: true })
    } catch {
      // Best effort; the temp name is unique and harmless.
    }
    throw error
  }
}

/** Sleep synchronously without a shell or a busy loop. */
function sleepSync(ms) {
  try {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
  } catch {
    // Platforms without SharedArrayBuffer: fall back to a bounded spin.
    const end = Date.now() + ms
    while (Date.now() < end) {
      // Bounded spin.
    }
  }
}

/**
 * Run one critical section under the per-task mutex.
 * @param options - mutex inputs and the body.
 * @param options.home - Firstmate home.
 * @param options.task - task id.
 * @param options.now - clock function.
 * @param options.lockWaitMs - bounded wait.
 * @param options.body - the critical section.
 * @returns the body's result.
 */
function withMutex({ home, task, now = Date.now, lockWaitMs = DEFAULT_LOCK_WAIT_MS }, body) {
  const clock = typeof now === 'function' ? now : () => now
  const { dir, lockDir } = leasePaths(home, task)
  mkdirSync(dir, { recursive: true })
  const deadline = clock() + Math.max(0, lockWaitMs)
  for (;;) {
    try {
      mkdirSync(lockDir)
      break
    } catch (error) {
      if (error?.code !== 'EEXIST') throw error
      let stale = false
      try {
        stale = clock() - statSync(lockDir).mtimeMs > LOCK_STALE_MS
      } catch {
        // The holder released between the failure and the stat; retry.
        continue
      }
      if (stale) {
        try {
          rmSync(lockDir, { recursive: true, force: true })
        } catch {
          // Another actor may have removed it first.
        }
        continue
      }
      if (clock() >= deadline) {
        throw new LeaseError(
          'busy',
          `lease mutex for task '${task}' stayed busy past ${lockWaitMs}ms`,
          { task, lock: lockDir },
        )
      }
      sleepSync(10)
    }
  }
  try {
    writeFileSync(join(lockDir, 'owner'), `${process.pid} ${Date.now()}\n`)
  } catch {
    // Diagnostic only; holding the directory is the mutex.
  }
  try {
    return body()
  } finally {
    try {
      rmSync(lockDir, { recursive: true, force: true })
    } catch {
      // The 5s staleness bound recovers an unremovable mutex.
    }
  }
}

/**
 * Acquire one task lease, or refresh the caller's own live lease.
 * @param options - acquire inputs.
 * @param options.home - the identity's home.
 * @param options.task - task id.
 * @param options.identity - session identity (`{home, ownerLabel, sessionId}`).
 * @param options.purpose - operation label shown in refusals.
 * @param options.ttlMs - hold validity in milliseconds.
 * @param options.now - clock function or number, for tests.
 * @param options.lockWaitMs - bounded mutex wait.
 * @returns the held record (its `token` is the fencing token).
 */
export function acquireLease({
  home,
  task,
  identity,
  purpose = '',
  ttlMs = DEFAULT_TTL_MS,
  now = Date.now,
  lockWaitMs = DEFAULT_LOCK_WAIT_MS,
} = {}) {
  const target = assertSameHome(identity, home)
  requireHome(target)
  validateTaskId(task)
  const clock = typeof now === 'function' ? now : () => now
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) {
    throw new LeaseError('usage', `invalid ttl: ${String(ttlMs)}`, { ttl: ttlMs })
  }
  return withMutex({ home: target, task, now: clock, lockWaitMs }, () => {
    const { record, corrupt } = readLease(target, task)
    const base = record ?? freeRecord(target, task)
    const at = clock()
    if (base.state === 'held') {
      const live = at - base.renewed_at < base.ttl
      if (live) {
        if (base.owner === identity.ownerLabel && base.session === identity.sessionId) {
          const refreshed = {
            ...base,
            renewed_at: at,
            ttl: Math.max(1, Math.floor(ttlMs)),
            purpose: purpose || base.purpose,
          }
          writeLease(target, task, refreshed)
          return refreshed
        }
        throw new LeaseError(
          'contention',
          `task '${task}' is leased by ${base.owner} (${base.purpose || 'no purpose'}) for another ${Math.max(0, base.ttl - (at - base.renewed_at))}ms; retry after it releases`,
          {
            task,
            holder: base.owner,
            session: base.session,
            purpose: base.purpose,
            token: base.token,
            expires_at: base.renewed_at + base.ttl,
          },
        )
      }
      writeLease(target, task, { ...base, state: 'free', reaped_at: at })
    }
    const recordOut = {
      v: RECORD_VERSION,
      task,
      state: 'held',
      token: (base.token ?? 0) + 1,
      owner: identity.ownerLabel,
      session: identity.sessionId,
      home: target,
      pid: process.pid,
      purpose,
      acquired_at: at,
      renewed_at: at,
      ttl: Math.max(1, Math.floor(ttlMs)),
      released_at: null,
      reaped_at: null,
    }
    writeLease(target, task, recordOut)
    if (corrupt) {
      recordOut.warning = 'replaced an unreadable lease record; the fencing token restarted from 0'
    }
    return recordOut
  })
}

/**
 * Renew a held lease. Fails closed when the token is stale or the hold expired.
 * @param options - renew inputs.
 * @param options.home - the identity's home.
 * @param options.task - task id.
 * @param options.identity - session identity.
 * @param options.token - the fencing token this holder was granted.
 * @param options.ttlMs - optional new validity.
 * @param options.now - clock function or number.
 * @returns the renewed record.
 */
export function renewLease({
  home,
  task,
  identity,
  token,
  ttlMs,
  now = Date.now,
  lockWaitMs = DEFAULT_LOCK_WAIT_MS,
} = {}) {
  const target = assertSameHome(identity, home)
  requireHome(target)
  validateTaskId(task)
  const clock = typeof now === 'function' ? now : () => now
  return withMutex({ home: target, task, now: clock, lockWaitMs }, () => {
    const { record, corrupt } = readLease(target, task)
    if (corrupt) {
      throw new LeaseError('invalid-record', `lease record for '${task}' is unreadable and grants nothing`, { task })
    }
    if (record === null || record.state !== 'held') {
      throw new LeaseError('not-held', `task '${task}' is not currently leased`, { task })
    }
    if (record.token !== token) {
      throw new LeaseError(
        'fenced',
        `stale fencing token ${String(token)} for task '${task}'; the live token is ${record.token} (holder ${record.owner})`,
        { task, presented_token: token ?? null, live_token: record.token, holder: record.owner },
      )
    }
    if (record.owner !== identity.ownerLabel || record.session !== identity.sessionId) {
      throw new LeaseError(
        'fenced',
        `lease for task '${task}' is held by ${record.owner}, not ${identity.ownerLabel}`,
        { task, live_token: record.token, holder: record.owner },
      )
    }
    const at = clock()
    if (at - record.renewed_at >= record.ttl) {
      writeLease(target, task, { ...record, state: 'free', reaped_at: at })
      throw new LeaseError(
        'expired',
        `lease for task '${task}' expired ${at - record.renewed_at - record.ttl}ms ago and has been released; re-acquire before writing`,
        { task, token: record.token, expired_at: record.renewed_at + record.ttl },
      )
    }
    const renewed = {
      ...record,
      renewed_at: at,
      ttl: ttlMs === undefined ? record.ttl : Math.max(1, Math.floor(ttlMs)),
      purpose: record.purpose,
    }
    writeLease(target, task, renewed)
    return renewed
  })
}

/**
 * Release a held lease. Idempotent when the record is already free.
 * @param options - release inputs.
 * @param options.home - the identity's home.
 * @param options.task - task id.
 * @param options.identity - session identity.
 * @param options.token - the fencing token this holder was granted.
 * @param options.now - clock function or number.
 * @returns the released record.
 */
export function releaseLease({
  home,
  task,
  identity,
  token,
  now = Date.now,
  lockWaitMs = DEFAULT_LOCK_WAIT_MS,
} = {}) {
  const target = assertSameHome(identity, home)
  requireHome(target)
  validateTaskId(task)
  const clock = typeof now === 'function' ? now : () => now
  return withMutex({ home: target, task, now: clock, lockWaitMs }, () => {
    const { record, corrupt } = readLease(target, task)
    if (corrupt) {
      throw new LeaseError('invalid-record', `lease record for '${task}' is unreadable; nothing to release`, { task })
    }
    if (record === null || record.state === 'free') {
      return record ?? freeRecord(target, task)
    }
    if (record.token !== token || record.owner !== identity.ownerLabel || record.session !== identity.sessionId) {
      throw new LeaseError(
        'fenced',
        `stale release for task '${task}': the live token is ${record.token} held by ${record.owner}`,
        { task, presented_token: token ?? null, live_token: record.token, holder: record.owner },
      )
    }
    const released = { ...record, state: 'free', released_at: clock(), renewed_at: record.renewed_at }
    writeLease(target, task, released)
    return released
  })
}

/**
 * Verify a presented token against the live record without mutating it.
 * @param options - guard inputs.
 * @param options.home - the identity's home.
 * @param options.task - task id.
 * @param options.identity - session identity.
 * @param options.token - the fencing token the caller believes it holds.
 * @param options.now - clock function or number.
 * @returns the live record.
 * @throws {LeaseError} `not-held`, `expired`, or `fenced`.
 */
export function guardLease({ home, task, identity, token, now = Date.now } = {}) {
  const target = assertSameHome(identity, home)
  requireHome(target)
  validateTaskId(task)
  const clock = typeof now === 'function' ? now : () => now
  const { record, corrupt } = readLease(target, task)
  if (corrupt) {
    throw new LeaseError('invalid-record', `lease record for '${task}' is unreadable and grants nothing`, { task })
  }
  if (record === null || record.state !== 'held') {
    throw new LeaseError('not-held', `task '${task}' is not currently leased`, { task })
  }
  if (record.token !== token || record.owner !== identity.ownerLabel || record.session !== identity.sessionId) {
    throw new LeaseError(
      'fenced',
      `stale fencing token for task '${task}': the live token is ${record.token} held by ${record.owner}`,
      { task, presented_token: token ?? null, live_token: record.token, holder: record.owner },
    )
  }
  if (clock() - record.renewed_at >= record.ttl) {
    throw new LeaseError('expired', `lease for task '${task}' has expired; re-acquire before writing`, {
      task,
      token: record.token,
      expired_at: record.renewed_at + record.ttl,
    })
  }
  return record
}

/**
 * Read one lease without mutating it.
 * @param options - inspect inputs.
 * @param options.home - home to read.
 * @param options.task - task id.
 * @param options.now - clock function or number.
 * @returns `{ task, home, exists, corrupt, record, live, remaining_ms, holder }`.
 */
export function inspectLease({ home, task, now = Date.now } = {}) {
  const target = requireHome(home)
  validateTaskId(task)
  const clock = typeof now === 'function' ? now : () => now
  const { record, corrupt } = readLease(target, task)
  if (record === null) {
    return { task, home: target, exists: false, corrupt, record: null, live: false, remaining_ms: 0, holder: null }
  }
  const live = record.state === 'held' && clock() - record.renewed_at < record.ttl
  return {
    task,
    home: target,
    exists: true,
    corrupt,
    record,
    live,
    remaining_ms: live ? Math.max(0, record.ttl - (clock() - record.renewed_at)) : 0,
    holder: record.state === 'held' ? record.owner : null,
  }
}

/**
 * List every task lease record in one home, without mutating anything.
 * @param options - list inputs.
 * @param options.home - home to read.
 * @param options.now - clock function or number.
 * @returns one summary row per task that has a lease record.
 */
export function listLeases({ home, now = Date.now } = {}) {
  const target = requireHome(home)
  const clock = typeof now === 'function' ? now : () => now
  const dir = join(target, 'state', 'leases')
  if (!existsSync(dir)) return []
  const rows = []
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith('.lease')) continue
    const task = entry.slice(0, -'.lease'.length)
    if (!TASK_ID.test(task)) continue
    const { record, corrupt } = readLease(target, task)
    if (corrupt || record === null) {
      rows.push({ task, state: 'unreadable', live: false, token: null, owner: null, purpose: null, expires_at: null })
      continue
    }
    const live = record.state === 'held' && clock() - record.renewed_at < record.ttl
    rows.push({
      task,
      state: record.state,
      live,
      token: record.token,
      owner: record.owner,
      purpose: record.purpose,
      expires_at: record.state === 'held' ? record.renewed_at + record.ttl : null,
    })
  }
  return rows.sort((left, right) => left.task.localeCompare(right.task))
}

/**
 * Sweep expired held leases in one home. Never touches a live or free record.
 * @param options - reap inputs.
 * @param options.home - home to sweep.
 * @param options.now - clock function or number.
 * @returns the reaped records' summaries.
 */
export function reapExpiredLeases({ home, now = Date.now, lockWaitMs = DEFAULT_LOCK_WAIT_MS } = {}) {
  const target = requireHome(home)
  const clock = typeof now === 'function' ? now : () => now
  const dir = join(target, 'state', 'leases')
  if (!existsSync(dir)) return []
  const reaped = []
  for (const entry of readdirSync(dir)) {
    if (!entry.endsWith('.lease')) continue
    const task = entry.slice(0, -'.lease'.length)
    if (!TASK_ID.test(task)) continue
    const at = clock()
    const { record, corrupt } = readLease(target, task)
    if (corrupt || record === null || record.state !== 'held') continue
    if (at - record.renewed_at < record.ttl) continue
    try {
      const freed = withMutex({ home: target, task, now: clock, lockWaitMs }, () => {
        const current = readLease(target, task)
        if (current.corrupt || current.record === null || current.record.state !== 'held') return null
        if (clock() - current.record.renewed_at < current.record.ttl) return null
        const next = { ...current.record, state: 'free', reaped_at: at }
        writeLease(target, task, next)
        return next
      })
      if (freed !== null) {
        reaped.push({ task, token: freed.token, owner: freed.owner, renewed_at: freed.renewed_at, ttl: freed.ttl })
      }
    } catch {
      // A mutex timeout or a concurrent claim leaves the record to the next sweep.
    }
  }
  return reaped
}

/**
 * Acquire a lease, run a body under a heartbeat, and release the lease.
 *
 * A failed renewal does not kill the body; it records `fenced` on the returned
 * handle so the caller can report that it stopped before its next write.
 * @param options - the same inputs as {@link acquireLease}.
 * @param body - the guarded operation, receiving the live handle.
 * @returns `{ result, lease, fenced }`.
 */
export async function withLease(options, body) {
  const record = acquireLease(options)
  const handle = { record, token: record.token, task: options.task, home: record.home, fenced: null }
  const ttl = record.ttl
  const heartbeatMs = Math.max(5000, Math.floor(ttl / 3))
  const timer = setInterval(() => {
    try {
      handle.record = renewLease({ ...options, token: handle.token })
    } catch (error) {
      handle.fenced = error
      clearInterval(timer)
    }
  }, heartbeatMs)
  timer.unref?.()
  let result
  try {
    result = await body(handle)
  } finally {
    clearInterval(timer)
    try {
      handle.record = releaseLease({ ...options, token: handle.token })
    } catch (error) {
      if (handle.fenced === null) handle.fenced = error
    }
  }
  return { result, lease: handle.record, fenced: handle.fenced }
}

/**
 * Acquire the narrow maintenance lease for one of its reserved purposes.
 * @param options - acquire inputs plus the operation name.
 * @returns the held record.
 */
export function acquireMaintenanceLease({ home, identity, purpose, now = Date.now } = {}) {
  if (typeof purpose !== 'string' || purpose.length === 0) {
    throw new LeaseError('usage', 'the maintenance lease requires a named purpose')
  }
  return acquireLease({
    home,
    task: MAINTENANCE_TASK,
    identity,
    purpose: `maintenance:${purpose}`,
    ttlMs: MAINTENANCE_TTL_MS,
    now,
  })
}
