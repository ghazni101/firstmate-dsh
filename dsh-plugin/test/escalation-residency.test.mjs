/**
 * Escalation residency regression.
 *
 * A coordinator's first turn settles, then routine traffic wakes it through
 * the plugin's `agents.resume` as a same-id replacement. DSH's subagent manager
 * refuses that replacement as a `sendMessage` caller (`rootOf`: "agent has no
 * active runtime owner"), so escalation must reach the parent through the
 * objects and the real fork provider, and its subagent seam enforces the same
 * `rootOf` refusal, so the old `sendMessage` delivery cannot pass.
 *
 * Every write stays in a throwaway Firstmate home. No network, no model call.
 */
import assert from 'node:assert/strict'
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { test } from 'node:test'
import { ENGINE_PROVIDER, ESCALATION_TAG, readEngineRecord, readEscalations } from '../src/engine-records.js'
import { apply } from '../index.js'
import { EngineHost } from '../src/engine.js'
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

const options = runtime === null ? { skip: 'installed DSH runtime unavailable' } : {}

/** One completed-turn parent Session, backed by a real DSH Session object. */
function parentAgent(home, id) {
  const session = Session.create(id, [
    { seq: 0, time: 1000, type: 'turn/start', data: {} },
    { seq: 1, time: 1001, type: 'turn/end', data: {} },
  ], { version: 4, id, createdAt: 1, isSeeded: false, cwd: home })
  const { agent } = makeAgent({ id, cwd: home, header: { id } })
  agent.session = session
  return agent
}

/**
 * Build the subagent seam. `sendMessage` enforces DSH's residency rule: only
 * the exact agent of the resident activation may send into a session tree.
 */
function makeSubagents(home) {
  const activations = []
  const sends = []
  let residentAgent = null
  const subagents = {
    async startActivation(spec) {
      const seed = await forkProvider.prepareContinuable({ parent: spec.parent })
      const child = Session.create(
        spec.childId,
        seed.seed ?? [],
        { version: 4, id: spec.childId, createdAt: 1, isSeeded: true, cwd: home, origin: 'subagent', parentSession: spec.parent.id, delegationDepth: 1 },
        seed.seed?.length ?? 0,
      )
      const settled = Promise.withResolvers()
      const resident = makeAgent({
        id: spec.childId,
        cwd: home,
        header: { origin: 'subagent', delegationDepth: 1, parentSession: spec.parent.id },
      }).agent
      residentAgent = resident
      const activation = {
        child,
        resident,
        result: settled.promise,
        complete() { settled.resolve({ output: [], stopReason: 'completed' }) },
      }
      activations.push(activation)
      return {
        childId: spec.childId,
        name: spec.name,
        messageId: `msg-${activations.length}`,
        result: activation.result,
        async dispose() { settled.resolve({ output: [], stopReason: 'aborted' }) },
      }
    },
    async sendMessage(sender, targetId, content) {
      if (sender !== residentAgent) throw new Error('agent has no active runtime owner')
      sends.push({ sender, targetId, content })
    },
  }
  return { subagents, activations, sends }
}

/**
 * Build the plugin-owned agent registry: the live parent resolves through
 * `get`, and `resume` returns a same-id replacement for the coordinator.
 */
function makeAgents({ parent, parentMessages, home }) {
  const live = new Map([[parent.id, {
    id: parent.id,
    steer(message) { parentMessages.push(message) },
  }]])
  const resumed = []
  const agents = {
    get(id) { return live.get(id) },
    async resume(options) {
      resumed.push(options)
      const agent = makeAgent({
        id: options.resumeSessionId,
        cwd: home,
        header: { origin: 'subagent', delegationDepth: 1, parentSession: parent.id },
      }).agent
      agent.steer = () => {}
      return { agent, async dispose() {} }
    },
  }
  return { agents, live, resumed }
}

