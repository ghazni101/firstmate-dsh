/**
 * Live DSH Host driver for the two-session coordinator guard.
 *
 * Boots a disposable DSH web Host from a profile copy under a private DSH_HOME
 * and a loopback port, then drives the same Host API the GUI uses
 * (session/create, session/prompt, session/events) through the authenticated
 * /api bridge. All writes stay under a temporary directory. No live profile,
 * live fleet, or operator credential is touched.
 *
 * The coordinator is attached by seeding its durable record for the two real
 * parent sessions before they are created; the plugin then starts its engine
 * on agent creation and the real fork provider creates the child. A
 * credential-free scripted provider is registered inside the disposable plugin
 * copy and emits one `firstmate_native_escalate` tool call for a captain-class
 * traffic batch, so the driver asserts a real coordinator escalation turn:
 * real lineage, real session events, no parent message from routine traffic,
 * and exactly one tagged escalation in the owning parent only.
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, cpSync, writeFileSync, rmSync, realpathSync, chmodSync, mkdtempSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'

import { completedTurnBoundary, readEscalations, recordEscalation, writeEngineRecord } from '../../dsh-plugin/src/engine-records.js'
import { RESTART_OUTCOME } from './fm-dsh-scripted-llm/index.js'

const REPO = fileURLToPath(new URL('../../', import.meta.url)).replace(/\/$/, '')
const PLUGIN = join(REPO, 'dsh-plugin')
const SCRIPTED = join(REPO, 'tests', 'fixtures', 'fm-dsh-scripted-llm')
const ROOT = mkdtempSync(join(tmpdir(), 'fm-dsh-live-'))
const DSH_HOME = join(ROOT, 'dsh-home')
const LAB = join(ROOT, 'lab-home')
const PROFILE = join(DSH_HOME, 'profiles', 'web')
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function note(message) {
  process.stdout.write(`ok - ${message}\n`)
}

/**
 * Copy the web profile, pinning its plugin and default directory to the lab.
 */
function makeProfile() {
  const source = join(homedir(), '.dsh', 'profiles', 'web')
  assert.ok(existsSync(source), `installed DSH web profile missing: ${source}`)
  mkdirSync(dirname(PROFILE), { recursive: true })
  cpSync(source, PROFILE, { recursive: true, dereference: false })
  const pluginLink = join(PROFILE, 'node_modules', '@local', 'dsh-plugin-firstmate-native')
  rmSync(pluginLink, { recursive: true, force: true })
  cpSync(PLUGIN, pluginLink, { recursive: true })
  // Test-only seam: register a credential-free scripted provider inside the
  // disposable plugin copy so a real coordinator turn can call the tool.
  cpSync(join(SCRIPTED, 'index.js'), join(pluginLink, 'scripted-llm.js'))
  const indexPath = join(pluginLink, 'index.js')
  const patched = readFileSync(indexPath, 'utf8')
    .replace("export const inject = ['tools']", "export const inject = ['tools', 'llm']\nimport { apply as registerScripted } from './scripted-llm.js'")
    .replace('export function apply(ctx, config = {}) {', 'export function apply(ctx, config = {}) {\n  registerScripted(ctx)')
  assert.notEqual(patched, readFileSync(indexPath, 'utf8'), 'the disposable plugin must register the scripted provider')
  writeFileSync(indexPath, patched)
  const patch = join(PROFILE, 'cordis.patch.yml')
  const original = readFileSync(patch, 'utf8')
  const rewritten = original
    .replace(/provider: deepseek-account/, 'provider: fm-scripted')
    .replace(/model: deepseek-flash/, 'model: scripted-escalate')
    .replace(/defaultDirectory: .*/, `defaultDirectory: ${LAB}`)
    .replace(/(id: firstmate-native[\s\S]*?enabled: true\n)/, '$1    engineTickMs: 500\n')
  assert.notEqual(rewritten, original, 'the disposable profile must repoint the default directory')
  writeFileSync(patch, rewritten)
}

/**
 * Mint the disposable Firstmate lab home.
 */
