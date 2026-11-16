/**
 * Identity and home-resolution tests: anchors, precedence, subagent skip,
 * canonical containment, and cross-home refusal.
 */
import assert from 'node:assert/strict'
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'

import { LeaseError } from '../src/errors.js'
import {
  canonicalPath,
  isFirstmateHome,
  isInside,
  isNativeHome,
  resolveHome,
  walkUpToHome,
} from '../src/home.js'
import { assertSameHome, identifySession, identityNote, isSubagentHeader } from '../src/identity.js'
import { cleanup, makeAgent, makeHome, makeIdentity } from './helpers.mjs'

test('a directory is a home only when every anchor exists', () => {
  const home = makeHome({ anchors: false })
  try {
    assert.equal(isFirstmateHome(home), false)
    writeFileSync(join(home, 'AGENTS.md'), '# fixture\n')
    assert.equal(isFirstmateHome(home), false)
    mkdirSync(join(home, 'bin'), { recursive: true })
    writeFileSync(join(home, 'bin', 'fm-session-start.sh'), '#!/usr/bin/env bash\nexit 0\n')
    assert.equal(isFirstmateHome(home), false)
    writeFileSync(join(home, 'bin', 'fm-spawn.sh'), '#!/usr/bin/env bash\nexit 0\n')
    assert.equal(isFirstmateHome(home), true)
  } finally {
    cleanup(home)
  }
})

test('home resolution walks up from a session directory', () => {
  const home = makeHome()
  try {
    const nested = join(home, 'projects', 'demo', 'src')
    mkdirSync(nested, { recursive: true })
    assert.equal(walkUpToHome(nested), canonicalPath(home))
    assert.equal(resolveHome({ sessionDir: nested, env: {}, cwd: tmpdir() }), canonicalPath(home))
  } finally {
    cleanup(home)
  }
})

test('a configured home wins, and a session outside it is not a supervisor', () => {
  const homeA = makeHome()
  const homeB = makeHome()
  const outside = mkdtempSync(join(tmpdir(), 'fm-outside-'))
  try {
    assert.equal(resolveHome({ configured: homeB, sessionDir: homeA, env: {}, cwd: outside }), canonicalPath(homeB))
    const { agent } = makeAgent({ cwd: outside })
    assert.equal(identifySession({ agent, configuredHome: homeB, env: {}, cwd: outside }), null)
  } finally {
    cleanup(homeA)
    cleanup(homeB)
    rmSync(outside, { recursive: true, force: true })
  }
})

test('FM_HOME is a fallback only when it is itself a home', () => {
  const home = makeHome()
  const notAHome = mkdtempSync(join(tmpdir(), 'fm-nothome-'))
  try {
    assert.equal(resolveHome({ env: { FM_HOME: home }, cwd: notAHome }), canonicalPath(home))
    assert.equal(resolveHome({ env: { FM_HOME: notAHome }, cwd: notAHome }), undefined)
  } finally {
    cleanup(home)
    rmSync(notAHome, { recursive: true, force: true })
  }
})

test('a symlinked session directory resolves to the same home', () => {
  const home = makeHome()
  const linkRoot = mkdtempSync(join(tmpdir(), 'fm-link-'))
  try {
    const link = join(linkRoot, 'home-link')
    symlinkSync(home, link, 'dir')
    assert.equal(resolveHome({ sessionDir: link, env: {}, cwd: linkRoot }), canonicalPath(home))
    assert.equal(isInside(link, home), true)
  } finally {
    cleanup(home)
    rmSync(linkRoot, { recursive: true, force: true })
  }
})

test('identifySession returns the DSH session identity for a root session', () => {
  const home = makeHome()
  try {
    const { agent } = makeAgent({ id: 'agent-1', cwd: home, header: { agentPreset: 'firstmate' } })
    const identity = identifySession({ agent, configuredHome: home, env: {} })
    assert.equal(identity.sessionId, 'agent-1')
    assert.equal(identity.agentId, 'agent-1')
    assert.equal(identity.home, canonicalPath(home))
    assert.equal(identity.ownerLabel, 'dsh:agent-1')
    assert.equal(identity.preset, 'firstmate')
  } finally {
    cleanup(home)
  }
})

test('subagents never become supervisor candidates', () => {
  const home = makeHome()
  try {
    for (const header of [{ origin: 'subagent' }, { delegationDepth: 1 }, { parentSession: 'parent' }]) {
      const { agent } = makeAgent({ cwd: home, header })
      const identity = identifySession({ agent, configuredHome: home, env: {} })
      const expected = header.origin === 'subagent' || header.delegationDepth === 1
      assert.equal(isSubagentHeader(header), expected)
      assert.equal(identity === null, expected)
    }
  } finally {
    cleanup(home)
  }
})

test('assertSameHome accepts its own home and refuses another', () => {
  const homeA = makeHome()
  const homeB = makeHome()
  try {
    const identity = makeIdentity(homeA)
    assert.equal(assertSameHome(identity, homeA), canonicalPath(homeA))
    const error = (() => {
      try {
        assertSameHome(identity, homeB)
      } catch (caught) {
        return caught
      }
      return undefined
    })()
    assert.ok(error instanceof LeaseError)
    assert.equal(error.code, 'cross-home')
  } finally {
    cleanup(homeA)
    cleanup(homeB)
  }
})

test('native opt-in is a per-home marker', () => {
  const home = makeHome()
  const other = makeHome({ native: false })
  try {
    assert.equal(isNativeHome(home), true)
    assert.equal(isNativeHome(other), false)
  } finally {
    cleanup(home)
    cleanup(other)
  }
})

test('the identity note is static text without ownership claims', () => {
  const note = identityNote(makeIdentity('/home/example/firstmate', 'session-9'))
  assert.match(note, /home \/home\/example\/firstmate/)
  assert.match(note, /session-9/)
  assert.match(note, /no fleet-wide owner/)
  assert.doesNotMatch(note, /lock/i)
})
