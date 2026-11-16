/**
 * The per-home reconciliation loop for a native Firstmate home.
 *
 * One tick is: reap expired leases, observe the durable records through the
 * existing read-only engine scripts, select actionable work for THIS home,
 * lease-then-act through a home-authored rule, release, and report. Event hints
 * are latency only; the tick is the truth.
 *
 * Design decisions made here (recorded in docs/dsh-native-architecture.md):
 *   - Selection is rule-driven by a home-local `config/native-loop.json`, so
 *     project policy (which project, mode, yolo, branch) never gets baked into
 *     the supervisor. A rule names a script and its arguments; the loop supplies
 *     `{id}` and the other task fields.
 *   - Merge rules are gated by the task's project posture, read at action time
 *     from `bin/fm-project-mode.sh`; an unreadable or non-yolo posture skips the
 *     action and reports it instead of merging.
 *   - Every executed action runs under that task's lease, so two loops in one
 *     home cannot double-act. A loop that loses its lease stops writing.
 *   - A tick never kills a worker, tears down work, or retires anything on
 *     expiry. It only reaps leases and runs authored actions.
 *   - No fleet lock, no home lock, and no ancestry identity is consulted.
 *
 * Contract: docs/dsh-native-architecture.md sections 4 and 6.
 *
 * @module @local/dsh-plugin-firstmate-native/src/reconcile
 */
import { existsSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { assertSameHome } from './identity.js'
import { reapExpiredLeases, withLease } from './lease.js'
import { combinedOutput, runScript } from './scripts.js'

/** Schema id of one tick report. */
export const LOOP_REPORT_SCHEMA = 'fm-native-loop.v1'

/** Default tick interval. */
export const DEFAULT_TICK_MS = 15000

/** Home-local loop configuration path. */
export const LOOP_CONFIG_FILE = 'config/native-loop.json'

/** Default cap on executed actions per tick. */
export const DEFAULT_MAX_ACTIONS = 3

/** Scripts the loop never runs: the plugin's own session lifecycle owns them. */
const DENIED_SCRIPTS = new Set([
  'fm-session-start.sh',
  'fm-lock.sh',
  'fm-watch.sh',
  'fm-watch-arm.sh',
  'fm-watch-checkpoint.sh',
  'fm-supervise-daemon.sh',
  'fm-afk-start.sh',
  'fm-supervision-host.sh',
])

/** Scripts whose action needs the task project's posture before it may run. */
const MERGE_SCRIPTS = new Map([
  ['fm-pr-merge.sh', 'pr'],
  ['fm-merge-local.sh', 'local'],
])

/** A script name the loop accepts. */
const SCRIPT_NAME = /^fm-[a-z0-9][a-z0-9-]*\.sh$/

/**
 * Read and validate the home-local loop configuration.
 * @param options - load inputs.
 * @returns the validated configuration with defaults applied.
 * @throws when the file is unreadable or invalid.
 */
export function loadLoopConfig({ home } = {}) {
  const path = join(home, LOOP_CONFIG_FILE)
  if (!existsSync(path)) {
    return {
      tick_ms: DEFAULT_TICK_MS,
      max_actions_per_tick: DEFAULT_MAX_ACTIONS,
      rules: [],
      present: false,
      path,
    }
  }
  let parsed
  try {
    parsed = JSON.parse(readFileSync(path, 'utf8'))
  } catch (error) {
    throw new Error(`native loop config ${path} is not valid JSON: ${error.message}`)
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`native loop config ${path} must be a JSON object`)
  }
  const tickMs = parsed.tick_ms === undefined ? DEFAULT_TICK_MS : Number(parsed.tick_ms)
  if (!Number.isSafeInteger(tickMs) || tickMs < 1000 || tickMs > 3600000) {
    throw new Error('native loop config tick_ms must be an integer between 1000 and 3600000')
  }
  const maxActions = parsed.max_actions_per_tick === undefined
    ? DEFAULT_MAX_ACTIONS
    : Number(parsed.max_actions_per_tick)
  if (!Number.isSafeInteger(maxActions) || maxActions < 1 || maxActions > 50) {
    throw new Error('native loop config max_actions_per_tick must be an integer between 1 and 50')
  }
  if (parsed.rules !== undefined && !Array.isArray(parsed.rules)) {
    throw new Error('native loop config rules must be an array')
  }
  const rules = (parsed.rules ?? []).map((rule, index) => validateRule(rule, index))
  return { tick_ms: tickMs, max_actions_per_tick: maxActions, rules, present: true, path }
}

