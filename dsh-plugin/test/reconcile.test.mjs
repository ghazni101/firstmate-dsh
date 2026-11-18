/**
 * Per-home reconciliation loop tests: dry-run selection, lease-then-act,
 * contention, degraded observation, merge-posture gating, and reaping.
 *
 * Every fixture is a throwaway home with fake engine scripts, so no fleet,
 * network, or real worker is involved.
 */
import assert from 'node:assert/strict'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { acquireLease, listLeases } from '../src/lease.js'
import { loadLoopConfig, reconcileHint, reconcileTick } from '../src/reconcile.js'
import { cleanup, makeHome, makeIdentity, writeScript } from './helpers.mjs'

const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '')
const CLI = join(PLUGIN_DIR, 'bin', 'fm-reconcile.mjs')

const QUEUED_SNAPSHOT = {
  schema: 'fm-fleet-snapshot.v1',
  backlog: {
    records: [
      { id: 'fm-a', state: 'queued', kind: 'ship', title: 'A', unresolved_blocker_ids: [] },
      { id: 'fm-blocked', state: 'queued', kind: 'ship', title: 'Blocked', unresolved_blocker_ids: ['fm-a'] },
    ],
  },
  tasks: [],
}

const IN_FLIGHT_SNAPSHOT = {
  schema: 'fm-fleet-snapshot.v1',
  backlog: { records: [] },
  tasks: [{ id: 'fm-b', state: 'in_flight', kind: 'ship', pr_url: 'https://example.invalid/pr/1' }],
}

/**
 * Create a loop fixture home.
 * @param options - config, snapshot, and posture.
 * @returns the home path.
 */
function loopHome({ config, snapshot = QUEUED_SNAPSHOT, mode = 'direct-PR off' } = {}) {
  const home = makeHome({
    scripts: {
      'fm-fleet-snapshot.sh': `cat "$FM_HOME/snapshot.json"\n`,
      'fm-spawn.sh': `printf '%s|%s|%s\\n' "\${FM_LEASE_TOKEN:-}" "\${FM_LEASE_SESSION:-}" "$*" >> "$FM_HOME/state/spawn.log"\n`,
      'fm-pr-merge.sh': `printf '%s|%s\\n' "\${FM_LEASE_TOKEN:-}" "$*" >> "$FM_HOME/state/merge.log"\n`,
      'fm-project-mode.sh': `printf '%s\\n' "${mode}"\n`,
    },
  })
  writeFileSync(join(home, 'snapshot.json'), JSON.stringify(snapshot))
  writeFileSync(join(home, 'config', 'native-loop.json'), JSON.stringify(config))
  return home
}

const DISPATCH = {
  tick_ms: 1000,
  max_actions_per_tick: 2,
  rules: [
    {
      id: 'dispatch',
      when: 'queued',
      kind: 'ship',
      script: 'fm-spawn.sh',
      vars: { project: 'demo' },
      args: ['{id}', '{project}', '--mode', 'direct-PR', '--yolo', 'off'],
    },
  ],
}

test('a dry-run tick reports the plan and runs nothing', async () => {
  const home = loopHome({ config: DISPATCH })
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home) })
    assert.equal(report.schema, 'fm-native-loop.v1')
    assert.equal(report.applied, false)
    assert.equal(report.observed.queued, 2)
    assert.equal(report.actions.length, 1, 'only one unblocked queued task is actionable')
    assert.equal(report.actions[0].task, 'fm-a')
    assert.equal(report.actions[0].outcome, 'planned')
    assert.equal(existsSync(join(home, 'state', 'spawn.log')), false)
  } finally {
    cleanup(home)
  }
})

test('an applied tick runs the action under the task lease and releases it', async () => {
  const home = loopHome({ config: DISPATCH })
  try {
    const identity = makeIdentity(home, 'loop-session')
    const report = await reconcileTick({ home, identity, apply: true, pluginDir: PLUGIN_DIR })
    assert.equal(report.actions.length, 1)
    assert.equal(report.actions[0].outcome, 'acted')
    assert.equal(report.actions[0].token, 1)
    const log = readFileSync(join(home, 'state', 'spawn.log'), 'utf8').trim()
    assert.match(log, /^1\|loop-session\|fm-a demo --mode direct-PR --yolo off$/)
    assert.deepEqual(listLeases({ home }).filter((lease) => lease.live), [])
  } finally {
    cleanup(home)
  }
})

