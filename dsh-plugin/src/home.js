/**
 * Firstmate home detection and resolution for one DSH session.
 *
 * A home is identified by anchors, never by a lock file or a process name. The
 * session's own `cwd` is the primary signal because one DSH process may serve
 * several homes; pinned configuration and `FM_HOME` are fallbacks.
 *
 * Ownership of the anchors is docs/dsh-native-architecture.md section 3.2.
 *
 * @module @local/dsh-plugin-firstmate-native/src/home
 */
import { existsSync, realpathSync, statSync } from 'node:fs'
import { dirname, join, resolve, sep } from 'node:path'

/**
 * Files that make a directory a Firstmate home.
 *
 * `bin/fm-watch-arm.sh` is deliberately absent: retiring the watcher must not
 * invalidate identity.
 */
export const HOME_ANCHORS = Object.freeze([
  'AGENTS.md',
  'bin/fm-session-start.sh',
  'bin/fm-spawn.sh',
])

/** Marker directory file that enables the native surface for one home. */
export const NATIVE_HOME_MARKER = 'config/dsh-native'

/**
 * Canonicalize a path when it exists; resolve lexically otherwise.
 * @param path - candidate path.
 * @returns an absolute canonical path.
 */
export function canonicalPath(path) {
  const absolute = resolve(String(path))
  try {
    return realpathSync(absolute)
  } catch {
    return absolute
  }
}

/**
 * Whether a directory is a usable Firstmate home.
 * @param dir - absolute candidate directory.
 * @returns true when every anchor exists.
 */
export function isFirstmateHome(dir) {
  if (typeof dir !== 'string' || dir.length === 0) return false
  return HOME_ANCHORS.every((anchor) => existsSync(join(dir, anchor)))
}

/**
 * Walk a directory upward until a home is found.
 * @param start - directory to begin at.
 * @returns the first ancestor (including `start`) that is a home, or undefined.
 */
export function walkUpToHome(start) {
  if (typeof start !== 'string' || start.length === 0) return undefined
  let dir = resolve(start)
  for (;;) {
    if (isFirstmateHome(dir)) return canonicalPath(dir)
    const parent = dirname(dir)
    if (parent === dir) return undefined
    dir = parent
  }
}

/**
 * Resolve the home for one session or process.
 *
 * Precedence: an explicit configured home, an ancestor of the session's `cwd`,
 * `FM_HOME` (only when it is itself a home, never an ancestor walk), then an
 * ancestor of this process's working directory.
 * @param options - resolution inputs.
 * @param options.configured - `config.home` on the plugin row, when set.
 * @param options.sessionDir - the session's working directory, when known.
 * @param options.env - environment to read `FM_HOME` from (defaults to process.env).
 * @param options.cwd - process working directory (defaults to process.cwd()).
 * @returns an absolute canonical home, or undefined when nothing resolves.
 */
export function resolveHome({ configured, sessionDir, env = process.env, cwd = process.cwd() } = {}) {
  if (typeof configured === 'string' && configured.trim().length > 0) {
    const pinned = resolve(configured.trim())
    if (isFirstmateHome(pinned)) return canonicalPath(pinned)
  }
  const fromSession = walkUpToHome(sessionDir)
  if (fromSession !== undefined) return fromSession
  const envHome = env?.FM_HOME
  if (typeof envHome === 'string' && envHome.trim().length > 0 && isFirstmateHome(resolve(envHome))) {
    return canonicalPath(resolve(envHome))
  }
  return walkUpToHome(cwd)
}

/**
 * Whether `child` is `parent` or lives beneath it, after canonicalization.
 * @param child - absolute path to test.
 * @param parent - absolute containing path.
 * @returns true when contained.
 */
export function isInside(child, parent) {
  const c = canonicalPath(child)
  const p = canonicalPath(parent)
  return c === p || c.startsWith(p.endsWith(sep) ? p : p + sep)
}

/**
 * Whether a home has opted in to the native plugin surface.
 * @param home - Firstmate home.
 * @returns true when `config/dsh-native` exists.
 */
export function isNativeHome(home) {
  if (typeof home !== 'string' || home.length === 0) return false
  return existsSync(join(home, NATIVE_HOME_MARKER))
}

/**
 * Whether a path exists and is a directory.
 * @param path - candidate.
 * @returns true for an existing directory.
 */
export function isDirectory(path) {
  try {
    return statSync(path).isDirectory()
  } catch {
    return false
  }
}
