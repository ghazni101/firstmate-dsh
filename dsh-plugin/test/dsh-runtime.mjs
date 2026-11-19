/**
 * Locate the installed DSH runtime for tests that compose real DSH objects.
 *
 * The plugin has no DSH dependency of its own: it runs inside a DSH profile.
 * A test that wants the real session store or fork provider therefore resolves
 * them from the `dsh` executable on PATH (or DSH_INSTALL_DIR), never from a
 * hardcoded user path. Resolution is local; no network and no product code.
 */
import { execFileSync } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import { createRequire } from 'node:module'
import { dirname, join } from 'node:path'
import { pathToFileURL } from 'node:url'

/**
 * Resolve the DSH installation root and a require bound to it.
 * @returns `{ root, requireDsh, runtimeUrl }` or null when DSH is absent.
 */
export function findDshRuntime() {
  let bin = null
  if (typeof process.env.DSH_INSTALL_DIR === 'string' && process.env.DSH_INSTALL_DIR.length > 0) {
    bin = join(process.env.DSH_INSTALL_DIR, 'lib', 'bin.js')
  }
  if (bin === null || !existsSync(bin)) {
    try {
      bin = realpathSync(execFileSync('which', ['dsh'], { encoding: 'utf8' }).trim())
    } catch {
      return null
    }
  }
  if (!existsSync(bin)) return null
  const root = dirname(dirname(bin))
  const requireDsh = createRequire(bin)
  return { root, requireDsh, runtimeUrl: pathToFileURL(bin).href }
}

/**
 * Import one real DSH package from the installation.
 * @param runtime - resolved runtime from `findDshRuntime()`.
 * @param name - package specifier.
 * @returns the module namespace.
 */
export async function importDsh(runtime, name) {
  return import(pathToFileURL(runtime.requireDsh.resolve(name)).href)
}