/**
 * Validate one loop rule.
 * @param rule - candidate rule.
 * @param index - its position, for diagnostics.
 * @returns the normalized rule.
 */
function validateRule(rule, index) {
  const where = `native loop rule[${index}]`
  if (rule === null || typeof rule !== 'object' || Array.isArray(rule)) {
    throw new Error(`${where} must be an object`)
  }
  const when = rule.when ?? 'queued'
  if (!['queued', 'in_flight', 'any'].includes(when)) {
    throw new Error(`${where}.when must be queued, in_flight, or any`)
  }
  if (rule.enabled === false) return { id: rule.id ?? `rule-${index}`, when, enabled: false, matcher: () => false }
  if (typeof rule.script !== 'string' || !SCRIPT_NAME.test(rule.script)) {
    throw new Error(`${where}.script must be one bare bin/fm-*.sh file name`)
  }
  if (DENIED_SCRIPTS.has(rule.script)) {
    throw new Error(`${where}.script ${rule.script} is owned by the supervisor lifecycle and cannot be a loop action`)
  }
  const args = rule.args === undefined ? [] : rule.args
  if (!Array.isArray(args) || args.length > 200 || args.some((arg) => typeof arg !== 'string')) {
    throw new Error(`${where}.args must be an array of at most 200 strings`)
  }
  const vars = rule.vars === undefined ? {} : rule.vars
  if (vars === null || typeof vars !== 'object' || Array.isArray(vars)) {
    throw new Error(`${where}.vars must be an object`)
  }
  for (const [key, value] of Object.entries(vars)) {
    if (typeof value !== 'string') throw new Error(`${where}.vars.${key} must be a string`)
  }
  const timeoutMs = rule.timeout_ms === undefined ? 120000 : Number(rule.timeout_ms)
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 900000) {
    throw new Error(`${where}.timeout_ms must be an integer between 1000 and 900000`)
  }
  if (rule.kind !== undefined && typeof rule.kind !== 'string') {
    throw new Error(`${where}.kind must be a string when set`)
  }
  return {
    id: typeof rule.id === 'string' && rule.id.length > 0 ? rule.id : `rule-${index}`,
    when,
    enabled: true,
    script: rule.script,
    args,
    vars,
    kind: rule.kind,
    timeout_ms: timeoutMs,
  }
}

/**
 * Observe the home's durable records through read-only engine scripts.
 * @param options - observation inputs.
 * @returns `{ snapshot, queued, inFlight, degraded }`.
 */
export async function observeHome({ home, timeoutMs = 60000, signal } = {}) {
  const result = await runScript(home, 'fm-fleet-snapshot.sh', ['--json'], { timeoutMs, signal })
  if (result.code !== 0) {
    return {
      snapshot: null,
      queued: [],
      inFlight: [],
      degraded: `fm-fleet-snapshot.sh ${result.timedOut ? 'timed out' : `exited ${result.code}`}: ${combinedOutput(result).slice(0, 2000)}`,
    }
  }
  let snapshot
  try {
    snapshot = JSON.parse(result.stdout)
  } catch (error) {
    return { snapshot: null, queued: [], inFlight: [], degraded: `snapshot was not JSON: ${error.message}` }
  }
  const records = Array.isArray(snapshot?.backlog?.records) ? snapshot.backlog.records : []
  const queued = records
    .filter((record) => record !== null && typeof record === 'object')
    .filter((record) => record.state === 'queued')
    .filter((record) => (Array.isArray(record.unresolved_blocker_ids) ? record.unresolved_blocker_ids.length === 0 : true))
    .map((record) => ({
      id: String(record.id ?? ''),
      when: 'queued',
      state: record.state,
      kind: record.kind ?? null,
      title: record.title ?? null,
      repo: record.repo ?? null,
      pr_url: record.pr_url ?? null,
      record,
    }))
    .filter((item) => item.id.length > 0)
  const tasks = Array.isArray(snapshot?.tasks) ? snapshot.tasks : []
  const inFlight = tasks
    .filter((task) => task !== null && typeof task === 'object')
    .filter((task) => task.state === 'in_flight' || task?.backlog?.state === 'in_flight')
    .map((task) => ({
      id: String(task.id ?? ''),
      when: 'in_flight',
      state: 'in_flight',
      kind: task.kind ?? null,
      title: task.title ?? task?.backlog?.title ?? null,
      repo: task.repo ?? task?.backlog?.repo ?? null,
      pr_url: task.pr_url ?? task?.pr_url ?? null,
      task,
    }))
    .filter((item) => item.id.length > 0)
  return { snapshot, queued, inFlight, degraded: null }
}

