/**
 * Follow-up transport for the native supervisor.
 *
 * `agent.followup()` wakes the agent; `agent.inject()` only queues context that
 * waits for other input. The supervisor uses this channel for latency only:
 * every decision is re-derived from durable files, so a lost or duplicated
 * follow-up is never authoritative.
 *
 * Contract: docs/dsh-native-architecture.md section 5.4.
 *
 * @module @local/dsh-plugin-firstmate-native/src/transport
 */
import { randomUUID } from 'node:crypto'

/** Default tag prefixed to supervisor follow-ups. */
export const SUPERVISOR_TAG = 'firstmate native'

/**
 * Build one marked user message.
 * @param text - the body.
 * @param options - tag and optional identity.
 * @returns a UserMessage-shaped object.
 */
export function buildFollowup(text, { tag = SUPERVISOR_TAG, id } = {}) {
  return {
    id: typeof id === 'string' && id.length > 0 ? id : randomUUID(),
    role: 'user',
    content: [{ type: 'text', text: `[${tag}]\n${String(text ?? '')}` }],
    source: { kind: 'user' },
  }
}

/**
 * Create a deduplicating follow-up channel.
 *
 * A second identical body is not queued while the first is still unread: the
 * agent drains the durable queue on its first read, so the duplicate adds
 * nothing and can only confuse a turn.
 * @param options - channel bounds.
 * @returns `{ deliver, read, pendingTexts, size }`.
 */
export function createFollowupChannel({ maxPending = 64 } = {}) {
  const pending = new Map()

  return {
    /**
     * Deliver one body unless an identical body is still unread.
     * @param agent - the agent object with a `followup(message)` method.
     * @param text - the body.
     * @returns `{ delivered, id, duplicate }`.
     */
    deliver(agent, text) {
      const body = String(text ?? '')
      for (const entry of pending.values()) {
        if (entry.text === body) return { delivered: false, id: entry.id, duplicate: true }
      }
      if (typeof agent?.followup !== 'function') return { delivered: false, id: null, duplicate: false }
      const message = buildFollowup(body)
      try {
        agent.followup(message)
      } catch {
        return { delivered: false, id: null, duplicate: false }
      }
      pending.set(message.id, { text: body, id: message.id })
      while (pending.size > maxPending) {
        const oldest = pending.keys().next().value
        pending.delete(oldest)
      }
      return { delivered: true, id: message.id, duplicate: false }
    },

    /**
     * Clear the unread entry for one message that was claimed or discarded.
     * @param id - the message identity.
     * @returns true when an entry was cleared.
     */
    read(id) {
      return typeof id === 'string' ? pending.delete(id) : false
    },

    /** @returns the unread bodies, oldest first. */
    pendingTexts() {
      return [...pending.values()].map((entry) => entry.text)
    },

    /** @returns the number of unread entries. */
    size() {
      return pending.size
    },
  }
}
