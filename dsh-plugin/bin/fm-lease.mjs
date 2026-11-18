#!/usr/bin/env node
/**
 * fm-lease.mjs - command surface for the N-owner per-task lease.
 *
 * This is the adapter bash callers use to reach the native lease protocol. It
 * is a thin argument parser over src/lease.js: the protocol is not
 * reimplemented here, and the CLI never decides policy.
 *
 * Usage:
 *   fm-lease.mjs acquire --home <dir> --task <id> [--purpose <text>] [--ttl-ms <n>]
 *                        [--session <id>] [--identity-home <dir>]
 *   fm-lease.mjs renew   --home <dir> --task <id> --token <n>
 *   fm-lease.mjs release --home <dir> --task <id> --token <n>
 *   fm-lease.mjs inspect --home <dir> --task <id>
 *   fm-lease.mjs reap    --home <dir>
 *   fm-lease.mjs guard   --home <dir> --task <id> --token <n> -- <command> [args...]
 *
 * The identity's home is `--identity-home` when given, else `FM_HOME` when set,
 * else `--home`. A mismatch is a cross-home refusal (exit 6), so a bash caller
 * cannot claim with a mismatched environment. `--session` (or
 * `FM_DSH_SESSION_ID`) names the holder; the plugin passes the real DSH session
 * id, and a shell caller gets a stable per-process label otherwise.
 *
 * Output is one JSON object on stdout. Exit codes: 0 ok, 2 usage/invalid,
 * 3 not held/expired/invalid record, 4 fenced, 5 contention, 6 cross-home,
 * 7 mutex busy.
 *
 * Contract: docs/dsh-native-architecture.md section 4.10.
 */
import { spawnSync } from 'node:child_process'
import { asLeaseError, LeaseError } from '../src/errors.js'
import { canonicalPath } from '../src/home.js'
import { assertSameHome } from '../src/identity.js'
import {
  acquireLease,
  guardLease,
  inspectLease,
  reapExpiredLeases,
  releaseLease,
  renewLease,
} from '../src/lease.js'

const USAGE = `usage: fm-lease.mjs <acquire|renew|release|inspect|reap|guard> [flags]
  common: --home <dir> --task <id>
  acquire: [--purpose <text>] [--ttl-ms <n>] [--session <id>] [--identity-home <dir>]
  renew/release/guard: --token <n>
  guard: -- <command> [args...]
`

/**
 * Parse argv into a command, long flags, and positional values.
 * @param argv - process argv without node and script.
 * @returns `{ command, flags, positional }`.
 */
function parse(argv) {
  const [command, ...rest] = argv
  const flags = {}
  const positional = []
  for (let index = 0; index < rest.length; index += 1) {
    const value = rest[index]
    if (value === '--') {
      positional.push(...rest.slice(index + 1))
      break
    }
    if (typeof value === 'string' && value.startsWith('--')) {
      const key = value.slice(2)
      const next = rest[index + 1]
      if (next === undefined || (typeof next === 'string' && next.startsWith('--'))) {
        flags[key] = true
      } else {
        flags[key] = next
        index += 1
      }
      continue
    }
    positional.push(value)
  }
  return { command, flags, positional }
}

/** @param flags - parsed flags. @param key - flag name. @returns required string value. */
function required(flags, key) {
  const value = flags[key]
  if (typeof value !== 'string' || value.length === 0) {
    throw new LeaseError('usage', `--${key} is required`)
  }
  return value
}

/** @param flags - parsed flags. @param key - flag name. @returns a finite positive integer. */
function requiredInt(flags, key) {
  const raw = required(flags, key)
  const value = Number(raw)
  if (!Number.isSafeInteger(value) || value < 0) {
    throw new LeaseError('usage', `--${key} must be a non-negative integer`)
  }
  return value
}

/**
 * Build the CLI identity for one call.
 * @param flags - parsed flags.
 * @returns `{ identity, home }` where `home` is the canonical target.
 */