/**
 * Whether a rule applies to one work item.
 * @param rule - a validated rule.
 * @param item - one observed item.
 * @returns true when the rule matches.
 */
function ruleMatches(rule, item) {
  if (rule.enabled === false) return false
  if (rule.when !== 'any' && rule.when !== item.when) return false
  if (rule.kind !== undefined && rule.kind !== item.kind) return false
  return true
}

/**
 * Substitute `{name}` placeholders in one argument.
 * @param argument - the template.
 * @param values - available values.
 * @returns `{ text }` or `{ missing }`.
 */
function substitute(argument, values) {
  let missing = null
  const text = argument.replace(/\{([a-zA-Z0-9_]+)\}/g, (_match, name) => {
    const value = values[name]
    if (value === undefined || value === null || value === '') {
      missing = name
      return `{${name}}`
    }
    return String(value)
  })
  return missing === null ? { text } : { missing }
}

/**
 * Build the argv for one rule and item.
 * @param rule - the validated rule.
 * @param item - the observed item.
 * @returns `{ argv }` or `{ missing }`.
 */
function buildArgv(rule, item) {
  const values = {
    ...rule.vars,
    id: item.id,
    task: item.id,
    kind: item.kind,
    title: item.title,
    repo: item.repo,
    pr_url: item.pr_url,
    state: item.state,
  }
  const argv = []
  for (const template of rule.args) {
    const substituted = substitute(template, values)
    if (substituted.missing !== undefined) return { missing: substituted.missing }
    argv.push(substituted.text)
  }
  return { argv }
}

/**
 * Check the task project's merge posture before a merge action.
 * @param options - gate inputs.
 * @returns `{ allowed, reason, mode, yolo }`.
 */
export async function mergeAuthority({ home, rule, script, timeoutMs = 30000, signal } = {}) {
  const kind = MERGE_SCRIPTS.get(script)
  if (kind === undefined) return { allowed: true, reason: null, mode: null, yolo: null }
  const project = rule.vars?.project
  if (typeof project !== 'string' || project.length === 0) {
    return { allowed: false, reason: 'merge rule must set vars.project', mode: null, yolo: null }
  }
  const result = await runScript(home, 'fm-project-mode.sh', [project], { timeoutMs, signal })
  if (result.code !== 0) {
    return { allowed: false, reason: `project posture unreadable for ${project}`, mode: null, yolo: null }
  }
  const [mode = '', yolo = ''] = combinedOutput(result).trim().split(/\s+/)
  if (kind === 'pr') {
    const allowed = yolo === 'on' && (mode === 'no-mistakes' || mode === 'direct-PR')
    return {
      allowed,
      reason: allowed ? null : `PR merge needs a no-mistakes/direct-PR project with yolo on (read ${mode} ${yolo})`,
      mode,
      yolo,
    }
  }
  const allowed = yolo === 'on' && mode === 'local-only'
  return {
    allowed,
    reason: allowed ? null : `local-only landing needs mode local-only with yolo on (read ${mode} ${yolo})`,
    mode,
    yolo,
  }
}

/**
 * Run one reconciliation tick.
 * @param options - tick inputs.
 * @param options.home - the home to reconcile.
 * @param options.identity - the calling session identity.
 * @param options.config - a loaded loop config, or undefined to load it.
 * @param options.apply - false (default) only reports what it would do.
 * @param options.pluginDir - native plugin package root exported to actions.
 * @param options.now - clock function, for tests.
 * @param options.signal - cancellation.
 * @returns a `fm-native-loop.v1` report.
 */
