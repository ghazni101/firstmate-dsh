/**
 * Native lease seam tests for bin/fm-lease-lib.sh and bin/fm-native-lib.sh.
 *
 * The mutating entrypoints call `fm_lease_guard` / `fm_lease_forbid_branch`;
 * a native home routes those calls to the per-task DSH lease. These tests run
 * the real engine library against throwaway homes, with no fleet lock.
 */
import assert from 'node:assert/strict'
import { existsSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

import { cleanup, makeHome } from './helpers.mjs'

const PLUGIN_DIR = fileURLToPath(new URL('..', import.meta.url)).replace(/[\\/]+$/, '')
const LEASE_LIB = fileURLToPath(new URL('../../bin/fm-lease-lib.sh', import.meta.url))
const CLI = join(PLUGIN_DIR, 'bin', 'fm-lease.mjs')
const PR_MERGE = fileURLToPath(new URL('../../bin/fm-pr-merge.sh', import.meta.url))
const MERGE_LOCAL = fileURLToPath(new URL('../../bin/fm-merge-local.sh', import.meta.url))

/**
 * Run one real merge entrypoint against a fixture home.
 * @param home - fixture home.
 * @param argv - entrypoint and arguments.
 * @param lease - presented lease variables.
 * @returns the spawn result.
 */
function merge(home, argv, lease = {}) {
  return spawnSync(argv[0], argv.slice(1), {
    env: {
      ...process.env,
      FM_HOME: home,
      FM_LEASE_TOKEN: '',
      FM_LEASE_SESSION: '',
      FM_LEASE_TASK: '',
      ...lease,
    },
    encoding: 'utf8',
  })
}

const MERGE_ENTRYPOINTS = [
  ['PR merge', () => [PR_MERGE, 'task-a', 'https://github.com/example/repo/pull/1'], /PR merge \(fm-pr-merge\) refused/],
  ['local-only landing', () => [MERGE_LOCAL, 'task-a'], /local-only landing \(fm-merge-local\) refused/],
]

/**
 * Acquire a lease through the owning CLI.
 * @param home - fixture home.
 * @param task - task id.
 * @param session - holder session.
 * @returns the held record.
 */
function acquire(home, task, session) {
  const result = spawnSync(process.execPath, [CLI, 'acquire', '--home', home, '--task', task, '--session', session], {
    env: { ...process.env, FM_HOME: home },
    encoding: 'utf8',
  })
  assert.equal(result.status, 0, result.stderr)
  return JSON.parse(result.stdout).record
}

/**
 * Run one bash body with the real engine lease library sourced.
 * @param home - fixture home.
 * @param body - bash body.
 * @param env - extra environment.
 * @returns the spawn result.
 */
function bash(home, body, env = {}) {
  return spawnSync('bash', ['-c', `. "${LEASE_LIB}"\n${body}`], {
    env: {
      ...process.env,
      FM_HOME: home,
      STATE: join(home, 'state'),
      FM_CONFIG_OVERRIDE: join(home, 'config'),
      FM_LEASE_TOKEN: '',
      FM_LEASE_SESSION: '',
      FM_LEASE_TASK: '',
      ...env,
    },
    encoding: 'utf8',
  })
}

/**
 * Create a native-lease fixture home.
 * @param options - marker and plugin-dir overrides.
 * @returns the home path.
 */
function nativeHome({ marker = true, pluginDir = PLUGIN_DIR } = {}) {
  const home = makeHome()
  if (marker) writeFileSync(join(home, 'config', 'dsh-native-lease'), 'on\n')
  if (pluginDir !== null) writeFileSync(join(home, 'config', 'native-plugin-dir'), `${pluginDir}\n`)
  return home
}

test('a native home accepts a mutation that presents a live lease token', () => {
  const home = nativeHome()
  try {
    const record = acquire(home, 'task-a', 'session-a')
    const result = bash(home, 'fm_lease_guard task-a "steer test"', {
      FM_LEASE_TOKEN: String(record.token),
      FM_LEASE_SESSION: 'session-a',
      FM_LEASE_TASK: 'task-a',
    })
    assert.equal(result.status, 0, result.stderr)
    assert.equal(existsSync(join(home, 'state', '.lock')), false, 'the native guard must not create or require the fleet lock')
  } finally {
    cleanup(home)
  }
})

test('a native home refuses a task id that cannot name a lease instead of skipping the guard', () => {
  const home = nativeHome()
  try {
    const result = bash(home, 'fm_lease_guard "../task-a" "steer test"; echo reached')
    assert.equal(result.status, 6, result.stdout + result.stderr)
    assert.doesNotMatch(result.stdout, /reached/)
    assert.match(result.stderr, /cannot name a native task lease/)
  } finally {
    cleanup(home)
  }
})

test('a home without the native marker still passes an unusual task id untouched', () => {
  const home = nativeHome({ marker: false })
  try {
    const result = bash(home, 'fm_lease_guard "../task-a" "steer test"; echo reached')
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /reached/)
  } finally {
    cleanup(home)
  }
})