test('a tick skips a task another session already holds', async () => {
  const home = loopHome({ config: DISPATCH })
  try {
    acquireLease({ home, task: 'fm-a', identity: makeIdentity(home, 'other-session') })
    const report = await reconcileTick({ home, identity: makeIdentity(home, 'loop-session'), apply: true })
    assert.equal(report.actions.length, 1)
    assert.equal(report.actions[0].outcome, 'contended')
    assert.match(report.actions[0].reason, /leased by/)
    assert.equal(existsSync(join(home, 'state', 'spawn.log')), false)
  } finally {
    cleanup(home)
  }
})

test('a degraded observation reports and takes no action', async () => {
  const home = loopHome({ config: DISPATCH })
  try {
    writeScript(home, 'fm-fleet-snapshot.sh', `printf 'snapshot backend down\\n' >&2\nexit 3\n`)
    const report = await reconcileTick({ home, identity: makeIdentity(home), apply: true })
    assert.equal(report.actions.length, 0)
    assert.match(report.degraded, /exited 3/)
    assert.equal(existsSync(join(home, 'state', 'spawn.log')), false)
  } finally {
    cleanup(home)
  }
})

test('a missing placeholder value skips the action instead of guessing', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{ id: 'land', when: 'queued', script: 'fm-pr-merge.sh', args: ['{id}', '{pr_url}'] }],
    },
  })
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home), apply: true })
    assert.equal(report.actions.length, 0)
    assert.ok(report.skipped.some((entry) => entry.reason === 'missing value {pr_url}'))
  } finally {
    cleanup(home)
  }
})

test('a merge action is skipped when the project posture is not yolo', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{
        id: 'land',
        when: 'in_flight',
        script: 'fm-pr-merge.sh',
        vars: { project: 'demo' },
        args: ['{id}', '{pr_url}'],
      }],
    },
    snapshot: IN_FLIGHT_SNAPSHOT,
    mode: 'direct-PR off',
  })
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home), apply: true })
    assert.equal(report.actions[0].outcome, 'skipped')
    assert.match(report.actions[0].reason, /yolo on/)
    assert.equal(existsSync(join(home, 'state', 'merge.log')), false)
    assert.match(reconcileHint(report) ?? '', /need a posture or captain decision/)
  } finally {
    cleanup(home)
  }
})

test('a merge action runs under the lease when the project posture is yolo', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{
        id: 'land',
        when: 'in_flight',
        script: 'fm-pr-merge.sh',
        vars: { project: 'demo' },
        args: ['{id}', '{pr_url}'],
      }],
    },
    snapshot: IN_FLIGHT_SNAPSHOT,
    mode: 'direct-PR on',
  })
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home, 'loop-session'), apply: true })
    assert.equal(report.actions[0].outcome, 'acted')
    const log = readFileSync(join(home, 'state', 'merge.log'), 'utf8').trim()
    assert.match(log, /^1\|fm-b https:\/\/example\.invalid\/pr\/1$/)
  } finally {
    cleanup(home)
  }
})

test('a local-only landing needs mode local-only', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{
        id: 'land',
        when: 'queued',
        script: 'fm-merge-local.sh',
        vars: { project: 'demo' },
        args: ['{id}'],
      }],
    },
    mode: 'direct-PR on',
  })
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home), apply: true })
    assert.equal(report.actions[0].outcome, 'skipped')
    assert.match(report.actions[0].reason, /local-only/)
  } finally {
    cleanup(home)
  }
})

test('a loop config cannot name a supervisor-lifecycle script', () => {
  const home = loopHome({ config: { rules: [{ when: 'queued', script: 'fm-watch.sh', args: [] }] } })
  try {
    assert.throws(() => loadLoopConfig({ home }), /owned by the supervisor lifecycle/)
  } finally {
    cleanup(home)
  }
})

test('a tick reaps expired leases before acting', async () => {
  const home = loopHome({ config: { tick_ms: 1000, rules: [] } })
  try {
    const T0 = Date.now() - 1000
    acquireLease({ home, task: 'fm-old', identity: makeIdentity(home, 'gone'), ttlMs: 10, now: () => T0 })
    const report = await reconcileTick({ home, identity: makeIdentity(home) })
    assert.deepEqual(report.reaped.map((row) => row.task), ['fm-old'])
    assert.equal(listLeases({ home }).find((lease) => lease.task === 'fm-old').state, 'free')
  } finally {
    cleanup(home)
  }
})

test('the loop CLI runs one applied tick without a fleet lock', () => {
  const home = loopHome({ config: DISPATCH })
  try {
    const result = spawnSync(process.execPath, [CLI, '--home', home, '--once', '--apply', '--json'], {
      env: { ...process.env, FM_HOME: home },
      encoding: 'utf8',
    })
    assert.equal(result.status, 0, result.stderr)
    const report = JSON.parse(result.stdout)
    assert.equal(report.actions[0].outcome, 'acted')
    assert.equal(existsSync(join(home, 'state', 'spawn.log')), true)
    assert.equal(existsSync(join(home, 'state', '.lock')), false)
  } finally {
    cleanup(home)
  }
})

