/**
 * Per-PR delivery decisions, as seen by the native supervisor.
 *
 * The record format, resolution order, and enforcement live in the engine
 * (`bin/fm-delivery-lib.sh` and `bin/fm-delivery.sh`); this module is a typed
 * caller for the plugin's reconciliation gate and its tool surface. It never
 * re-implements the resolution order.
 *
 * @module @local/dsh-plugin-firstmate-native/src/delivery
 */
import { combinedOutput, runScript } from './scripts.js'

/** Bound for one decision read. */
export const DELIVERY_READ_TIMEOUT_MS = 30000

/**
 * Parse the CLI's key=value output.
 * @param text - CLI stdout.
 * @returns a field map.
 */
export function parseDeliveryFields(text) {
  const fields = {}
  for (const line of String(text ?? '').split('\n')) {
    const index = line.indexOf('=')
    if (index <= 0) continue
    fields[line.slice(0, index)] = line.slice(index + 1)
  }
  return fields
}

/**
 * Resolve the effective delivery decision for a task and/or PR.
 * @param options - resolution inputs.
 * @param options.home - Firstmate home.
 * @param options.task - task id, when known.
 * @param options.prUrl - canonical PR URL, when known.
 * @param options.project - project registry name, when known.
 * @param options.signal - cancellation.
 * @returns `{ available, mode, yolo, deliverySource, yoloSource, shadowed, reason, task, pr, error }`.
 */
export async function resolveDelivery({ home, task, prUrl, project, signal } = {}) {
  const argv = ['resolve']
  if (typeof task === 'string' && task.length > 0) argv.push('--task', task)
  if (typeof prUrl === 'string' && prUrl.length > 0) argv.push('--pr', prUrl)
  if (typeof project === 'string' && project.length > 0) argv.push('--project', project)
  const result = await runScript(home, 'fm-delivery.sh', argv, {
    timeoutMs: DELIVERY_READ_TIMEOUT_MS,
    signal,
  })
  if (result.code !== 0) {
    return {
      available: false,
      error: result.spawnError ?? (combinedOutput(result).slice(0, 1000) || `fm-delivery.sh exited ${result.code}`),
      mode: null,
      yolo: null,
      deliverySource: null,
      yoloSource: null,
      shadowed: null,
      reason: null,
      task: task ?? null,
      pr: prUrl ?? null,
    }
  }
  const fields = parseDeliveryFields(result.stdout)
  return {
    available: true,
    mode: fields.mode ?? null,
    yolo: fields.yolo ?? null,
    deliverySource: fields.delivery_source ?? null,
    yoloSource: fields.yolo_source ?? null,
    shadowed: fields.shadowed === undefined || fields.shadowed === '' ? null : fields.shadowed,
    reason: fields.reason === undefined || fields.reason === '' ? null : fields.reason,
    task: fields.task ?? task ?? null,
    pr: fields.pr ?? prUrl ?? null,
    error: null,
  }
}

/**
 * Run one decision action through the owning CLI.
 * @param options - action inputs.
 * @param options.home - Firstmate home.
 * @param options.action - resolve | get | set | clear | list.
 * @param options.task - task id.
 * @param options.prUrl - PR URL.
 * @param options.project - project name.
 * @param options.mode - delivery mode for set.
 * @param options.yolo - on | off | inherit for set.
 * @param options.reason - decision reason for set.
 * @param options.signal - cancellation.
 * @returns `{ ok, code, fields, text, error }`.
 */
export async function deliveryAction({ home, action, task, prUrl, project, mode, yolo, reason, signal } = {}) {
  const argv = [action]
  if (action !== 'list') {
    if (typeof task === 'string' && task.length > 0) argv.push('--task', task)
    if (typeof prUrl === 'string' && prUrl.length > 0) argv.push('--pr', prUrl)
  }
  if (action === 'resolve' || action === 'set') {
    if (typeof project === 'string' && project.length > 0) argv.push('--project', project)
  }
  if (action === 'set') {
    if (typeof mode === 'string' && mode.length > 0) argv.push('--mode', mode)
    if (typeof yolo === 'string' && yolo.length > 0) argv.push('--yolo', yolo)
    if (typeof reason === 'string' && reason.length > 0) argv.push('--reason', reason)
  }
  const result = await runScript(home, 'fm-delivery.sh', argv, {
    timeoutMs: DELIVERY_READ_TIMEOUT_MS,
    signal,
  })
  const text = combinedOutput(result)
  return {
    ok: result.code === 0,
    code: result.code,
    fields: parseDeliveryFields(result.stdout),
    text: text.length > 0 ? text : result.stdout.trim(),
    error: result.code === 0 ? null : (result.spawnError ?? (text.slice(0, 1000) || `fm-delivery.sh exited ${result.code}`)),
  }
}
