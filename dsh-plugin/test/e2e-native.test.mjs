/**
 * End-to-end native supervisor path tests.
 *
 * These compose the whole chain with fake workers and a throwaway home:
 *   reconcile tick -> per-task lease -> engine mutation script -> native guard
 *   seam (bin/fm-lease-lib.sh -> bin/fm-native-lib.sh) -> success,
 * with no fleet lock anywhere, plus the refusals that make that safe.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { listLeases } from '../src/lease.js'
import { reconcileTick } from '../src/reconcile.js'
import { cleanup, makeHome, makeIdentity } from './helpers.mjs'

const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '')
const ENGINE_LEASE_LIB = fileURLToPath(new URL('../../bin/fm-lease-lib.sh', import.meta.url))

const SNAPSHOT = {
  schema: 'fm-fleet-snapshot.v1',
  backlog: { records: [{ id: 'fm-e2e', state: 'queued', kind: 'ship', title: 'E2E', unresolved_blocker_ids: [] }] },
  tasks: [],
}

/** A fake steer script that goes through the REAL native guard seam. */
const GUARDED_STEER = `#!/usr/bin/env bash
set -u
STATE="$FM_HOME/state"
. "${ENGINE_LEASE_LIB}"
fm_lease_guard "$1" "steer (e2e)"
printf 'delivered:%s:%s\\n' "$1" "\${FM_LEASE_TOKEN:-}" >> "$FM_HOME/state/send.log"
`

/**
 * Build one end-to-end native home.
 * @returns the home path.
 */
function e2eHome() {
  const home = makeHome({
    scripts: {
      'fm-fleet-snapshot.sh': `cat "$FM_HOME/snapshot.json"\n`,
      'fm-send.sh': GUARDED_STEER,
    },
  })
  writeFileSync(join(home, 'config', 'dsh-native-lease'), 'on\n')
  writeFileSync(join(home, 'config', 'native-plugin-dir'), `${PLUGIN_DIR}\n`)
  writeFileSync(join(home, 'snapshot.json'), JSON.stringify(SNAPSHOT))
  writeFileSync(join(home, 'config', 'native-loop.json'), JSON.stringify({
    tick_ms: 1000,
    rules: [{ id: 'steer', when: 'queued', script: 'fm-send.sh', args: ['{id}'] }],
  }))
  return home
}

test('a tick drives an engine mutation through the lease and the native guard seam', async () => {
  const home = e2eHome()
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home, 'loop-session'), apply: true, pluginDir: PLUGIN_DIR })
    assert.equal(report.degraded, null)
    assert.equal(report.actions[0].outcome, 'acted', JSON.stringify(report.actions[0]))
    const log = readFileSync(join(home, 'state', 'send.log'), 'utf8').trim()
    assert.equal(log, 'delivered:fm-e2e:1')
    assert.deepEqual(listLeases({ home }).filter((lease) => lease.live), [])
    assert.equal(existsSync(join(home, 'state', '.lock')), false)
  } finally {
    cleanup(home)
  }
})

test('the same engine mutation refuses when invoked directly without a lease', () => {
  const home = e2eHome()
  try {
    const result = spawnSync(join(home, 'bin', 'fm-send.sh'), ['fm-e2e'], {
      env: { ...process.env, FM_HOME: home, STATE: join(home, 'state'), FM_LEASE_TOKEN: '', FM_LEASE_SESSION: '', FM_LEASE_TASK: '' },
      encoding: 'utf8',
    })
    assert.equal(result.status, 6, result.stderr)
    assert.match(result.stderr, /FM_LEASE_TOKEN\/FM_LEASE_SESSION are unset/)
    assert.equal(existsSync(join(home, 'state', 'send.log')), false)
  } finally {
    cleanup(home)
  }
})

test('two concurrent ticks for one home act on the task at most once', async () => {
  const home = e2eHome()
  try {
    const identityA = makeIdentity(home, 'loop-a')
    const identityB = makeIdentity(home, 'loop-b')
    const [first, second] = await Promise.all([
      reconcileTick({ home, identity: identityA, apply: true, pluginDir: PLUGIN_DIR }),
      reconcileTick({ home, identity: identityB, apply: true, pluginDir: PLUGIN_DIR }),
    ])
    const acted = [first, second].flatMap((report) => report.actions).filter((action) => action.outcome === 'acted')
    const contended = [first, second].flatMap((report) => report.actions).filter((action) => action.outcome === 'contended')
    assert.equal(acted.length, 1, JSON.stringify([first.actions, second.actions]))
    assert.equal(contended.length, 1)
    assert.equal(readFileSync(join(home, 'state', 'send.log'), 'utf8').trim().split('\n').length, 1)
  } finally {
    cleanup(home)
  }
})

test('a loop recovers a crashed holder by expiry, with a higher token', async () => {
  const home = e2eHome()
  try {
    const stale = makeIdentity(home, 'crashed-loop')
    const { acquireLease } = await import('../src/lease.js')
    acquireLease({ home, task: 'fm-e2e', identity: stale, ttlMs: 20 })
    await new Promise((resolve) => setTimeout(resolve, 60))
    const report = await reconcileTick({ home, identity: makeIdentity(home, 'replacement-loop'), apply: true, pluginDir: PLUGIN_DIR })
    assert.equal(report.reaped.length, 1)
    assert.equal(report.actions[0].outcome, 'acted')
    assert.equal(report.actions[0].token, 2)
  } finally {
    cleanup(home)
  }
})

test('a tick refuses to act in another home', async () => {
  const homeA = e2eHome()
  const homeB = makeHome()
  try {
    await assert.rejects(
      reconcileTick({ home: homeB, identity: makeIdentity(homeA), apply: true, pluginDir: PLUGIN_DIR }),
      (error) => error.code === 'cross-home',
    )
    assert.equal(existsSync(join(homeB, 'state', 'send.log')), false)
  } finally {
    cleanup(homeA)
    cleanup(homeB)
  }
})
