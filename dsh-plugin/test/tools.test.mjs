/**
 * Plugin tool-surface tests: feature-flag gating, read-only tools, per-home
 * opt-in, fixed allowlists, bounded output, and identity cleanup.
 */
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { apply } from '../index.js'
import { acquireLease, inspectLease, listLeases } from '../src/lease.js'
import {
  cleanup,
  emit,
  execFor,
  makeAgent,
  makeContext,
  makeHome,
  makeIdentity,
  toolNamed,
} from './helpers.mjs'

/** Script bodies used by the tool fixtures. */
const STATUS_SCRIPT = `printf '{"home":"%s","underway":[]}\\n' "$FM_HOME"\n`
const TASKS_SCRIPT = `for arg in "$@"; do printf 'ARG:%s\\n' "$arg"; done\n`
const INBOX_SCRIPT = `case "$1" in
  ready) printf '{"lock":"free","posture":"present"}\\n' ;;
  list) printf 'note: hello from the inbox\\n' ;;
  receipts) printf '{"pending":[]}\\n' ;;
  *) printf 'unexpected args: %s\\n' "$*" >&2; exit 2 ;;
esac
`

/**
 * Boot the plugin against one fixture home and one fake agent.
 * @param options - fixture options.
 * @returns the booted surface.
 */
async function boot({ home, cwd = home, header = {}, native = true } = {}) {
  const context = makeContext()
  apply(context.ctx, { enabled: true, home })
  const { agent, contributions } = makeAgent({ id: 'agent-a', cwd, header })
  await emit(context.listeners, 'agent/created', { agent })
  return { ...context, agent, contributions }
}

test('the plugin is inert unless enabled', () => {
  const context = makeContext()
  apply(context.ctx, {})
  assert.equal(context.tools.length, 0)
  assert.equal(context.listeners.size, 0)
})

test('enabling registers exactly the eight tools and the identity listeners', async () => {
  const home = makeHome({ scripts: {
    'fm-bearings-snapshot.sh': STATUS_SCRIPT,
    'fm-tasks-axi.sh': TASKS_SCRIPT,
    'fm-inbox.sh': INBOX_SCRIPT,
  } })
  try {
    const surface = await boot({ home })
    assert.deepEqual(surface.tools.map((tool) => tool.name).sort(),
      ['firstmate_native_delivery', 'firstmate_native_inbox', 'firstmate_native_lease', 'firstmate_native_reconcile', 'firstmate_native_run', 'firstmate_native_start', 'firstmate_native_status', 'firstmate_native_tasks'])
    assert.ok(surface.listeners.has('agent/created'))
    assert.ok(surface.listeners.has('agent/disposed'))
    for (const tool of surface.tools) {
      assert.equal(tool.output.schema.type, 'object')
      assert.deepEqual(tool.output.render({}, { text: 'ok' }), [{ type: 'text', text: 'ok' }])
    }
  } finally {
    cleanup(home)
  }
})

test('a root session in an opted-in home receives one static identity note', async () => {
  const home = makeHome()
  try {
    const surface = await boot({ home })
    assert.equal(surface.contributions.length, 1)
    const contribution = surface.contributions[0]
    assert.equal(contribution.name, 'firstmate:native-identity')
    assert.equal(contribution.order, 130)
    assert.equal(contribution.interpolate, false)
    assert.equal(typeof contribution.text, 'string')
    assert.match(contribution.text, /no fleet-wide owner/)
  } finally {
    cleanup(home)
  }
})

test('a home without the native marker gets no context and refuses tools', async () => {
  const home = makeHome({ native: false, scripts: { 'fm-bearings-snapshot.sh': STATUS_SCRIPT } })
  try {
    const surface = await boot({ home })
    assert.equal(surface.contributions.length, 0)
    const tool = toolNamed(surface.tools, 'firstmate_native_status')
    await assert.rejects(tool.execute({}, execFor(surface.agent)), /config\/dsh-native/)
  } finally {
    cleanup(home)
  }
})

