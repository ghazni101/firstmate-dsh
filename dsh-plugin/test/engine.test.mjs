/**
 * Supervision-engine mechanism tests: fork seeding, engine tool gating,
 * escalation delivery and recovery, deduplication, two-engine contention,
 * crash recreation, parent-end close, and model-free quiet ticks.
 *
 * Every fixture is a throwaway home with fake scripts and a fake subagent
 * service, so no live fleet, DSH process, or model call is involved.
 */
import assert from 'node:assert/strict'
import { readFileSync, rmSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'

import { apply } from '../index.js'
import { EngineHost } from '../src/engine.js'
import {
  completedTurnBoundary,
  completedTurnPrefix,
  diffFleetEvents,
  engineEscalationPath,
  observeFleetEvents,
  readEngineInbox,
  readEngineRecord,
  readEscalations,
  recordEscalation,
  writeEngineRecord,
} from '../src/engine-records.js'
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

/** A task that is merely working. */
const ROUTINE_TASK = {
  id: 'task-a',
  kind: 'ship',
  current_state: { state: 'working' },
  paths: { status_log: { last_event: { state: 'working', raw: 'working [at=1]: reviewing' } } },
  hints: { pending_decision: false, blocked_event: false, open_decisions: [] },
  pr: { url: null },
  backlog: { captain_actionable: false, hold_bucket: null },
}

/** A task whose reader already classified a live pending decision. */
const CAPTAIN_TASK = {
  ...ROUTINE_TASK,
  id: 'task-b',
  hints: { pending_decision: true, blocked_event: false, open_decisions: ['scope'] },
}

const ROUTINE_SNAPSHOT = { schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: [ROUTINE_TASK] }
const CAPTAIN_SNAPSHOT = { schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: [CAPTAIN_TASK] }
const EMPTY_SNAPSHOT = { schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: [] }

/**
 * Create a home fixture with a snapshot reader and an engine opt-in.
 * @param options - fixture options.
 * @returns the home path.
 */
function engineHome({
  snapshot = ROUTINE_SNAPSHOT,
  dispatch = { default: { harness: 'omp', model: 'opencode-go/deepseek-v4.1-flash', provider: 'opencode-go', effort: 'high' } },
  engine = true,
} = {}) {
  const home = makeHome({
    scripts: {
      'fm-fleet-snapshot.sh': `cat "$FM_HOME/snapshot.json"\n`,
      'fm-bearings-snapshot.sh': `printf '{"home":"%s"}\\n' "$FM_HOME"\n`,
    },
  })
  writeFileSync(join(home, 'snapshot.json'), JSON.stringify(snapshot))
  if (dispatch !== null) writeFileSync(join(home, 'config', 'crew-dispatch.json'), JSON.stringify(dispatch))
  if (engine) writeFileSync(join(home, 'config', 'dsh-engine'), 'on\n')
  return home
}

/**
 * Build a fake interactive session agent with a controllable event log.
 * @param options - agent options.
 * @returns the fake agent.
 */
function rootAgent({ home, id = 'parent-a', events = [{ seq: 0, type: 'turn/start' }, { seq: 1, type: 'turn/end' }] } = {}) {
  const { agent } = makeAgent({ id, cwd: home, header: { id } })
  agent.session.snapshotEvents = () => events
  return agent
}

/**
 * Build a fake subagent service.
 * @param options - failure injection.
 * @returns controls plus the service object.
 */
function makeSubagents({ failSends = 0 } = {}) {
  const activations = []
  const specs = []
  const sends = []
  let failures = failSends
  const subagents = {
    async startActivation(spec) {
      const settled = Promise.withResolvers()
      const control = {
        childId: spec.childId,
        spec,
        result: settled.promise,
        disposed: 0,
        fail(stopReason = 'error') {
          settled.resolve({ output: [], stopReason })
        },
        complete() {
          settled.resolve({ output: [], stopReason: 'completed' })
        },
      }
      activations.push(control)
      specs.push(spec)
      return {
        childId: spec.childId,
        name: spec.childId,
        messageId: `msg-${activations.length}`,
        result: settled.promise,
        async dispose() {
          control.disposed += 1
          settled.resolve({ output: [], stopReason: 'aborted' })
        },
      }
    },
    async sendMessage(sender, targetId, content, options) {
      sends.push({ sender, targetId, content, options })
      if (failures > 0) {
        failures -= 1
        throw Object.assign(new Error('subagent is not resumable'), { code: 'NOT_RESUMABLE' })
      }
      return `send-${sends.length}`
    },
  }
  return { subagents, activations, specs, sends }
}

/**
 * Flush pending microtasks and timers.
 * @returns a promise resolved after one turn.
 */
function flush() {
  return new Promise((resolve) => setImmediate(resolve))
}

/**
 * Write one live engine record.
 * @param options - record options.
 * @returns the written record.
 */
function seedEngineRecord({ home, parent = 'parent-a', engine = 'engine-a', status = 'live' } = {}) {
  return writeEngineRecord({
    home,
    parentSession: parent,
    record: {
      parent_session: parent,
      home,
      engine_session: engine,
      status,
      subagent_provider: 'fork',
      label: 'firstmate-engine',
      owner_pid: process.pid,
      owner_started: null,
      crashes: 0,
      seen: {},
    },
  })
}

/**
 * Build one engine agent whose lineage matches the seeded record.
 * @param options - agent options.
 * @returns the fake engine agent.
 */
function engineAgent({ home, parent = 'parent-a', id = 'engine-a' } = {}) {
  const { agent } = makeAgent({
    id,
    cwd: home,
    header: { origin: 'subagent', delegationDepth: 1, parentSession: parent },
  })
  return agent
}

/**
 * Boot the plugin against one fixture home.
 * @param options - boot options.
 * @returns the booted surface.
 */
async function boot({ home, subagents, engineTickMs = 0 } = {}) {
  const context = makeContext({ services: subagents === undefined ? {} : { subagents } })
  apply(context.ctx, { enabled: true, home, engineTickMs })
  const parent = rootAgent({ home })
  await emit(context.listeners, 'agent/created', { agent: parent, source: 'startup' })
  return { ...context, parent }
}

/**
 * Build one EngineHost fixture.
 * @returns host plus fixtures.
 */
function hostFixture({ home, fake, parent, id = 'parent-a' }) {
  const identity = makeIdentity(home, id)
  const host = new EngineHost({
    home,
    parentAgent: parent,
    identity,
    subagents: fake.subagents,
    tickMs: 0,
  })
  return { host, identity }
}

test('the fork seed boundary is the last completed turn, never the in-flight one', () => {
  const events = [
    { seq: 0, type: 'turn/start' },
    { seq: 1, type: 'message' },
    { seq: 2, type: 'turn/end' },
    { seq: 3, type: 'turn/start' },
    { seq: 4, type: 'message' },
  ]
  assert.equal(completedTurnBoundary(events), 2)
  assert.deepEqual(completedTurnPrefix(events).map((event) => event.seq), [0, 1, 2])
  assert.equal(completedTurnBoundary([{ seq: 0, type: 'turn/start' }]), null)
  assert.deepEqual(completedTurnPrefix([{ seq: 0, type: 'turn/start' }]), [])
})

test('engine creation forks the completed-turn prefix with the dispatch default', async () => {
  const home = engineHome()
  try {
    const fake = makeSubagents()
    const parent = rootAgent({ home, events: [{ seq: 0, type: 'turn/start' }] })
    const { host } = hostFixture({ home, fake, parent })

    const deferred = await host.tick()
    assert.equal(deferred.skipped, 'awaiting-completed-turn')
    assert.equal(fake.activations.length, 0, 'no fork before a completed turn')

    parent.session.snapshotEvents = () => [{ seq: 0, type: 'turn/start' }, { seq: 1, type: 'turn/end' }]
    const created = await host.tick()
    assert.equal(created.created, true)
    assert.equal(fake.activations.length, 1)
    const spec = fake.specs[0]
    assert.equal(spec.provider, 'fork')
    assert.equal(spec.parent, parent)
    assert.equal(spec.delivery, 'caller')
    assert.equal(spec.label, 'firstmate-engine')
    assert.equal(spec.childId, created.engine_session)
    assert.equal(spec.agentOptions.provider, 'opencode-go')
    assert.equal(spec.agentOptions.model, 'deepseek-v4.1-flash')
    assert.equal(spec.agentOptions.reasoningEffort, 'high')
    assert.match(spec.prompt[0].text, /firstmate_native_engine_inbox/)
    assert.match(spec.prompt[0].text, /Never address the captain/)

    const record = readEngineRecord({ home, parentSession: 'parent-a' })
    assert.equal(record.status, 'live')
    assert.equal(record.engine_session, created.engine_session)
    assert.equal(record.seed_boundary, 1)

    const inbox = readEngineInbox({ home, parentSession: 'parent-a' }).records
    assert.equal(inbox.length, 1)
    assert.equal(inbox[0].class, 'routine')
    assert.equal(inbox[0].items[0].id, 'task-a')
    assert.equal(typeof inbox[0].delivered_at, 'number')
  } finally {
    cleanup(home)
  }
})

test('a quiet fleet with no engine creates nothing', async () => {
  const home = engineHome({ snapshot: EMPTY_SNAPSHOT })
  try {
    const fake = makeSubagents()
    const parent = rootAgent({ home })
    const { host } = hostFixture({ home, fake, parent })
    const report = await host.tick()
    assert.equal(report.quiet, true)
    assert.equal(report.idle, true)
    assert.equal(fake.activations.length, 0)
    assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }), null)
  } finally {
    cleanup(home)
  }
})