test('a settled coordinator resumed through agents.resume delivers one tagged escalation to its own parent', options, async (t) => {
  const home = makeHome({ scripts: { 'fm-fleet-snapshot.sh': 'cat "$FM_HOME/snapshot.json"\n' } })
  t.after(() => cleanup(home))
  writeFileSync(join(home, 'config', 'dsh-engine'), 'on\n')
  writeFileSync(join(home, 'config', 'crew-dispatch.json'), JSON.stringify({
    default: { harness: 'omp', model: 'opencode-go/deepseek-v4.1-flash', provider: 'opencode-go', effort: 'low' },
  }))
  writeFileSync(join(home, 'snapshot.json'), JSON.stringify({
    schema: 'fm-fleet-snapshot.v1',
    backlog: { records: [] },
    tasks: [{
      id: 'task-a', owner_session: 'parent-a', kind: 'ship', current_state: { state: 'working' },
      paths: { status_log: { last_event: { state: 'working', raw: 'working [at=1]: reviewing' } } },
      hints: { pending_decision: false, blocked_event: false, open_decisions: [] },
      pr: { url: null }, backlog: { captain_actionable: false, hold_bucket: null },
    }],
  }))

  const parent = parentAgent(home, 'parent-a')
  const parentMessages = []
  const fake = makeSubagents(home)
  const registry = makeAgents({ parent, parentMessages, home })
  const context = makeContext({ services: { subagents: fake.subagents, agents: registry.agents } })
  apply(context.ctx, { enabled: true, home, engineTickMs: 0 })
  await emit(context.listeners, 'agent/created', { agent: parent, source: 'startup' })

  // Create the coordinator through startActivation, then settle its first turn.
  const host = new EngineHost({
    home,
    parentAgent: parent,
    identity: makeIdentity(home, 'parent-a'),
    subagents: fake.subagents,
    agents: registry.agents,
    tickMs: 0,
  })
  const lease = toolNamed(context.tools ?? context.ctx.tools, 'firstmate_native_lease')
  await lease.execute({ action: 'acquire', task: 'task-a', purpose: 'dispatch' }, execFor(parent))
  let record = null
  for (let attempt = 0; attempt < 100; attempt += 1) {
    await host.tick()
    record = readEngineRecord({ home, parentSession: 'parent-a' })
    if (record !== null && typeof record.engine_session === 'string') break
  }
  assert.ok(record !== null && typeof record.engine_session === 'string', 'the coordinator was not created')
  assert.equal(fake.activations.length, 1)
  fake.activations[0].complete()
  const engineSession = record.engine_session

  // The seam really refuses the woken, same-id coordinator as a tree sender.
  const woken = await registry.agents.resume({ resumeSessionId: engineSession })
  await assert.rejects(
    fake.subagents.sendMessage(woken.agent, parent.id, [{ type: 'text', text: 'probe' }]),
    /agent has no active runtime owner/,
  )
  await emit(context.listeners, 'agent/created', { agent: woken.agent, source: 'resume' })

  // Escalate from the woken coordinator. Delivery must reach the live parent
  // through the plugin-owned registry, not through the refused tree sender.
  const escalate = toolNamed(context.tools ?? context.ctx.tools, 'firstmate_native_escalate')
  const result = await escalate.execute(
    { outcome: 'PR is ready for the captain.', task: 'task-a' },
    execFor(woken.agent),
  )
  assert.equal(result.delivered, true)
  assert.equal(fake.sends.length, 0, 'the refused tree sender is never used for delivery')
  assert.equal(parentMessages.length, 1, 'the parent receives exactly one escalation')
  assert.match(parentMessages[0].content[0].text, new RegExp(`\\[${ESCALATION_TAG}\\]`))
  assert.match(parentMessages[0].content[0].text, /PR is ready for the captain/)
  assert.equal(parentMessages[0].source?.kind, 'user', 'no subagent settlement notice is produced')
  const records = readEscalations({ home, parentSession: 'parent-a' }).records
  assert.equal(records.length, 1)
  assert.equal(typeof records[0].delivered_at, 'number')
})
