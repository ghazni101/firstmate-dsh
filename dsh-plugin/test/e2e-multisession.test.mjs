/**
 * Two-session supervision end to end, composed with real DSH objects.
 *
 * Unlike engine.test.mjs (synthetic agents and a stub subagent service) and
 * e2e-native.test.mjs (lease/guard chain without a DSH session), this test uses
 * the installed DSH runtime's real Session objects for both interactive
 * parents and the real in-process fork provider for the child seed. The
 * subagent manager's catalog write and the coordinator's model turn are the
 * only test-owned seams; the live guard in
 * tests/fm-dsh-multisession-coordinator-live-e2e.test.sh covers them against a
 * real DSH Host over the API the GUI uses.
 *
 * Every write stays in a throwaway Firstmate home. No network, no live fleet.
 */
import assert from 'node:assert/strict'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'

import { apply } from '../index.js'
import { EngineHost } from '../src/engine.js'
import {
  ENGINE_AGENT_NAME,
  ENGINE_PROVIDER,
  readEngineInbox,
  readEngineRecord,
  readEscalations,
} from '../src/engine-records.js'
import { acquireLease, listLeases } from '../src/lease.js'
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
import { findDshRuntime, importDsh } from './dsh-runtime.mjs'

const runtime = findDshRuntime()
let Session = null
let forkProvider = null
if (runtime !== null) {
  const sessionModule = await importDsh(runtime, '@deepseek-ai/dsh-session')
  const forkModule = await importDsh(runtime, '@deepseek-ai/dsh-subagent-fork-in-process')
  Session = sessionModule.Session
  let captured = null
  forkModule.apply({ subagents: { registerProvider(provider) { captured = provider } } }, { providerName: ENGINE_PROVIDER })
  forkProvider = captured
}

/** One log-only/event-shaped entry, kept deliberately minimal. */
function event(seq, type, data) {
  return { seq, time: 1000 + seq, type, data }
}

/**
 * Build a real DSH Session whose last turn is still in flight.
 * @param id - session id.
 * @param home - fixture home.
 * @returns the real Session.
 */
function parentSession(id, home) {
  const events = [
    event(0, 'turn/start', { turn: 1 }),
    event(1, 'turn/end', { turn: 1, reason: 'completed' }),
    event(2, 'turn/start', { turn: 2 }),
  ]
  return Session.create(id, events, { version: 4, id, createdAt: 1, isSeeded: false, cwd: home })
}

/**
 * Build a parent agent backed by a real DSH Session.
 * @param options - fixture inputs.
 * @returns the agent.
 */
function parentAgent({ home, id }) {
  const { agent } = makeAgent({ id, cwd: home, header: { id } })
  agent.session = parentSession(id, home)
  return agent
}

/**
 * Build a coordinator subagent service that uses the real fork provider for
 * the seed and records the catalog entry a real manager would append.
 * @param home - fixture home.
 * @returns the service plus its observations.
 */
function makeSubagents(home) {
  const activations = []
  const catalog = new Map()
  const sends = []
  const subagents = {
    async startActivation(spec) {
      const seed = await forkProvider.prepareContinuable({ parent: spec.parent })
      const child = Session.create(
        spec.childId,
        seed.seed ?? [],
        { version: 4, id: spec.childId, createdAt: 1, isSeeded: true, cwd: home, origin: 'subagent', parentSession: spec.parent.id, delegationDepth: 1 },
        seed.seed?.length ?? 0,
      )
      const activation = {
        spec,
        seed,
        child,
        disposed: 0,
        result: Promise.withResolvers().promise,
        async dispose() { this.disposed += 1 },
      }
      activations.push(activation)
      if (!catalog.has(spec.parent.id)) catalog.set(spec.parent.id, [])
      catalog.get(spec.parent.id).push({ name: spec.name, childId: spec.childId, provider: spec.provider })
      return { childId: spec.childId, name: spec.name, messageId: `msg-${activations.length}`, result: activation.result, async dispose() { await activation.dispose() } }
    },
    async sendMessage(sender, targetId, content) {
      sends.push({ sender, targetId, content })
      return `send-${sends.length}`
    },
  }
  return { subagents, activations, catalog, sends }
}

/**
 * Build the plugin-owned agent registry that wakes a coordinator.
 * @returns the registry plus its observations.
 */
function makeAgents() {
  const resumed = []
  const messages = []
  const agents = {
    async resume(options) {
      const handle = {
        agent: { id: options.resumeSessionId, steer(message) { messages.push(message) } },
        disposed: 0,
        async dispose() { this.disposed += 1 },
      }
      resumed.push(options)
      return handle
    },
  }
  return { agents, resumed, messages }
}

/**
 * Create one engine fixture home with a snapshot reader.
 * @returns the home path.
 */