test('fleet snapshots classify captain events without a second policy', () => {
  const events = observeFleetEvents(CAPTAIN_SNAPSHOT)
  const event = events.get('task-b')
  assert.equal(event.class, 'captain')
  assert.deepEqual(event.open_decisions, ['scope'])
  const changed = diffFleetEvents({ seen: {}, events })
  assert.equal(changed.length, 1)
  assert.equal(changed[0].class, 'captain')
  const stable = diffFleetEvents({ seen: { 'task-b': event.signature }, events })
  assert.deepEqual(stable, [])
})

test('engine tool gating: engine allowed, ordinary subagents and root escalate refused', async () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home })
    const surface = await boot({ home })
    const engine = engineAgent({ home })
    const status = toolNamed(surface.tools, 'firstmate_native_status')
    const escalate = toolNamed(surface.tools, 'firstmate_native_escalate')
    const delivery = toolNamed(surface.tools, 'firstmate_native_delivery')

    const result = await status.execute({}, execFor(engine))
    assert.equal(result.ok, true)
    assert.equal(result.tool, 'firstmate_native_status')

    await assert.rejects(delivery.execute({ action: 'list' }, execFor(engine)), /not part of the supervision engine surface/)
    await assert.rejects(escalate.execute({ outcome: 'done' }, execFor(surface.parent)), /not available to the interactive session/)

    const ordinary = makeAgent({
      id: 'ordinary-child',
      cwd: home,
      header: { origin: 'subagent', delegationDepth: 1, parentSession: 'parent-a' },
    }).agent
    await assert.rejects(status.execute({}, execFor(ordinary)), /not a Firstmate supervisor session/)

    rmSync(join(home, 'config', 'dsh-engine'))
    await assert.rejects(status.execute({}, execFor(engine)), /not a Firstmate supervisor session/)
  } finally {
    cleanup(home)
  }
})

