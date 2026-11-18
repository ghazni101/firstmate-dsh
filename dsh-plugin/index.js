/**
 * Firstmate native supervisor for DeepSeek Harness.
 *
 * Phase 0 of the DSH-native overhaul: identity plus read-only fleet tools plus
 * the per-task lease foundation. It is inert unless `config.enabled` is true on
 * the Loader row and the home carries `config/dsh-native`, so linking the
 * bundle cannot change behavior for an existing home.
 *
 * What it does when enabled:
 *
 * 1. Identity — for a root DSH session whose directory resolves to a Firstmate
 *    home, records `{ sessionId, home, ownerLabel }` and contributes one static
 *    runtime-context note. Subagents and directories outside a home are
 *    ignored. Process ancestry and the fleet lock play no part.
 * 2. Read-only tools — `firstmate_native_status`, `firstmate_native_tasks`, `firstmate_native_inbox`
 *    run one allowlisted home script with `FM_HOME` pinned. No tool takes a
 *    script name, and no tool mutates.
 * 3. Follow-up transport — a deduplicating `agent.followup()` channel for later
 *    phases. It is latency only; durable files remain the truth.
 * 4. Phase 1 task authority — `firstmate_native_lease` and `firstmate_native_run`. A mutating
 *    script run requires a task and executes under that task's lease, with the
 *    lease identity exported to the script; read-only scripts run directly and
 *    the session-lifecycle scripts are refused.
 *
 * It does not inject a session-start digest, arm supervision, host a watcher or
 * daemon, enter a posture, claim a home-wide owner, or mutate anything outside a
 * held task lease. The per-task lease library lives in `./src/lease.js`, its CLI
 * in `./bin/fm-lease.mjs`, and its bash adapter in `./lib/fm-lease2-lib.sh`.
 *
 * Contract: docs/dsh-native-architecture.md.
 *
 * @module @local/dsh-plugin-firstmate-native
 */
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import { deliveryAction, resolveDelivery } from './src/delivery.js'
import { LeaseError } from './src/errors.js'
import { identifySession, identityNote } from './src/identity.js'
import { isNativeHome } from './src/home.js'
import {
  acquireLease,
  guardLease,
  inspectLease,
  listLeases,
  reapExpiredLeases,
  releaseLease,
  renewLease,
  withLease,
} from './src/lease.js'
import { reconcileHint, reconcileTick } from './src/reconcile.js'
import { assertScript, capOutput, combinedOutput, failScript, MAX_OUTPUT_CHARS, runScript, toolResult } from './src/scripts.js'
import { createFollowupChannel } from './src/transport.js'

/** Stable plugin name used by the Loader row. */
export const name = 'firstmate-native'

/** Services this plugin contributes through; the tool registry gates activation. */
export const inject = ['tools']

/** Default timeout for one read-only tool call. */
const DEFAULT_TIMEOUT_MS = 120000

/** Fixed allowlist per tool: no script name ever comes from the model. */
const READ_ONLY_SCRIPTS = Object.freeze({
  status: new Set(['fm-bearings-snapshot.sh']),
  tasks: new Set(['fm-tasks-axi.sh']),
  inbox: new Set(['fm-inbox.sh']),
})

/** The plugin package root, exported to child scripts as FM_NATIVE_PLUGIN_DIR. */
const PLUGIN_DIR = fileURLToPath(new URL('.', import.meta.url)).replace(/[\\/]+$/, '')

/** Engine scripts the command channel never runs: their owner is the plugin itself. */
const CHANNEL_DENIED_SCRIPTS = new Set([
  'fm-session-start.sh',
  'fm-watch.sh',
  'fm-watch-arm.sh',
  'fm-watch-checkpoint.sh',
  'fm-supervise-daemon.sh',
  'fm-afk-start.sh',
  'fm-supervision-host.sh',
])

/**
 * Scripts verified as read-only. Every other allowlisted script is classified as
 * mutating and requires a task lease; a read-only session never mutates.
 */
const CHANNEL_READ_ONLY_SCRIPTS = new Set([
  'fm-bearings-snapshot.sh',
  'fm-crew-state.sh',
  'fm-fleet-snapshot.sh',
  'fm-harness.sh',
  'fm-project-mode.sh',
])

/** Longest timeout a command-channel call may ask for. */
const CHANNEL_MAX_TIMEOUT_MS = 900000