function identityFor(flags) {
  const home = canonicalPath(required(flags, 'home'))
  const identityHome = typeof flags['identity-home'] === 'string'
    ? canonicalPath(flags['identity-home'])
    : (typeof process.env.FM_HOME === 'string' && process.env.FM_HOME.length > 0
      ? canonicalPath(process.env.FM_HOME)
      : home)
  const sessionId = typeof flags.session === 'string' && flags.session.length > 0
    ? flags.session
    : (typeof process.env.FM_DSH_SESSION_ID === 'string' && process.env.FM_DSH_SESSION_ID.length > 0
      ? process.env.FM_DSH_SESSION_ID
      : `shell:${process.ppid}`)
  return {
    home,
    identity: {
      sessionId: String(sessionId),
      agentId: String(sessionId),
      home: identityHome,
      ownerLabel: `dsh:${sessionId}`,
    },
  }
}

/** @param value - a record or value. @returns the JSON text plus a newline. */
function json(value) {
  return `${JSON.stringify(value)}\n`
}

/**
 * Run one command.
 * @param parsed - parsed argv.
 * @returns `{ payload, exitCode }`.
 */
function run(parsed) {
  const { command, flags, positional } = parsed
  if (command === undefined || command === '--help' || command === '-h' || command === 'help') {
    return { payload: { ok: true, usage: USAGE }, exitCode: 0 }
  }
  const task = typeof flags.task === 'string' ? flags.task : undefined
  if (task === undefined && command !== 'reap') throw new LeaseError('usage', '--task is required')

  switch (command) {
    case 'acquire': {
      const { home, identity } = identityFor(flags)
      const ttlMs = flags['ttl-ms'] === undefined ? undefined : requiredInt(flags, 'ttl-ms')
      const record = acquireLease({
        home,
        task,
        identity,
        purpose: typeof flags.purpose === 'string' ? flags.purpose : '',
        ...(ttlMs === undefined ? {} : { ttlMs }),
      })
      return {
        payload: { ok: true, command, home, task, token: record.token, record },
        exitCode: 0,
      }
    }
    case 'renew': {
      const { home, identity } = identityFor(flags)
      const token = requiredInt(flags, 'token')
      const ttlMs = flags['ttl-ms'] === undefined ? undefined : requiredInt(flags, 'ttl-ms')
      const record = renewLease({ home, task, identity, token, ...(ttlMs === undefined ? {} : { ttlMs }) })
      return { payload: { ok: true, command, home, task, token: record.token, record }, exitCode: 0 }
    }
    case 'release': {
      const { home, identity } = identityFor(flags)
      const token = requiredInt(flags, 'token')
      const record = releaseLease({ home, task, identity, token })
      return { payload: { ok: true, command, home, task, token, record }, exitCode: 0 }
    }
    case 'inspect': {
      const home = canonicalPath(required(flags, 'home'))
      const inspection = inspectLease({ home, task })
      return { payload: { ok: true, command, ...inspection }, exitCode: 0 }
    }
    case 'reap': {
      const { home, identity } = identityFor(flags)
      assertSameHome(identity, home)
      const reaped = reapExpiredLeases({ home })
      return { payload: { ok: true, command, home, reaped }, exitCode: 0 }
    }
    case 'guard': {
      const { home, identity } = identityFor(flags)
      const token = requiredInt(flags, 'token')
      const record = guardLease({ home, task, identity, token })
      if (positional.length === 0) {
        return { payload: { ok: true, command, home, task, token: record.token, record }, exitCode: 0 }
      }
      const [program, ...args] = positional
      const child = spawnSync(program, args, {
        stdio: 'inherit',
        env: {
          ...process.env,
          FM_HOME: home,
          FM_LEASE_HOME: home,
          FM_LEASE_TASK: task,
          FM_LEASE_TOKEN: String(token),
          FM_LEASE_OWNER: identity.ownerLabel,
          FM_LEASE_SESSION: identity.sessionId,
        },
      })
      return { payload: null, exitCode: typeof child.status === 'number' ? child.status : 1 }
    }
    default:
      throw new LeaseError('usage', `unknown command ${JSON.stringify(command)}\n${USAGE}`)
  }
}

const parsed = parse(process.argv.slice(2))
try {
  const outcome = run(parsed)
  if (outcome.payload !== null) process.stdout.write(json(outcome.payload))
  process.exitCode = outcome.exitCode
} catch (error) {
  const failure = asLeaseError(error)
  process.stdout.write(json({ ok: false, command: parsed.command ?? null, code: failure.code, message: failure.message, ...failure.details }))
  process.stderr.write(`fm-lease: ${failure.message}\n`)
  process.exitCode = failure.exitCode
}