function engineHome() {
  const home = makeHome({
    scripts: { 'fm-fleet-snapshot.sh': 'cat "$FM_HOME/snapshot.json"\n' },
  })
  writeFileSync(join(home, 'config', 'dsh-engine'), 'on\n')
  writeFileSync(join(home, 'config', 'crew-dispatch.json'), JSON.stringify({
    default: { harness: 'omp', model: 'opencode-go/deepseek-v4.1-flash', provider: 'opencode-go', effort: 'low' },
  }))
  writeFileSync(join(home, 'snapshot.json'), JSON.stringify({ schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: [] }))
  return home
}

/** One routine task owned by a session. */
function routineTask(id, owner) {
  return {
    id, owner_session: owner, kind: 'ship', current_state: { state: 'working' },
    paths: { status_log: { last_event: { state: 'working', raw: 'working [at=1]: reviewing' } } },
    hints: { pending_decision: false, blocked_event: false, open_decisions: [] },
    pr: { url: null }, backlog: { captain_actionable: false, hold_bucket: null },
  }
}
/** Return one routine task with a fresh ordinary progress line. */
function progressed(task) {
  return { ...task, paths: { status_log: { last_event: { state: 'working', raw: 'working [at=2]: still reviewing' } } } }
}


/**
 * Write the current fleet snapshot.
 * @param home - fixture home.
 * @param tasks - task records.
 */
function setSnapshot(home, tasks) {
  writeFileSync(join(home, 'snapshot.json'), JSON.stringify({ schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks }))
}
/**
 * Run one tick through a fresh host, as the plugin's interval would.
 * @param options - host inputs.
 * @returns the tick report.
 */
function tick({ home, parent, identity, services }) {
  const host = new EngineHost({ home, parentAgent: parent, identity, ...services, tickMs: 0 })
  return host.tick()
}

const options = runtime === null ? { skip: 'installed DSH runtime unavailable' } : {}

