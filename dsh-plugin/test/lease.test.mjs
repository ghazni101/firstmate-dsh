/**
 * Lease protocol tests: acquire, contention, expiry, fencing, reaping, and
 * cross-home refusal, all against throwaway homes. No live fleet is involved.
 */
import assert from 'node:assert/strict'
import { spawn, spawnSync } from 'node:child_process'
import { mkdirSync, readFileSync, utimesSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { LeaseError } from '../src/errors.js'
import {
  acquireLease,
  acquireMaintenanceLease,
  guardLease,
  inspectLease,
  MAINTENANCE_TASK,
  reapExpiredLeases,
  releaseLease,
  renewLease,
  withLease,
} from '../src/lease.js'
import { cleanup, makeHome, makeIdentity } from './helpers.mjs'

const CLI = fileURLToPath(new URL('../bin/fm-lease.mjs', import.meta.url))

/** @param fn - a function expected to throw. @returns the thrown value. */
function catchError(fn) {
  try {
    fn()
  } catch (error) {
    return error
  }
  throw new Error('expected the call to throw')
}

const T0 = Date.now()

test('acquire creates a held record with the first fencing token', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const record = acquireLease({ home, task: 'task-one', identity, purpose: 'land' })
    assert.equal(record.state, 'held')
    assert.equal(record.token, 1)
    assert.equal(record.owner, identity.ownerLabel)
    assert.equal(record.session, identity.sessionId)
    assert.equal(record.home, home)
    assert.equal(record.purpose, 'land')
    const stored = JSON.parse(readFileSync(join(home, 'state', 'leases', 'task-one.lease'), 'utf8'))
    assert.equal(stored.token, 1)
    assert.equal(stored.state, 'held')
  } finally {
    cleanup(home)
  }
})

test('re-acquiring the same task as the same session refreshes without a new token', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const first = acquireLease({ home, task: 't', identity, ttlMs: 10000, now: () => T0 })
    const second = acquireLease({ home, task: 't', identity, ttlMs: 10000, now: () => T0 + 1000 })
    assert.equal(second.token, first.token)
    assert.equal(second.acquired_at, first.acquired_at)
    assert.equal(second.renewed_at, T0 + 1000)
  } finally {
    cleanup(home)
  }
})

test('a second session is refused while the first holds the lease', () => {
  const home = makeHome()
  try {
    const owner = makeIdentity(home, 'session-a')
    const other = makeIdentity(home, 'session-b')
    acquireLease({ home, task: 't', identity: owner, purpose: 'steer', ttlMs: 60000, now: () => T0 })
    const error = catchError(() => acquireLease({ home, task: 't', identity: other, now: () => T0 + 1000 }))
    assert.ok(error instanceof LeaseError)
    assert.equal(error.code, 'contention')
    assert.equal(error.details.holder, owner.ownerLabel)
    assert.equal(error.details.purpose, 'steer')
    assert.equal(error.exitCode, 5)
    const inspection = inspectLease({ home, task: 't', now: () => T0 + 1000 })
    assert.equal(inspection.live, true)
    assert.equal(inspection.remaining_ms, 59000)
  } finally {
    cleanup(home)
  }
})

test('an expired hold can be claimed by another session with a higher token', () => {
  const home = makeHome()
  try {
    const owner = makeIdentity(home, 'session-a')
    const other = makeIdentity(home, 'session-b')
    const first = acquireLease({ home, task: 't', identity: owner, ttlMs: 1000, now: () => T0 })
    const second = acquireLease({ home, task: 't', identity: other, ttlMs: 1000, now: () => T0 + 1500 })
    assert.equal(first.token, 1)
    assert.equal(second.token, 2)
    assert.equal(second.owner, other.ownerLabel)
    assert.equal(second.acquired_at, T0 + 1500)
  } finally {
    cleanup(home)
  }
})

test('renewing a hold that already expired fails closed and frees the record', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const record = acquireLease({ home, task: 't', identity, ttlMs: 1000, now: () => T0 })
    const error = catchError(() => renewLease({ home, task: 't', identity, token: record.token, now: () => T0 + 1500 }))
    assert.equal(error.code, 'expired')
    assert.equal(error.exitCode, 3)
    const inspection = inspectLease({ home, task: 't', now: () => T0 + 1500 })
    assert.equal(inspection.record.state, 'free')
    assert.equal(inspection.record.reaped_at, T0 + 1500)
  } finally {
    cleanup(home)
  }
})

