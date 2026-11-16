/**
 * Bash adapter tests for lib/fm-lease2-lib.sh.
 *
 * Each case runs a real bash subshell that sources the adapter, against a
 * throwaway home. This is the surface phase 2 wires into the mutating bin
 * scripts, so it is tested as bash rather than as JavaScript.
 */
import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { cleanup, makeHome } from './helpers.mjs'

const LIB = fileURLToPath(new URL('../lib/fm-lease2-lib.sh', import.meta.url))

/**
 * Run one bash body with the adapter sourced.
 * @param home - fixture home, exported as FM_HOME.
 * @param body - bash body.
 * @param env - extra environment.
 * @returns the spawn result.
 */
function bash(home, body, env = {}) {
  return spawnSync('bash', ['-c', `. "${LIB}"\n${body}`], {
    env: { ...process.env, FM_HOME: home, ...env },
    encoding: 'utf8',
  })
}

test('the adapter acquires a lease and prints its fencing token', () => {
  const home = makeHome()
  try {
    const result = bash(home, 'fm_lease2_acquire "$FM_HOME" task-one "land PR"')
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout.trim(), '1')
    const inspected = bash(home, 'fm_lease2_inspect "$FM_HOME" task-one')
    assert.match(inspected.stdout, /"live":true/)
    assert.match(inspected.stdout, /"purpose":"land PR"/)
  } finally {
    cleanup(home)
  }
})

test('a second bash process gets a contention refusal and exit 5', () => {
  const home = makeHome()
  try {
    const first = bash(home, 'fm_lease2_acquire "$FM_HOME" task-one')
    assert.equal(first.status, 0, first.stderr)
    const second = bash(home, 'fm_lease2_acquire "$FM_HOME" task-one "other"')
    assert.equal(second.status, 5)
    assert.match(second.stderr, /contention/)
  } finally {
    cleanup(home)
  }
})

test('guard runs the command with the lease identity exported', () => {
  const home = makeHome()
  try {
    const result = bash(home, [
      'token=$(fm_lease2_acquire "$FM_HOME" task-one) || exit',
      'fm_lease2_guard "$FM_HOME" task-one "$token" -- sh -c \'printf "%s/%s/%s" "$FM_LEASE_TASK" "$FM_LEASE_TOKEN" "$FM_LEASE_OWNER"\'',
    ].join('\n'))
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /^task-one\/1\/dsh:shell:\d+$/)
  } finally {
    cleanup(home)
  }
})

test('guard refuses a stale token before running the command', () => {
  const home = makeHome()
  try {
    const result = bash(home, [
      'fm_lease2_acquire "$FM_HOME" task-one >/dev/null',
      'fm_lease2_guard "$FM_HOME" task-one 99 -- sh -c \'echo SHOULD-NOT-RUN\'',
    ].join('\n'))
    assert.equal(result.status, 4)
    assert.doesNotMatch(result.stdout, /SHOULD-NOT-RUN/)
    assert.match(result.stdout, /"code":"fenced"/)
    assert.match(result.stderr, /fencing token/)
  } finally {
    cleanup(home)
  }
})

test('release then re-acquire keeps the token monotonic', () => {
  const home = makeHome()
  try {
    const result = bash(home, [
      'token=$(fm_lease2_acquire "$FM_HOME" task-one)',
      'fm_lease2_release "$FM_HOME" task-one "$token" >/dev/null || exit 1',
      'fm_lease2_acquire "$FM_HOME" task-one',
    ].join('\n'))
    assert.equal(result.status, 0, result.stderr)
    assert.equal(result.stdout.trim(), '2')
  } finally {
    cleanup(home)
  }
})

test('live_token reports the holder and clears after release', () => {
  const home = makeHome()
  try {
    const result = bash(home, [
      'token=$(fm_lease2_acquire "$FM_HOME" task-one)',
      'printf "held=%s\\n" "$(fm_lease2_live_token "$FM_HOME" task-one)"',
      'fm_lease2_release "$FM_HOME" task-one "$token" >/dev/null',
      'fm_lease2_live_token "$FM_HOME" task-one',
      'printf "after=%s\\n" "$?"',
    ].join('\n'))
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /held=1/)
    assert.match(result.stdout, /after=1/)
  } finally {
    cleanup(home)
  }
})

test('the adapter refuses to act without FM_HOME', () => {
  const home = makeHome()
  try {
    const env = { ...process.env }
    delete env.FM_HOME
    const result = spawnSync('bash', ['-c', `. "${LIB}"\nfm_lease2_acquire "${home}" task-one`], { env, encoding: 'utf8' })
    assert.equal(result.status, 2)
    assert.match(result.stderr, /FM_HOME is required/)
  } finally {
    cleanup(home)
  }
})

test('cross-home use is refused with exit 6', () => {
  const homeA = makeHome()
  const homeB = makeHome()
  try {
    const cross = bash(homeA, `fm_lease2_acquire "${homeB}" task-one`)
    assert.equal(cross.status, 6)
    assert.match(cross.stderr, /cross-home/)
  } finally {
    cleanup(homeA)
    cleanup(homeB)
  }
})