test('a session outside any home is refused by every tool', async () => {
  const home = makeHome({ scripts: { 'fm-bearings-snapshot.sh': STATUS_SCRIPT } })
  const outside = mkdtempSync(join(tmpdir(), 'fm-outside-'))
  try {
    const surface = await boot({ home, cwd: outside })
    assert.equal(surface.contributions.length, 0)
    const tool = toolNamed(surface.tools, 'firstmate_native_status')
    await assert.rejects(tool.execute({}, execFor(surface.agent)), /not a Firstmate supervisor session/)
  } finally {
    cleanup(home)
    rmSync(outside, { recursive: true, force: true })
  }
})

test('a subagent session is refused and contributes nothing', async () => {
  const home = makeHome({ scripts: { 'fm-bearings-snapshot.sh': STATUS_SCRIPT } })
  try {
    const surface = await boot({ home, header: { origin: 'subagent' } })
    assert.equal(surface.contributions.length, 0)
    const tool = toolNamed(surface.tools, 'firstmate_native_status')
    await assert.rejects(tool.execute({}, execFor(surface.agent)), /not a Firstmate supervisor session/)
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_status runs the snapshot with FM_HOME pinned and parses JSON', async () => {
  const home = makeHome({ scripts: { 'fm-bearings-snapshot.sh': STATUS_SCRIPT } })
  try {
    const surface = await boot({ home })
    const value = await toolNamed(surface.tools, 'firstmate_native_status').execute({}, execFor(surface.agent))
    assert.equal(value.ok, true)
    assert.equal(value.format, 'json')
    assert.equal(value.data.home, home)
    assert.equal(value.tool, 'firstmate_native_status')
    assert.equal(value.truncated, false)
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_tasks translates filters into the backend command', async () => {
  const home = makeHome({ scripts: { 'fm-tasks-axi.sh': TASKS_SCRIPT } })
  try {
    const surface = await boot({ home })
    const value = await toolNamed(surface.tools, 'firstmate_native_tasks').execute({
      state: 'queued',
      limit: 5,
      fields: 'blocked_by',
      blocked: true,
    }, execFor(surface.agent))
    for (const expected of ['ARG:list', 'ARG:--state', 'ARG:queued', 'ARG:--limit', 'ARG:5', 'ARG:--fields', 'ARG:blocked_by', 'ARG:--blocked']) {
      assert.match(value.text, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')))
    }
    assert.equal(value.format, 'text')
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_tasks refuses malformed filters', async () => {
  const home = makeHome({ scripts: { 'fm-tasks-axi.sh': TASKS_SCRIPT } })
  try {
    const surface = await boot({ home })
    const tool = toolNamed(surface.tools, 'firstmate_native_tasks')
    await assert.rejects(tool.execute({ limit: 0 }, execFor(surface.agent)), /between 1 and 200/)
    await assert.rejects(tool.execute({ limit: 500 }, execFor(surface.agent)), /between 1 and 200/)
    await assert.rejects(tool.execute({ fields: 'Bad Field' }, execFor(surface.agent)), /lowercase field names/)
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_inbox maps its three read-only views', async () => {
  const home = makeHome({ scripts: { 'fm-inbox.sh': INBOX_SCRIPT } })
  try {
    const surface = await boot({ home })
    const tool = toolNamed(surface.tools, 'firstmate_native_inbox')
    const ready = await tool.execute({}, execFor(surface.agent))
    assert.equal(ready.format, 'json')
    assert.equal(ready.data.lock, 'free')
    const notes = await tool.execute({ view: 'notes' }, execFor(surface.agent))
    assert.equal(notes.format, 'text')
    assert.match(notes.text, /note: hello/)
    const receipts = await tool.execute({ view: 'receipts' }, execFor(surface.agent))
    assert.equal(receipts.format, 'json')
    assert.deepEqual(receipts.data.pending, [])
  } finally {
    cleanup(home)
  }
})

test('oversized output is capped and marked instead of dropped', async () => {
  const home = makeHome({ scripts: {
    'fm-bearings-snapshot.sh': `head -c 60000 /dev/zero | tr '\\0' 'x'\n`,
  } })
  try {
    const surface = await boot({ home })
    const value = await toolNamed(surface.tools, 'firstmate_native_status').execute({}, execFor(surface.agent))
    assert.equal(value.truncated, true)
    assert.ok(value.text.length > 48000)
    assert.match(value.text, /\[truncated at 48000 characters\]/)
  } finally {
    cleanup(home)
  }
})

test('a failing read-only script surfaces its own diagnostic', async () => {
  const home = makeHome({ scripts: {
    'fm-bearings-snapshot.sh': `printf 'backend unavailable\\n' >&2\nexit 3\n`,
  } })
  try {
    const surface = await boot({ home })
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_status').execute({}, execFor(surface.agent)),
      /firstmate_native_status failed \(exit 3\)[\s\S]*backend unavailable/,
    )
  } finally {
    cleanup(home)
  }
})

test('disposing the agent removes its contribution while tools still re-resolve identity', async () => {
  const home = makeHome({ scripts: { 'fm-bearings-snapshot.sh': STATUS_SCRIPT } })
  try {
    const surface = await boot({ home })
    assert.equal(surface.contributions.length, 1)
    await emit(surface.listeners, 'agent/disposed', { agent: surface.agent })
    assert.equal(surface.contributions.length, 0)
    // A tool call re-derives the identity from the session header rather than
    // failing because the agent predates activation.
    const value = await toolNamed(surface.tools, 'firstmate_native_status').execute({}, execFor(surface.agent))
    assert.equal(value.ok, true)
    assert.equal(value.data.home, home)
  } finally {
    cleanup(home)
  }
})

// --- Phase 1: task lease and command channel -------------------------------

/** Mutating fixture script that proves the lease identity reached it. */
const SEND_SCRIPT = `printf 'lease=%s token=%s owner=%s\\n' "\${FM_LEASE_TASK:-}" "\${FM_LEASE_TOKEN:-}" "\${FM_LEASE_OWNER:-}"
[ -n "\${FM_LEASE_TOKEN:-}" ]
`

const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '')
const ENGINE_LEASE_LIB = fileURLToPath(new URL('../../bin/fm-lease-lib.sh', import.meta.url))

/**
 * Mutating fixture script that goes through the REAL native guard seam, so it
 * only succeeds when the channel exported a live token and its holding session.
 */
const GUARDED_SEND_SCRIPT = `#!/usr/bin/env bash
set -u
STATE="$FM_HOME/state"
. "${ENGINE_LEASE_LIB}"
fm_lease_guard "$1" "steer (channel)"
printf 'session=%s token=%s\\n' "\${FM_LEASE_SESSION:-}" "\${FM_LEASE_TOKEN:-}"
`

test('firstmate_native_lease acquires, inspects, renews, and releases one task', async () => {
  const home = makeHome()
  try {
    const surface = await boot({ home })
    const tool = toolNamed(surface.tools, 'firstmate_native_lease')
    const acquired = await tool.execute({ action: 'acquire', task: 'task-a', purpose: 'land PR' }, execFor(surface.agent))
    assert.equal(acquired.ok, true)
    assert.equal(acquired.token, 1)
    assert.equal(acquired.record.state, 'held')
    const inspected = await tool.execute({ action: 'inspect', task: 'task-a' }, execFor(surface.agent))
    assert.equal(inspected.inspection.live, true)
    assert.equal(inspected.inspection.record.purpose, 'land PR')
    const renewed = await tool.execute({ action: 'renew', task: 'task-a', token: 1 }, execFor(surface.agent))
    assert.equal(renewed.record.token, 1)
    const released = await tool.execute({ action: 'release', task: 'task-a', token: 1 }, execFor(surface.agent))
    assert.equal(released.record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_lease surfaces contention with its stable code', async () => {
  const home = makeHome()
  try {
    const surface = await boot({ home })
    acquireLease({ home, task: 'task-a', identity: makeIdentity(home, 'other-session') })
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_lease').execute({ action: 'acquire', task: 'task-a' }, execFor(surface.agent)),
      /contention:/,
    )
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_lease reap frees expired holds only', async () => {
  const home = makeHome()
  try {
    const surface = await boot({ home })
    acquireLease({ home, task: 'stale', identity: makeIdentity(home, 'other'), ttlMs: 10 })
    await new Promise((resolve) => setTimeout(resolve, 30))
    const reaped = await toolNamed(surface.tools, 'firstmate_native_lease').execute({ action: 'reap' }, execFor(surface.agent))
    assert.deepEqual(reaped.reaped.map((row) => row.task), ['stale'])
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run runs a read-only script without a task', async () => {
  const home = makeHome({ scripts: { 'fm-crew-state.sh': `printf 'state: busy\\n'\n` } })
  try {
    const surface = await boot({ home })
    const result = await toolNamed(surface.tools, 'firstmate_native_run').execute({ script: 'fm-crew-state.sh' }, execFor(surface.agent))
    assert.equal(result.ok, true)
    assert.equal(result.read_only, true)
    assert.equal(result.leased, false)
    assert.match(result.stdout, /state: busy/)
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run requires a task for a mutating script', async () => {
  const home = makeHome({ scripts: { 'fm-send.sh': SEND_SCRIPT } })
  try {
    const surface = await boot({ home })
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_run').execute({ script: 'fm-send.sh', args: ['x'] }, execFor(surface.agent)),
      /task \(required for a mutating script\) is required/,
    )
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run takes and releases the task lease around a mutating script', async () => {
  const home = makeHome({ scripts: { 'fm-send.sh': SEND_SCRIPT } })
  try {
    const surface = await boot({ home })
    const result = await toolNamed(surface.tools, 'firstmate_native_run').execute({
      script: 'fm-send.sh',
      args: ['task-a', 'hello'],
      task: 'task-a',
    }, execFor(surface.agent))
    assert.equal(result.ok, true)
    assert.equal(result.read_only, false)
    assert.equal(result.leased, true)
    assert.equal(result.token, 1)
    assert.match(result.stdout, /lease=task-a token=1 owner=dsh:agent-a/)
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run exports the holding session to a guarded mutating script', async () => {
  const home = makeHome({ scripts: { 'fm-send.sh': GUARDED_SEND_SCRIPT } })
  writeFileSync(join(home, 'config', 'dsh-native-lease'), 'on\n')
  writeFileSync(join(home, 'config', 'native-plugin-dir'), `${PLUGIN_DIR}\n`)
  try {
    const surface = await boot({ home })
    const result = await toolNamed(surface.tools, 'firstmate_native_run').execute({
      script: 'fm-send.sh',
      args: ['task-a'],
      task: 'task-a',
    }, execFor(surface.agent))
    assert.equal(result.ok, true, result.stderr)
    assert.equal(result.exit_code, 0)
    assert.match(result.stdout, /session=agent-a token=1/)
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run exports the holding session when the caller passes its token', async () => {
  const home = makeHome({ scripts: { 'fm-send.sh': GUARDED_SEND_SCRIPT } })
  writeFileSync(join(home, 'config', 'dsh-native-lease'), 'on\n')
  writeFileSync(join(home, 'config', 'native-plugin-dir'), `${PLUGIN_DIR}\n`)
  try {
    const surface = await boot({ home })
    const leaseTool = toolNamed(surface.tools, 'firstmate_native_lease')
    const acquired = await leaseTool.execute({ action: 'acquire', task: 'task-a' }, execFor(surface.agent))
    const result = await toolNamed(surface.tools, 'firstmate_native_run').execute({
      script: 'fm-send.sh',
      args: ['task-a'],
      task: 'task-a',
      token: acquired.token,
    }, execFor(surface.agent))
    assert.equal(result.ok, true, result.stderr)
    assert.equal(result.exit_code, 0)
    assert.match(result.stdout, /session=agent-a token=1/)
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'held')
    await leaseTool.execute({ action: 'release', task: 'task-a', token: acquired.token }, execFor(surface.agent))
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run with a held token leaves the caller lease in place', async () => {
  const home = makeHome({ scripts: { 'fm-send.sh': SEND_SCRIPT } })
  try {
    const surface = await boot({ home })
    const leaseTool = toolNamed(surface.tools, 'firstmate_native_lease')
    const acquired = await leaseTool.execute({ action: 'acquire', task: 'task-a' }, execFor(surface.agent))
    const result = await toolNamed(surface.tools, 'firstmate_native_run').execute({
      script: 'fm-send.sh',
      task: 'task-a',
      token: acquired.token,
    }, execFor(surface.agent))
    assert.equal(result.ok, true)
    assert.match(result.stdout, /token=1/)
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'held')
    await leaseTool.execute({ action: 'release', task: 'task-a', token: acquired.token }, execFor(surface.agent))
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'free')
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run refuses a stale token', async () => {
  const home = makeHome({ scripts: { 'fm-send.sh': SEND_SCRIPT } })
  try {
    const surface = await boot({ home })
    await toolNamed(surface.tools, 'firstmate_native_lease').execute({ action: 'acquire', task: 'task-a' }, execFor(surface.agent))
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_run').execute({ script: 'fm-send.sh', task: 'task-a', token: 99 }, execFor(surface.agent)),
      /fenced:/,
    )
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run refuses the session-lifecycle scripts', async () => {
  const home = makeHome()
  try {
    const surface = await boot({ home })
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_run').execute({ script: 'fm-watch.sh' }, execFor(surface.agent)),
      /owned by the plugin/,
    )
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_run').execute({ script: '../evil.sh' }, execFor(surface.agent)),
      /one bare bin\/fm-\*\.sh file name/,
    )
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_run reports a failing mutating script faithfully and still releases', async () => {
  const home = makeHome({ scripts: { 'fm-fail.sh': `printf 'boom\\n' >&2\nexit 7\n` } })
  try {
    const surface = await boot({ home })
    const result = await toolNamed(surface.tools, 'firstmate_native_run').execute({ script: 'fm-fail.sh', task: 'task-a' }, execFor(surface.agent))
    assert.equal(result.ok, false)
    assert.equal(result.exit_code, 7)
    assert.match(result.stderr, /boom/)
    assert.equal(inspectLease({ home, task: 'task-a' }).record.state, 'free')
  } finally {
    cleanup(home)
  }
})


// --- Phases 3 and 4: reconciliation and native start -----------------------

/** A minimal observed snapshot for the loop tools. */
const LOOP_SNAPSHOT = {
  schema: 'fm-fleet-snapshot.v1',
  backlog: { records: [{ id: 'fm-a', state: 'queued', kind: 'ship', title: 'A', unresolved_blocker_ids: [] }], tasks: [] },
  tasks: [],
}

test('firstmate_native_reconcile reports a dry run and applies an authored rule', async () => {
  const home = makeHome({ scripts: {
    'fm-fleet-snapshot.sh': `cat "$FM_HOME/snapshot.json"\n`,
    'fm-spawn.sh': `printf '%s|%s\\n' "\${FM_LEASE_TOKEN:-}" "$*" >> "$FM_HOME/state/spawn.log"\n`,
  } })
  try {
    writeFileSync(join(home, 'snapshot.json'), JSON.stringify(LOOP_SNAPSHOT))
    writeFileSync(join(home, 'config', 'native-loop.json'), JSON.stringify({
      rules: [{ id: 'dispatch', when: 'queued', script: 'fm-spawn.sh', vars: { project: 'demo' }, args: ['{id}', '{project}'] }],
    }))
    const surface = await boot({ home })
    const tool = toolNamed(surface.tools, 'firstmate_native_reconcile')
    const dry = await tool.execute({}, execFor(surface.agent))
    assert.equal(dry.schema, 'fm-native-loop.v1')
    assert.equal(dry.actions[0].outcome, 'planned')
    assert.equal(existsSync(join(home, 'state', 'spawn.log')), false)
    const applied = await tool.execute({ apply: true }, execFor(surface.agent))
    assert.equal(applied.actions[0].outcome, 'acted')
    assert.match(readFileSync(join(home, 'state', 'spawn.log'), 'utf8').trim(), /^1\|fm-a demo$/)
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_start composes the digest without the fleet lock', async () => {
  const home = makeHome({ scripts: {
    'fm-fleet-snapshot.sh': `cat "$FM_HOME/snapshot.json"\n`,
    'fm-inbox.sh': `printf '{"lock":"free","posture":"present"}\n'\n`,
  } })
  try {
    writeFileSync(join(home, 'snapshot.json'), JSON.stringify(LOOP_SNAPSHOT))
    writeFileSync(join(home, 'state', '.wake-queue'), 'row-one\nrow-two\n')
    const surface = await boot({ home })
    const lease = await toolNamed(surface.tools, 'firstmate_native_lease').execute(
      { action: 'acquire', task: 'fm-a', purpose: 'native start check' },
      execFor(surface.agent),
    )
    const digest = await toolNamed(surface.tools, 'firstmate_native_start').execute({}, execFor(surface.agent))
    assert.equal(digest.ok, true)
    assert.equal(digest.identity.home, home)
    assert.equal(digest.summary.backlog.queued, 1)
    assert.equal(digest.leases.held, 1)
    assert.equal(digest.leases.rows[0].task, 'fm-a')
    assert.equal(digest.wake_queue.queued, 2)
    assert.equal(existsSync(join(home, 'state', '.lock')), false)
    await toolNamed(surface.tools, 'firstmate_native_lease').execute(
      { action: 'release', task: 'fm-a', token: lease.token },
      execFor(surface.agent),
    )
  } finally {
    cleanup(home)
  }
})


// --- Per-PR delivery decisions ---------------------------------------------

/** Fake delivery CLI that echoes a decision and records writes. */
const DELIVERY_SCRIPT = `#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$FM_HOME/state/delivery.log"
case "$1" in
  resolve) printf 'mode=no-mistakes\nyolo=on\ndelivery_source=pr\nyolo_source=pr\ntask=fm-a\npr=\nshadowed=\nreason=\\n' ;;
  list) printf 'task-fm-a delivery=no-mistakes yolo=inherit task=fm-a pr=\\n' ;;
  *) printf 'recorded\\n' ;;
esac
`

test('firstmate_native_delivery resolves, writes, and lists decisions', async () => {
  const home = makeHome({ scripts: { 'fm-delivery.sh': DELIVERY_SCRIPT } })
  try {
    const surface = await boot({ home })
    const tool = toolNamed(surface.tools, 'firstmate_native_delivery')
    const resolved = await tool.execute({ action: 'resolve', task: 'fm-a', project: 'demo' }, execFor(surface.agent))
    assert.equal(resolved.ok, true)
    assert.equal(resolved.fields.mode, 'no-mistakes')
    assert.equal(resolved.fields.delivery_source, 'pr')
    const set = await tool.execute({
      action: 'set', task: 'fm-a', mode: 'no-mistakes', yolo: 'off', reason: 'gate it',
    }, execFor(surface.agent))
    assert.equal(set.ok, true)
    const log = readFileSync(join(home, 'state', 'delivery.log'), 'utf8')
    assert.match(log, /set --task fm-a --mode no-mistakes --yolo off --reason gate it/)
    const listed = await tool.execute({ action: 'list' }, execFor(surface.agent))
    assert.equal(listed.ok, true)
    assert.match(listed.text, /task-fm-a delivery=no-mistakes/)
    // A task write is a task mutation, so it released the lease it took.
    assert.deepEqual(listLeases({ home }).filter((lease) => lease.live), [])
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_delivery validates its arguments', async () => {
  const home = makeHome({ scripts: { 'fm-delivery.sh': DELIVERY_SCRIPT } })
  try {
    const surface = await boot({ home })
    const tool = toolNamed(surface.tools, 'firstmate_native_delivery')
    await assert.rejects(tool.execute({ action: 'resolve' }, execFor(surface.agent)), /task or pr is required/)
    await assert.rejects(tool.execute({ action: 'set', task: 'fm-a' }, execFor(surface.agent)), /mode is required/)
    await assert.rejects(
      tool.execute({ action: 'set', task: 'fm-a', mode: 'no-mistakes', yolo: 'maybe' }, execFor(surface.agent)),
      /yolo must be on, off, or inherit/,
    )
  } finally {
    cleanup(home)
  }
})

test('firstmate_native_delivery refuses a task write another session holds', async () => {
  const home = makeHome({ scripts: { 'fm-delivery.sh': DELIVERY_SCRIPT } })
  try {
    acquireLease({ home, task: 'fm-a', identity: makeIdentity(home, 'other-session') })
    const surface = await boot({ home })
    await assert.rejects(
      toolNamed(surface.tools, 'firstmate_native_delivery').execute(
        { action: 'set', task: 'fm-a', mode: 'no-mistakes' },
        execFor(surface.agent),
      ),
      /contention:/,
    )
  } finally {
    cleanup(home)
  }
})