/** Shortest timeout a command-channel call may ask for. */
const CHANNEL_MIN_TIMEOUT_MS = 1000

/** Bounds for a lease TTL requested through the lease tool. */
const LEASE_MIN_TTL_MS = 1000
const LEASE_MAX_TTL_MS = 86400000

/** Runtime-context order: after working-directory/sandbox/approval context. */
const IDENTITY_CONTEXT_ORDER = 130

/** Context section name contributed for one session. */
const IDENTITY_CONTEXT_NAME = 'firstmate:native-identity'

/**
 * Build a registry-ready tool definition from a compact description.
 * @param spec - name, description, parameters, execute, and optional timeout.
 * @returns a ToolDefinition the Harness registry accepts.
 */
function defineTool(spec) {
  return {
    name: spec.name,
    description: spec.description,
    parameters: spec.parameters,
    output: {
      schema: { type: 'object', additionalProperties: true },
      render(_args, value) {
        const text = value && typeof value.text === 'string' && value.text.length > 0
          ? value.text
          : JSON.stringify(value, null, 2)
        return [{ type: 'text', text }]
      },
    },
    ...(spec.timeoutMs === undefined ? {} : { timeoutMs: spec.timeoutMs }),
    execute: spec.execute,
  }
}

/**
 * Register the native supervisor surface on this profile's tool registry.
 * @param ctx - plugin context.
 * @param config - the Loader row's config object.
 */