test('the loop CLI refuses a cross-home identity', () => {
  const homeA = loopHome({ config: DISPATCH })
  const homeB = makeHome()
  try {
    const result = spawnSync(process.execPath, [CLI, '--home', homeB, '--once'], {
      env: { ...process.env, FM_HOME: homeA },
      encoding: 'utf8',
    })
    assert.equal(result.status, 6)
    assert.match(result.stderr, /cross-home/)
  } finally {
    cleanup(homeA)
    cleanup(homeB)
  }
})

// --- Per-PR delivery decisions drive the loop ------------------------------

/**
 * Build a fake delivery CLI whose resolve output is fixed.
 * @param fields - delivery decision fields.
 * @returns the script body.
 */
function deliveryScript({ mode = 'no-mistakes', yolo = 'on', source = 'pr' } = {}) {
  return `#!/usr/bin/env bash
case "$1" in
  resolve) printf 'mode=${mode}\\nyolo=${yolo}\\ndelivery_source=${source}\\nyolo_source=${source}\\ntask=\\npr=\\nshadowed=\\nreason=\\n' ;;
  *) printf 'ok\\n' ;;
esac
`
}

test('a per-PR decision can turn the pipeline off for a merge the registry would gate', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{
        id: 'land',
        when: 'in_flight',
        script: 'fm-pr-merge.sh',
        vars: { project: 'demo' },
        args: ['{id}', '{pr_url}'],
      }],
    },
    snapshot: IN_FLIGHT_SNAPSHOT,
    mode: 'direct-PR on',
  })
  try {
    writeScript(home, 'fm-delivery.sh', deliveryScript({ mode: 'direct-PR', yolo: 'off', source: 'pr' }))
    const report = await reconcileTick({ home, identity: makeIdentity(home), apply: true })
    assert.equal(report.actions[0].outcome, 'skipped')
    assert.match(report.actions[0].reason, /from pr/)
    assert.equal(existsSync(join(home, 'state', 'merge.log')), false)
  } finally {
    cleanup(home)
  }
})

test('a per-PR decision can turn the pipeline on for a merge the registry would allow', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{
        id: 'land',
        when: 'in_flight',
        script: 'fm-pr-merge.sh',
        vars: { project: 'demo' },
        args: ['{id}', '{pr_url}'],
      }],
    },
    snapshot: IN_FLIGHT_SNAPSHOT,
    mode: 'direct-PR on',
  })
  try {
    writeScript(home, 'fm-delivery.sh', deliveryScript({ mode: 'no-mistakes', yolo: 'on', source: 'task' }))
    const report = await reconcileTick({ home, identity: makeIdentity(home, 'loop-session'), apply: true })
    assert.equal(report.actions[0].outcome, 'acted')
    assert.equal(existsSync(join(home, 'state', 'merge.log')), true)
  } finally {
    cleanup(home)
  }
})

test('loop rules can consume the resolved delivery decision', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{
        id: 'dispatch',
        when: 'queued',
        script: 'fm-spawn.sh',
        vars: { project: 'demo' },
        args: ['{id}', '--mode', '{delivery_mode}', '--yolo', '{yolo}'],
      }],
    },
  })
  try {
    writeScript(home, 'fm-delivery.sh', deliveryScript({ mode: 'direct-PR', yolo: 'on', source: 'task' }))
    const report = await reconcileTick({ home, identity: makeIdentity(home, 'loop-session'), apply: true })
    assert.equal(report.actions[0].outcome, 'acted')
    const log = readFileSync(join(home, 'state', 'spawn.log'), 'utf8').trim()
    assert.match(log, /fm-a --mode direct-PR --yolo on$/)
  } finally {
    cleanup(home)
  }
})

test('a rule needing a delivery decision is skipped when the layer is unavailable', async () => {
  const home = loopHome({
    config: {
      tick_ms: 1000,
      rules: [{ id: 'dispatch', when: 'queued', script: 'fm-spawn.sh', args: ['{id}', '--mode', '{delivery_mode}'] }],
    },
  })
  try {
    const report = await reconcileTick({ home, identity: makeIdentity(home), apply: true })
    assert.equal(report.actions.length, 0)
    assert.ok(report.skipped.some((entry) => /delivery decision unavailable/.test(entry.reason ?? '')))
    assert.equal(existsSync(join(home, 'state', 'spawn.log')), false)
  } finally {
    cleanup(home)
  }
})