function makeLab() {
  mkdirSync(join(LAB, 'bin'), { recursive: true })
  mkdirSync(join(LAB, 'config'), { recursive: true })
  mkdirSync(join(LAB, 'state'), { recursive: true })
  writeFileSync(join(LAB, 'AGENTS.md'), '# disposable live lab home\n')
  for (const name of ['fm-session-start.sh', 'fm-spawn.sh']) {
    const path = join(LAB, 'bin', name)
    writeFileSync(path, '#!/usr/bin/env bash\nexit 0\n')
    chmodSync(path, 0o755)
  }
  for (const name of ['dsh-native', 'dsh-native-lease', 'dsh-engine']) writeFileSync(join(LAB, 'config', name), 'on\n')
  writeFileSync(join(LAB, 'config', 'native-plugin-dir'), `${PLUGIN}\n`)
  writeFileSync(join(LAB, 'config', 'crew-dispatch.json'), JSON.stringify({
    default: { harness: 'omp', model: 'scripted-escalate', provider: 'fm-scripted', effort: 'low' },
  }))
  const snapshot = join(LAB, 'bin', 'fm-fleet-snapshot.sh')
  writeFileSync(snapshot, '#!/usr/bin/env bash\ncat "$FM_HOME/snapshot.json"\n')
  chmodSync(snapshot, 0o755)
  writeFileSync(join(LAB, 'snapshot.json'), JSON.stringify({ schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: [] }))
}

/** Minimal task projection for one owned task. */
function task(id, owner, raw = 'working [at=1]: reviewing') {
  return {
    id, owner_session: owner, kind: 'ship', current_state: { state: 'working' },
    paths: { status_log: { last_event: { state: 'working', raw } } },
    hints: { pending_decision: false, blocked_event: false, open_decisions: [] },
    pr: { url: null }, backlog: { captain_actionable: false, hold_bucket: null },
  }
}

