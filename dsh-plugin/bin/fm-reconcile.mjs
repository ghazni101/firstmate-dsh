#!/usr/bin/env node
/**
 * fm-reconcile.mjs - one-tick or looping per-home reconciliation for a native
 * Firstmate home.
 *
 * This is the headless supervisor's engine. It owns no fleet state and takes no
 * fleet lock: every action runs under the task's lease, so several loops in one
 * home are safe and a loop that loses a lease stops writing. A DSH headless
 * session runs it (or calls the `firstmate_native_reconcile` tool); a shell can run it
 * directly for operations and tests.
 *
 * Usage:
 *   fm-reconcile.mjs --home <dir> --once [--apply] [--json]
 *   fm-reconcile.mjs --home <dir> --loop [--apply] [--interval-ms <n>]
 *
 * `--once` runs one tick and prints its `fm-native-loop.v1` report. `--loop`
 * runs ticks until SIGINT/SIGTERM and writes `state/.native-loop-beat` each
 * tick. Without `--apply` a tick only reports what it would do.
 *
 * The identity's home is `--identity-home` when given, else `FM_HOME` when set,
 * else `--home`; a mismatch is a cross-home refusal.
 *
 * @module @local/dsh-plugin-firstmate-native/bin/fm-reconcile
 */
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { asLeaseError, LeaseError } from '../src/errors.js'
import { canonicalPath } from '../src/home.js'
import { reconcileHint, reconcileTick } from '../src/reconcile.js'

const USAGE = `usage: fm-reconcile.mjs --home <dir> --once [--apply] [--json]
       fm-reconcile.mjs --home <dir> --loop [--apply] [--interval-ms <n>]
`

/**
 * Parse argv into long flags.
 * @param argv - process argv without node and script.
 * @returns `{ flags }`.
 */
function parse(argv) {
  const flags = {}
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index]
    if (!value.startsWith('--')) continue
    const key = value.slice(2)
    const next = argv[index + 1]
    if (next === undefined || next.startsWith('--')) {
      flags[key] = true
    } else {
      flags[key] = next
      index += 1
    }
  }
  return flags
}

/** @param value - a flag value. @returns it as a non-empty string. */
function required(value, name) {
  if (typeof value !== 'string' || value.length === 0) {
    throw new LeaseError('usage', `--${name} is required\n${USAGE}`)
  }
  return value
}

/**
 * Build the CLI identity for this invocation.
 * @param flags - parsed flags.
 * @returns `{ home, identity }`.
 */
function identityFor(flags) {
  const home = canonicalPath(required(flags.home, 'home'))
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
  // The identity home is explicit so a mismatched FM_HOME is refused by the
  // tick's cross-home check before any observation or mutation.
  const identity = {
    sessionId: String(sessionId),
    agentId: String(sessionId),
    home: identityHome,
    ownerLabel: `dsh:${sessionId}`,
  }
  return { home, identity }
}

/** @param home - home whose beat to write. @param session - session id. */
function beat(home, session) {
  try {
    mkdirSync(join(home, 'state'), { recursive: true })
    writeFileSync(join(home, 'state', '.native-loop-beat'), `${Date.now()} ${session}\n`)
  } catch {
    // A beat is observation only; a failure never changes the tick.
  }
}

/** @param report - a tick report. @returns its model-facing text. */
function render(report) {
  const lines = [
    `native reconcile ${report.home} (${report.applied ? 'apply' : 'dry-run'})`,
    `observed: queued=${report.observed.queued} in_flight=${report.observed.in_flight} reaped=${report.reaped.length}`,
  ]
  for (const action of report.actions) {
    lines.push(`${action.outcome}: ${action.task} -> bin/${action.script} ${action.args.join(' ')}${action.reason ? ` (${action.reason.split('\n')[0]})` : ''}`)
  }
  for (const entry of report.skipped) {
    if (!report.actions.some((action) => action.task === entry.task && action.rule === entry.rule)) {
      lines.push(`skipped: ${entry.task} (${entry.rule}) (${entry.reason})`)
    }
  }
  if (report.degraded !== null) lines.push(`degraded: ${report.degraded}`)
  return lines.join('\n')
}

const flags = parse(process.argv.slice(2))
if (flags.help === true || flags.h === true) {
  process.stdout.write(USAGE)
  process.exit(0)
}

let running = true
const stop = () => { running = false }
process.on('SIGINT', stop)
process.on('SIGTERM', stop)

try {
  const { home, identity } = identityFor(flags)
  const apply = flags.apply === true
  const loop = flags.loop === true
  const intervalMs = flags['interval-ms'] === undefined ? 15000 : Number(flags['interval-ms'])
  if (loop) {
    if (!Number.isSafeInteger(intervalMs) || intervalMs < 1000 || intervalMs > 3600000) {
      throw new LeaseError('usage', '--interval-ms must be an integer between 1000 and 3600000')
    }
    while (running) {
      const report = await reconcileTick({ home, identity, apply })
      beat(home, identity.sessionId)
      if (flags.json === true) process.stdout.write(`${JSON.stringify(report)}\n`)
      else process.stdout.write(`${render(report)}\n`)
      const hint = reconcileHint(report)
      if (hint !== null) process.stderr.write(`${hint}\n`)
      if (!running) break
      await new Promise((resolve) => setTimeout(resolve, intervalMs))
    }
    process.exitCode = 0
  } else {
    const report = await reconcileTick({ home, identity, apply })
    if (flags.json === true) process.stdout.write(`${JSON.stringify(report)}\n`)
    else process.stdout.write(`${render(report)}\n`)
    const hint = reconcileHint(report)
    if (hint !== null) process.stderr.write(`${hint}\n`)
    process.exitCode = report.degraded === null ? 0 : 1
  }
} catch (error) {
  const failure = asLeaseError(error)
  process.stderr.write(`fm-reconcile: ${failure.message}\n`)
  process.exitCode = failure.exitCode
}
