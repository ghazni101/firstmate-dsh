/**
 * Shared fixtures for the native supervisor tests.
 *
 * Every fixture is a throwaway home under the OS temp directory: the suite never
 * reads or writes a live fleet, never needs `bin/`, and never needs network.
 *
 * @module @local/dsh-plugin-firstmate-native/test/helpers
 */
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

/**
 * Write one executable script into a fixture home's `bin/`.
 * @param home - fixture home.
 * @param name - bare script name.
 * @param body - shell body, with or without a shebang.
 * @returns the script path.
 */
export function writeScript(home, name, body) {
  mkdirSync(join(home, 'bin'), { recursive: true })
  const path = join(home, 'bin', name)
  writeFileSync(path, body.startsWith('#!') ? body : `#!/usr/bin/env bash\n${body}`)
  chmodSync(path, 0o755)
  return path
}

/**
 * Create a throwaway Firstmate home.
 * @param options - fixture shape.
 * @param options.native - write `config/dsh-native` (default true).
 * @param options.anchors - write the home anchors (default true).
 * @param options.scripts - extra `bin/` scripts, by name.
 * @returns the home path.
 */
export function makeHome({ native = true, anchors = true, scripts = {} } = {}) {
  const home = mkdtempSync(join(tmpdir(), 'fm-native-'))
  mkdirSync(join(home, 'state'), { recursive: true })
  mkdirSync(join(home, 'config'), { recursive: true })
  if (anchors) {
    writeFileSync(join(home, 'AGENTS.md'), '# fixture home\n')
    writeScript(home, 'fm-session-start.sh', 'exit 0\n')
    writeScript(home, 'fm-spawn.sh', 'exit 0\n')
  }
  if (native) writeFileSync(join(home, 'config', 'dsh-native'), 'enabled\n')
  for (const [name, body] of Object.entries(scripts)) writeScript(home, name, body)
  return home
}

/**
 * Remove a fixture home.
 * @param home - fixture home.
 */
export function cleanup(home) {
  try {
    rmSync(home, { recursive: true, force: true })
  } catch {
    // Best effort; the OS temp dir is disposable.
  }
}

/**
 * Build one session identity for a fixture home.
 * @param home - firstmate home.
 * @param sessionId - session id.
 * @returns the identity object.
 */
export function makeIdentity(home, sessionId = 'session-a') {
  return {
    sessionId,
    agentId: sessionId,
    home,
    ownerLabel: `dsh:${sessionId}`,
  }
}

/**
 * Build a fake DSH agent whose context contributions are recorded.
 * @param options - agent shape.
 * @param options.id - agent id.
 * @param options.cwd - session working directory.
 * @param options.header - extra session header fields.
 * @returns `{ agent, contributions }`.
 */
export function makeAgent({ id = 'agent-a', cwd, header = {} } = {}) {
  const contributions = []
  const agent = {
    id,
    session: { id, header: { id, cwd, ...header } },
    ctx: {
      systemPrompt: {
        context(contribution) {
          contributions.push(contribution)
          return () => {
            const index = contributions.indexOf(contribution)
            if (index >= 0) contributions.splice(index, 1)
          }
        },
      },
    },
    followups: [],
    followup(message) {
      agent.followups.push(message)
    },
  }
  return { agent, contributions }
}

/**
 * Build a fake Host plugin context that records registrations.
 * @returns `{ ctx, listeners, tools, cleanups }`.
 */
export function makeContext() {
  const listeners = new Map()
  const tools = []
  const cleanups = []
  const ctx = {
    tools: {
      register(tool) {
        tools.push(tool)
      },
    },
    on(event, listener) {
      const existing = listeners.get(event)
      if (existing === undefined) listeners.set(event, [listener])
      else existing.push(listener)
    },
    effect(fn) {
      const dispose = fn()
      cleanups.push(dispose)
      return () => {}
    },
  }
  return { ctx, listeners, tools, cleanups }
}

/**
 * Fire every recorded listener for one event.
 * @param listeners - the listener map from {@link makeContext}.
 * @param event - event name.
 * @param payload - event payload.
 * @returns the listeners' results.
 */
export async function emit(listeners, event, payload) {
  const recorded = listeners.get(event) ?? []
  const results = []
  for (const listener of recorded) results.push(await listener(payload))
  return results
}

/**
 * Build the tool-run context for one fake agent.
 * @param agent - the agent.
 * @returns an execution context.
 */
export function execFor(agent) {
  return { agent, signal: new AbortController().signal }
}

/**
 * Find one registered tool by name.
 * @param tools - registered tools.
 * @param name - tool name.
 * @returns the tool definition.
 */
export function toolNamed(tools, name) {
  const tool = tools.find((candidate) => candidate.name === name)
  if (tool === undefined) throw new Error(`tool ${name} was not registered`)
  return tool
}