test('an engine escalation is delivered and recorded durably', async () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home })
    const fake = makeSubagents()
    const surface = await boot({ home, subagents: fake.subagents })
    const engine = engineAgent({ home })
    const escalate = toolNamed(surface.tools, 'firstmate_native_escalate')

    const result = await escalate.execute({ outcome: 'Task task-a is ready for review.', task: 'task-a' }, execFor(engine))
    assert.equal(result.ok, true)
    assert.equal(result.delivered, true)
    assert.equal(result.duplicate, false)
    assert.equal(fake.sends.length, 1)
    assert.equal(fake.sends[0].sender, engine)
    assert.equal(fake.sends[0].targetId, 'parent-a')
    assert.match(fake.sends[0].content[0].text, /firstmate engine escalation/)
    assert.match(fake.sends[0].content[0].text, /task-a is ready for review/)

    const records = readEscalations({ home, parentSession: 'parent-a' }).records
    assert.equal(records.length, 1)
    assert.equal(records[0].id, result.id)
    assert.equal(records[0].task, 'task-a')
    assert.equal(typeof records[0].delivered_at, 'number')
    assert.equal(surface.parent.followups.length, 0, 'the parent is only reached through the engine steer')
  } finally {
    cleanup(home)
  }
})

test('a repeated escalation deduplicates and retries a failed delivery', async () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home })
    const fake = makeSubagents({ failSends: 1 })
    const surface = await boot({ home, subagents: fake.subagents })
    const engine = engineAgent({ home })
    const escalate = toolNamed(surface.tools, 'firstmate_native_escalate')

    const first = await escalate.execute({ outcome: 'Merge is blocked on a red check.', task: 'task-a' }, execFor(engine))
    assert.equal(first.delivered, false)
    assert.equal(first.pending, true)
    let records = readEscalations({ home, parentSession: 'parent-a' }).records
    assert.equal(records.length, 1)
    assert.equal(records[0].delivered_at, null)
    assert.equal(records[0].delivery_attempts, 1)

    const second = await escalate.execute({ outcome: 'Merge is blocked on a red check.', task: 'task-a' }, execFor(engine))
    assert.equal(second.duplicate, true)
    assert.equal(second.id, first.id)
    assert.equal(second.delivered, true)
    assert.equal(fake.sends.length, 2, 'the duplicate retried delivery instead of recording again')
    records = readEscalations({ home, parentSession: 'parent-a' }).records
    assert.equal(records.length, 1)
    assert.equal(typeof records[0].delivered_at, 'number')
  } finally {
    cleanup(home)
  }
})

