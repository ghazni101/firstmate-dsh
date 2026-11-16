/**
 * Follow-up transport tests: message shape, deduplication, and clearing.
 */
import assert from 'node:assert/strict'
import { test } from 'node:test'

import { buildFollowup, createFollowupChannel } from '../src/transport.js'

/** A fake agent recording delivered messages. */
function fakeAgent() {
  return {
    messages: [],
    followup(message) {
      this.messages.push(message)
    },
  }
}

test('buildFollowup produces a marked user message', () => {
  const message = buildFollowup('task ready for review')
  assert.equal(message.role, 'user')
  assert.match(message.id, /^[0-9a-f-]{36}$/)
  assert.deepEqual(message.content, [{ type: 'text', text: '[firstmate native]\ntask ready for review' }])
  assert.deepEqual(message.source, { kind: 'user' })
})

test('a duplicate body is not queued while the first is unread', () => {
  const channel = createFollowupChannel()
  const agent = fakeAgent()
  const first = channel.deliver(agent, 'same body')
  const second = channel.deliver(agent, 'same body')
  assert.equal(first.delivered, true)
  assert.equal(second.delivered, false)
  assert.equal(second.duplicate, true)
  assert.equal(agent.messages.length, 1)
  assert.equal(channel.size(), 1)
})

test('reading a message clears its dedupe entry', () => {
  const channel = createFollowupChannel()
  const agent = fakeAgent()
  const first = channel.deliver(agent, 'wake')
  assert.equal(channel.read(first.id), true)
  assert.equal(channel.read(first.id), false)
  const again = channel.deliver(agent, 'wake')
  assert.equal(again.delivered, true)
  assert.equal(agent.messages.length, 2)
})

test('a failing followup is reported as not delivered', () => {
  const channel = createFollowupChannel()
  const result = channel.deliver({ followup() { throw new Error('disposing') } }, 'wake')
  assert.equal(result.delivered, false)
  assert.equal(channel.size(), 0)
})

test('delivery without a followup method is a no-op', () => {
  const channel = createFollowupChannel()
  const result = channel.deliver({}, 'wake')
  assert.equal(result.delivered, false)
  assert.deepEqual(channel.pendingTexts(), [])
})