let child
let base
let cookie
let count = 0
let hostStderr = ''
try {
  makeLab()
  makeProfile()

  /** Stop only the disposable Host started by this guard. */
  async function stopHost() {
    const current = child
    if (current === null || current.exitCode !== null || current.signalCode !== null) return
    const exited = new Promise((resolve) => current.once('exit', resolve))
    current.kill('SIGTERM')
    await exited
  }

  /** Start or restart the Host with the same home and rebind its RPC client. */
  async function startHost() {
    child = spawn('dsh', ['--profile', 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'], {
      env: { ...process.env, DSH_HOME }, stdio: ['ignore', 'pipe', 'pipe'],
    })
    let banner = ''
    child.stdout.on('data', (chunk) => { banner += chunk.toString() })
    child.stderr.on('data', (chunk) => {
      hostStderr += chunk.toString()
      process.stderr.write(`[dsh] ${chunk}`)
    })
    let token = null
    base = null
    for (let attempt = 0; attempt < 300; attempt += 1) {
      const match = banner.match(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([^\s]+)/)
      if (match) { base = `http://127.0.0.1:${match[1]}`; token = match[2]; break }
      await sleep(100)
    }
    assert.ok(base && token, `the disposable Host never printed its API URL: ${banner.slice(0, 300)}`)
    const connect = await fetch(`${base}/connect?token=${token}&interactions=answer`, { redirect: 'manual' })
    cookie = connect.headers.get('set-cookie')?.split(';')[0]
    assert.equal(connect.status, 302)
    assert.ok(cookie, 'the API peer exchange must mint a cookie')
    note('disposable DSH Host listens on a private loopback port')
  }

  await startHost()

  /** One GUI-shaped Host RPC call. */
  async function rpc(method, args) {
    const rpcId = `live-${++count}`
    const response = await fetch(`${base}/api/${method}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', cookie },
      body: JSON.stringify({ type: 'client-request', rpcId, method, payload: { args } }),
    })
    const text = await response.text()
    let body
    try { body = JSON.parse(text) } catch { throw new Error(`${method}: HTTP ${response.status} ${text.slice(0, 200)}`) }
    assert.equal(body.rpcId, rpcId)
    assert.equal(body.result.ok, true, `${method}: ${JSON.stringify(body.result.error)}`)
    return body.result.value
  }

  /** Page the durable events of one session. */
  const events = (sessionId) => rpc('session/events', { request: { address: { kind: 'session', sessionId } } })

  const sessions = []
  for (const [index, taskId] of ['task-a', 'task-b'].entries()) {
    const sessionId = `session-${randomUUID()}`
    writeEngineRecord({ home: LAB, parentSession: sessionId, record: {
      parent_session: sessionId, home: LAB, engine_session: null, status: 'live',
      subagent_provider: 'fork', label: 'firstmate-engine', owner_pid: child.pid,
      owner_started: null, crashes: 0, seen: {},
    } })
    const created = await rpc('session/create', { request: { sessionId, cwd: LAB } })
    assert.equal(created.sessionId, sessionId)
    const accepted = await rpc('session/prompt', { request: {
      requestId: `req-${index}`, sessionId, mode: 'queue', content: [{ type: 'text', text: `claim ${taskId}` }],
    } })
    assert.equal(accepted.accepted, true)
    let page
    for (let attempt = 0; attempt < 300; attempt += 1) {
      page = await events(sessionId)
      if (page.records.some((row) => row.event.type === 'turn/end')) break
      await sleep(100)
    }
    const types = page.records.map((row) => row.event.type)
    assert.ok(types.includes('turn/end'), `session ${sessionId} never completed its prompt turn`)
    const endSeq = completedTurnBoundary(page.records.map((row) => row.event))
    assert.equal(typeof endSeq, 'number')
    assert.equal(page.records.find((row) => row.event.seq === endSeq).event.type, 'turn/end')
    sessions.push({ sessionId, taskId, endSeq })
    writeFileSync(join(LAB, 'snapshot.json'), JSON.stringify({ schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: sessions.map((s) => task(s.taskId, s.sessionId)) }))
  }
  note('two real sessions completed their prompt turns with a real turn/end boundary')

  // The plugin starts each engine from the seeded durable record on creation;
  // the real fork provider appends a subagent/catalog fact to its parent.
  let catalogCount = 0
  for (let attempt = 0; attempt < 300; attempt += 1) {
    catalogCount = 0
    for (const session of sessions) {
      const page = await events(session.sessionId)
      if (page.records.some((row) => row.event.type === 'subagent/catalog')) catalogCount += 1
      const record = JSON.parse(readFileSync(join(LAB, 'state', 'engines', `${session.sessionId}.json`), 'utf8'))
      if (typeof record.engine_session === 'string' && record.engine_session.length > 0) {
        assert.equal(record.seed_boundary, session.endSeq, 'the real fork boundary must be the last completed turn')
      }
    }
    if (catalogCount === 2) break
    await sleep(200)
  }
  assert.equal(catalogCount, 2, 'each real parent must have one fork-created coordinator in its catalog')
  note('two real fork coordinators appear in their own parent catalogs')

  // Routine traffic must not post into the parent conversation.
  const before = await events(sessions[0].sessionId)
  const beforeTypes = before.records.map((row) => `${row.event.seq}:${row.event.type}`)
  const raw = task(sessions[0].taskId, sessions[0].sessionId, 'working [at=2]: still reviewing')
  writeFileSync(join(LAB, 'snapshot.json'), JSON.stringify({ schema: 'fm-fleet-snapshot.v1', backlog: { records: [] }, tasks: [raw, ...sessions.slice(1).map((s) => task(s.taskId, s.sessionId))] }))
  writeFileSync(join(LAB, 'state', `${sessions[0].taskId}.status`), `working [at=${Math.floor(Date.now() / 1000)}]: still reviewing\n`)
  await sleep(1500)
  const after = await events(sessions[0].sessionId)
  const added = after.records.map((row) => `${row.event.seq}:${row.event.type}`).filter((entry) => !beforeTypes.includes(entry))
  assert.deepEqual(added.filter((entry) => /message|followup|escalation/.test(entry)), [], `routine traffic posted into the parent: ${added.join(',')}`)
  note('routine traffic produced no parent message')

  // A captain-class outcome drives one real coordinator escalation turn. The
  // scripted provider emits the tool call only for a [captain] traffic batch,
  // so routine traffic above stayed silent.
  const blocker = {
    ...task(sessions[0].taskId, sessions[0].sessionId, 'blocked [at=live]: PR is ready for the captain'),
    hints: { pending_decision: true, blocked_event: true, open_decisions: ['merge'] },
  }
  writeFileSync(join(LAB, 'snapshot.json'), JSON.stringify({
    schema: 'fm-fleet-snapshot.v1', backlog: { records: [] },
    tasks: [blocker, ...sessions.slice(1).map((s) => task(s.taskId, s.sessionId))],
  }))
  const tagged = (page) => page.records.filter((row) =>
    row.event.type === 'user/message'
    && JSON.stringify(row.event.data ?? {}).includes('firstmate engine escalation'))
  let escalations = []
  for (let attempt = 0; attempt < 200; attempt += 1) {
    escalations = tagged(await events(sessions[0].sessionId))
    if (escalations.length > 0) break
    await sleep(100)
  }
  assert.equal(escalations.length, 1, `the owning parent must receive exactly one tagged escalation, saw ${escalations.length}`)
  assert.equal(escalations[0].event.data?.source?.kind, 'user', 'the escalation arrives as an ordinary user steer')
  const otherParent = tagged(await events(sessions[1].sessionId))
  assert.equal(otherParent.length, 0, 'the second parent receives no escalation')
  const settled = (await events(sessions[0].sessionId)).records.filter((row) =>
    row.event.type === 'user/message' && row.event.data?.source?.kind === 'subagent-settled')
  assert.equal(settled.length, 0, 'no subagent settlement notice reached the parent')
  note('a real coordinator escalation turn delivered one tagged message to its own parent only')

  // Record an undelivered captain outcome, restart only the disposable Host,
  // and prove that its new process adopts the persisted coordinator and
  // delivers that outcome. The home, sessions, and durable records are reused.
  const readRecord = (sessionId) => JSON.parse(readFileSync(join(LAB, 'state', 'engines', `${sessionId}.json`), 'utf8'))
  const preRestart = sessions.map((session) => ({ sessionId: session.sessionId, record: readRecord(session.sessionId) }))
  const pending = recordEscalation({
    home: LAB, parentSession: sessions[0].sessionId,
    engineSession: preRestart[0].record.engine_session,
    task: sessions[0].taskId, outcome: RESTART_OUTCOME,
  }).record
  assert.equal(pending.delivered_at, null, 'the outcome must be pending before the restart')
  await stopHost()
  await startHost()
  note('disposable DSH Host restarted with the same persisted home and sessions')

  const resumed = await rpc('session/prompt', { request: {
    requestId: 'req-restart', sessionId: sessions[0].sessionId, mode: 'queue',
    content: [{ type: 'text', text: 'continue after restart' }],
  } })
  assert.equal(resumed.accepted, true, 'the persisted parent session must resume after the restart')
  for (let attempt = 0; attempt < 300; attempt += 1) {
    const page = await events(sessions[0].sessionId)
    if (page.records.some((row) => row.event.type === 'turn/end' && row.event.seq > preRestart[0].record.seed_boundary)) break
    await sleep(100)
  }

  for (let attempt = 0; attempt < 200; attempt += 1) {
    const current = readRecord(sessions[0].sessionId)
    if (current.status === 'live' && current.engine_session === preRestart[0].record.engine_session && current.owner_pid === child.pid) break
    await sleep(200)
  }
  const adopted = readRecord(sessions[0].sessionId)
  assert.equal(adopted.engine_session, preRestart[0].record.engine_session, 'the restarted Host must adopt the persisted coordinator session')
  assert.equal(adopted.status, 'live')
  assert.equal(adopted.owner_pid, child.pid, 'the engine record must be re-owned by the new Host process')
  assert.equal(hostStderr.includes('already used by another subagent you created'), false, 'no coordinator name collision after restart')
  note('the restarted Host adopted the persisted coordinator without a name collision')

  const restartBlocker = {
    ...task(sessions[0].taskId, sessions[0].sessionId, 'blocked [at=restart]: restart-proof PR is ready for the captain'),
    hints: { pending_decision: true, blocked_event: true, open_decisions: ['merge'] },
  }
  writeFileSync(join(LAB, 'snapshot.json'), JSON.stringify({
    schema: 'fm-fleet-snapshot.v1', backlog: { records: [] },
    tasks: [restartBlocker, ...sessions.slice(1).map((s) => task(s.taskId, s.sessionId))],
  }))
  let restartTagged = []
  for (let attempt = 0; attempt < 200; attempt += 1) {
    restartTagged = tagged(await events(sessions[0].sessionId))
      .filter((row) => JSON.stringify(row.event.data ?? {}).includes(RESTART_OUTCOME))
    if (restartTagged.length > 0) break
    await sleep(100)
  }
  assert.equal(restartTagged.length, 1, 'the pending captain outcome must be delivered after the restart')
  assert.equal(restartTagged[0].event.data?.source?.kind, 'user')
  const deliveredAfter = readEscalations({ home: LAB, parentSession: sessions[0].sessionId })
    .records.find((row) => row.id === pending.id)
  assert.ok(deliveredAfter && typeof deliveredAfter.delivered_at === 'number', 'the pending escalation must be marked delivered')
  const catalogAfter = (await events(sessions[0].sessionId)).records
  assert.equal(catalogAfter.filter((row) => row.event.type === 'subagent/catalog').length, 1, 'only one coordinator child remains in the parent catalog')
  assert.equal(catalogAfter.filter((row) => row.event.type === 'user/message' && row.event.data?.source?.kind === 'subagent-settled').length, 0, 'no settlement notice reached the parent')
  note('the adopted coordinator delivered the pending captain outcome after restart')

  assert.ok(existsSync(join(LAB, 'state', 'engines')), 'the disposable home must hold the engine records')
  note(`${base} ${realpathSync(PLUGIN)}`)
} finally {
  if (child) child.kill('SIGTERM')
  rmSync(ROOT, { recursive: true, force: true })
}
