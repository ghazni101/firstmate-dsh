/**
 * Bound script execution for the native plugin.
 *
 * The plugin is a typed shell over the existing engine: it runs one allowlisted
 * `bin/fm-*.sh` with `FM_HOME` pinned to the resolved home, the DSH harness
 * marker set, a timeout, and bounded output. It never takes a script name from
 * the model and never runs a path.
 *
 * @module @local/dsh-plugin-firstmate-native/src/scripts
 */
import { execFile } from 'node:child_process'
import { join } from 'node:path'

/** Marker the shell engine reads to report `dsh` as the primary harness. */
export const HARNESS_MARKER_ENV = 'FM_HARNESS_DSH'

/** Default cap on model-facing script output. */
export const MAX_OUTPUT_CHARS = 48000

/** A script the plugin may run: one bare file name under the home `bin/`. */
const SCRIPT_NAME = /^fm-[a-z0-9][a-z0-9-]*\.sh$/

/**
 * Refuse anything that is not a bare allowlisted script name.
 * @param name - candidate script name.
 * @param allowlist - the fixed allowlist for this call site.
 * @returns the name.
 */
export function assertScript(name, allowlist) {
  if (typeof name !== 'string' || !SCRIPT_NAME.test(name) || !allowlist.has(name)) {
    throw new Error(`refused script ${JSON.stringify(name)}: not in this tool's allowlist`)
  }
  return name
}

/**
 * Run one home script without ever rejecting.
 * @param home - resolved Firstmate home.
 * @param script - bare script file name.
 * @param args - argv after the script.
 * @param options - timeout, extra environment, and abort signal.
 * @returns a captured outcome `{ code, timedOut, signal, stdout, stderr, spawnError }`.
 */
export function runScript(home, script, args, options = {}) {
  const timeout = Number.isFinite(options.timeoutMs) && options.timeoutMs > 0
    ? options.timeoutMs
    : 120000
  const env = {
    ...process.env,
    [HARNESS_MARKER_ENV]: '1',
    ...(options.env ?? {}),
    FM_HOME: home,
  }
  return new Promise((done) => {
    execFile(
      join(home, 'bin', script),
      Array.isArray(args) ? args : [],
      {
        cwd: home,
        timeout,
        maxBuffer: 16 * 1024 * 1024,
        encoding: 'utf8',
        env,
        signal: options.signal,
      },
      (error, stdout, stderr) => {
        const timedOut = Boolean(error?.killed) || error?.code === 'ABORT_ERR'
        let code = 0
        if (error) code = typeof error.code === 'number' ? error.code : null
        done({
          code,
          timedOut,
          signal: error?.signal ?? null,
          stdout: typeof stdout === 'string' ? stdout : '',
          stderr: typeof stderr === 'string' ? stderr : '',
          spawnError: error && code === null && error?.code !== 'ABORT_ERR' ? String(error.message) : undefined,
        })
      },
    )
  })
}

/**
 * Join a script's stdout and stderr in that order.
 * @param result - a {@link runScript} outcome.
 * @returns the combined text.
 */
export function combinedOutput(result) {
  return [result.stdout, result.stderr]
    .map((part) => part.trimEnd())
    .filter((part) => part.length > 0)
    .join('\n')
}

/**
 * Cap model-facing text.
 * @param text - the text.
 * @param max - maximum characters.
 * @returns `{ text, truncated }`.
 */
export function capOutput(text, max = MAX_OUTPUT_CHARS) {
  const value = String(text ?? '')
  if (value.length <= max) return { text: value, truncated: false }
  return {
    text: `${value.slice(0, max)}\n\n[truncated at ${max} characters]`,
    truncated: true,
  }
}

/**
 * Shape one successful tool result.
 * @param fields - result fields.
 * @returns the canonical tool value.
 */
export function toolResult({ home, tool, format = 'text', data = null, text = '', truncated = false }) {
  return { ok: true, home, tool, format, data, text, truncated, exit_code: 0 }
}

/**
 * Throw an actionable failure carrying the script's own output.
 * @param label - operation label.
 * @param result - a {@link runScript} outcome.
 * @param timeoutMs - the timeout that was used.
 */
export function failScript(label, result, timeoutMs) {
  const detail = capOutput(combinedOutput(result), 4000).text
  const status = result.code === null
    ? (result.timedOut ? `timed out after ${timeoutMs}ms` : 'no exit status')
    : `exit ${result.code}`
  throw new Error(`${label} failed (${status})${detail.length > 0 ? `\n\n${detail}` : ''}`)
}
