/**
 * Credential-free scripted LLM adapter for the disposable two-session live
 * guard. The live fixture copies this module into its disposable plugin copy
 * and calls `apply` from that plugin, so no live profile, DSH_HOME, or
 * credential is touched.
 *
 * It never spends tokens. A coordinator turn carrying a `[captain]` engine
 * traffic batch gets one tool call to `firstmate_native_escalate`; the next
 * call, which carries that tool's result, ends the turn. Every other turn
 * ends with a plain text reply. A `[captain]` batch carrying `restart-proof`
 * emits the restart outcome, so the guard can deliver an outcome that was
 * recorded before a Host restart.
 */
const PROVIDER = 'fm-scripted'
const MODEL = 'scripted-escalate'
const OUTCOME = 'Live guard: PR is ready for the captain.'
export const RESTART_OUTCOME = 'Live guard: coordinator resumed after host restart.'
const RESTART_MARKER = 'restart-proof'
const TOOL_CALL_ID = 'fm-live-escalate'

/** Duck-typed LlmAdapter: every method the registry and loop call is present. */
class ScriptedAdapter {
  providerInfo(provider) {
    return { id: provider, name: 'Firstmate scripted test provider' }
  }

  providerRetryPolicy() {
    return undefined
  }

  imageRequestPricing() {
    return undefined
  }

  imageRequestTarget(_provider, _model, image) {
    return { width: image.width, height: image.height, maxBytes: image.bytes }
  }

  listModels(provider) {
    return Promise.resolve([{ provider, id: MODEL, name: MODEL }])
  }

  resolveModel(provider, model) {
    return Promise.resolve({ provider, id: model, name: model })
  }

  async prepareCall(provider, model, signal) {
    return {
      model: await this.resolveModel(provider, model, signal),
      stream: (options) => this.stream(options),
    }
  }

  async *stream(options) {
    if (options.signal?.aborted === true) return
    const messages = options.messages ?? []
    const text = messages.map((message) => JSON.stringify(message.content ?? [])).join('\n')
    const captainBatch = text.includes('[firstmate engine traffic]') && text.includes('[captain]')
    const batchIndex = messages.findLastIndex((message) => JSON.stringify(message.content ?? []).includes('[firstmate engine traffic]'))
    const answered = batchIndex >= 0 && messages.slice(batchIndex + 1).some((message) => message.role === 'tool')
    if (captainBatch && !answered) {
      const outcome = text.includes(RESTART_MARKER) ? RESTART_OUTCOME : OUTCOME
      const args = JSON.stringify({ outcome, task: 'task-a' })
      yield { type: 'block-start', index: 0, blockType: 'tool-call' }
      yield { type: 'tool-call-delta', index: 0, id: TOOL_CALL_ID, name: 'firstmate_native_escalate', argumentsDelta: args }
      yield { type: 'block-end', index: 0, block: { type: 'tool-call', id: TOOL_CALL_ID, name: 'firstmate_native_escalate', arguments: args } }
      yield { type: 'usage', usage: { inputTokens: 1, outputTokens: 1 } }
      yield { type: 'finish', reason: { kind: 'tool-calls' } }
      return
    }
    yield { type: 'block-start', index: 0, blockType: 'text' }
    yield { type: 'text-delta', index: 0, text: 'Traffic absorbed.' }
    yield { type: 'block-end', index: 0, block: { type: 'text', text: 'Traffic absorbed.' } }
    yield { type: 'usage', usage: { inputTokens: 1, outputTokens: 1 } }
    yield { type: 'finish', reason: { kind: 'stop' } }
  }
}

/** Register the scripted provider on the disposable profile. */
export function apply(ctx) {
  ctx.llm.registerAdapter([PROVIDER], new ScriptedAdapter())
}