for (const [label, argv, refusal] of MERGE_ENTRYPOINTS) {
  test(`a native home refuses a ${label} that presents no task lease`, () => {
    const home = nativeHome()
    try {
      const result = merge(home, argv())
      assert.equal(result.status, 6, result.stderr)
      assert.match(result.stderr, refusal)
      assert.match(result.stderr, /no live native lease/)
    } finally {
      cleanup(home)
    }
  })

  test(`a native home refuses a ${label} whose lease covers another task`, () => {
    const home = nativeHome()
    try {
      const record = acquire(home, 'task-b', 'session-a')
      const result = merge(home, argv(), {
        FM_LEASE_TOKEN: String(record.token),
        FM_LEASE_SESSION: 'session-a',
        FM_LEASE_TASK: 'task-b',
      })
      assert.equal(result.status, 6, result.stderr)
      assert.match(result.stderr, /belongs to task task-b, not task-a/)
    } finally {
      cleanup(home)
    }
  })

  test(`a native home lets a ${label} with a live task lease past the lease gate`, () => {
    const home = nativeHome()
    try {
      const record = acquire(home, 'task-a', 'session-a')
      const result = merge(home, argv(), {
        FM_LEASE_TOKEN: String(record.token),
        FM_LEASE_SESSION: 'session-a',
        FM_LEASE_TASK: 'task-a',
      })
      // The fixture has no task record, so the entrypoint proceeds past the lease
      // gate and stops at its next, unrelated guard.
      assert.notEqual(result.status, 6, result.stderr)
      assert.doesNotMatch(result.stderr, /refused - /)
      assert.match(result.stderr, /task metadata is unavailable|no meta for task task-a/)
    } finally {
      cleanup(home)
    }
  })

  test(`a home without the native marker runs a ${label} with no lease, as before`, () => {
    const home = nativeHome({ marker: false })
    try {
      const result = merge(home, argv())
      assert.notEqual(result.status, 6, result.stderr)
      assert.doesNotMatch(result.stderr, /native lease/)
    } finally {
      cleanup(home)
    }
  })
}

test('a native home refuses a mutation with no presented lease', () => {
  const home = nativeHome()
  try {
    const result = bash(home, 'fm_lease_guard task-a "steer test"')
    assert.equal(result.status, 6)
    assert.match(result.stderr, /FM_LEASE_TOKEN\/FM_LEASE_SESSION are unset/)
  } finally {
    cleanup(home)
  }
})

test('a native home refuses a stale or fenced token', async () => {
  const home = nativeHome()
  try {
    const firstResult = spawnSync(process.execPath, [CLI, 'acquire', '--home', home, '--task', 'task-a', '--session', 'session-old', '--ttl-ms', '20'], {
      env: { ...process.env, FM_HOME: home },
      encoding: 'utf8',
    })
    assert.equal(firstResult.status, 0, firstResult.stderr)
    const first = JSON.parse(firstResult.stdout).record
    await new Promise((resolve) => setTimeout(resolve, 50))
    const second = acquire(home, 'task-a', 'session-new')
    assert.equal(second.token, first.token + 1)
    const stale = bash(home, 'fm_lease_guard task-a "steer test"', {
      FM_LEASE_TOKEN: String(first.token),
      FM_LEASE_SESSION: 'session-old',
      FM_LEASE_TASK: 'task-a',
    })
    assert.equal(stale.status, 6)
    assert.match(stale.stderr, /lease token/)
  } finally {
    cleanup(home)
  }
})

test('a native home refuses a token borrowed from another task', () => {
  const home = nativeHome()
  try {
    const record = acquire(home, 'task-a', 'session-a')
    const result = bash(home, 'fm_lease_guard task-b "steer test"', {
      FM_LEASE_TOKEN: String(record.token),
      FM_LEASE_SESSION: 'session-a',
      FM_LEASE_TASK: 'task-a',
    })
    assert.equal(result.status, 6)
    assert.match(result.stderr, /belongs to task task-a/)
  } finally {
    cleanup(home)
  }
})

test('a native home refuses when the plugin root is not recorded', () => {
  const home = nativeHome({ pluginDir: null })
  try {
    const record = acquire(home, 'task-a', 'session-a')
    const result = bash(home, 'fm_lease_guard task-a "steer test"', {
      FM_LEASE_TOKEN: String(record.token),
      FM_LEASE_SESSION: 'session-a',
      FM_LEASE_TASK: 'task-a',
    })
    assert.equal(result.status, 6)
    assert.match(result.stderr, /lease CLI is unavailable/)
  } finally {
    cleanup(home)
  }
})

test('a home without the native marker keeps the two-actor behavior', () => {
  const home = makeHome()
  try {
    // No native marker: an unmarked caller with no lease file passes the old
    // guard, exactly as before this seam landed.
    const result = bash(home, 'fm_lease_guard task-a "steer test"')
    assert.equal(result.status, 0, result.stderr)
    // The branch partition still refuses the branch actor in a legacy home.
    const branch = bash(home, 'FM_SUPERVISION_ACTOR=branch fm_lease_forbid_branch "PR merge"')
    assert.equal(branch.status, 6)
  } finally {
    cleanup(home)
  }
})

test('a native home has no branch actor, so the partition is a no-op', () => {
  const home = nativeHome()
  try {
    const result = bash(home, 'FM_SUPERVISION_ACTOR=branch fm_lease_forbid_branch "PR merge"')
    assert.equal(result.status, 0, result.stderr)
  } finally {
    cleanup(home)
  }
})

test('the native guard release hook never releases the caller lease', () => {
  const home = nativeHome()
  try {
    const record = acquire(home, 'task-a', 'session-a')
    const result = bash(home, [
      `FM_LEASE_TOKEN="${record.token}" FM_LEASE_SESSION="session-a" fm_lease_guard task-a "steer test"`,
      'fm_lease_guard_release',
      'fm_lease_guard task-a "steer again"',
      'echo still-guarded',
    ].join('\n'), {
      FM_LEASE_TOKEN: String(record.token),
      FM_LEASE_SESSION: 'session-a',
      FM_LEASE_TASK: 'task-a',
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /still-guarded/)
    const inspect = spawnSync(process.execPath, [CLI, 'inspect', '--home', home, '--task', 'task-a'], {
      env: { ...process.env, FM_HOME: home },
      encoding: 'utf8',
    })
    assert.match(inspect.stdout, /"live":true/)
  } finally {
    cleanup(home)
  }
})