test('a stale holder is fenced out and the new holder alone may release', () => {
  const home = makeHome()
  try {
    const stale = makeIdentity(home, 'session-old')
    const fresh = makeIdentity(home, 'session-new')
    const oldRecord = acquireLease({ home, task: 't', identity: stale, ttlMs: 1000, now: () => T0 })
    const newRecord = acquireLease({ home, task: 't', identity: fresh, ttlMs: 60000, now: () => T0 + 2000 })

    const renewError = catchError(() => renewLease({
      home, task: 't', identity: stale, token: oldRecord.token, now: () => T0 + 2001,
    }))
    assert.equal(renewError.code, 'fenced')
    assert.equal(renewError.exitCode, 4)
    assert.equal(renewError.details.live_token, newRecord.token)

    const releaseError = catchError(() => releaseLease({
      home, task: 't', identity: stale, token: oldRecord.token, now: () => T0 + 2002,
    }))
    assert.equal(releaseError.code, 'fenced')

    const released = releaseLease({
      home, task: 't', identity: fresh, token: newRecord.token, now: () => T0 + 2003,
    })
    assert.equal(released.state, 'free')
    assert.equal(released.released_at, T0 + 2003)
  } finally {
    cleanup(home)
  }
})

test('reap frees only expired holds and never deletes a record', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    acquireLease({ home, task: 'stale', identity, ttlMs: 1000, now: () => T0 })
    acquireLease({ home, task: 'live', identity, ttlMs: 60000, now: () => T0 })
    const reaped = reapExpiredLeases({ home, now: () => T0 + 2000 })
    assert.deepEqual(reaped.map((row) => row.task), ['stale'])
    assert.equal(inspectLease({ home, task: 'stale', now: () => T0 + 2000 }).record.state, 'free')
    assert.equal(inspectLease({ home, task: 'live', now: () => T0 + 2000 }).record.state, 'held')
  } finally {
    cleanup(home)
  }
})

test('cross-home claiming is refused before anything is written', () => {
  const homeA = makeHome()
  const homeB = makeHome()
  try {
    const identity = makeIdentity(homeA, 'session-a')
    const error = catchError(() => acquireLease({ home: homeB, task: 't', identity }))
    assert.equal(error.code, 'cross-home')
    assert.equal(error.exitCode, 6)
    assert.equal(error.details.requested_home, homeB)
    assert.equal(inspectLease({ home: homeB, task: 't' }).exists, false)
  } finally {
    cleanup(homeA)
    cleanup(homeB)
  }
})

test('an unreadable record grants nothing but does not wedge the task', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const file = join(home, 'state', 'leases', 't.lease')
    acquireLease({ home, task: 't', identity, ttlMs: 1000, now: () => T0 })
    writeFileSync(file, 'not json at all\n')
    const renewError = catchError(() => renewLease({ home, task: 't', identity, token: 1, now: () => T0 }))
    assert.equal(renewError.code, 'invalid-record')
    const reclaimed = acquireLease({ home, task: 't', identity, ttlMs: 1000, now: () => T0 + 1 })
    assert.equal(reclaimed.state, 'held')
    assert.equal(reclaimed.token, 1)
    assert.match(reclaimed.warning ?? '', /unreadable/)
  } finally {
    cleanup(home)
  }
})

test('withLease releases the lease even when the body throws', async () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    await assert.rejects(
      withLease({ home, task: 't', identity, ttlMs: 60000 }, async () => {
        throw new Error('body failed')
      }),
      /body failed/,
    )
    const inspection = inspectLease({ home, task: 't' })
    assert.equal(inspection.record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('withLease hands the live handle to the body and releases afterwards', async () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const outcome = await withLease({ home, task: 't', identity, ttlMs: 60000 }, async (handle) => {
      const live = inspectLease({ home, task: 't' })
      assert.equal(live.live, true)
      assert.equal(live.record.token, handle.token)
      return 'done'
    })
    assert.equal(outcome.result, 'done')
    assert.equal(outcome.fenced, null)
    assert.equal(inspectLease({ home, task: 't' }).record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('concurrent CLI claims from separate processes produce exactly one holder', async () => {
  const home = makeHome()
  try {
    const sessions = ['race-1', 'race-2', 'race-3', 'race-4', 'race-5']
    const results = await Promise.all(sessions.map((session) => new Promise((resolve) => {
      const child = spawn(process.execPath, [
        CLI, 'acquire', '--home', home, '--task', 'race', '--session', session, '--purpose', 'race',
      ], {
        env: { ...process.env, FM_HOME: home },
        stdio: ['ignore', 'pipe', 'pipe'],
      })
      let stdout = ''
      child.stdout.on('data', (chunk) => { stdout += chunk.toString('utf8') })
      child.on('close', (code) => resolve({ session, code, stdout }))
    })))
    const winners = results.filter((row) => row.code === 0)
    assert.equal(winners.length, 1, `expected one winner, got ${JSON.stringify(results)}`)
    const winnersBody = JSON.parse(winners[0].stdout)
    assert.equal(winnersBody.token, 1)
    for (const loser of results.filter((row) => row.code !== 0)) {
      assert.ok([5, 7].includes(loser.code), `unexpected loser exit ${loser.code}: ${loser.stdout}`)
    }
    const inspection = inspectLease({ home, task: 'race' })
    assert.equal(inspection.record.state, 'held')
    assert.equal(inspection.record.owner, `dsh:${winners[0].session}`)
  } finally {
    cleanup(home)
  }
})

test('the CLI refuses a claim whose environment names another home', () => {
  const homeA = makeHome()
  const homeB = makeHome()
  try {
    const child = spawnSync(process.execPath, [CLI, 'acquire', '--home', homeB, '--task', 't', '--session', 'session-a'], {
      env: { ...process.env, FM_HOME: homeA },
      encoding: 'utf8',
    })
    assert.equal(child.status, 6, child.stderr)
    const body = JSON.parse(child.stdout)
    assert.equal(body.code, 'cross-home')
    assert.equal(inspectLease({ home: homeB, task: 't' }).exists, false)
  } finally {
    cleanup(homeA)
    cleanup(homeB)
  }
})

test('tokens stay monotonic across release and reclaim', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const first = acquireLease({ home, task: 't', identity })
    releaseLease({ home, task: 't', identity, token: first.token })
    const second = acquireLease({ home, task: 't', identity })
    assert.equal(first.token, 1)
    assert.equal(second.token, 2)
  } finally {
    cleanup(home)
  }
})

test('the maintenance lease uses its own reserved record and TTL', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const record = acquireMaintenanceLease({ home, identity, purpose: 'fleet-sync' })
    assert.equal(record.task, 'maintenance')
    assert.equal(record.purpose, 'maintenance:fleet-sync')
    assert.equal(record.ttl, 300000)
    assert.equal(record.token, 1)
    assert.equal(inspectLease({ home, task: MAINTENANCE_TASK }).live, true)
  } finally {
    cleanup(home)
  }
})