test('two real sessions keep one coordinator each, isolated traffic, and one lease winner', options, async (t) => {
  const home = engineHome()
  const taskA = routineTask('task-a', 'parent-a')
  const taskB = routineTask('task-b', 'parent-b')
  setSnapshot(home, [taskA, taskB, routineTask('foreign', 'parent-b'), routineTask('unowned-routine', null)])
  t.after(() => cleanup(home))
  const services = makeSubagents(home)
  const registry = makeAgents()
  services.agents = registry.agents
  const context = makeContext({ services: { subagents: services.subagents, agents: registry.agents } })
  apply(context.ctx, { enabled: true, home, engineTickMs: 0 })
  const a = parentAgent({ home, id: 'parent-a' })
  const b = parentAgent({ home, id: 'parent-b' })
  await emit(context.listeners, 'agent/created', { agent: a, source: 'startup' })
  await emit(context.listeners, 'agent/created', { agent: b, source: 'startup' })
  const hostA = new EngineHost({ home, parentAgent: a, identity: makeIdentity(home, 'parent-a'), ...services, tickMs: 0 })
  const hostB = new EngineHost({ home, parentAgent: b, identity: makeIdentity(home, 'parent-b'), ...services, tickMs: 0 })

  const lease = toolNamed(context.tools ?? context.ctx.tools, 'firstmate_native_lease')
  assert.ok(lease, 'the lease tool is registered')

  // 1. Fork lineage and seed. A lease claim is the lazy trigger; the fork must
  //    reuse the completed-turn prefix, not the in-flight second turn.
  await lease.execute({ action: 'acquire', task: 'task-a', purpose: 'dispatch' }, execFor(a))
  await lease.execute({ action: 'acquire', task: 'task-b', purpose: 'dispatch' }, execFor(b))
  let recordA = null
  let recordB = null
  for (let attempt = 0; attempt < 100 && (recordA === null || recordB === null); attempt += 1) {
    await hostA.tick()
    await hostB.tick()
    recordA = readEngineRecord({ home, parentSession: 'parent-a' })
    recordB = readEngineRecord({ home, parentSession: 'parent-b' })
  }
  assert.notEqual(recordA, null)
  assert.notEqual(recordB, null)
  assert.notEqual(recordA.engine_session, recordB.engine_session)
  assert.equal(services.activations.length, 2)
  assert.equal(services.catalog.get('parent-a').length, 1)
  assert.equal(services.catalog.get('parent-b').length, 1)
  assert.deepEqual(services.catalog.get('parent-a')[0], {
    name: ENGINE_AGENT_NAME, childId: recordA.engine_session, provider: ENGINE_PROVIDER,
  })
  const seedA = services.activations.find((item) => item.spec.childId === recordA.engine_session).seed.seed
  assert.deepEqual(seedA.map((entry) => entry.type), ['turn/start', 'turn/end'])
  assert.equal(seedA.at(-1).seq, a.session.snapshotEvents().findLast((entry) => entry.type === 'turn/end').seq)

  // 2. Routine isolation. Each inbox batch carries only its own session's
  //    task, and no settlement or chat message lands in either parent.
  setSnapshot(home, [progressed(taskA), progressed(taskB), routineTask('foreign', 'parent-b'), routineTask('unowned-routine', null)])
  const eventsA = a.session.snapshotEvents().map((entry) => `${entry.seq}:${entry.type}`)
  const eventsB = b.session.snapshotEvents().map((entry) => `${entry.seq}:${entry.type}`)
  await hostA.tick()
  await hostB.tick()
  const batchA = readEngineInbox({ home, parentSession: 'parent-a' }).records.filter((row) => Array.isArray(row.items)).at(-1)
  const batchB = readEngineInbox({ home, parentSession: 'parent-b' }).records.filter((row) => Array.isArray(row.items)).at(-1)
  assert.deepEqual(batchA.items.map((item) => item.id), ['task-a'])
  assert.deepEqual(batchB.items.map((item) => item.id), ['task-b'])
  assert.deepEqual(a.session.snapshotEvents().map((entry) => `${entry.seq}:${entry.type}`), eventsA)
  assert.deepEqual(b.session.snapshotEvents().map((entry) => `${entry.seq}:${entry.type}`), eventsB)
  assert.equal(services.sends.length, 0)
  assert.equal(a.followups.length, 0)
  assert.equal(b.followups.length, 0)

  // 3. Escalation. One captain-class outcome reaches only its own parent.
  const escalate = toolNamed(context.tools ?? context.ctx.tools, 'firstmate_native_escalate')
  const engineA = makeAgent({ id: recordA.engine_session, cwd: home, header: { origin: 'subagent', delegationDepth: 1, parentSession: 'parent-a' } }).agent
  await emit(context.listeners, 'agent/created', { agent: engineA, source: 'startup' })
  const escalated = await escalate.execute({ outcome: 'A real blocker needs the captain.', task: 'owned-a' }, execFor(engineA))
  assert.equal(escalated.delivered, true)
  assert.equal(readEscalations({ home, parentSession: 'parent-a' }).records.length, 1)
  assert.equal(readEscalations({ home, parentSession: 'parent-b' }).records.length, 0)
  assert.equal(services.sends.length, 1)
  assert.equal(services.sends[0].targetId, 'parent-a')
  assert.match(services.sends[0].content[0].text, /escalation/)

  // 4. Contention. Both coordinators claim one shared task; one wins.
  const identityA = { home, sessionId: 'parent-a', ownerLabel: 'dsh:parent-a' }
  const identityB = { home, sessionId: 'parent-b', ownerLabel: 'dsh:parent-b' }
  const winner = acquireLease({ home, task: 'shared', identity: identityA, purpose: 'dispatch' })
  let refusal = null
  try {
    acquireLease({ home, task: 'shared', identity: identityB, purpose: 'dispatch' })
  } catch (error) {
    refusal = error
  }
  assert.ok(winner.token >= 1)
  assert.equal(refusal?.code, 'contention')
  assert.equal(listLeases({ home }).filter((row) => row.task === 'shared' && row.state === 'held' && row.live).length, 1)

  // 5. Lifecycle. Closing one parent releases only its own lease and
  //    coordinator; a resumed parent forks fresh from its completed turns.
  await hostA.close({ terminal: true, reason: 'parent-ended' })
  assert.equal(readEngineRecord({ home, parentSession: 'parent-a' }).status, 'closed')
  assert.equal(readEngineRecord({ home, parentSession: 'parent-b' }).status, 'live')
  assert.equal(services.activations.find((item) => item.spec.childId === recordA.engine_session).disposed, 1)
  assert.equal(services.activations.find((item) => item.spec.childId === recordB.engine_session).disposed, 0)
  assert.equal(listLeases({ home }).some((row) => row.task === 'task-a' && row.state === 'held' && row.live), false)
  assert.equal(listLeases({ home }).some((row) => row.task === 'task-b' && row.state === 'held' && row.live), true)

  const resumed = parentAgent({ home, id: 'parent-a' })
  const beforeResume = recordA.engine_session
  await tick({ home, parent: resumed, identity: makeIdentity(home, 'parent-a'), services })
  const fresh = readEngineRecord({ home, parentSession: 'parent-a' })
  assert.notEqual(fresh.engine_session, beforeResume)
  assert.deepEqual(services.activations.at(-1).seed.seed.map((entry) => entry.type), ['turn/start', 'turn/end'])

  const resumesBefore = registry.resumed.length
  const batchesBefore = readEngineInbox({ home, parentSession: 'parent-b' }).records.length
  const quiet = await tick({ home, parent: b, identity: makeIdentity(home, 'parent-b'), services })
  assert.equal(quiet.quiet, true)
  assert.equal(registry.resumed.length, resumesBefore)
  assert.equal(readEngineInbox({ home, parentSession: 'parent-b' }).records.length, batchesBefore)

  // 6. Cleanup. No fleet-wide lock, and nothing was written outside the home.
  assert.equal(existsSync(join(home, 'state', '.lock')), false)
  assert.equal(readFileSync(join(home, 'config', 'dsh-engine'), 'utf8').trim(), 'on')
})