test('two engines in one home contend for one task with exactly one winner', async () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home, parent: 'parent-a', engine: 'engine-a' })
    seedEngineRecord({ home, parent: 'parent-b', engine: 'engine-b' })
    const fake = makeSubagents()
    const surface = await boot({ home, subagents: fake.subagents })
    const engineA = engineAgent({ home, parent: 'parent-a', id: 'engine-a' })
    const engineB = engineAgent({ home, parent: 'parent-b', id: 'engine-b' })
    const lease = toolNamed(surface.tools, 'firstmate_native_lease')
    const escalate = toolNamed(surface.tools, 'firstmate_native_escalate')

    const winner = await lease.execute({ action: 'acquire', task: 'shared', purpose: 'supervise' }, execFor(engineA))
    assert.equal(winner.ok, true)
    assert.equal(winner.token, 1)

    await assert.rejects(
      lease.execute({ action: 'acquire', task: 'shared', purpose: 'supervise' }, execFor(engineB)),
      /contention/,
    )

    const escalation = await escalate.execute({ outcome: 'Only engine-a should see this.' }, execFor(engineB))
    assert.equal(escalation.ok, true)
    assert.equal(fake.sends.at(-1).targetId, 'parent-b', 'an engine only ever escalates into its own parent')

    const recordA = readEngineRecord({ home, parentSession: 'parent-a' })
    const recordB = readEngineRecord({ home, parentSession: 'parent-b' })
    assert.equal(recordA.engine_session, 'engine-a')
    assert.equal(recordB.engine_session, 'engine-b')
  } finally {
    cleanup(home)
  }
})

test('a crashed engine is recreated on the next tick without touching the parent', async () => {
  const home = engineHome()
  try {
    const fake = makeSubagents()
    const parent = rootAgent({ home })
    const { host } = hostFixture({ home, fake, parent })

    const created = await host.tick()
    assert.equal(created.created, true)
    const firstEngine = created.engine_session

    fake.activations[0].fail('error')
    await flush()
    assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }).status, 'crashed')

    const recreated = await host.tick()
    assert.equal(recreated.created, true)
    assert.notEqual(recreated.engine_session, firstEngine)
    assert.equal(fake.activations.length, 2)
    assert.equal(fake.activations[0].disposed, 0, 'a settled engine is not disposed twice')
    const record = readEngineRecord({ home, parentSession: 'parent-a' })
    assert.equal(record.status, 'live')
    assert.equal(record.crashes, 1)
    assert.equal(parent.followups.length, 0, 'the parent is never steered by engine lifecycle')
    assert.equal(fake.sends.length, 0, 'recovery does not message the parent')
  } finally {
    cleanup(home)
  }
})

