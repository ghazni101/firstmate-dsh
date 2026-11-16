/**
 * DSH session identity for the native supervisor.
 *
 * Identity comes from the session itself (`SessionHeader` plus the resolved
 * home), never from process ancestry, a lock file, or an environment marker.
 * A root session whose directory resolves to a home is a supervisor candidate;
 * subagents and directories outside a home are not.
 *
 * Contract: docs/dsh-native-architecture.md section 3.
 *
 * @module @local/dsh-plugin-firstmate-native/src/identity
 */
import { LeaseError } from './errors.js'
import { canonicalPath, isInside, resolveHome } from './home.js'

/**
 * Whether a session header describes a subagent child.
 *
 * `parentSession` alone is not evidence: historical ordinary forks retain it.
 * The coarse product classification and the persisted delegation depth are.
 * @param header - a session header, when known.
 * @returns true for a subagent session.
 */
export function isSubagentHeader(header) {
  if (header === undefined || header === null) return false
  if (header.origin === 'subagent') return true
  const depth = Number(header.delegationDepth ?? 0)
  return Number.isFinite(depth) && depth > 0
}

/**
 * Resolve the identity of one DSH agent/session.
 * @param options - identity inputs.
 * @param options.agent - the DSH agent object (`{ id, session: { header } }`).
 * @param options.configuredHome - pinned home from the plugin row, when set.
 * @param options.env - environment used for the `FM_HOME` fallback.
 * @param options.cwd - process working directory fallback.
 * @returns the identity, or null when this session is not a supervisor candidate.
 */
export function identifySession({ agent, configuredHome, env = process.env, cwd = process.cwd() } = {}) {
  if (agent === undefined || agent === null) return null
  const header = agent.session?.header
  if (header === undefined || header === null) return null
  if (isSubagentHeader(header)) return null
  const sessionDir = typeof header.cwd === 'string' && header.cwd.length > 0 ? header.cwd : undefined
  const home = resolveHome({ configured: configuredHome, sessionDir, env, cwd })
  if (home === undefined) return null
  if (sessionDir !== undefined && !isInside(sessionDir, home)) return null
  const sessionId = typeof header.id === 'string' && header.id.length > 0
    ? header.id
    : String(agent.id ?? '')
  if (sessionId.length === 0) return null
  return {
    sessionId,
    agentId: String(agent.id ?? sessionId),
    home,
    cwd: sessionDir ?? null,
    preset: typeof header.agentPreset === 'string' ? header.agentPreset : null,
    ownerLabel: `dsh:${sessionId}`,
  }
}

/**
 * Refuse an operation in a home that is not this identity's home.
 * @param identity - the calling session's identity.
 * @param home - the home the operation names.
 * @returns the canonical target home.
 * @throws {LeaseError} `cross-home` when the homes differ.
 */
export function assertSameHome(identity, home) {
  if (identity === undefined || identity === null) {
    throw new LeaseError('usage', 'no session identity is available for this operation')
  }
  if (typeof home !== 'string' || home.length === 0) {
    throw new LeaseError('usage', 'no home was named for this operation')
  }
  const target = canonicalPath(home)
  if (canonicalPath(identity.home) !== target) {
    throw new LeaseError(
      'cross-home',
      `cross-home refusal: this session belongs to ${identity.home} and may not act on ${target}; cross-home work moves by explicit handoff`,
      { identity_home: canonicalPath(identity.home), requested_home: target },
    )
  }
  return target
}

/**
 * Render the static runtime-context note for one identity.
 *
 * The text is static on purpose: the Harness resolves a context provider twice
 * per step, so a one-shot function would be empty on the admitted pass.
 * @param identity - the calling session's identity.
 * @returns the note text.
 */
export function identityNote(identity) {
  return [
    `Firstmate native session for home ${identity.home} (session ${identity.sessionId}).`,
    'Ownership: one task at a time through that task\'s lease; no fleet-wide owner exists.',
    'Cross-home work must be handed off; this session cannot claim another home\'s task.',
    'Read-only fleet tools are available; task mutations require holding that task\'s lease.',
  ].join('\n')
}