export async function reconcileTick({
  home,
  identity,
  config,
  apply = false,
  pluginDir,
  now = Date.now,
  signal,
} = {}) {
  assertSameHome(identity, home)
  const clock = typeof now === 'function' ? now : () => now
  const started = clock()
  const reaped = reapExpiredLeases({ home, now: clock })
  const loop = config ?? loadLoopConfig({ home })
  const report = {
    schema: LOOP_REPORT_SCHEMA,
    home,
    session: identity.sessionId,
    started_at: started,
    applied: apply === true,
    config_present: loop.present,
    reaped,
    observed: { queued: 0, in_flight: 0 },
    actions: [],
    skipped: [],
    degraded: null,
  }
  const observation = await observeHome({ home, signal })
  if (observation.degraded !== null) {
    report.degraded = observation.degraded
    return report
  }
  // Observed counts are the raw durable picture; blocked queued rows are
  // reported as skipped rather than silently omitted from the count.
  const allRecords = Array.isArray(observation.snapshot?.backlog?.records)
    ? observation.snapshot.backlog.records
    : []
  const allTasks = Array.isArray(observation.snapshot?.tasks) ? observation.snapshot.tasks : []
  report.observed = {
    queued: allRecords.filter((record) => record?.state === 'queued').length,
    in_flight: allTasks.filter((task) => task?.state === 'in_flight' || task?.backlog?.state === 'in_flight').length,
  }
  for (const record of allRecords) {
    if (record?.state !== 'queued') continue
    const blockers = Array.isArray(record.unresolved_blocker_ids) ? record.unresolved_blocker_ids : []
    if (blockers.length > 0) {
      report.skipped.push({ task: String(record.id ?? ''), rule: null, reason: `blocked by ${blockers.join(', ')}` })
    }
  }
  if (loop.rules.length === 0) return report

  const items = [...observation.queued, ...observation.inFlight]
  let attempts = 0
  for (const item of items) {
    if (attempts >= loop.max_actions_per_tick) break
    const rule = loop.rules.find((candidate) => ruleMatches(candidate, item))
    if (rule === undefined) continue
    const built = buildArgv(rule, item)
    if (built.missing !== undefined) {
      report.skipped.push({ task: item.id, rule: rule.id, reason: `missing value {${built.missing}}` })
      continue
    }
    attempts += 1
    const action = {
      task: item.id,
      rule: rule.id,
      script: rule.script,
      args: built.argv,
      outcome: 'planned',
      reason: null,
      token: null,
      exit_code: null,
    }
    report.actions.push(action)
    if (!apply) continue
    const authority = await mergeAuthority({ home, rule, script: rule.script, signal })
    if (!authority.allowed) {
      action.outcome = 'skipped'
      action.reason = authority.reason
      report.skipped.push({ task: item.id, rule: rule.id, reason: authority.reason })
      continue
    }
    const timeoutMs = rule.timeout_ms
    try {
      const leased = await withLease(
        {
          home,
          task: item.id,
          identity,
          purpose: `reconcile:${rule.id}`,
          ttlMs: Math.max(120000, timeoutMs + 60000),
        },
        async (handle) => runScript(home, rule.script, built.argv, {
          timeoutMs,
          signal,
          env: {
            ...(pluginDir === undefined ? {} : { FM_NATIVE_PLUGIN_DIR: pluginDir }),
            FM_LEASE_HOME: home,
            FM_LEASE_TASK: item.id,
            FM_LEASE_TOKEN: String(handle.token),
            FM_LEASE_SESSION: identity.sessionId,
            FM_LEASE_OWNER: identity.ownerLabel,
          },
        }),
      )
      action.token = leased.lease?.token ?? null
      action.exit_code = leased.result.code
      action.outcome = leased.result.code === 0 ? 'acted' : 'failed'
      if (leased.fenced !== null) {
        action.outcome = 'fenced'
        action.reason = `${leased.fenced.code ?? 'fenced'}: ${leased.fenced.message}`
      } else if (leased.result.code !== 0) {
        action.reason = combinedOutput(leased.result).slice(0, 2000)
      }
      if (leased.result.timedOut) action.reason = `timed out after ${timeoutMs}ms`
    } catch (error) {
      const code = error?.code === 'contention' ? 'contention' : (error?.code ?? 'error')
      action.outcome = code === 'contention' ? 'contended' : 'error'
      action.reason = error instanceof Error ? error.message : String(error)
    }
  }
  return report
}

/**
 * Render the one-line hint for an interactive session, when a tick needs one.
 * @param report - a tick report.
 * @returns the hint text, or null when nothing is captain-relevant.
 */
export function reconcileHint(report) {
  if (report === undefined || report === null) return null
  if (report.degraded !== null) return `native reconcile could not read ${report.home}: ${report.degraded}`
  const failed = report.actions.filter((action) => ['failed', 'error', 'fenced'].includes(action.outcome))
  const skipped = report.skipped.filter((entry) => /merge|project|posture/.test(entry.reason ?? ''))
  const lines = []
  if (failed.length > 0) {
    lines.push(`native reconcile: ${failed.length} action(s) failed`)
    for (const action of failed) lines.push(`- ${action.task} (${action.rule}): ${(action.reason ?? '').split('\n')[0]}`)
  }
  if (skipped.length > 0) {
    lines.push(`native reconcile: ${skipped.length} action(s) need a posture or captain decision`)
    for (const entry of skipped) lines.push(`- ${entry.task} (${entry.rule}): ${entry.reason}`)
  }
  return lines.length === 0 ? null : lines.join('\n')
}