test('the maintenance id cannot be claimed as an ordinary task', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home)
    const error = catchError(() => acquireLease({ home, task: MAINTENANCE_TASK, identity, purpose: 'anything' }))
    assert.ok(error instanceof LeaseError)
    assert.equal(error.code, 'usage')
    assert.equal(inspectLease({ home, task: MAINTENANCE_TASK }).exists, false, 'nothing was written')
    const cli = spawnSync(process.execPath, [CLI, 'acquire', '--home', home, '--task', MAINTENANCE_TASK, '--session', 's'], {
      env: { ...process.env, FM_HOME: home },
      encoding: 'utf8',
    })
    assert.equal(cli.status, 2, cli.stdout)
    assert.equal(inspectLease({ home, task: MAINTENANCE_TASK }).exists, false)
  } finally {
    cleanup(home)
  }
})

test('the maintenance lease refuses a purpose outside its reserved set', () => {
  const home = makeHome()
  try {
    const error = catchError(() => acquireMaintenanceLease({ home, identity: makeIdentity(home), purpose: 'merge-pr' }))
    assert.equal(error.code, 'usage')
    assert.equal(inspectLease({ home, task: MAINTENANCE_TASK }).exists, false)
  } finally {
    cleanup(home)
  }
})

test('a busy mutex times out on the wall clock even when the lease clock is fixed', () => {
  const home = makeHome()
  try {
    mkdirSync(join(home, 'state', 'leases', '.t.lock'), { recursive: true })
    const started = Date.now()
    const error = catchError(() => acquireLease({ home, task: 't', identity: makeIdentity(home), now: T0, lockWaitMs: 50 }))
    assert.equal(error.code, 'busy')
    assert.ok(Date.now() - started < 1500, 'the bounded wait elapsed instead of spinning forever')
  } finally {
    cleanup(home)
  }
})

test('a fresh mutex is not judged stale by a lease clock set in the future', () => {
  const home = makeHome()
  try {
    const lockDir = join(home, 'state', 'leases', '.t.lock')
    mkdirSync(lockDir, { recursive: true })
    const error = catchError(() => acquireLease({
      home,
      task: 't',
      identity: makeIdentity(home),
      now: Date.now() + 3600000,
      lockWaitMs: 50,
    }))
    assert.equal(error.code, 'busy', 'a live holder\'s mutex was broken by a skewed lease clock')
    const old = (Date.now() - 60000) / 1000
    utimesSync(lockDir, old, old)
    const record = acquireLease({ home, task: 't', identity: makeIdentity(home), lockWaitMs: 50 })
    assert.equal(record.token, 1, 'a genuinely abandoned mutex is still recovered')
  } finally {
    cleanup(home)
  }
})

test('the guard refuses a stale token before running the command', () => {
  const home = makeHome()
  try {
    const identity = makeIdentity(home, 'session-a')
    const stale = acquireLease({ home, task: 't', identity, ttlMs: 400 })
    const fresh = makeIdentity(home, 'session-b')
    // Expire the stale hold, then let another session take the task.
    const clock = { now: T0 + 5000 }
    releaseLease({ home, task: 't', identity, token: stale.token, now: () => clock.now })
    const live = acquireLease({ home, task: 't', identity: fresh, now: () => clock.now })
    assert.throws(
      () => guardLease({ home, task: 't', identity, token: stale.token, now: () => clock.now }),
      (error) => error.code === 'fenced' && error.details.live_token === live.token,
    )
    const guarded = guardLease({ home, task: 't', identity: fresh, token: live.token, now: () => clock.now })
    assert.equal(guarded.owner, fresh.ownerLabel)
  } finally {
    cleanup(home)
  }
})