test('closing an engine marks its record closed and never closes the parent', async () => {
  const home = engineHome()
  try {
    const fake = makeSubagents()
    const parent = rootAgent({ home })
    const { host } = hostFixture({ home, fake, parent })
    await host.tick()
    assert.equal(fake.activations.length, 1)

    await host.close({ terminal: true, reason: 'parent-session-ended' })
    assert.equal(fake.activations[0].disposed, 1)
    assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }).status, 'closed')
    assert.equal(parent.followups.length, 0)
    assert.equal(fake.sends.length, 0)
  } finally {
    cleanup(home)
  }
})

test('a parent-end event closes the engine record through the plugin', async () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home })
    const surface = await boot({ home })
    await emit(surface.listeners, 'agent/disposed', { agent: surface.parent })
    assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }).status, 'closed')
    assert.equal(surface.parent.followups.length, 0)
  } finally {
    cleanup(home)
  }
})

test('a resumed session supersedes its old engine so the next tick forks fresh', async () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home, engine: 'engine-old' })
    const fake = makeSubagents()
    const surface = await boot({ home, subagents: fake.subagents })
    const resumed = rootAgent({ home, id: 'parent-a' })
    await emit(surface.listeners, 'agent/created', { agent: resumed, source: 'resume' })
    assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }).status, 'superseded')
  } finally {
    cleanup(home)
  }
})

test('engine records live beside their escalations and not in the retire machinery', () => {
  const home = engineHome()
  try {
    seedEngineRecord({ home })
    const record = readEngineRecord({ home, parentSession: 'parent-a' })
    assert.match(JSON.stringify(record), /fm-native-engine\.v1/)
    assert.equal(readFileSync(join(home, 'state', 'engines', 'parent-a.json'), 'utf8').length > 0, true)
    assert.match(engineEscalationPath(home, 'parent-a'), /state\/engines\/parent-a\.escalations\.json$/)
  } finally {
    cleanup(home)
  }
})

test('the next tick recovers a lost escalation, then throttles the nudge', async () => {
  const home = engineHome({ snapshot: EMPTY_SNAPSHOT })
  try {
    seedEngineRecord({ home })
    const { record } = recordEscalation({
      home,
      parentSession: 'parent-a',
      engineSession: 'engine-a',
      outcome: 'Captain approval is needed for the merge.',
    })
    const fake = makeSubagents()
    const parent = rootAgent({ home })
    const { host } = hostFixture({ home, fake, parent })

    const recovered = await host.tick()
    assert.equal(recovered.delivered, true)
    assert.equal(recovered.retries, 1)
    assert.equal(fake.sends.length, 1)
    const text = fake.sends[0].content[0].text
    assert.match(text, new RegExp(record.id))
    assert.match(text, /firstmate_native_escalate retry_id=/)
    assert.equal(readEscalations({ home, parentSession: 'parent-a' }).records[0].delivered_at, null, 'the engine delivers, not the tick')

    const quiet = await host.tick()
    assert.equal(quiet.quiet, true, 'the throttle prevents a wake loop')
    assert.equal(fake.sends.length, 1)
  } finally {
    cleanup(home)
  }
})

test('a root lease claim starts supervision and forks on the next tick', async () => {
  const home = engineHome()
  let surface
  try {
    const fake = makeSubagents()
    surface = await boot({ home, subagents: fake.subagents, engineTickMs: 5 })
    assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }), null)
    const lease = toolNamed(surface.tools, 'firstmate_native_lease')
    await lease.execute({ action: 'acquire', task: 'task-a', purpose: 'dispatch' }, execFor(surface.parent))

    let record = null
    for (let attempt = 0; attempt < 200 && record === null; attempt += 1) {
      await new Promise((resolve) => setTimeout(resolve, 5))
      record = readEngineRecord({ home, parentSession: 'parent-a' })
    }
    assert.notEqual(record, null)
    assert.equal(record.status, 'live')
    assert.equal(fake.activations.length, 1)
    assert.equal(fake.activations[0].spec.provider, 'fork')
  } finally {
    for (const dispose of surface?.cleanups ?? []) dispose()
    cleanup(home)
  }
})