export function apply(ctx, config = {}) {
  // Feature flag: the default row ships disabled and registers nothing at all.
  if (config.enabled !== true) return
  if (ctx?.tools?.register === undefined) return

  const configuredHome = typeof config.home === 'string' ? config.home.trim() : undefined
  const defaultTimeout = Number.isFinite(config.timeoutMs) && config.timeoutMs > 0
    ? config.timeoutMs
    : DEFAULT_TIMEOUT_MS

  /** Per-agent identity, keyed by DSH agent id. */
  const identities = new Map()

  /** Per-agent runtime-context disposer, keyed by DSH agent id. */
  const contextDisposers = new Map()

  /** Latency-only follow-up channel for reconciliation hints. */
  const followups = createFollowupChannel()

  /**
   * Resolve the identity for a tool call's agent, re-deriving it when the agent
   * predates plugin activation.
   * @param exec - the tool run context.
   * @returns the identity.
   * @throws when this session is not a supervisor candidate or its home is not opted in.
   */
  const requireIdentity = (exec) => {
    const agent = exec?.agent
    const cached = agent === undefined ? undefined : identities.get(agent.id)
    const identity = cached ?? identifySession({ agent, configuredHome })
    if (identity === undefined || identity === null) {
      throw new Error(
        'This session is not a Firstmate supervisor session: it is a subagent, or its working directory is not inside a Firstmate home. Run it from inside a home or pin the plugin row\'s `home` option.',
      )
    }
    identities.set(agent?.id ?? identity.agentId, identity)
    if (!isNativeHome(identity.home)) {
      throw new Error(
        `The native Firstmate surface is not enabled for ${identity.home}: create ${identity.home}/config/dsh-native to opt in. Nothing was read or changed.`,
      )
    }
    return identity
  }

  /**
   * Run one allowlisted read-only script for a tool call.
   * @param exec - tool run context.
   * @param identity - the resolved identity.
   * @param tool - tool key in {@link READ_ONLY_SCRIPTS}.
   * @param script - the script name.
   * @param args - argv after the script.
   * @param label - operation label.
   * @param timeoutMs - timeout for this call.
   * @returns `{ result, output }`.
   */
  const runReadOnly = async (exec, identity, tool, script, args, label, timeoutMs) => {
    assertScript(script, READ_ONLY_SCRIPTS[tool])
    const result = await runScript(identity.home, script, args, {
      timeoutMs,
      signal: exec?.signal,
    })
    if (result.code !== 0) failScript(label, result, timeoutMs)
    return { result, output: combinedOutput(result) }
  }

  /**
   * Normalize a command-channel timeout.
   * @param value - requested milliseconds, when set.
   * @param fallback - default for this call site.
   * @returns the bounded timeout.
   */
  const normalizeTimeout = (value, fallback) => {
    if (value === undefined) return fallback
    if (!Number.isInteger(value) || value < CHANNEL_MIN_TIMEOUT_MS || value > CHANNEL_MAX_TIMEOUT_MS) {
      throw new Error(`timeout_ms must be an integer between ${CHANNEL_MIN_TIMEOUT_MS} and ${CHANNEL_MAX_TIMEOUT_MS}`)
    }
    return value
  }

  /**
   * Normalize a lease TTL.
   * @param value - requested milliseconds, when set.
   * @returns the bounded TTL, or undefined to use the library default.
   */
  const normalizeTtl = (value) => {
    if (value === undefined) return undefined
    if (!Number.isInteger(value) || value < LEASE_MIN_TTL_MS || value > LEASE_MAX_TTL_MS) {
      throw new Error(`ttl_ms must be an integer between ${LEASE_MIN_TTL_MS} and ${LEASE_MAX_TTL_MS}`)
    }
    return value
  }

  /**
   * Normalize a command-channel argv list.
   * @param value - the requested arguments.
   * @returns a bounded array of strings.
   */
  const normalizeArgs = (value) => {
    if (value === undefined) return []
    if (!Array.isArray(value) || value.length > 200) {
      throw new Error('args must be an array of at most 200 strings')
    }
    return value.map((item) => String(item))
  }

  /**
   * Require a task id argument.
   * @param value - candidate.
   * @param label - what to name in the error.
   * @returns the task id.
   */
  const requireTaskId = (value, label = 'task') => {
    if (typeof value !== 'string' || value.length === 0) throw new Error(`${label} is required`)
    return value
  }

  /**
   * Require a fencing token argument.
   * @param value - candidate.
   * @returns the token.
   */
  const requireToken = (value) => {
    if (!Number.isSafeInteger(value) || value < 0) throw new Error('token must be a non-negative integer')
    return value
  }

  /**
   * Re-throw a lease refusal with its stable code in the model-facing message.
   * @param error - anything thrown by the lease library.
   */
  const surfaceLeaseError = (error) => {
    if (error instanceof LeaseError) throw new Error(`${error.code}: ${error.message}`)
    throw error
  }

  /**
   * Build one command-channel result value.
   * @param fields - outcome fields.
   * @returns the canonical tool value.
   */
  const channelOutcome = ({ home, script, args, readOnly, result, token = null, leased = false, fenced = null }) => {
    const stdout = capOutput(result.stdout, MAX_OUTPUT_CHARS)
    const stderr = capOutput(result.stderr, MAX_OUTPUT_CHARS)
    const exitCode = result.timedOut || result.spawnError !== undefined ? null : result.code
    const body = capOutput(
      [`bin/${script} ${args.join(' ')}`.trim(), stdout.text, stderr.text].filter((part) => part.length > 0).join('\n'),
      MAX_OUTPUT_CHARS,
    )
    return {
      ok: exitCode === 0,
      home,
      script,
      args,
      read_only: readOnly,
      exit_code: exitCode,
      timed_out: result.timedOut,
      signal: result.signal ?? null,
      stdout: stdout.text,
      stderr: stderr.text,
      token,
      leased,
      fenced,
      text: body.text,
      truncated: stdout.truncated || stderr.truncated || body.truncated,
    }
  }

  ctx.tools.register(defineTool({
    name: 'firstmate_native_status',
    description:
      'Read-only Firstmate fleet snapshot for this session\'s home: in-flight tasks, open decisions, secondmates, landed work, gates, and reports. Use it before dispatch, on a heartbeat, or whenever current fleet state matters. Never mutates the home and takes no task lease.',
    parameters: {
      type: 'object',
      properties: {
        include_prs: {
          type: 'boolean',
          description: 'Also perform live forge discovery and checks (slower; needs authenticated gh/glab/tea).',
        },
      },
      additionalProperties: false,
    },
    timeoutMs: 180000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const argv = ['--json']
      if (args?.include_prs === true) argv.push('--include-prs')
      const { output } = await runReadOnly(exec, identity, 'status', 'fm-bearings-snapshot.sh', argv, 'firstmate_native_status', 150000)
      const capped = capOutput(output, MAX_OUTPUT_CHARS)
      try {
        const snapshot = JSON.parse(output)
        return toolResult({
          home: identity.home,
          tool: 'firstmate_native_status',
          format: 'json',
          data: snapshot,
          text: capped.text,
          truncated: capped.truncated,
        })
      } catch {
        return toolResult({
          home: identity.home,
          tool: 'firstmate_native_status',
          format: 'text',
          data: null,
          text: capped.text,
          truncated: capped.truncated,
        })
      }
    },
  }))

  ctx.tools.register(defineTool({
    name: 'firstmate_native_tasks',
    description:
      'Read-only listing of this home\'s backlog through its own configured backend. Filter by state, cap the page, or request extra fields. Never mutates the backlog and takes no task lease.',
    parameters: {
      type: 'object',
      properties: {
        state: {
          type: 'string',
          enum: ['queued', 'in_flight', 'done', 'held'],
          description: 'Only rows in this state.',
        },
        limit: {
          type: 'integer',
          minimum: 1,
          maximum: 200,
          description: 'Maximum rows to print.',
        },
        fields: {
          type: 'string',
          description: 'Comma-separated extra fields, such as "blocked_by,created".',
        },
        blocked: {
          type: 'boolean',
          description: 'Only rows that are blocked.',
        },
      },
      additionalProperties: false,
    },
    timeoutMs: 90000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const argv = ['list']
      if (args?.state !== undefined) {
        if (!['queued', 'in_flight', 'done', 'held'].includes(args.state)) {
          throw new Error('state must be one of queued, in_flight, done, held')
        }
        argv.push('--state', args.state)
      }
      if (Number.isInteger(args?.limit)) {
        if (args.limit < 1 || args.limit > 200) throw new Error('limit must be between 1 and 200')
        argv.push('--limit', String(args.limit))
      }
      if (typeof args?.fields === 'string' && args.fields.length > 0) {
        if (!/^[a-z_]+(,[a-z_]+)*$/.test(args.fields)) {
          throw new Error('fields must be a comma-separated list of lowercase field names')
        }
        argv.push('--fields', args.fields)
      }
      if (args?.blocked === true) argv.push('--blocked')
      const { output } = await runReadOnly(exec, identity, 'tasks', 'fm-tasks-axi.sh', argv, 'firstmate_native_tasks', defaultTimeout)
      const capped = capOutput(output, MAX_OUTPUT_CHARS)
      return toolResult({
        home: identity.home,
        tool: 'firstmate_native_tasks',
        format: 'text',
        data: null,
        text: capped.text,
        truncated: capped.truncated,
      })
    },
  }))

  ctx.tools.register(defineTool({
    name: 'firstmate_native_inbox',
    description:
      'Read-only view of this home\'s captain inbox: supervisor readiness, the human note list, or pending receipts. Never mutates a note and takes no task lease.',
    parameters: {
      type: 'object',
      properties: {
        view: {
          type: 'string',
          enum: ['ready', 'notes', 'receipts'],
          description: 'ready (default) reports readiness; notes lists notes; receipts lists pending note receipts as JSON.',
        },
      },
      additionalProperties: false,
    },
    timeoutMs: 90000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const view = args?.view ?? 'ready'
      if (!['ready', 'notes', 'receipts'].includes(view)) {
        throw new Error('view must be ready, notes, or receipts')
      }
      const argv = view === 'notes'
        ? ['list']
        : view === 'receipts'
          ? ['receipts', '--all-pending', '--json']
          : ['ready']
      const { output } = await runReadOnly(exec, identity, 'inbox', 'fm-inbox.sh', argv, 'firstmate_native_inbox', defaultTimeout)
      const capped = capOutput(output, MAX_OUTPUT_CHARS)
      let data = null
      let format = 'text'
      if (view !== 'notes') {
        try {
          data = JSON.parse(output)
          format = 'json'
        } catch {
          data = null
        }
      }
      return toolResult({
        home: identity.home,
        tool: 'firstmate_native_inbox',
        format,
        data,
        text: capped.text,
        truncated: capped.truncated,
      })
    },
  }))

  ctx.tools.register(defineTool({
    name: 'firstmate_native_lease',
    description:
      'Task lease control for this session\'s home. One task at a time has one holder; the returned token is the fencing token a mutation must present. acquire is idempotent for the same session, renew/heartbeat keeps a hold alive, release drops it, inspect reads without mutating, and reap frees expired holds only. Expiry never kills a worker or discards unlanded work.',
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['acquire', 'renew', 'release', 'inspect', 'reap'],
          description: 'acquire, renew, release, inspect, or reap.',
        },
        task: { type: 'string', description: 'Exact task id. Required for every action except reap.' },
        token: { type: 'integer', description: 'The fencing token from acquire. Required for renew and release.' },
        purpose: { type: 'string', description: 'Short label naming the operation, shown in refusals.' },
        ttl_ms: { type: 'integer', description: 'Optional hold validity in milliseconds (1000-86400000).' },
      },
      required: ['action'],
      additionalProperties: false,
    },
    timeoutMs: 60000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const action = args?.action
      try {
        if (action === 'reap') {
          const reaped = reapExpiredLeases({ home: identity.home })
          const text = reaped.length === 0
            ? 'No expired leases in this home.'
            : `Reaped ${reaped.length} expired lease(s): ${reaped.map((row) => row.task).join(', ')}`
          return { ok: true, home: identity.home, action, reaped, text }
        }
        if (!['acquire', 'renew', 'release', 'inspect'].includes(action)) {
          throw new Error('action must be acquire, renew, release, inspect, or reap')
        }
        const task = requireTaskId(args?.task)
        const ttlMs = normalizeTtl(args?.ttl_ms)
        if (action === 'inspect') {
          const inspection = inspectLease({ home: identity.home, task })
          return { ok: true, home: identity.home, action, task, inspection, text: JSON.stringify(inspection, null, 2) }
        }
        if (action === 'acquire') {
          const record = acquireLease({
            home: identity.home,
            task,
            identity,
            purpose: typeof args?.purpose === 'string' ? args.purpose : '',
            ...(ttlMs === undefined ? {} : { ttlMs }),
          })
          return { ok: true, home: identity.home, action, task, token: record.token, record, text: JSON.stringify(record, null, 2) }
        }
        const token = requireToken(args?.token)
        if (action === 'renew') {
          const record = renewLease({ home: identity.home, task, identity, token, ...(ttlMs === undefined ? {} : { ttlMs }) })
          return { ok: true, home: identity.home, action, task, token: record.token, record, text: JSON.stringify(record, null, 2) }
        }
        const record = releaseLease({ home: identity.home, task, identity, token })
        return { ok: true, home: identity.home, action, task, token, record, text: JSON.stringify(record, null, 2) }
      } catch (error) {
        surfaceLeaseError(error)
      }
    },
  }))

  ctx.tools.register(defineTool({
    name: 'firstmate_native_run',
    description:
      'Run one allowlisted Firstmate home script (bin/fm-*.sh) as this session. Read-only scripts run directly. A mutating script requires a task and runs under that task\'s lease: the tool either takes the lease for the call and releases it afterwards, or uses the token you already hold and leaves your lease alone. The lease identity is exported to the script as FM_LEASE_HOME, FM_LEASE_TASK, FM_LEASE_TOKEN, FM_LEASE_SESSION, and FM_LEASE_OWNER. Session-start, lock, watcher, daemon, and terminal-launcher scripts are refused.',
    parameters: {
      type: 'object',
      properties: {
        script: {
          type: 'string',
          description: 'One bare script file name under the home bin/, such as "fm-tasks-axi.sh"; any path is refused.',
        },
        args: {
          type: 'array',
          items: { type: 'string' },
          description: 'Arguments after the script name, one array element per argument. No shell parsing or expansion happens.',
        },
        task: {
          type: 'string',
          description: 'Task id the script mutates. Required for a mutating script; the lease is taken for the call unless token is given.',
        },
        token: {
          type: 'integer',
          description: 'A fencing token this session already holds for task. When set, the lease is verified and left in place instead of acquired and released.',
        },
        timeout_ms: {
          type: 'integer',
          description: 'Optional timeout for this call, between 1000 and 900000, defaulting to the plugin\'s configured timeout.',
        },
      },
      required: ['script'],
      additionalProperties: false,
    },
    timeoutMs: 960000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const script = typeof args?.script === 'string' ? args.script : ''
      if (!/^fm-[a-z0-9][a-z0-9-]*\.sh$/.test(script)) {
        throw new Error('script must be one bare bin/fm-*.sh file name')
      }
      if (CHANNEL_DENIED_SCRIPTS.has(script)) {
        throw new Error(`${script} is owned by the plugin's own session lifecycle and is refused`)
      }
      const argv = normalizeArgs(args?.args)
      const timeoutMs = normalizeTimeout(args?.timeout_ms, defaultTimeout)
      const env = { FM_NATIVE_PLUGIN_DIR: PLUGIN_DIR }
      const readOnly = CHANNEL_READ_ONLY_SCRIPTS.has(script)
      if (readOnly) {
        const result = await runScript(identity.home, script, argv, { timeoutMs, signal: exec?.signal, env })
        return channelOutcome({ home: identity.home, script, args: argv, readOnly: true, result })
      }
      const task = requireTaskId(args?.task, 'task (required for a mutating script)')
      const leaseEnv = {
        ...env,
        FM_LEASE_HOME: identity.home,
        FM_LEASE_TASK: task,
        FM_LEASE_SESSION: identity.sessionId,
        FM_LEASE_OWNER: identity.ownerLabel,
      }
      try {
        if (args?.token !== undefined) {
          const token = requireToken(args.token)
          guardLease({ home: identity.home, task, identity, token })
          const result = await runScript(identity.home, script, argv, {
            timeoutMs,
            signal: exec?.signal,
            env: { ...leaseEnv, FM_LEASE_TOKEN: String(token) },
          })
          return channelOutcome({ home: identity.home, script, args: argv, readOnly: false, result, token, leased: true })
        }
        const ttlMs = Math.max(120000, timeoutMs + 60000)
        const leased = await withLease(
          { home: identity.home, task, identity, purpose: `run:${script}`, ttlMs },
          async (handle) => runScript(identity.home, script, argv, {
            timeoutMs,
            signal: exec?.signal,
            env: { ...leaseEnv, FM_LEASE_TOKEN: String(handle.token) },
          }),
        )
        return channelOutcome({
          home: identity.home,
          script,
          args: argv,
          readOnly: false,
          result: leased.result,
          token: leased.lease?.token ?? null,
          leased: true,
          fenced: leased.fenced === null ? null : `${leased.fenced.code ?? 'fenced'}: ${leased.fenced.message}`,
        })
      } catch (error) {
        surfaceLeaseError(error)
      }
    },
  }))

  /**
   * Count the durable wake-queue rows in one home.
   * @param home - Firstmate home.
   * @returns the non-empty line count, or 0 when the queue is absent.
   */
  const wakeQueueCount = (home) => {
    try {
      return readFileSync(join(home, 'state', '.wake-queue'), 'utf8')
        .split('\n')
        .filter((line) => line.trim().length > 0)
        .length
    } catch {
      return 0
    }
  }

  ctx.tools.register(defineTool({
    name: 'firstmate_native_reconcile',
    description:
      'Run one per-home reconciliation tick for this session\'s home: reap expired leases, read the durable records, select actionable work authored in config/native-loop.json, and (with apply) run each action under that task\'s lease. Dry-run by default. Merge actions are gated by the task project\'s posture and skip when it is not yolo. Never kills a worker, tears down work, or consults the fleet lock.',
    parameters: {
      type: 'object',
      properties: {
        apply: { type: 'boolean', description: 'Execute the selected actions. False (default) only reports the plan.' },
        hint: { type: 'boolean', description: 'Deliver a follow-up to this session when the tick needs captain attention.' },
      },
      additionalProperties: false,
    },
    timeoutMs: 900000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const report = await reconcileTick({
        home: identity.home,
        identity,
        apply: args?.apply === true,
        pluginDir: PLUGIN_DIR,
        signal: exec?.signal,
      })
      const hint = reconcileHint(report)
      if (args?.hint === true && hint !== null && exec?.agent !== undefined) {
        followups.deliver(exec.agent, hint)
      }
      return {
        ...report,
        ok: report.degraded === null,
        hint,
        tool: 'firstmate_native_reconcile',
        text: JSON.stringify(report, null, 2),
      }
    },
  }))

  ctx.tools.register(defineTool({
    name: 'firstmate_native_start',
    description:
      'Read-only native session start for this session\'s home: identity, inbox readiness, fleet/backlog summary, held task leases, and queued durable wakes. It composes the native startup input without running session-start and without mutating anything.',
    parameters: { type: 'object', properties: {}, additionalProperties: false },
    timeoutMs: 180000,
    async execute(_args, exec) {
      const identity = requireIdentity(exec)
      const home = identity.home
      const signal = exec?.signal
      const [snapshotResult, readyResult] = await Promise.all([
        runScript(home, 'fm-fleet-snapshot.sh', ['--json'], { timeoutMs: 90000, signal }),
        runScript(home, 'fm-inbox.sh', ['ready'], { timeoutMs: 60000, signal }),
      ])
      let snapshot = null
      if (snapshotResult.code === 0) {
        try {
          snapshot = JSON.parse(snapshotResult.stdout)
        } catch {
          snapshot = null
        }
      }
      let readiness = null
      if (readyResult.code === 0) {
        try {
          readiness = JSON.parse(readyResult.stdout)
        } catch {
          readiness = null
        }
      }
      const records = Array.isArray(snapshot?.backlog?.records) ? snapshot.backlog.records : []
      const summary = {
        schema: snapshot?.schema ?? null,
        backlog: {
          queued: records.filter((record) => record?.state === 'queued').length,
          in_flight: records.filter((record) => record?.state === 'in_flight').length,
          held: records.filter((record) => record?.hold_bucket !== null && record?.hold_bucket !== undefined).length,
        },
        tasks: Array.isArray(snapshot?.tasks) ? snapshot.tasks.length : 0,
      }
      const leases = listLeases({ home })
      const digest = {
        ok: snapshot !== null && readyResult.code === 0,
        identity: {
          session: identity.sessionId,
          owner: identity.ownerLabel,
          home: identity.home,
          cwd: identity.cwd,
        },
        readiness,
        summary,
        leases: {
          held: leases.filter((lease) => lease.live).length,
          free: leases.filter((lease) => lease.state === 'free').length,
          rows: leases,
        },
        wake_queue: { queued: wakeQueueCount(home) },
        snapshot_error: snapshot === null
          ? `fm-fleet-snapshot.sh ${snapshotResult.timedOut ? 'timed out' : `exited ${snapshotResult.code}`}`
          : null,
        readiness_error: readyResult.code === 0 ? null : `fm-inbox.sh exited ${readyResult.code}`,
      }
      const text = [
        `Firstmate native start for home ${home} (session ${identity.sessionId}).`,
        `Readiness: ${readiness === null ? 'unreadable' : 'read'}; backlog queued=${summary.backlog.queued} in_flight=${summary.backlog.in_flight} held=${summary.backlog.held}; tasks=${summary.tasks}.`,
        `Task leases: ${digest.leases.held} held, ${digest.leases.free} free. Durable wakes queued: ${digest.wake_queue.queued}.`,
        'Ownership is per task through the lease; no fleet-wide owner exists and the fleet lock is not part of this path.',
      ].join('\n')
      return { ...digest, tool: 'firstmate_native_start', text }
    },
  }))

  ctx.tools.register(defineTool({
    name: 'firstmate_native_delivery',
    description:
      'Per-PR (or per-task) delivery decision for this session\'s home: whether a pull request must go through the no-mistakes gate or may be delivered directly. resolve reports the effective decision (PR record, then task record, then the project registry) with yolo and the losing source; set/clear write or remove the durable record (a task write takes that task\'s lease); list/show read it. This layer never runs or inspects a pipeline run itself.',
    parameters: {
      type: 'object',
      properties: {
        action: {
          type: 'string',
          enum: ['resolve', 'get', 'set', 'clear', 'list'],
          description: 'resolve the effective decision, read one record, write one, clear one, or list all.',
        },
        task: { type: 'string', description: 'Exact task id. Required for get/set/clear unless pr is given.' },
        pr: { type: 'string', description: 'Canonical pull/merge-request URL, for PR-scoped decisions and lookups.' },
        project: { type: 'string', description: 'Project registry name, used as the resolution fallback for resolve/set.' },
        mode: {
          type: 'string',
          enum: ['no-mistakes', 'direct-PR', 'local-only'],
          description: 'Required for set: the delivery path this PR or task must use.',
        },
        yolo: {
          type: 'string',
          enum: ['on', 'off', 'inherit'],
          description: 'Merge authority for set; inherit (default) keeps the project registry posture.',
        },
        reason: { type: 'string', description: 'Short reason recorded with the decision.' },
      },
      required: ['action'],
      additionalProperties: false,
    },
    timeoutMs: 120000,
    async execute(args, exec) {
      const identity = requireIdentity(exec)
      const action = args?.action
      if (!['resolve', 'get', 'set', 'clear', 'list'].includes(action)) {
        throw new Error('action must be resolve, get, set, clear, or list')
      }
      if (action !== 'list' && (typeof args?.task !== 'string' || args.task.length === 0)
        && (typeof args?.pr !== 'string' || args.pr.length === 0)) {
        throw new Error('task or pr is required')
      }
      if (action === 'set' && (typeof args?.mode !== 'string' || args.mode.length === 0)) {
        throw new Error('mode is required for set')
      }
      if (action === 'set' && args?.yolo !== undefined && !['on', 'off', 'inherit'].includes(args.yolo)) {
        throw new Error('yolo must be on, off, or inherit')
      }
      const call = () => deliveryAction({
        home: identity.home,
        action,
        task: typeof args?.task === 'string' ? args.task : undefined,
        prUrl: typeof args?.pr === 'string' ? args.pr : undefined,
        project: typeof args?.project === 'string' ? args.project : undefined,
        mode: typeof args?.mode === 'string' ? args.mode : undefined,
        yolo: typeof args?.yolo === 'string' ? args.yolo : undefined,
        reason: typeof args?.reason === 'string' ? args.reason : undefined,
        signal: exec?.signal,
      })
      try {
        // A task-scoped write is a task mutation: hold that task's lease for it.
        const needsTaskLease = (action === 'set' || action === 'clear')
          && typeof args?.task === 'string' && args.task.length > 0
        if (needsTaskLease) {
          const leased = await withLease(
            { home: identity.home, task: args.task, identity, purpose: `delivery:${action}` },
            call,
          )
          if (leased.fenced !== null) {
            throw new Error(`${leased.fenced.code ?? 'fenced'}: ${leased.fenced.message}`)
          }
          const result = leased.result
          if (!result.ok) throw new Error(`delivery decision failed: ${result.error}`)
          return { ok: true, home: identity.home, action, task: args.task, fields: result.fields, text: result.text }
        }
        const result = await call()
        if (!result.ok) throw new Error(`delivery decision failed: ${result.error}`)
        return { ok: true, home: identity.home, action, fields: result.fields, text: result.text }
      } catch (error) {
        surfaceLeaseError(error)
      }
    },
  }))

  ctx.on('agent/created', async ({ agent } = {}) => {
    try {
      const identity = identifySession({ agent, configuredHome })
      if (identity === null) return
      identities.set(agent.id, identity)
      if (!isNativeHome(identity.home)) return
      const dispose = agent?.ctx?.systemPrompt?.context?.({
        name: IDENTITY_CONTEXT_NAME,
        order: IDENTITY_CONTEXT_ORDER,
        interpolate: false,
        text: identityNote(identity),
      })
      if (typeof dispose === 'function') contextDisposers.set(agent.id, dispose)
    } catch {
      // Identity contribution must never fail agent creation.
    }
  })

  ctx.on('agent/disposed', ({ agent } = {}) => {
    const id = agent?.id
    if (id === undefined) return
    identities.delete(id)
    const dispose = contextDisposers.get(id)
    contextDisposers.delete(id)
    try {
      dispose?.()
    } catch {
      // The agent scope is already unwinding.
    }
  })

  ctx.effect(() => () => {
    for (const dispose of contextDisposers.values()) {
      try {
        dispose()
      } catch {
        // Best effort during unload.
      }
    }
    contextDisposers.clear()
    identities.clear()
  })
}

/** Re-export the lease library for programmatic callers and tests. */
export {
  acquireLease,
  acquireMaintenanceLease,
  guardLease,
  inspectLease,
  MAINTENANCE_TASK,
  reapExpiredLeases,
  releaseLease,
  renewLease,
  withLease,
} from './src/lease.js'
export { identifySession, identityNote, isSubagentHeader } from './src/identity.js'
export { isFirstmateHome, isNativeHome, resolveHome } from './src/home.js'
export { buildFollowup, createFollowupChannel } from './src/transport.js'
export { loadLoopConfig, observeHome, reconcileHint, reconcileTick } from './src/reconcile.js'
export { listLeases } from './src/lease.js'
export { deliveryAction, resolveDelivery } from './src/delivery.js'
export { LeaseError } from './src/errors.js'
