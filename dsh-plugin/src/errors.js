/**
 * Typed errors for the native supervisor surface.
 *
 * One code space covers the lease protocol, identity resolution, and the CLI so
 * a bash caller and a tool result can branch on the same word. Exit codes are
 * the CLI contract owned by docs/dsh-native-architecture.md section 4.10.
 *
 * @module @local/dsh-plugin-firstmate-native/src/errors
 */

/** CLI exit codes. Keep these aligned with the architecture page's table. */
export const EXIT = Object.freeze({
  ok: 0,
  usage: 2,
  'not-held': 3,
  expired: 3,
  'invalid-record': 3,
  fenced: 4,
  contention: 5,
  'cross-home': 6,
  busy: 7,
})

/** A refusal or integrity failure with a stable machine-readable code. */
export class LeaseError extends Error {
  /**
   * @param code - one of the codes in {@link EXIT}.
   * @param message - human-readable explanation.
   * @param details - extra structured context, safe to print as JSON.
   */
  constructor(code, message, details = {}) {
    super(message)
    this.name = 'LeaseError'
    this.code = code
    this.details = details
  }

  /** @returns the CLI exit code for this refusal. */
  get exitCode() {
    return EXIT[this.code] ?? EXIT.usage
  }
}

/**
 * Normalize any thrown value into a LeaseError.
 * @param error - anything thrown.
 * @returns a LeaseError.
 */
export function asLeaseError(error) {
  if (error instanceof LeaseError) return error
  const message = error instanceof Error ? error.message : String(error)
  return new LeaseError('usage', message)
}
