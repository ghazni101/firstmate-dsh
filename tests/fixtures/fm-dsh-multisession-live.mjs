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
 * on agent creation and the real fork provider creates the child. The model
 * turn cannot run without credentials, so this driver does not assert the
 * coordinator's decisions - the portable suite does that with controllable
 * seams. It does assert real lineage, real session events, and no parent
 * message from routine traffic.
 */
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, cpSync, writeFileSync, rmSync, realpathSync, symlinkSync, chmodSync, mkdtempSync } from 'node:fs'
import { homedir, tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'

import { completedTurnBoundary, writeEngineRecord } from '../../dsh-plugin/src/engine-records.js'

const REPO = fileURLToPath(new URL('../../', import.meta.url)).replace(/\/$/, '')
const PLUGIN = join(REPO, 'dsh-plugin')
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
  rmSync(pluginLink, { force: true })
  symlinkSync(PLUGIN, pluginLink)
  const patch = join(PROFILE, 'cordis.patch.yml')
  const original = readFileSync(patch, 'utf8')
  const rewritten = original
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
    default: { harness: 'omp', model: 'opencode-go/deepseek-v4.1-flash', provider: 'opencode-go', effort: 'low' },
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
try {
  makeLab()
  makeProfile()
  child = spawn('dsh', ['--profile', 'web', '--host', '127.0.0.1', '--port', '0', '--no-open'], {
    env: { ...process.env, DSH_HOME }, stdio: ['ignore', 'pipe', 'pipe'],
  })
  let banner = ''
  child.stdout.on('data', (chunk) => { banner += chunk.toString() })
  child.stderr.on('data', (chunk) => { process.stderr.write(`[dsh] ${chunk}`) })
  let base = null
  let token = null
  for (let attempt = 0; attempt < 300; attempt += 1) {
    const match = banner.match(/http:\/\/127\.0\.0\.1:(\d+)\/\?token=([^\s]+)/)
    if (match) { base = `http://127.0.0.1:${match[1]}`; token = match[2]; break }
    await sleep(100)
  }
  assert.ok(base && token, `the disposable Host never printed its API URL: ${banner.slice(0, 300)}`)
  note('disposable DSH Host listens on a private loopback port')

  const connect = await fetch(`${base}/connect?token=${token}&interactions=answer`, { redirect: 'manual' })
  const cookie = connect.headers.get('set-cookie')?.split(';')[0]
  assert.equal(connect.status, 302)
  assert.ok(cookie, 'the API peer exchange must mint a cookie')
  let count = 0

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

  assert.ok(existsSync(join(LAB, 'state', 'engines')), 'the disposable home must hold the engine records')
  note(`${base} ${realpathSync(PLUGIN)}`)
} finally {
  if (child) child.kill('SIGTERM')
  rmSync(ROOT, { recursive: true, force: true })
}
