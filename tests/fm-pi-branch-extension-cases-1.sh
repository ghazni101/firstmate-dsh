# shellcheck shell=bash
# Test cases for fm-pi-branch-extension, split out of tests/fm-pi-branch-extension.test.sh so no single
# ShellCheck root carries the whole suite. Definition-only:
# tests/fm-pi-branch-extension.test.sh owns the setup and the run order, sources this
# file, and calls these cases.
# shellcheck disable=SC2034,SC2329 # cases share setup and helpers with their .test.sh runner


# Semantic-version floor for a version string this file already holds (Pi's
# package.json field). bin/fm-bootstrap.sh's tool_version_at_least is the same
# rule for a tool it invokes itself; this is the string-shaped form, kept here
# rather than in tests/lib.sh because this is its only consumer and every test
# sources that library. It is deliberately as strict: a version that is not
# exactly one major.minor.patch triple never satisfies a floor it was not
# checked against.
pi_version_at_least() {  # <version> <min-version>
  local version=$1 min=$2 parts major minor patch extra
  local min_major min_minor min_patch min_extra
  parts=$(printf '%s\n' "$version" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

# Keep JavaScript heredocs outside command substitutions. Stock macOS Bash
# 3.2 reparses quotes and template literals inside that combination.
install_pi_branch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-ai" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.pi/extensions/fm-branch-supervision.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-model-picker.ts" "$repo/.pi/extensions/lib/fm-branch-model-picker.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  mkdir -p "$repo/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
import { writeFileSync } from "node:fs";

export const VERSION = process.env.FM_STUB_PI_VERSION || "0.99.0";

export function getAgentDir() {
  return "/stub-agent-dir";
}

export function getMarkdownTheme() {
  return {};
}

export function keyHint(_keybinding, description) {
  return `ctrl+o ${description}`;
}

export class ToolExecutionComponent {
  updateResult(result) {
    this.result = result;
  }
  render() {
    return (this.result?.content ?? [])
      .filter((item) => item.type === "text")
      .flatMap((item) => item.text.split("\n"));
  }
}

export class UserMessageComponent {}

export class DynamicBorder {
  constructor(color) {
    this.color = color;
  }
  invalidate() {}
  render() {
    return ["--"];
  }
}

export class ModelRuntime {
  constructor() {
    this.models = (globalThis.__fmBranchStaticModels?.() ?? []).map((model) => ({ ...model }));
    this.authenticated = new Set(this.models.filter((model) => model.storedAuth !== false).map((model) => model.provider));
    this.registeredProviderConfigs = new Map();
    // Like the real runtime, a registered provider's credentials are only
    // known once refresh() has run for it; registration alone is provisional.
    this.pendingAuth = new Set();
  }
  static async create() {
    const queuedError = globalThis.__fmModelRuntimeErrors?.shift();
    if (queuedError) throw new Error(queuedError);
    if (globalThis.__fmModelRuntimeError) throw new Error(globalThis.__fmModelRuntimeError);
    const runtime = new ModelRuntime();
    (globalThis.__fmModelRuntimes ??= []).push(runtime);
    return runtime;
  }
  registerProvider(providerId, config) {
    this.registeredProviderConfigs.set(providerId, config);
    for (const model of config.models ?? []) {
      this.models.push({ ...model, provider: providerId });
    }
    if (config.oauth || config.apiKey) this.pendingAuth.add(providerId);
  }
  async refresh(options) {
    for (const providerId of options?.providers ?? this.pendingAuth) {
      if (this.pendingAuth.delete(providerId)) this.authenticated.add(providerId);
    }
  }
  getModel(provider, id) {
    return this.models.find((model) => model.provider === provider && model.id === id);
  }
  hasConfiguredAuth(provider) {
    return this.authenticated.has(provider);
  }
}
export class DefaultResourceLoader {
  constructor(options) {
    this.options = options;
    (globalThis.__fmLoaders ??= []).push(this);
  }
  async reload() {
    this.reloaded = true;
  }
}

export class SessionManager {
  constructor(file) {
    this.file = file;
    this.entries = [];
  }
  static create(cwd, dir) {
    globalThis.__fmCreateCount = (globalThis.__fmCreateCount ?? 0) + 1;
    const sm = new SessionManager(`${dir}/created-${process.pid}-${globalThis.__fmCreateCount}.jsonl`);
    sm.created = true;
    writeFileSync(sm.file, "");
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  static open(path) {
    const sm = new SessionManager(path);
    sm.opened = true;
    (globalThis.__fmSessionManagers ??= []).push(sm);
    return sm;
  }
  getSessionFile() {
    return this.file;
  }
  getEntries() {
    return this.entries;
  }
  buildSessionContext() {
    const model = globalThis.__fmRecordedModels?.get(this.file) ?? null;
    return { messages: model ? [{ role: "assistant", content: [], provider: model.provider, model: model.modelId }] : [], thinkingLevel: "medium", model };
  }
}

export function createBashToolDefinition(cwd, options) {
  return {
    name: "bash",
    label: "stub bash",
    description: "stub bash",
    parameters: { type: "object" },
    __cwd: cwd,
    __options: options,
    execute: async (_toolCallId, params) => {
      if (!globalThis.__fmExecuteBranchBash) return { content: [], details: undefined };
      const initial = { command: String(params.command ?? ""), cwd, env: { ...process.env } };
      const context = options.spawnHook ? options.spawnHook(initial) : initial;
      return globalThis.__fmExecuteBranchBash(context);
    },
  };
}

export async function createAgentSession(options) {
  if (globalThis.__fmCreateSessionError) throw new Error(globalThis.__fmCreateSessionError);
  globalThis.__fmCreateStarted = (globalThis.__fmCreateStarted ?? 0) + 1;
  if (globalThis.__fmCreateGate) await globalThis.__fmCreateGate;
  if (options.model && (!options.modelRuntime || !options.modelRuntime.getModel(options.model.provider, options.model.id))) {
    throw new Error(`branch runtime cannot use ${options.model.provider}/${options.model.id}`);
  }
  const persistMessages = (messages) => {
    const tracked = [...messages];
    tracked.push = (...items) => {
      for (const message of items) options.sessionManager.getEntries().push({ type: "message", message });
      return Array.prototype.push.apply(tracked, items);
    };
    return tracked;
  };
  let branchMessages = persistMessages(globalThis.__fmInitialBranchMessages ?? []);
  for (const message of branchMessages) options.sessionManager.getEntries().push({ type: "message", message });
  const session = {
    options,
    ops: [],
    get messages() {
      return branchMessages;
    },
    set messages(messages) {
      branchMessages = persistMessages(messages);
    },
    disposed: false,
    async prompt(text) {
      if (globalThis.__fmPromptGate) {
        globalThis.__fmPromptStarted = true;
        await globalThis.__fmPromptGate;
      }
      session.ops.push({ kind: "prompt", text });
      (globalThis.__fmPrompts ??= []).push(text);
      session.messages.push({ role: "user", content: text });
      await globalThis.__fmOnBranchPrompt?.({ session, text });
    },
    async sendCustomMessage(message, opts) {
      if (globalThis.__fmMirrorGate) {
        globalThis.__fmMirrorStarted = true;
        await globalThis.__fmMirrorGate;
      }
      session.ops.push({ kind: "custom", message, opts });
      (globalThis.__fmMirrors ??= []).push(message);
    },
    dispose() {
      session.disposed = true;
    },
  };
  const restoredModel = options.model
    ? { provider: options.model.provider, modelId: options.model.id }
    : globalThis.__fmRecordedModels?.get(options.sessionManager.getSessionFile());
  if (restoredModel) (globalThis.__fmRecordedModels ??= new Map()).set(options.sessionManager.getSessionFile(), restoredModel);
  (globalThis.__fmSessions ??= []).push(session);
  return { session, extensionsResult: {} };
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-ai/package.json" <<'JSON'
{"name":"@earendil-works/pi-ai","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-ai/index.js" <<'JS'
// Pi's own thinking-level rules, reproduced from the installed package so the
// portable regression can drive models with different effort ceilings. The
// live guard (tests/fm-pi-branch-live-e2e.test.sh) is what proves the real
// vendor surface still behaves this way.
const EXTENDED_THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];

export function getSupportedThinkingLevels(model) {
  if (!model.reasoning) return ["off"];
  return EXTENDED_THINKING_LEVELS.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    if (level === "xhigh" || level === "max") return mapped !== undefined;
    return true;
  });
}

export function clampThinkingLevel(model, level) {
  const available = getSupportedThinkingLevels(model);
  if (available.includes(level)) return level;
  const requested = EXTENDED_THINKING_LEVELS.indexOf(level);
  if (requested === -1) return available[0] ?? "off";
  for (let i = requested; i < EXTENDED_THINKING_LEVELS.length; i += 1) {
    if (available.includes(EXTENDED_THINKING_LEVELS[i])) return EXTENDED_THINKING_LEVELS[i];
  }
  for (let i = requested - 1; i >= 0; i -= 1) {
    if (available.includes(EXTENDED_THINKING_LEVELS[i])) return EXTENDED_THINKING_LEVELS[i];
  }
  return available[0] ?? "off";
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Text {
  constructor(text, paddingX, paddingY) {
    this.text = text;
    this.paddingX = paddingX;
    this.paddingY = paddingY;
  }
}

export class Container {
  constructor() {
    this.children = [];
  }
  addChild(child) {
    this.children.push(child);
  }
  clear() {
    this.children = [];
  }
  render() {
    return this.children.flatMap((child) => child.render?.() ?? []);
  }
}

export class Box extends Container {
  constructor(paddingX, paddingY, bgFn) {
    super();
    this.paddingX = paddingX;
    this.paddingY = paddingY;
    this.bgFn = bgFn;
  }
  setBgFn(bgFn) {
    this.bgFn = bgFn;
  }
}

export class Input {
  constructor() {
    this.value = "";
    this.focused = false;
  }
  getValue() {
    return this.value;
  }
  setValue(value) {
    this.value = value;
  }
  handleInput(data) {
    this.value = data === "\u007f" ? this.value.slice(0, -1) : this.value + data;
  }
  invalidate() {}
  render() {
    return [this.value];
  }
}

// Records every construction so a driver can assert the rows and the visible
// bound the extension asked Pi's real SelectList for. Navigation keys arrive
// as their keybinding ids because the driver's fake keybindings manager
// matches an id against the raw key data.
export class SelectList {
  constructor(items, maxVisible, theme) {
    this.items = items;
    this.maxVisible = maxVisible;
    this.theme = theme;
    this.selectedIndex = 0;
    (globalThis.__fmPickerLists ??= []).push({ items: items.map((item) => ({ ...item })), maxVisible });
  }
  handleInput(data) {
    if (data === "tui.select.down") {
      this.selectedIndex = Math.min(this.selectedIndex + 1, this.items.length - 1);
    } else if (data === "tui.select.up") {
      this.selectedIndex = Math.max(0, this.selectedIndex - 1);
    } else if (data === "tui.select.confirm") {
      const item = this.items[this.selectedIndex];
      if (item) this.onSelect?.(item);
    } else if (data === "tui.select.cancel") {
      this.onCancel?.();
    }
  }
  getSelectedItem() {
    return this.items[this.selectedIndex] ?? null;
  }
  invalidate() {}
  render() {
    return this.items.slice(0, this.maxVisible).map((item) => item.label);
  }
}

export function fuzzyFilter(items, query, getText) {
  const needle = query.toLowerCase();
  return items.filter((item) => getText(item).toLowerCase().includes(needle));
}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties, options) {
    return { type: "object", properties, ...(options ?? {}) };
  },
  String(options) {
    return { type: "string", ...(options ?? {}) };
  },
  Number(options) {
    return { type: "number", ...(options ?? {}) };
  },
  Boolean(options) {
    return { type: "boolean", ...(options ?? {}) };
  },
  Optional(schema) {
    return { ...schema, optional: true };
  },
  Literal(value) {
    return { const: value };
  },
  Union(schemas, options) {
    return { anyOf: schemas, ...(options ?? {}) };
  },
};
JS
}

# Shared driver preamble: a fake main-session ExtensionAPI with a synchronous
# event bus (mirrors pi's EventEmitter-backed bus), captured handlers, and
# captured main-bound messages.
DRIVER_PRELUDE_FILE="$TMP_ROOT/driver-prelude.js"
cat > "$DRIVER_PRELUDE_FILE" <<'JS'
const { spawnSync } = await import("node:child_process");
const { mkdirSync, writeFileSync } = await import("node:fs");
const { pathToFileURL } = await import("node:url");

const home = process.env.FM_HOME;
const realRoot = process.env.FM_ROOT_OVERRIDE;
const approvedProject = `${home}/projects/approved`;
mkdirSync(`${home}/state`, { recursive: true });
mkdirSync(`${home}/config`, { recursive: true });
mkdirSync(approvedProject, { recursive: true });
writeFileSync(`${home}/state/branch-driver.meta`, `project=${approvedProject}\nwindow=fm-branch-driver\n`);
// Supervision is default-on for every task: no captain grant file gates it
// any more.
// The branch acts only for the session that owns the fleet lock; drivers own
// it by default, while cold-start and secondary-session scenarios opt out.
if (!process.env.FM_TEST_SKIP_LOCK) {
  writeFileSync(`${home}/state/.lock`, `${process.pid}\n`);
}

// Stubbed model surface: Pi's own catalog and selector dialog, scripted.
// registryModels is what ctx.modelRegistry serves, uiSelections queues the
// captain's answers to ctx.ui.select, and notices records what the command
// told the captain.
const registryModels = [];
const uiSelections = [];
const uiPrompts = [];
const notices = [];
const commands = new Map();
let mainModel = { provider: "anthropic", id: "main-model" };
// Main's own effort, which Pi answers through pi.getThinkingLevel(). Drivers
// change it through setMainThinkingLevel and then fire Pi's own
// thinking_level_select event, exactly as Pi does for a real /settings pick.
let mainThinkingLevel = "medium";
function setMainThinkingLevel(level) {
  mainThinkingLevel = level;
}
globalThis.__fmBranchStaticModels = () => registryModels
  .filter((model) => model.branchAvailable !== false)
  .map((model) => ({ ...model }));
const modelRegistry = {
  getAvailable: () => registryModels.filter((model) => model.mainAvailable !== false).slice(),
  find: (provider, id) => registryModels.find((model) => model.provider === provider && model.id === id),
  hasConfiguredAuth: (model) => model.mainAvailable !== false,
  getRegisteredProviderConfig: (providerId) => globalThis.__fmExtensionProviderConfigs?.get(providerId),
  getRegisteredProviderIds: () => [...(globalThis.__fmExtensionProviderConfigs?.keys() ?? [])],
};
function makeCtx(extra) {
  return {
    modelRegistry,
    get model() {
      return mainModel;
    },
    ui: {
      select(title, options) {
        uiPrompts.push({ title, options });
        return Promise.resolve(uiSelections.shift());
      },
      notify(message, type) {
        notices.push({ message, type });
      },
    },
    ...(extra ?? {}),
  };
}

// A TUI-mode context whose ui.custom runs the extension's real picker
// component headlessly: the factory receives a fake renderer, a pass-through
// theme, and a keybindings manager that matches a keybinding id against the
// raw key data, and then the next queued keystroke script is fed to the
// component's own handleInput. Keystrokes are either a keybinding id
// (navigation) or literal characters (search). mainModelWrites records every
// attempt to move the captain's own model, which pinning the branch must
// never do.
const uiKeystrokes = [];
const mainModelWrites = [];
function makeTuiCtx(extra) {
  const base = makeCtx(extra);
  return {
    ...base,
    get model() {
      return mainModel;
    },
    mode: "tui",
    settingsManager: {
      setDefaultModelAndProvider(provider, id) {
        mainModelWrites.push({ provider, id });
      },
    },
    setModel(provider, id) {
      mainModelWrites.push({ provider, id });
    },
    ui: {
      ...base.ui,
      async custom(factory) {
        let result;
        let settled = false;
        const component = await factory(
          {
            requestRender() {},
          },
          { fg: (_color, text) => text, bold: (text) => text },
          { matches: (data, id) => data === id },
          (value) => {
            result = value;
            settled = true;
          },
        );
        component.render(80);
        for (const key of uiKeystrokes.shift() ?? ["tui.select.confirm"]) {
          if (settled) break;
          component.handleInput(key);
        }
        if (!settled) throw new Error("the picker script ended without a selection or a cancellation");
        return result;
      },
    },
  };
}

const busHandlers = new Map();
const bus = {
  on(channel, handler) {
    busHandlers.set(channel, [...(busHandlers.get(channel) ?? []), handler]);
    return () => {};
  },
  emit(channel, data) {
    for (const handler of busHandlers.get(channel) ?? []) handler(data);
  },
};
const piHandlers = new Map();
const sentToMain = [];
const mainUserMessages = [];
const mainTools = [];
const renderers = new Map();
const entryRenderers = new Map();
const markdownTransformers = [];
const mainEntries = [];
const mainSessionManager = {
  getSessionFile: () => `${home}/main.jsonl`,
  getEntries: () => mainEntries,
};
const defaultSessionCtx = { model: mainModel, modelRegistry, sessionManager: mainSessionManager };
let activeMainSession = mainSessionManager;
const pi = {
  events: bus,
  on(event, handler) {
    piHandlers.set(event, [...(piHandlers.get(event) ?? []), handler]);
  },
  registerTool(tool) {
    mainTools.push(tool);
  },
  registerCommand(name, options) {
    commands.set(name, options);
  },
  registerMessageRenderer(customType, renderer) {
    renderers.set(customType, renderer);
  },
  registerEntryRenderer(customType, renderer) {
    entryRenderers.set(customType, renderer);
  },
  registerMarkdownTransformer(transformer) {
    markdownTransformers.push(transformer);
  },
  appendEntry(customType, data) {
    activeMainSession.getEntries().push({ type: "custom", customType, data });
  },
  sendMessage(message, options) {
    sentToMain.push({ message, options: options ?? {} });
  },
  sendUserMessage(content, options) {
    mainUserMessages.push({ content, options: options ?? {} });
  },
  getThinkingLevel() {
    if (globalThis.__fmThinkingLevelError) throw new Error(globalThis.__fmThinkingLevelError);
    return mainThinkingLevel;
  },
};
// Pi's own extension runner awaits every handler in turn
// (dist/core/extensions/runner.js emit), so this driver does too: a handler
// that awaits a subprocess must be allowed to finish before the driver
// asserts on what it did.
async function fire(event, payload, ctx) {
  const eventCtx = ctx;
  if (eventCtx?.sessionManager) activeMainSession = eventCtx.sessionManager;
  let result;
  for (const handler of piHandlers.get(event) ?? []) result = await handler(payload, eventCtx);
  return result;
}
function makeOffer(message, projects = [approvedProject], heartbeat = false, eligible = projects.length > 0 || heartbeat, awayOnly = false) {
  const offer = {
    message,
    projects,
    heartbeat,
    eligible,
    awayOnly,
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.settlement = settlement;
    },
  };
  return offer;
}
function dispatch(message, projects, heartbeat, eligible) {
  const offer = makeOffer(message, projects, heartbeat, eligible);
  if (offer.eligible) {
    const row = offer.heartbeat
      ? "1\t1\theartbeat\theartbeat\theartbeat\n"
      : `1\t1\tsignal\tbranch-driver.status\t${message}\n`;
    writeFileSync(`${home}/state/.wake-queue`, row);
  }
  bus.emit("fm-branch-supervision:dispatch", offer);
  return offer;
}
async function settle(predicate, label) {
  for (let i = 0; i < 250; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error(`timed out waiting for ${label}`);
}
function outcomeScript(args) {
  const result = spawnSync("bash", [`${realRoot}/bin/fm-branch-outcome.sh`, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state` },
  });
  if (result.status !== 0) throw new Error(`fm-branch-outcome.sh ${args.join(" ")} failed: ${result.stderr}`);
  return (result.stdout || "").trim();
}
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
JS
DRIVER_PRELUDE=$(cat "$DRIVER_PRELUDE_FILE")

test_branch_dispatch_two_stage_filter_and_prefix_contract() {
  local repo home out status
  repo="$TMP_ROOT/dispatch-root"
  home="$TMP_ROOT/dispatch-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { pi, fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, entryRenderers, mainEntries, defaultSessionCtx, home, realRoot }; })()`);
const { pi, fire, dispatch, settle, outcomeScript, sentToMain, mainUserMessages, mainTools, renderers, entryRenderers, mainEntries, defaultSessionCtx, home, realRoot } = globalThis.__t;
import { readFileSync, writeFileSync } from "node:fs";

writeFileSync(`${home}/state/.lock`, `${process.ppid}\n`);
await fire("session_start", {}, defaultSessionCtx);

// 1. An accepted wake reaches the branch session, never main. Keep the
// scripted turn open until its durable report below, matching a real Pi prompt
// whose tool calls complete before session.prompt() settles.
let finishWakePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishWakePrompt = resolve; });
const offer = dispatch("signal: task-9 done: PR https://example.com/pr/9 checks green");
if (!offer.accepted) throw new Error("branch did not accept the wake offer");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const wakePrompt = globalThis.__fmPrompts[0];
if (!wakePrompt.includes("FIRSTMATE SUPERVISION WAKE: signal: task-9 done")) {
  throw new Error(`branch prompt lost the wake reason: ${wakePrompt}`);
}
if (mainUserMessages.length !== 0) throw new Error("accepted wake leaked to main as a user message");

// 2. Byte-stable prefix contract: same tool names in the same order, a
// generator-produced system prompt, no project resources, and the branch bash
// carries the deterministic actor identity.
const session = globalThis.__fmSessions[0];
if (JSON.stringify(session.options.tools) !== JSON.stringify(["read", "bash", "fm_branch_report"])) {
  throw new Error(`unexpected tool order: ${JSON.stringify(session.options.tools)}`);
}
const loader = globalThis.__fmLoaders[0];
for (const key of ["noExtensions", "noSkills", "noPromptTemplates", "noThemes", "noContextFiles"]) {
  if (loader.options[key] !== true) throw new Error(`branch loader must set ${key}`);
}
if (!loader.options.systemPrompt || !loader.options.systemPrompt.startsWith("You are the SUPERVISION BRANCH")) {
  throw new Error("branch system prompt is not the generator's output");
}
if (loader.options.systemPrompt.length < 4096) throw new Error("branch prompt is below the provider caching minimum");
const bashTool = session.options.customTools.find((tool) => tool.name === "bash");
const hooked = bashTool.__options.spawnHook({ command: "true", cwd: "/x", env: { PATH: "/bin" } });
if (hooked.env.FM_SUPERVISION_ACTOR !== "branch") throw new Error("branch bash does not inject the branch actor");
if (hooked.env.FM_LEASE_HOLDER_PID !== String(process.ppid)) throw new Error("branch bash does not pin the verified session-lock holder pid");

// 3. Shared per-home prompt_cache_key: overrides only payloads that already
// carry one, stable within the home.
let cacheHandler = null;
const factoryEntry = loader.options.extensionFactories[0];
const factory = typeof factoryEntry === "function" ? factoryEntry : factoryEntry.factory;
factory({ on: (event, handler) => { if (event === "before_provider_request") cacheHandler = handler; } });
if (!cacheHandler) throw new Error("branch cache-key hook not registered");
const rewriteA = cacheHandler({ type: "before_provider_request", payload: { prompt_cache_key: "session-a", model: "m" } });
const rewriteB = cacheHandler({ type: "before_provider_request", payload: { prompt_cache_key: "session-b", model: "m" } });
if (!rewriteA.prompt_cache_key.startsWith("fm-branch-")) throw new Error(`unexpected cache key: ${rewriteA.prompt_cache_key}`);
if (rewriteA.prompt_cache_key !== rewriteB.prompt_cache_key) throw new Error("branch cache key varies within one home");
if (rewriteA.model !== "m") throw new Error("cache-key hook dropped payload fields");
const untouched = cacheHandler({ type: "before_provider_request", payload: { model: "m" } });
if (untouched !== undefined) throw new Error("cache-key hook rewrote a provider payload with no prompt_cache_key");
console.log(`CACHE_KEY=${rewriteA.prompt_cache_key}`);

// 4. Two-stage filter, stage 2: routine while main is idle appends with no
// turn; routine while main is busy defers to after the captain's next prompt;
// captain-relevant persists a visible entry with no model turn. Store rows are
// written before delivery and marked read only after it.
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
const r1 = await report.execute("call-1", { task: "branch-driver", verdict: "routine", summary: "worker healthy, no action needed", wake: "signal: working" }, undefined, undefined, {});
if (r1.isError) throw new Error(`routine report failed: ${JSON.stringify(r1)}`);
finishWakePrompt();
// Reports below are made outside any wake prompt (as a real Pi turn cannot):
// wait for the wake to settle so its task scope has been cleared.
await offer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
if (sentToMain.length !== 1) throw new Error("routine report did not merge exactly one note");
if (sentToMain[0].message.customType !== "fm-branch-merge") throw new Error("merge note has the wrong custom type");
if (sentToMain[0].options.triggerTurn) throw new Error("routine idle merge must not trigger a turn");
if (sentToMain[0].options.deliverAs) throw new Error("routine idle merge must append immediately");
await fire("agent_start", {});
await report.execute("call-2", { task: "task-9", verdict: "routine", summary: "still healthy" }, undefined, undefined, {});
if (sentToMain[1].options.deliverAs !== "nextTurn" || sentToMain[1].options.triggerTurn) {
  throw new Error(`routine busy merge must defer to nextTurn without a turn: ${JSON.stringify(sentToMain[1].options)}`);
}
await fire("agent_end", {});
await report.execute("call-3", { task: "task-9", verdict: "captain", summary: "PR https://example.com/pr/9 checks green, ready for review" }, undefined, undefined, {});
// A captain outcome opens exactly ONE sequence-keyed processing turn: a
// hidden, typed request that names the sequence and carries the exact stored
// summary. No unkeyed turn ever opens, and routine delivery is untouched.
const processingRequests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (processingRequests.length !== 1) throw new Error(`captain delivery opened ${processingRequests.length} processing requests, not exactly one`);
const processingRequest = processingRequests[0];
if (processingRequest.options.triggerTurn !== true || processingRequest.options.deliverAs !== "followUp") {
  throw new Error(`the processing request must open one follow-up turn: ${JSON.stringify(processingRequest.options)}`);
}
if (processingRequest.message.display !== false) throw new Error("the processing request must stay hidden: the visible entry is the display");
if (!processingRequest.message.content.includes("[seq 3, recorded 0m ago] task-9: PR https://example.com/pr/9 checks green, ready for review")) {
  throw new Error(`the processing request lost its sequence key, recorded age, or exact summary: ${processingRequest.message.content}`);
}
if (sentToMain.some((sent) => sent.options.triggerTurn && sent.message.customType !== "fm-branch-process")) {
  throw new Error("an unkeyed turn opened on main");
}
if (sentToMain.length !== 3) throw new Error(`captain delivery changed routine delivery: ${JSON.stringify(sentToMain)}`);
writeFileSync(`${home}/state/delivered-processing-request`, processingRequest.message.content);
if (typeof sentToMain[0].message.content !== "string" || !sentToMain[0].message.content.startsWith("⛵ ")) {
  throw new Error(`routine note missing sailboat prefix: ${sentToMain[0].message.content}`);
}
if (/branch merged|\[routine\]|\[captain\]/.test(sentToMain[0].message.content)) {
  throw new Error(`routine note still has boilerplate: ${sentToMain[0].message.content}`);
}
// A routine note is rendered as a custom message. A captain outcome is a
// versioned custom session entry whose exact store summary is its payload.
if (sentToMain[0].message.display !== true) {
  throw new Error(`routine note must render: display=${sentToMain[0].message.display}`);
}
writeFileSync(`${home}/state/delivered-routine-note`, sentToMain[0].message.content);
const captainEntries = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (captainEntries.length !== 1) throw new Error(`captain delivery count was ${captainEntries.length}, not 1`);
const captainRecord = captainEntries[0].data;
if (captainRecord.version !== 1 || captainRecord.seq !== 3 || captainRecord.task !== "task-9" || captainRecord.verdict !== "captain") {
  throw new Error(`captain entry lost its identity: ${JSON.stringify(captainRecord)}`);
}
if (captainRecord.summary !== "PR https://example.com/pr/9 checks green, ready for review") {
  throw new Error(`captain entry changed the exact summary: ${captainRecord.summary}`);
}

// The store (the owned durable contract) holds all three outcomes in order,
// and each merged note advanced the read cursor.
const rows = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
if (rows.length !== 3) throw new Error(`expected 3 store rows, got ${rows.length}`);
if (rows[0].verdict !== "routine" || rows[2].verdict !== "captain") throw new Error("store verdicts out of order");
if (rows[0].wake !== "signal: working") throw new Error("store lost the wake reason");
if (outcomeScript(["unread"]) !== "") throw new Error("merged outcomes were not marked read");

// 5. Main-side surfaces: the on-demand store reader tool and the merge-note
// renderer.
const outcomesTool = mainTools.find((tool) => tool.name === "fm_branch_outcomes");
if (!outcomesTool) throw new Error("fm_branch_outcomes was not registered on main");
const renderTheme = {
  fg(_color, text) { return text; },
  bg(_color, text) { return text; },
  bold(text) { return text; },
};
const renderContext = { state: {}, isError: false, isPartial: false };
const stockResult = { content: [{ type: "text", text: "OUTCOME_DUMP" }] };
const calmOffCall = outcomesTool.renderCall({}, renderTheme, renderContext);
const calmOffResult = outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext);
if (calmOffCall.constructor.name !== "Box" || calmOffCall.paddingX !== 1 || calmOffCall.paddingY !== 1) {
  throw new Error("fm_branch_outcomes changed its ordinary shell rendering");
}
if (calmOffResult.constructor.name !== "Container" || calmOffCall.children[0]?.text !== "fm_branch_outcomes" || calmOffCall.children[1]?.text !== "OUTCOME_DUMP") {
  throw new Error("fm_branch_outcomes changed its ordinary call or result rendering");
}
const legacyStockResult = {
  content: [{
    type: "text",
    text: Array.from({ length: 12 }, (_, index) => `LEGACY_OUTCOME_${String(index + 1).padStart(2, "0")}`).join("\n"),
  }],
};
const legacyRenderContext = { state: {}, isError: false, isPartial: false };
const legacyCall = outcomesTool.renderCall({}, renderTheme, legacyRenderContext);
outcomesTool.renderResult(legacyStockResult, { expanded: false, isPartial: false }, renderTheme, legacyRenderContext);
const collapsedLegacyText = legacyCall.children[1]?.text;
if (!collapsedLegacyText?.includes("LEGACY_OUTCOME_12") || collapsedLegacyText.includes("more lines")) {
  throw new Error("legacy all-line stock capability did not preserve collapsed Calm-off output");
}
outcomesTool.renderResult(legacyStockResult, { expanded: true, isPartial: false }, renderTheme, legacyRenderContext);
if (legacyCall.children[1]?.text !== collapsedLegacyText) {
  throw new Error("legacy all-line stock capability changed expanded Calm-off output");
}
pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: false });
const calmOnCall = outcomesTool.renderCall({}, renderTheme, renderContext);
const calmOnResult = outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext);
if (calmOnCall.constructor.name !== "Container" || calmOnCall.render(100).length !== 0 || calmOnResult.constructor.name !== "Container" || calmOnResult.render(100).length !== 0) {
  throw new Error("fm_branch_outcomes remained visible while Calm was on");
}
pi.events.emit("firstmate:calm-presentation", { active: false, stockExportRendering: false });
if (outcomesTool.renderCall({}, renderTheme, renderContext).constructor.name !== "Box" || outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext).constructor.name !== "Container") {
  throw new Error("fm_branch_outcomes did not restore ordinary rendering when Calm was turned off");
}
pi.events.emit("firstmate:calm-presentation", { active: true, stockExportRendering: true });
let exportCallFellBack = false;
let exportResultFellBack = false;
try {
  outcomesTool.renderCall({}, renderTheme, renderContext);
} catch {
  exportCallFellBack = true;
}
try {
  outcomesTool.renderResult(stockResult, { expanded: false, isPartial: false }, renderTheme, renderContext);
} catch {
  exportResultFellBack = true;
}
if (!exportCallFellBack || !exportResultFellBack) {
  throw new Error("fm_branch_outcomes replaced Pi stock export rendering");
}
const listed = await outcomesTool.execute("call-4", { recent: 2 }, undefined, undefined, {});
const listedText = listed.content[0].text;
if (listedText.split("\n").length !== 2 || !listedText.includes("checks green")) {
  throw new Error(`fm_branch_outcomes did not read the store: ${listedText}`);
}
if (!renderers.has("fm-branch-merge")) throw new Error("merge-note renderer missing");
if (!entryRenderers.has("fm-branch-visible-outcome")) throw new Error("visible captain-outcome renderer missing");
const assertRenderedNote = (note, glyph) => {
  const fgCalls = [];
  const rendered = renderers.get("fm-branch-merge")(
    { content: note },
    { expanded: false },
    {
      fg(color, text) {
        fgCalls.push({ color, text });
        return text;
      },
    },
  );
  if (!String(rendered.text).includes(glyph)) throw new Error(`renderer dropped ${glyph}: ${rendered.text}`);
  if (String(rendered.text).includes("branch merged")) throw new Error(`renderer kept boilerplate: ${rendered.text}`);
  if (rendered.paddingX === 0 && rendered.paddingY === 0) {
    throw new Error("renderer still pads with 0,0 instead of outputPad");
  }
  if (rendered.paddingX !== 1 || rendered.paddingY !== 0) {
    throw new Error(
      `renderer padding should match real Pi messages (outputPad, 0), got ${rendered.paddingX},${rendered.paddingY}`,
    );
  }
  const glyphCalls = fgCalls.filter((call) => call.text === glyph);
  if (glyphCalls.length !== 1 || glyphCalls[0].color === "dim") {
    throw new Error(`icon ${glyph} must carry color, not dim: ${JSON.stringify(fgCalls)}`);
  }
  const restCalls = fgCalls.filter((call) => call.text !== glyph);
  if (restCalls.length === 0 || restCalls.some((call) => call.color !== "dim")) {
    throw new Error(`note remainder must be dim: ${JSON.stringify(fgCalls)}`);
  }
};
assertRenderedNote(sentToMain[0].message.content, "⛵");
const captainRendered = entryRenderers.get("fm-branch-visible-outcome")(
  captainEntries[0],
  { expanded: false },
  renderTheme,
);
if (captainRendered.text !== "⚓ [seq 3] task-9: PR https://example.com/pr/9 checks green, ready for review") {
  throw new Error(`captain renderer changed the exact visible outcome: ${captainRendered.text}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "branch dispatch, prefix contract, and two-stage filter must hold: $out"
  case "$out" in
    CACHE_KEY=fm-branch-*) ;;
    *) fail "cache key line missing from driver output: $out" ;;
  esac
  pass "branch owns accepted wakes with a stable prefix and deterministic verdict-driven delivery"

  # The processing request must identify itself to main's model through the
  # real protocol executable: it is typed branch-outcome input whose body names
  # the sequence, the exact outcome, the acknowledgement tool, and the fact
  # that nothing but that acknowledgement closes it. Routine notes remain
  # plain rendered text rather than typed operational input.
  local kind body
  kind=$(./bin/fm-operational-input.sh kind < "$home/state/delivered-processing-request") \
    || fail "the processing request reaches main's model as unattributed text"
  [ "$kind" = branch-outcome ] || fail "the processing request was delivered as kind '$kind', not branch-outcome"
  body=$(./bin/fm-operational-input.sh body < "$home/state/delivered-processing-request") \
    || fail "the processing request envelope carries no readable body"
  case "$body" in
    *"delivered automatically by the supervision branch."*"It was not typed by the captain."*"[seq 3, recorded 0m ago] task-9: PR https://example.com/pr/9 checks green, ready for review"*) ;;
    *) fail "the processing request body lost its self-description or the outcome itself: $body" ;;
  esac
  case "$body" in
    *"check the task's current state first."*"sort the outcomes by that current state into still open and already settled"*"Your reply to the captain covers only the still-open outcomes"*"as if the settled outcomes had never been listed"*) ;;
    *) fail "the processing request body lost its check-first instruction for an outcome already settled: $body" ;;
  esac
  # An outcome carried over from before a restart or a switch of primary has
  # no visible entry in this transcript, so the request must not claim one.
  case "$body" in
    *"was recorded earlier, possibly before a restart or a switch of primary"*"may already have been handled"*) ;;
    *) fail "the processing request body does not say its outcomes were recorded earlier and may already be handled: $body" ;;
  esac
  case "$body" in
    *"anchor entries in this transcript"*) fail "the processing request claims transcript entries a carried-over outcome does not have: $body" ;;
  esac
  case "$body" in
    *"do not re-drain, re-run, or acknowledge the wake."*"call fm_branch_processed with through=3 exactly once."*"never counts as processing."*) ;;
    *) fail "the processing request body lost the event-ownership boundary or the sequence-bound acknowledgement duty: $body" ;;
  esac
  if ./bin/fm-operational-input.sh kind < "$home/state/delivered-routine-note" >/dev/null 2>&1; then
    fail "routine note must stay plain rendered text, not typed operational input"
  fi
  pass "a captain outcome reaches main's model as one typed, sequence-keyed processing request while routine notes stay plain"
}

test_requested_healthy_outcome_and_unsolicited_routine_outcome_delivery() {
  local repo home out status
  repo="$TMP_ROOT/requested-outcome-root"
  home="$TMP_ROOT/requested-outcome-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, sentToMain, mainEntries, outcomeScript, mainTools, home, realRoot }; })()`);
const { fire, dispatch, settle, sentToMain, mainEntries, outcomeScript, mainTools, home, realRoot } = globalThis.__t;
import { existsSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";

const fleetOperations = [];
globalThis.__fmExecuteBranchBash = async (context) => {
  // The retired two-actor lease helper is gone with the fleet session lock;
  // the branch's own shell now marks itself through the injected actor env.
  const actor = spawnSync("bash", ["-c", 'printf "%s\n" "${FM_SUPERVISION_ACTOR:-main}"'], {
    encoding: "utf8",
    cwd: context.cwd,
    env: context.env,
  });
  if (actor.status !== 0) throw new Error(`branch bash actor resolution failed: ${actor.stderr}`);
  const result = spawnSync("bash", ["-c", context.command], {
    encoding: "utf8",
    cwd: context.cwd,
    env: context.env,
  });
  fleetOperations.push({ command: context.command, actor: actor.stdout.trim(), status: result.status });
  return {
    content: [{ type: "text", text: `${result.stdout}${result.stderr}` }],
    details: { stdout: result.stdout, stderr: result.stderr, exitCode: result.status, actor: actor.stdout.trim() },
    isError: result.status !== 0,
  };
};

async function runFleetCommand(session, args) {
  const bash = session.options.customTools.find((tool) => tool.name === "bash");
  const command = ["bin/fm-wake-drain.sh", ...args].join(" ");
  const result = await bash.execute(`fleet-${fleetOperations.length}`, { command }, undefined, undefined, {});
  if (result.isError) throw new Error(`fleet command failed: ${JSON.stringify(result)}`);
  return result.details;
}

function directlyRequestsResourceReport(mirror) {
  const latestCaptain = mirror.at(-1) ?? "";
  const words = new Set(latestCaptain.toLowerCase().split(/[^a-z0-9]+/).filter(Boolean));
  const requestsDelivery = ["give", "provide", "send", "show"].some((word) => words.has(word));
  const namesReport = ["report", "status", "measurement"].some((word) => words.has(word));
  const namesResources = ["resource", "resources", "cpu", "memory"].some((word) => words.has(word));
  return requestsDelivery && namesReport && namesResources;
}

globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const mirror = session.ops
    .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
    .map((op) => op.message.content);
  const directlyRequested = directlyRequestsResourceReport(mirror);
  const drained = await runFleetCommand(session, []);
  const ack = drained.stderr.match(/--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)/);
  if (!ack) throw new Error(`drain did not return its acknowledgement command: ${drained.stderr}`);
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  const verdictDescription = report.parameters.properties.verdict.description;
  if (!verdictDescription.includes("Verdict: routine or captain") ||
      !verdictDescription.includes("one owner of the rule") ||
      verdictDescription.includes("unconditionally")) {
    throw new Error(`branch provider received conflicting verdict semantics: ${verdictDescription}`);
  }
  const result = await report.execute(
    `resource-result-${fleetOperations.length}`,
    {
      task: "branch-driver",
      verdict: directlyRequested ? "captain" : "routine",
      summary: "healthy resource report: CPU 12%, memory 41%",
      wake: "signal: healthy resource result",
    },
    undefined,
    undefined,
    {},
  );
  if (result.isError) throw new Error(`branch report failed: ${JSON.stringify(result)}`);
  await runFleetCommand(session, ["--ack-through", ack[1], "--recovery-generation", ack[2]]);
};

const explicitRequest = "Please give me a fresh mini system-resource report.";
const longRequests = [
  `${explicitRequest}${" head context".repeat(500)}`,
  `${"middle context ".repeat(250)}${explicitRequest}${" middle context".repeat(250)}`,
  `${"tail context ".repeat(500)}${explicitRequest}`,
];
const requestedPrompts = [...longRequests, "FIRSTMATE give me a fresh system-resource report."];
// Match Pi's real AgentSession.prompt ordering: before_agent_start receives
// the expanded prompt before _runAgentPrompt appends its user message to the
// SessionManager. Keeping entries stale at the hook boundary is the regression.
const entries = [];
const mainCtx = {
  model: { provider: "anthropic", id: "main-model" },
  sessionManager: {
    getSessionFile: () => `${home}/main.jsonl`,
    getEntries: () => entries,
  },
};
const operational = spawnSync(
  "bash",
  [`${realRoot}/bin/fm-operational-input.sh`, "encode", "watcher"],
  { encoding: "utf8", input: "operational watcher injection" },
);
if (operational.status !== 0) throw new Error(`could not create operational input: ${operational.stderr}`);
await fire("before_agent_start", { messageType: "user", prompt: operational.stdout }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: operational.stdout } });
const unsolicitedPrompt = "Please keep responses concise while monitoring the fleet.";
await fire("before_agent_start", { messageType: "user", prompt: unsolicitedPrompt }, mainCtx);
await fire("before_agent_start", {
  messageType: "custom",
  message: { role: "custom", customType: "fixture", content: "custom content must not become captain dialog", display: true },
}, mainCtx);
entries.push({ type: "message", message: { role: "user", content: unsolicitedPrompt } });
// Pi 1.2's idle sendMessage trigger carries a CustomMessage, not a prompt.
// Even report-request wording in it must never become captain dialog.
await fire("before_agent_start", {
  type: "before_agent_start",
  messageType: "custom",
  message: {
    role: "custom", customType: "fixture", content: explicitRequest,
    display: false, timestamp: Date.now(),
  },
  systemPrompt: "fixture", systemPromptOptions: {},
}, mainCtx);
await fire("agent_start", {}, mainCtx);
await fire("agent_end", {}, mainCtx);
const legacyOperational = "⁣FIRSTMATE_OP: give me a fresh system-resource report.";
await fire("before_agent_start", { messageType: "user", prompt: legacyOperational }, mainCtx);
entries.push({ type: "message", message: { role: "user", content: legacyOperational } });
await fire("agent_start", {}, mainCtx);
const unsolicited = dispatch("signal: healthy resource result");
if (!unsolicited.accepted) throw new Error("branch did not accept the unsolicited result");
await settle(() => fleetOperations.length === 2, "unsolicited result acknowledgement");
if (sentToMain.length !== 1 || sentToMain[0].options.triggerTurn) {
  throw new Error(`unsolicited healthy result opened a main turn: ${JSON.stringify(sentToMain)}`);
}
const sailboat = sentToMain[0];
if (sailboat.message.display !== true || !sailboat.message.content.startsWith("⛵ branch-driver:")) {
  throw new Error(`unsolicited healthy result was not a rendered sailboat note: ${JSON.stringify(sailboat)}`);
}

const outcomes = mainTools.find((tool) => tool.name === "fm_branch_outcomes");
if (!outcomes) throw new Error("main did not receive its outcome-reading permission surface");
const visibleToMain = await outcomes.execute("main-reads-sailboat", { recent: 1 }, undefined, undefined, {});
const mainOutcomeText = visibleToMain.content.map((item) => item.text ?? "").join("\n");
if (visibleToMain.isError || !mainOutcomeText.includes("healthy resource report: CPU 12%, memory 41%")) {
  throw new Error(`main could not use the sailboat content through its existing permission path: ${JSON.stringify(visibleToMain)}`);
}
if (fleetOperations.length !== 2) throw new Error("main's outcome read reprocessed the fleet event");

for (let index = 0; index < requestedPrompts.length; index += 1) {
  const content = requestedPrompts[index];
  if (index < longRequests.length && content.length <= 4000) {
    throw new Error(`request fixture ${index} did not exceed the mirror bound`);
  }
  await fire("before_agent_start", { messageType: "user", prompt: content }, mainCtx);
  // Pi persists this only after every before_agent_start handler has returned.
  entries.push({ type: "message", message: { role: "user", content } });
  await fire("agent_start", {}, mainCtx);
  const requested = dispatch("signal: healthy resource result");
  if (!requested.accepted) throw new Error(`branch did not accept requested result ${index}`);
  await settle(() => fleetOperations.length === 4 + (index * 2), `requested result ${index} acknowledgement`);
  const deliveredRequestMirror = globalThis.__fmSessions[0].ops
    .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
    .at(-1)?.message.content;
  if (deliveredRequestMirror !== `[captain] ${content}`) {
    throw new Error(`pre-turn-end mirror changed long captain request ${index}`);
  }
  const visible = entries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
  if (visible.length !== index + 1 || visible.at(-1).data.summary !== "healthy resource report: CPU 12%, memory 41%") {
    throw new Error(`requested result ${index} did not persist one exact visible outcome: ${JSON.stringify(visible)}`);
  }
}
const mirroredCaptainText = globalThis.__fmSessions[0].ops
  .filter((op) => op.kind === "custom" && op.message.customType === "fm-main-mirror")
  .map((op) => op.message.content);
for (const content of [unsolicitedPrompt, ...requestedPrompts]) {
  const copies = mirroredCaptainText.filter((text) => text === `[captain] ${content}`).length;
  if (copies !== 1) throw new Error(`current captain prompt was mirrored ${copies} times instead of once`);
}
if (mirroredCaptainText.some((text) =>
  text === `[captain] ${explicitRequest}` ||
  text.includes("operational watcher injection") || text.includes("FIRSTMATE_OP: give me a fresh system-resource report") ||
  text.includes("custom content must not become captain dialog")
)) {
  throw new Error("canonical current or legacy operational input entered captain mirror context");
}
if ((globalThis.__fmPrompts ?? []).length !== 5) throw new Error("a handled fleet wake was rerun");
let processingRequests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (sentToMain.length !== 1 + processingRequests.length) {
  throw new Error(`captain results entered model delivery as unkeyed messages: ${JSON.stringify(sentToMain)}`);
}
if (processingRequests.length !== 1 || processingRequests[0].options.triggerTurn !== true) {
  throw new Error(`captain results re-sent while the first keyed request was pending: ${JSON.stringify(processingRequests)}`);
}
await fire("agent_settled", {}, mainCtx);
processingRequests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (processingRequests.length !== 2 || processingRequests[1].options.triggerTurn !== true) {
  throw new Error(`the widened captain sequence set did not open one keyed turn at the run boundary: ${JSON.stringify(processingRequests)}`);
}
for (let seq = 2; seq <= 5; seq += 1) {
  if (!processingRequests[1].message.content.includes(`[seq ${seq}, recorded 0m ago] branch-driver: healthy resource report: CPU 12%, memory 41%`)) {
    throw new Error(`the widened processing request lost seq ${seq}: ${processingRequests[1].message.content}`);
  }
}
if (!processingRequests[1].message.content.includes("through=5")) {
  throw new Error(`the widened processing request lost its highest acknowledgement key: ${processingRequests[1].message.content}`);
}
if (fleetOperations.length !== 10 || fleetOperations.some((operation) => operation.status !== 0)) {
  throw new Error(`fleet event ownership repeated or failed work: ${JSON.stringify(fleetOperations)}`);
}
if (fleetOperations.some((operation) => operation.actor !== "branch")) {
  throw new Error(`main took fleet-event ownership: ${JSON.stringify(fleetOperations)}`);
}
if (existsSync(`${home}/state/.wake-queue`) && readFileSync(`${home}/state/.wake-queue`, "utf8") !== "") {
  throw new Error("acknowledged fleet wake remained queued for another owner");
}
const rows = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8").trim().split("\n").map((line) => JSON.parse(line));
if (rows.length !== 5 || rows[0].verdict !== "routine" || rows.slice(1).some((row) => row.verdict !== "captain")) {
  throw new Error(`provider classifications were not recorded once in order: ${JSON.stringify(rows)}`);
}
if (outcomeScript(["unread"]) !== "") throw new Error("merged outcomes remained unread for redelivery");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "requested and unsolicited healthy outcomes must follow their distinct public delivery paths: $out"
  pass "requested and unsolicited healthy outcomes keep distinct delivery and event ownership"
}

test_captain_outcome_is_exactly_once_across_crash_reload_and_unrelated_response() {
  local repo home out status
  repo="$TMP_ROOT/visible-outcome-recovery-root"
  home="$TMP_ROOT/visible-outcome-recovery-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, sentToMain, mainEntries, entryRenderers, outcomeScript, defaultSessionCtx }; })()`);
const { fire, sentToMain, mainEntries, entryRenderers, outcomeScript, defaultSessionCtx } = globalThis.__t;

// Incident topology: compaction leaves stale framing, then the immediately
// preceding assistant repeats an unrelated retry update. Neither can satisfy
// or alter a completed branch outcome because no model response is delivery.
mainEntries.push(
  { type: "compaction", summary: "Last user request: retry Gmail intake." },
  { type: "message", message: { role: "assistant", content: "The retry safe-stopped; diagnosis is underway." } },
);
const summary1 = "Completed diagnosis: the cursor trusted an unrelated assistant response.";
const seq1 = Number(outcomeScript(["append", "--task", "email-intake", "--verdict", "captain", "--summary", summary1]));
// Crash boundary: appendEntry persisted, but mark-read did not happen.
mainEntries.push({
  type: "custom",
  customType: "fm-branch-visible-outcome",
  data: { version: 1, seq: seq1, task: "email-intake", verdict: "captain", summary: summary1, silent: false },
});
await fire("session_start", {}, defaultSessionCtx);
if (outcomeScript(["unread"]) !== "") throw new Error("reload did not advance the cursor after finding the persisted entry");

const summary2 = "Second completed request stayed exact while main was streaming.";
const seq2 = Number(outcomeScript(["append", "--task", "task-busy", "--verdict", "captain", "--summary", summary2]));
await fire("agent_start", {});
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
await fire("agent_end", {});
const visible = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (visible.length !== 2 || visible[0].data.seq !== seq1 || visible[1].data.seq !== seq2) {
  throw new Error(`reload recovery was not sequence-keyed and exactly once: ${JSON.stringify(visible)}`);
}
if (visible[0].data.summary !== summary1 || visible[1].data.summary !== summary2) {
  throw new Error(`visible delivery changed an exact stored summary: ${JSON.stringify(visible)}`);
}
if (sentToMain.some((sent) => sent.message.customType !== "fm-branch-process")) {
  throw new Error(`captain recovery queued an unkeyed model message: ${JSON.stringify(sentToMain)}`);
}
// Recovery re-presents every still-unprocessed sequence in one keyed request.
const recovered = sentToMain.at(-1)?.message.content ?? "";
if (!recovered.includes(`[seq ${seq1}, recorded 0m ago] email-intake: ${summary1}`) || !recovered.includes(`[seq ${seq2}, recorded 0m ago] task-busy: ${summary2}`)) {
  throw new Error(`reload did not re-present the unprocessed outcomes for processing: ${recovered}`);
}

// A second reload sees the cursor and must stay idempotent.
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome").length !== 2) {
  throw new Error("a second reload duplicated a visible captain outcome");
}
const rendered = entryRenderers.get("fm-branch-visible-outcome")(
  visible[0],
  { expanded: false },
  { fg: (_color, text) => text },
);
if (rendered.text !== `⚓ [seq ${seq1}] email-intake: ${summary1}`) {
  throw new Error(`renderer did not preserve exact outcome text: ${rendered.text}`);
}

// A reused sequence with different content cannot be treated as delivery.
const seq3 = Number(outcomeScript(["append", "--task", "task-conflict", "--verdict", "captain", "--summary", "authoritative summary"]));
mainEntries.push({
  type: "custom",
  customType: "fm-branch-visible-outcome",
  data: { version: 1, seq: seq3, task: "task-conflict", verdict: "captain", summary: "different summary", silent: false },
});
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (!outcomeScript(["unread"]).includes('"seq":3')) {
  throw new Error("conflicting sequence content advanced the cursor instead of failing closed");
}
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq3).length !== 1) {
  throw new Error("conflicting sequence content caused another entry to be appended");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "captain outcome recovery must be deterministic across crash, reload, and stale assistant context: $out"
  pass "captain outcomes are exact and exactly once across crash, reload, busy main, compaction, and an unrelated assistant response"
}

test_captain_outcome_processing_turn_is_sequence_keyed_and_re_presented() {
  local repo home out status
  repo="$TMP_ROOT/processing-turn-root"
  home="$TMP_ROOT/processing-turn-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, sentToMain, mainEntries, mainTools, outcomeScript, defaultSessionCtx, home, bus, markdownTransformers }; })()`);
const { fire, dispatch, settle, sentToMain, mainEntries, mainTools, outcomeScript, defaultSessionCtx, home, bus, markdownTransformers } = globalThis.__t;
import { writeFileSync } from "node:fs";
import { spawn } from "node:child_process";

let requestsFloor = 0;
const requests = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-process").slice(requestsFloor);
const unprocessedSeqs = () => outcomeScript(["unprocessed"]).split("\n").filter(Boolean).map((line) => JSON.parse(line).seq);
let consumedRequests = 0;
const consumeRequest = async (userFirst = false) => {
  const pending = requests().at(-1);
  if (!pending || consumedRequests === requests().length) return;
  consumedRequests = requests().length;
  if (userFirst || pending.options.deliverAs === "nextTurn") {
    await fire("message_start", { message: { role: "user", content: "A new question" } });
  }
  await fire("message_start", { message: { role: "custom", ...pending.message } });
};
const runOf = async (fn) => {
  await fire("agent_start", {});
  await fire("turn_start", {});
  await consumeRequest();
  await fn?.();
  await fire("agent_end", {});
  await fire("agent_settled", {});
};
const render = (text, isStreaming = true, messageType = "assistant") => markdownTransformers.reduce(
  (value, transform) => transform(value, { messageType, isStreaming, availableWidth: 80 }), text,
);
const finish = async (text, extra = []) => {
  const message = { role: "assistant", content: [...(text ? [{ type: "text", text }] : []), ...extra], usage: { totalTokens: 7 }, stopReason: "stop" };
  await fire("message_start", { message });
  const replacement = await fire("message_end", { message });
  const stored = replacement?.message ?? message;
  mainEntries.push({ type: "message", message: stored });
  if (stored.usage !== message.usage) throw new Error("suppression lost usage accounting");
  return stored;
};
const visibleFinals = () => mainEntries.filter((entry) => entry.type === "message" && entry.message.role === "assistant")
  .flatMap((entry) => entry.message.content.filter((part) => part.type === "text").map((part) => part.text));
const priorResult = "Completed the requested work. The checks passed and the result is ready for review.";
await finish(priorResult);

// A home with a delivered captain row and no processed marker (upgraded from
// before the marker existed, or switched from the supervision host, whose
// drain advances the same read cursor) cannot tell a read row from an
// acknowledged one, so the first reconciliation presents it again for
// processing instead of adopting it as processed.
const legacy = Number(outcomeScript(["append", "--task", "legacy", "--verdict", "captain", "--summary", "delivered before processing existed"]));
outcomeScript(["mark-read", "--through", String(legacy)]);
mainEntries.push({ type: "custom", customType: "fm-branch-visible-outcome", data: { version: 1, seq: legacy, task: "legacy", verdict: "captain", summary: "delivered before processing existed", silent: false } });
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 1 || !requests()[0].message.content.includes(`[seq ${legacy}, recorded 0m ago] legacy: delivered before processing existed`)) {
  throw new Error(`a delivered but unacknowledged row was not presented again for processing: ${JSON.stringify(sentToMain)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([legacy])) throw new Error("the first reconciliation adopted a delivered row as processed");
outcomeScript(["mark-processed", "--through", String(legacy)]);
requestsFloor = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process").length;

// A routine outcome never opens a processing turn. Keep the scripted prompt
// open through its report, as the real AgentSession does for tool execution.
let finishRoutinePrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishRoutinePrompt = resolve; });
const routineOffer = dispatch("signal: routine wake");
if (!routineOffer.accepted) throw new Error("branch refused the routine wake");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "routine branch prompt");
const session = globalThis.__fmSessions[0];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
await report.execute("routine", { task: "branch-driver", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
finishRoutinePrompt();
// The reports below are made outside any wake prompt: wait for the wake to
// settle so its task scope has been cleared.
await routineOffer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
const routineSeq = JSON.parse(outcomeScript(["list", "--recent", "1"])).seq;
await runOf();
if (requests().length !== 0) throw new Error("a routine outcome opened a processing turn");

// An actionable (captain) outcome: exactly one keyed request while main is idle.
const decision = "worker needs a scope decision: option A skip the stage, option B re-implement it";
const first = await report.execute("captain-1", { task: "task-d", verdict: "captain", summary: decision }, undefined, undefined, {});
if (first.isError) throw new Error(`captain report failed: ${JSON.stringify(first)}`);
const seq = JSON.parse(outcomeScript(["list", "--recent", "1"])).seq;
if (requests().length !== 1) throw new Error(`captain delivery opened ${requests().length} requests, not 1`);
const request = requests()[0];
if (request.options.triggerTurn !== true || request.options.deliverAs !== "followUp" || request.message.display !== false) {
  throw new Error(`the processing request must be one hidden follow-up turn: ${JSON.stringify(request)}`);
}
if (!request.message.content.includes(`[seq ${seq}, recorded 0m ago] task-d: ${decision}`)) throw new Error(`the request lost its key or summary: ${request.message.content}`);
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error(`delivery did not leave seq ${seq} unprocessed: ${unprocessedSeqs()}`);

// The first presentation carries the one visible response for this outcome,
// even when it forgets to acknowledge.
await runOf(async () => {
  if (render("Captain, task-d needs your call.") !== "Captain, task-d needs your call.") {
    throw new Error("the first processing presentation hid its response while streaming");
  }
  await finish("Captain, task-d needs your call.");
});
if (visibleFinals().at(-1) !== "Captain, task-d needs your call.") throw new Error("the first processing presentation lost its final");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("an unacknowledged answer advanced the processed marker");
if (requests().length !== 2 || requests()[1].options.triggerTurn !== true) throw new Error("the first re-presentation must open its own turn");
if (!requests()[1].message.content.includes(`[seq ${seq}, recorded 0m ago] task-d: ${decision}`)) throw new Error("the re-presentation changed the outcome");
// The hidden retry repeats this set's prior reply instead of acknowledging.
// Exercise Pi's public message replacement and Markdown transformer surfaces:
// buffer streaming until the complete reply can be compared, then keep every
// differing reply, even one already visible outside this processing set.
await runOf(async () => {
  if (render("Captain, task-d needs your call.") !== "" || render("prior reasoning", true, "assistant-thinking") !== "") {
    throw new Error("a processing retry reply leaked while streaming");
  }
  if (render(priorResult, false) !== priorResult || render("A question", true, "user") !== "A question") {
    throw new Error("silencing a retry hid an earlier final or a user message");
  }
  const repeated = await finish(" \nCaptain, task-d needs your call. \n");
  if (repeated.content.length) throw new Error("the exact trimmed repeat retained visible content");
  await finish(priorResult);
  await finish("Captain, task-d needs your call!");
  const empty = await finish("");
  const whitespace = await finish(" \n\t");
  if (empty.content.length || whitespace.content.length) throw new Error("an empty retry retained visible content");
});
if (JSON.stringify(visibleFinals()) !== JSON.stringify([priorResult, "Captain, task-d needs your call.", priorResult, "Captain, task-d needs your call!"])) {
  throw new Error(`retry comparison hid new prose or exposed a repeat: ${JSON.stringify(visibleFinals())}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a repeated or empty answer advanced the processed marker");
if (requests().length !== 3) throw new Error(`an unrelated answer did not re-present the outcome: ${requests().length} requests`);
if (requests()[2].options.deliverAs !== "nextTurn" || requests()[2].options.triggerTurn) {
  throw new Error(`after the triggered budget the request must ride the next prompt: ${JSON.stringify(requests()[2].options)}`);
}
// A quiet settle with the copy still queued does not queue a duplicate.
await fire("agent_settled", {});
if (requests().length !== 3) throw new Error("a duplicate next-turn copy was queued");
// The captain's next prompt consumes that copy; settling unacknowledged queues one more.
await runOf(async () => {
  if (render("The new answer") !== "The new answer") throw new Error("a nextTurn request hid the user response");
  await finish("The new answer");
});
if (visibleFinals().at(-1) !== "The new answer") throw new Error("a nextTurn request removed the user final");
if (requests().length !== 4 || requests()[3].options.deliverAs !== "nextTurn") throw new Error("the outcome stopped being re-presented on later prompts");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a paraphrase advanced the processed marker");

// A session replacement re-presents with a fresh triggered budget.
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 5 || requests()[4].options.triggerTurn !== true) throw new Error("session start did not re-present the unprocessed outcome with its own turn");
if (mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq).length !== 1) {
  throw new Error("re-presentation duplicated the visible entry");
}

const call = { type: "toolCall", id: "ack-call", name: "fm_branch_processed", arguments: { through: seq } };
const thinking = { type: "thinking", thinking: "reasoning for the tool", thinkingSignature: "provider-signature" };
// The replacement's first presentation keeps prose sent alongside the
// acknowledgement call; this run's call is left unexecuted.
await runOf(async () => {
  const firstWithTool = await finish("Captain, task-d still needs your call.", [thinking, call]);
  if (firstWithTool.content.length !== 3 || firstWithTool.content[0].text !== "Captain, task-d still needs your call.") {
    throw new Error("the first presentation dropped prose sent alongside its acknowledgement");
  }
});
if (visibleFinals().at(-1) !== "Captain, task-d still needs your call.") throw new Error("the first presentation after replacement lost its final");
if (requests().length !== 6 || requests()[5].options.triggerTurn !== true) throw new Error("the replacement did not retry the unacknowledged outcome");
await fire("agent_start", {});
await fire("turn_start", {});
await consumeRequest();
await finish("stale after reload");
if (visibleFinals().at(-1) !== "stale after reload") throw new Error("session replacement hid differing retry prose");
const repeatedAfterReload = await finish("stale after reload");
if (repeatedAfterReload.content.length) throw new Error("session replacement lost retry comparison");
const withTool = await finish("stale after reload", [thinking, call]);
if (withTool.content.length !== 3 || withTool.content[0].text !== "stale after reload" || withTool.content[1] !== thinking || withTool.content[2] !== call) {
  throw new Error("retry comparison dropped prose, signed reasoning, or the acknowledgement call");
}
await fire("turn_start", {});
if (render("still unacknowledged") !== "") throw new Error("a tool continuation released suppression before acknowledgement");

// Only the sequence-bound acknowledgement closes it.
const nativeTools = new Map();
const messageTypes = new Set();
bus.emit("firstmate:native-tools", {
  register: (tool) => nativeTools.set(tool.name, tool),
  allowMessageType: (type) => messageTypes.add(type),
});
if ([...nativeTools.keys()].sort().join(",") !== "fm_branch_outcomes,fm_branch_processed") throw new Error("native discovery exposed unrelated tools");
for (const tool of mainTools) {
  if (nativeTools.get(tool.name)?.execute !== tool.execute) throw new Error("native controls lost the original guards");
}
if ([...messageTypes].sort().join(",") !== "firstmate-sessionstart-nudge,fm-branch-merge,fm-branch-process") throw new Error("operational message allowlist changed");
const processed = nativeTools.get("fm_branch_processed");
if (!processed) throw new Error("main did not receive its acknowledgement tool");
const routineAck = await processed.execute("ack-routine", { through: routineSeq }, undefined, undefined, {});
if (!routineAck.isError || !routineAck.content.some((item) => item.type === "text" && item.text.includes("not an unprocessed captain outcome"))) {
  throw new Error(`a routine-sequence acknowledgement was not clearly refused: ${JSON.stringify(routineAck)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a routine-sequence acknowledgement closed the open captain sequence");
const tooFar = await processed.execute("ack-too-far", { through: seq + 100 }, undefined, undefined, {});
if (!tooFar.isError) throw new Error("an acknowledgement beyond the read cursor was accepted");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("a refused acknowledgement moved the marker");
if (render("still refused") !== "") throw new Error("a refused acknowledgement released suppression");
const ack = await processed.execute("ack", { through: seq }, undefined, undefined, {});
if (ack.isError) throw new Error(`acknowledgement failed: ${JSON.stringify(ack)}`);
if (unprocessedSeqs().length !== 0) throw new Error("the acknowledgement did not close the sequence");
if (render("A newly processed response") !== "A newly processed response") throw new Error("successful acknowledgement did not release the response");
await finish("A newly processed response");
if (visibleFinals().at(-1) !== "A newly processed response") throw new Error("the acknowledged outcome lost its response");
const before = requests().length;
await runOf();
if (requests().length !== before) throw new Error("an acknowledged outcome was presented again");

// Two newer captain outcomes in a row: the second does not overlap a request
// still pending its run boundary, and the widened request appears at that
// boundary. A partial acknowledgement keeps the newer sequence open.
// The replacement session rebuilt the branch, so its report tool is the new
// session's; the old session's tool is generation-refused by design.
const stale = await report.execute("captain-stale", { task: "task-e", verdict: "captain", summary: "must be refused" }, undefined, undefined, {});
if (!stale.isError) throw new Error("a replaced branch session's report tool was accepted");
let finishReplacementPrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishReplacementPrompt = resolve; });
const replacementOffer = dispatch("signal: after replacement");
if (!replacementOffer.accepted) throw new Error("branch refused a wake after the replacement");
await settle(() => (globalThis.__fmSessions ?? []).length === 2, "replacement branch session");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "replacement branch prompt");
const report2 = globalThis.__fmSessions[1].options.customTools.find((tool) => tool.name === "fm_branch_report");
const beforePair = requests().length;
const second = await report2.execute("captain-2", { task: "branch-driver", verdict: "captain", summary: "PR https://example.com/pr/e is ready for review" }, undefined, undefined, {});
if (second.isError) throw new Error(`second captain report failed: ${JSON.stringify(second)}`);
finishReplacementPrompt();
// The next report is made outside the wake prompt: wait for the wake to
// settle so its task scope has been cleared.
await replacementOffer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
const seqE = seq + 1;
const seqF = seq + 2;
if (requests().length !== beforePair + 1 || !requests().at(-1).message.content.includes(`[seq ${seqE}, recorded 0m ago] branch-driver:`)) {
  throw new Error("the first newer captain outcome did not open its processing request");
}
const third = await report2.execute("captain-3", { task: "task-f", verdict: "captain", summary: "worker blocked on a missing credential" }, undefined, undefined, {});
if (third.isError) throw new Error(`third captain report failed: ${JSON.stringify(third)}`);
if (requests().length !== beforePair + 1) throw new Error("a widened sequence re-sent while the earlier request was pending");
const unlisted = await processed.execute("ack-unlisted", { through: seqF }, undefined, undefined, {});
if (!unlisted.isError || !unlisted.content.some((item) => item.type === "text" && item.text.includes("not listed in the active processing request"))) {
  throw new Error(`an unlisted newer sequence was not clearly refused: ${JSON.stringify(unlisted)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seqE, seqF])) {
  throw new Error(`an unlisted acknowledgement closed outcomes: ${unprocessedSeqs()}`);
}
await runOf();
if (requests().length !== beforePair + 2) throw new Error("the widened sequence was not presented at the run boundary");
const latest = requests().at(-1).message.content;
if (!latest.includes(`[seq ${seqE}, recorded 0m ago] branch-driver:`) || !latest.includes(`[seq ${seqF}, recorded 0m ago] task-f:`) || !latest.includes(`through=${seqF}`)) {
  throw new Error(`the widened request did not cover every unprocessed sequence with the highest key: ${latest}`);
}
const beforePairRepeat = requests().length;
await runOf();
if (requests().length !== beforePairRepeat + 1 || requests().at(-1).options.triggerTurn !== true) {
  throw new Error("the second presentation of the widened sequence set did not open its own turn");
}
await fire("agent_start", {});
await fire("turn_start", {});
await consumeRequest();
const partial = await processed.execute("ack-partial", { through: seqE }, undefined, undefined, {});
if (partial.isError) throw new Error(`partial acknowledgement failed: ${JSON.stringify(partial)}`);
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seqF])) throw new Error(`a partial acknowledgement did not keep the newer sequence open: ${unprocessedSeqs()}`);
if (render("partial response") !== "") throw new Error("partial acknowledgement released the remaining outcome's retry");
const beforeF = requests().length;
await runOf();
if (
  requests().length !== beforeF + 1 ||
  requests().at(-1).options.triggerTurn !== true ||
  requests().at(-1).options.deliverAs !== "followUp" ||
  !requests().at(-1).message.content.includes(`[seq ${seqF}, recorded 0m ago] task-f:`)
) {
  throw new Error("the changed remaining sequence set did not restart its triggered presentation budget");
}
const done = await processed.execute("ack-final", { through: seqF }, undefined, undefined, {});
if (done.isError || unprocessedSeqs().length !== 0) throw new Error("the final acknowledgement did not close the newer sequence");

// A follow-up queued while main is busy must not hide the answer already
// underway. Suppression starts only when Pi consumes the custom message.
await fire("agent_start", {});
await fire("turn_start", {});
await fire("message_start", { message: { role: "user", content: "An active user request" } });
await report2.execute("busy-report", { task: "task-g", verdict: "captain", summary: "A new decision" }, undefined, undefined, {});
await finish("The busy user answer");
if (visibleFinals().at(-1) !== "The busy user answer") throw new Error("queueing a retry hid an in-flight user answer");
await fire("turn_start", {});
await consumeRequest();
await finish("Captain, task-g needs your call.");
if (visibleFinals().at(-1) !== "Captain, task-g needs your call.") throw new Error("a consumed busy follow-up hid its first presentation");
// User steering in that same turn must immediately recover ordinary output.
await fire("message_start", { message: { role: "user", content: "A steering question" } });
await finish("The steering answer");
if (visibleFinals().at(-1) !== "The steering answer") throw new Error("processing suppression hid a steering response");
await fire("agent_end", {});
await fire("agent_settled", {});
// Pi can also batch the user before the custom follow-up in one turn.
await fire("agent_start", {});
await fire("turn_start", {});
await consumeRequest(true);
await finish("The batched user answer");
if (visibleFinals().at(-1) !== "The batched user answer") throw new Error("processing suppression hid a user batched before the custom message");
const latestSeq = unprocessedSeqs().at(-1);
await processed.execute("ack-busy", { through: latestSeq }, undefined, undefined, {});
await fire("agent_end", {});
await fire("agent_settled", {});

// A first reply can be empty or unrelated: a retry that finally handles the
// outcome must stay visible. Reusing the same response across new sequence
// sets must not make it a duplicate, and only the tool closes each outcome.
for (const initial of ["", "Unrelated prior acknowledgment"]) {
  await report2.execute("new-set", { task: "task-new", verdict: "captain", summary: "Another decision" }, undefined, undefined, {});
  const newSeq = unprocessedSeqs().at(-1);
  const startCount = visibleFinals().length;
  await runOf(async () => {
    const firstReply = await finish(initial);
    if ((firstReply.content[0]?.text ?? "") !== initial) throw new Error("first presentation changed its output");
  });
  const newAnswer = "Handled the new outcome.";
  await runOf(async () => {
    await finish(newAnswer);
    if (visibleFinals().at(-1) !== newAnswer) throw new Error("the first real handling on a retry was hidden");
    const repeat = await finish(newAnswer);
    if (repeat.content.length) throw new Error("a repeated retry final was retained");
  });
  if (visibleFinals().length !== startCount + (initial ? 2 : 1)) throw new Error("sequence comparison lost or duplicated a final");
  if (!unprocessedSeqs().includes(newSeq) || requests().at(-1).options.deliverAs !== "nextTurn") {
    throw new Error("an empty, unrelated, or differing reply closed the durable obligation");
  }
  await processed.execute("ack-new-set", { through: newSeq }, undefined, undefined, {});
  if (unprocessedSeqs().length) throw new Error("acknowledgement did not close the new set");
  await fire("agent_settled", {});
}

// A session that does not own the fleet lock cannot acknowledge anything.
// Only a LIVE foreign holder takes ownership away; "1", a malformed value, or a
// dead pid all belong to this native home.
const foreignHolder = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
writeFileSync(`${home}/state/.lock`, `${foreignHolder.pid}\n`);
try {
  const foreign = await processed.execute("ack-foreign", { through: seqF }, undefined, undefined, {});
  if (!foreign.isError || !foreign.content[0].text.includes("does not own the fleet lock")) {
    throw new Error(`a session without lock ownership acknowledged an outcome: ${JSON.stringify(foreign)}`);
  }
} finally {
  foreignHolder.kill("SIGTERM");
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "captain outcomes must be processed through a sequence-bound acknowledgement and re-presented until then: $out"
  pass "a captain outcome opens one sequence-keyed processing turn, survives empty and unrelated answers, is re-presented at run end and session start, and closes only on its acknowledgement"
}

test_abbreviated_processing_request_points_to_full_outcome() {
  local repo home out status
  repo="$TMP_ROOT/abbreviated-outcome-root"
  home="$TMP_ROOT/abbreviated-outcome-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, sentToMain, mainEntries, outcomeScript, defaultSessionCtx }; })()`);
const { fire, sentToMain, mainEntries, outcomeScript, defaultSessionCtx } = globalThis.__t;
const summary = "begin " + "x".repeat(1100) + " decision: do not merge until approved";
const seq = Number(outcomeScript(["append", "--task", "long-outcome", "--verdict", "captain", "--summary", summary]));
outcomeScript(["mark-read", "--through", String(seq)]);
mainEntries.push({ type: "custom", customType: "fm-branch-visible-outcome", data: { version: 1, seq, task: "long-outcome", verdict: "captain", summary, silent: false } });
await fire("session_start", {}, defaultSessionCtx);
const requests = sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
if (requests.length !== 1) throw new Error(`expected one processing request: ${JSON.stringify(requests)}`);
const delivered = requests[0].message.content;
const abbreviated = JSON.parse(outcomeScript(["unprocessed"]));
const pointer = `bin/fm-branch-outcome.sh lookup --seqs ${seq}`;
if (abbreviated.summary.length > 1024 || !abbreviated.summary.startsWith("begin ") || !abbreviated.summary.includes(`… [summary abbreviated; read the full outcome with ${pointer}]`)) {
  throw new Error(`unprocessed did not bound the summary with a row-specific lookup pointer: ${abbreviated.summary}`);
}
if (!delivered.includes(`[seq ${seq}, recorded ${abbreviated.recordedAgo} ago] long-outcome: ${abbreviated.summary}`)) throw new Error("processing request did not carry the bounded summary and its lookup pointer");
if (!delivered.includes("abbreviated line is incomplete") || !delivered.includes("read the full outcome before acting on, relaying, or acknowledging it")) {
  throw new Error("delivered instruction did not require reading the full outcome first");
}
const full = JSON.parse(outcomeScript(["lookup", "--seqs", String(seq)]));
if (full.seq !== seq || full.summary !== summary || abbreviated.summary.includes("decision: do not merge until approved")) throw new Error("lookup did not recover the omitted outcome detail");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "Pi must link every abbreviated processing line to the full durable outcome: $out"
  pass "Pi: an abbreviated processing request points to the full outcome and instructs main to read it first"
}

test_large_unprocessed_backlog_replays_in_batches() {
  local repo home out status
  repo="$TMP_ROOT/large-backlog-root"
  home="$TMP_ROOT/large-backlog-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, sentToMain, mainTools, outcomeScript, defaultSessionCtx, home }; })()`);
const { fire, sentToMain, mainTools, outcomeScript, defaultSessionCtx, home } = globalThis.__t;
import { writeFileSync, statSync, existsSync, readFileSync } from "node:fs";
const summary = "a".repeat(4096);
const rows = Array.from({ length: 320 }, (_, i) => JSON.stringify({ seq: i + 1, epoch: Math.floor(Date.now() / 1000), task: `backlog-${i + 1}`, wake: "", verdict: "captain", summary, silent: false, statusEndpoint: 0, statusIdent: "-" }));
writeFileSync(`${home}/state/branch-outcomes.jsonl`, rows.join("\n") + "\n");
writeFileSync(`${home}/state/.branch-outcomes-cursor`, "320\n");
if (statSync(`${home}/state/branch-outcomes.jsonl`).size <= 1024 * 1024 || existsSync(`${home}/state/.branch-outcomes-processed`)) throw new Error("fixture is not a marker-less >1 MiB backlog");
const requests = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
await fire("session_start", {}, defaultSessionCtx);
const processed = mainTools.find((tool) => tool.name === "fm_branch_processed");
for (let start = 1; start <= 320; start += 32) {
  const through = start + 31;
  const listing = outcomeScript(["unprocessed"]);
  if (Buffer.byteLength(listing) >= 1024 * 1024 || listing.split("\n").filter(Boolean).length !== 32) throw new Error(`store did not bound the batch starting at ${start}`);
  const request = requests().at(-1);
  if (!request || !request.message.content.includes(`[seq ${start}, recorded`) || !request.message.content.includes(`through=${through}`) || request.message.content.includes(`[seq ${through + 1},`)) throw new Error(`request did not present the batch starting at ${start}`);
  if (Buffer.byteLength(request.message.content) >= 1024 * 1024) throw new Error("encoded request exceeded runner limit");
  const ack = await processed.execute(`batch-${through}`, { through }, undefined, undefined, {});
  if (ack.isError || readFileSync(`${home}/state/.branch-outcomes-processed`, "utf8").trim() !== String(through)) throw new Error(`batch was not acknowledged through ${through}: ${JSON.stringify(ack)}`);
  await fire("agent_start", {});
  await fire("agent_end", {});
  await fire("agent_settled", {});
}
if (outcomeScript(["unprocessed"]).trim() !== "") throw new Error("backlog was not fully processed");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "Pi must replay a marker-less >1 MiB backlog in sequence-bound batches: $out"
  pass "Pi: a marker-less >1 MiB backlog is presented oldest first in bounded requests and continues after batch acknowledgement"
}

test_undated_unprocessed_outcome_surfaces_and_stays_unprocessed() {
  local repo home fake_root out status f
  repo="$TMP_ROOT/undated-outcome-root"
  home="$TMP_ROOT/undated-outcome-home"
  fake_root="$TMP_ROOT/undated-outcome-fmroot"
  mkdir -p "$home/state" "$home/config" "$fake_root/bin"
  install_pi_branch_extension_fixture "$repo"
  for f in "$ROOT"/bin/*; do ln -s "$f" "$fake_root/bin/${f##*/}"; done
  rm "$fake_root/bin/fm-branch-outcome.sh"
  # A store whose unprocessed listing breaks its contract by dropping the age
  # while $FM_HOME/strip-age exists.
  cat > "$fake_root/bin/fm-branch-outcome.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = unprocessed ] && [ -e "\$FM_HOME/strip-age" ]; then
  set -o pipefail
  "$ROOT/bin/fm-branch-outcome.sh" "\$@" | jq -c 'del(.recordedAgo)'
  exit
fi
exec "$ROOT/bin/fm-branch-outcome.sh" "\$@"
SH
  chmod +x "$fake_root/bin/fm-branch-outcome.sh"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, sentToMain, mainEntries, outcomeScript, defaultSessionCtx, home }; })()`);
const { fire, sentToMain, mainEntries, outcomeScript, defaultSessionCtx, home } = globalThis.__t;
import { rmSync, writeFileSync } from "node:fs";

const requests = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
const notes = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-merge" && sent.message.display === true);
const unprocessedSeqs = () => outcomeScript(["unprocessed"]).split("\n").filter(Boolean).map((line) => JSON.parse(line).seq);

const seq = Number(outcomeScript(["append", "--task", "undated", "--verdict", "captain", "--summary", "PR is ready to merge"]));
outcomeScript(["mark-read", "--through", String(seq)]);
mainEntries.push({ type: "custom", customType: "fm-branch-visible-outcome", data: { version: 1, seq, task: "undated", verdict: "captain", summary: "PR is ready to merge", silent: false } });
writeFileSync(`${home}/strip-age`, "");
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 0) throw new Error(`an undated outcome was formatted into a processing request: ${JSON.stringify(requests())}`);
if (notes().length !== 1 || !notes()[0].message.content.includes("breaks its contract") || !notes()[0].message.content.includes('"task":"undated"')) {
  throw new Error(`the store-contract error was not reported visibly to main: ${JSON.stringify(sentToMain)}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq])) throw new Error("an undated outcome was dropped or treated as processed");

rmSync(`${home}/strip-age`);
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 1 || !requests()[0].message.content.includes(`[seq ${seq}, recorded 0m ago] undated: PR is ready to merge`)) {
  throw new Error(`the outcome was not presented, dated, once the store was healthy: ${JSON.stringify(sentToMain)}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an unprocessed row without its age must be reported and stay unprocessed: $out"
  pass "an unprocessed captain row the store lists without its age is reported to main, never formatted undated, and stays unprocessed until the store is healthy"
}

test_branch_cache_key_is_per_home_stable() {
  local repo home_a home_b key_a1 key_a2 key_b
  repo="$TMP_ROOT/cache-key-root"
  home_a="$TMP_ROOT/cache-key-home-a"
  home_b="$TMP_ROOT/cache-key-home-b"
  mkdir -p "$home_a/state" "$home_a/config" "$home_b/state" "$home_b/config"
  install_pi_branch_extension_fixture "$repo"
  probe() {
    PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
      DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle }; })()`);
const { dispatch, settle } = globalThis.__t;
dispatch("signal: cache probe");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "branch wake prompt");
const loader = globalThis.__fmLoaders[0];
const entry = loader.options.extensionFactories[0];
let handler = null;
(typeof entry === "function" ? entry : entry.factory)({ on: (e, h) => { if (e === "before_provider_request") handler = h; } });
const rewritten = handler({ type: "before_provider_request", payload: { prompt_cache_key: "x" } });
console.log(rewritten.prompt_cache_key);
process.exit(0);
EOF
  }
  key_a1=$(probe "$home_a") || fail "cache-key probe A1 failed: $key_a1"
  key_a2=$(probe "$home_a") || fail "cache-key probe A2 failed: $key_a2"
  key_b=$(probe "$home_b") || fail "cache-key probe B failed: $key_b"
  [ -n "$key_a1" ] || fail "empty cache key from probe A1"
  [ "$key_a1" = "$key_a2" ] || fail "cache key not stable across branch sessions in one home: $key_a1 vs $key_a2"
  [ "$key_a1" != "$key_b" ] || fail "cache key does not separate homes: $key_a1"
  pass "branch prompt_cache_key is stable per home across sessions and distinct between homes"
}

test_branch_default_on_heartbeat_afk_and_fallback() {
  local repo broken home out status
  repo="$TMP_ROOT/gating-root"
  broken="$TMP_ROOT/gating-broken-root"
  home="$TMP_ROOT/gating-home"
  mkdir -p "$home/state" "$home/config" "$broken/bin"
  install_pi_branch_extension_fixture "$repo"
  cp "$ROOT/bin/fm-branch-outcome.sh" "$ROOT/bin/fm-classify-lib.sh" \
    "$ROOT/bin/fm-lease-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$ROOT/bin/fm-wake-grant.sh" "$broken/bin/"
  cat > "$broken/bin/fm-branch-prompt.sh" <<'SH'
#!/usr/bin/env bash
echo "synthetic generator failure" >&2
exit 1
SH
  chmod +x "$broken/bin/fm-branch-prompt.sh"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, fire, settle, home, sentToMain, mainEntries, mainTools, outcomeScript, defaultSessionCtx }; })()`);
const { dispatch, fire, settle, home, sentToMain, mainEntries, mainTools, outcomeScript, defaultSessionCtx } = globalThis.__t;
import { existsSync, readFileSync, rmSync, writeFileSync } from "node:fs";

// Default-on: with no config/pi-supervision-branch grant file present at
// all (this driver never writes one), a task-scoped wake is still accepted
// and activation still runs.
if (existsSync(`${home}/config/pi-supervision-branch`)) {
  throw new Error("test fixture unexpectedly wrote a grant file");
}
await fire("session_start", {}, defaultSessionCtx);
if (!dispatch("signal: default-on task wake").accepted) {
  throw new Error("a task-scoped wake was refused with no grant file present");
}
if (!existsSync(`${home}/state/.pi-branch-extension-loaded`)) {
  throw new Error("default-on activation did not write the diagnostic marker");
}
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "default-on task wake prompt");

// The real watcher emits a bare heartbeat only after its cheap bash scan has
// flagged a fleet pass as possibly captain-relevant. The branch accepts that
// wake without a resolved project and performs the deeper review.
if (!dispatch("heartbeat", [], true, true).accepted) {
  throw new Error("eligible heartbeat offer was refused");
}
if (dispatch("heartbeat", [], true, false).accepted) {
  throw new Error("heartbeat with a main-owned queue row was accepted");
}
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "heartbeat wake prompt");

// The branch can downgrade its deeper review to a silent routine outcome or
// escalate a captain-worthy finding into one main turn.
const heartbeatSession = globalThis.__fmSessions[globalThis.__fmSessions.length - 1];
const heartbeatReport = heartbeatSession.options.customTools.find((tool) => tool.name === "fm_branch_report");
await heartbeatReport.execute(
  "heartbeat-noop",
  { task: "fleet", verdict: "routine", summary: "fleet reviewed, nothing changed", silent: true },
  undefined,
  undefined,
  {},
);
const noopMerge = sentToMain[sentToMain.length - 1];
if (noopMerge.options.triggerTurn) throw new Error("a no-op heartbeat pass must not open a main turn");
if (noopMerge.message.display !== false) throw new Error("a no-op heartbeat pass must not render a merge note");
const storedNoop = readFileSync(`${home}/state/branch-outcomes.jsonl`, "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line))
  .find((row) => row.task === "fleet" && row.summary === "fleet reviewed, nothing changed");
if (!storedNoop || storedNoop.verdict !== "routine" || storedNoop.silent !== true) {
  throw new Error("the silent no-op heartbeat disposition was not stored durably");
}
await heartbeatReport.execute(
  "fleet-routine-action",
  { task: "fleet", verdict: "routine", summary: "reconciled the backlog after completed work" },
  undefined,
  undefined,
  {},
);
const fleetRoutineMerge = sentToMain[sentToMain.length - 1];
if (fleetRoutineMerge.message.display !== true) throw new Error("a fleet routine action must render");
if (!fleetRoutineMerge.message.content.startsWith("⛵ fleet: reconciled the backlog after completed work")) {
  throw new Error(`fleet routine action note changed: ${fleetRoutineMerge.message.content}`);
}
writeFileSync(`${home}/state/task-9.status`, "working: check 1 worker still building\n");
const taskNoChangeSummary = "The check 1 worker is still building. Nothing new has happened.";
const sentBeforeSilentTask = sentToMain.length;
const silentTaskResult = await heartbeatReport.execute(
  "task-no-change",
  { task: "task-9", verdict: "routine", summary: taskNoChangeSummary, silent: true },
  undefined,
  undefined,
  {},
);
if (silentTaskResult.isError) throw new Error(`a silent task-level routine outcome was refused: ${JSON.stringify(silentTaskResult)}`);
const taskNoChangeMerge = sentToMain[sentToMain.length - 1];
if (sentToMain.length !== sentBeforeSilentTask + 1 || taskNoChangeMerge.message.display !== false) {
  throw new Error("a silent task-level no-change outcome rendered a note or was not delivered");
}
const storedTaskNoChange = outcomeScript(["list", "--recent", "100"]).split("\n").filter(Boolean)
  .map((line) => JSON.parse(line)).find((row) => row.task === "task-9" && row.summary === taskNoChangeSummary);
if (!storedTaskNoChange || storedTaskNoChange.verdict !== "routine" || storedTaskNoChange.silent !== true) {
  throw new Error("the silent task no-change outcome was not stored durably");
}
if (!existsSync(`${home}/state/.task-9.branch-outcome-index`)) {
  throw new Error("the silent task outcome was omitted from the status-outcome backstop index");
}
const outcomesTool = mainTools.find((tool) => tool.name === "fm_branch_outcomes");
const listedTaskNoChange = await outcomesTool.execute("read-silent-task", { recent: 100 }, undefined, undefined, {});
if (listedTaskNoChange.isError || !listedTaskNoChange.content.some((item) => item.text.includes(taskNoChangeSummary))) {
  throw new Error("fm_branch_outcomes did not expose the silent task no-change outcome");
}
const beforeCaptainSilent = outcomeScript(["list", "--recent", "100"]).trim();
const captainSilent = await heartbeatReport.execute(
  "captain-silent-refused",
  { task: "fleet", verdict: "captain", summary: "captain outcomes stay visible", silent: true },
  undefined,
  undefined,
  {},
);
if (!captainSilent.isError || !captainSilent.content.some((item) => item.text.includes("routine verdict"))) {
  throw new Error("a captain outcome with silent=true was not refused");
}
if (outcomeScript(["list", "--recent", "100"]).trim() !== beforeCaptainSilent) {
  throw new Error("refusing a silent captain outcome still stored it");
}
await heartbeatReport.execute(
  "task-routine",
  { task: "task-9", verdict: "routine", summary: "worker healthy, no action needed" },
  undefined,
  undefined,
  {},
);
const taskRoutineMerge = sentToMain[sentToMain.length - 1];
if (taskRoutineMerge.message.display !== true) throw new Error("a task-scoped routine outcome must render");
if (!taskRoutineMerge.message.content.startsWith("⛵ task-9: worker healthy, no action needed")) {
  throw new Error(`task-scoped routine note changed: ${taskRoutineMerge.message.content}`);
}
await heartbeatReport.execute(
  "heartbeat-finding",
  { task: "fleet", verdict: "captain", summary: "task-2 has been stuck for an hour" },
  undefined,
  undefined,
  {},
);
const captainEntries = mainEntries.filter((entry) => entry.customType === "fm-branch-visible-outcome");
if (captainEntries.length !== 1 || captainEntries[0].data.summary !== "task-2 has been stuck for an hour") {
  throw new Error(`captain-worthy heartbeat finding was not persisted visibly: ${JSON.stringify(captainEntries)}`);
}
if (sentToMain.some((sent) => sent.options.triggerTurn && sent.message.customType !== "fm-branch-process")) {
  throw new Error("heartbeat outcome delivery opened an unkeyed model turn");
}
if (!sentToMain.some((sent) => sent.message.customType === "fm-branch-process" && sent.message.content.includes("task-2 has been stuck for an hour"))) {
  throw new Error("a captain-worthy heartbeat finding did not open its keyed processing turn");
}

// Every other fleet-wide or unresolvable wake (empty projects, not a
// heartbeat) still keeps the wake-to-main path.
if (dispatch("check: unresolved fleet event", []).accepted) {
  throw new Error("branch accepted an unscoped, non-heartbeat fleet wake");
}

// The legacy away daemon flag means nothing on Pi, where the daemon is never
// launched: the branch keeps accepting (docs/pi-supervision-branch.md
// "Postures"; the away-posture record itself is covered by
// test_away_record_parks_main_and_presents_after_archive).
writeFileSync(`${home}/state/.afk`, "");
if (!dispatch("signal: legacy flag present").accepted) throw new Error("branch declined a wake over the legacy daemon flag");
rmSync(`${home}/state/.afk`);
await settle(() => (globalThis.__fmPrompts ?? []).length === 3, "branch wake prompts");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "default-on eligibility, heartbeat routing, and legacy-flag indifference must bind: $out"

  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$TMP_ROOT/gating-home-2" FM_ROOT_OVERRIDE="$broken" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { dispatch, settle, mainUserMessages }; })()`);
const { dispatch, settle, mainUserMessages } = globalThis.__t;

// A branch that cannot come up rejects the accepted offer's settlement so the
// watcher retains delivery ownership and can route the durable wake to main.
// Later wakes are no longer accepted and therefore take that same watcher path
// directly (no wake is ever lost or independently delivered twice).
const firstOffer = dispatch("signal: first wake");
if (!firstOffer.accepted) throw new Error("first offer was not accepted");
const firstFailure = await firstOffer.settlement.then(
  () => null,
  (error) => error,
);
if (!(firstFailure instanceof Error) || !firstFailure.message.includes("synthetic generator failure")) {
  throw new Error(`branch settlement did not expose the startup failure: ${String(firstFailure)}`);
}
if (mainUserMessages.length !== 0) throw new Error("branch bypassed watcher-owned fallback delivery");
if (dispatch("signal: second wake").accepted) throw new Error("broken branch kept accepting wakes");
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "broken-branch settlement must return delivery ownership to the watcher: $out"
  pass "branch default-on eligibility (task-scoped, heartbeat, legacy flag ignored) binds and a broken branch rejects to watcher fallback"
}

# The away posture on the branch side (docs/pi-supervision-branch.md
# "Postures"): with the record present the wake carries the POSTURE: AWAY tail
# ending in the record's read-back verbatim while the branch session and its
# prefix are untouched; check and heartbeat rows are claimed and lift task
# scoping; a captain outcome persists its visible entry but opens NO processing
# turn on the parked main, at report time, at every run boundary, and at
# session start; a request already pending when the record appears is
# cancelled rather than re-presented; and the first run boundary after the
# record is archived presents the accumulated rows with a fresh triggered
# budget. Every record read goes through the real bin/fm-afk-contract.sh.
test_away_record_parks_main_and_presents_after_archive() {
  local repo home out status
  repo="$TMP_ROOT/away-root"
  home="$TMP_ROOT/away-home"
  mkdir -p "$home/state" "$home/config"
  install_pi_branch_extension_fixture "$repo"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, dispatch, settle, sentToMain, mainEntries, outcomeScript, defaultSessionCtx, home, realRoot, bus, approvedProject }; })()`);
const { fire, dispatch, settle, sentToMain, mainEntries, outcomeScript, defaultSessionCtx, home, realRoot, bus, approvedProject } = globalThis.__t;
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const contract = (args) => {
  const result = spawnSync("bash", [`${realRoot}/bin/fm-afk-contract.sh`, ...args], {
    encoding: "utf8",
    env: { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: `${home}/state` },
  });
  if (result.status !== 0) throw new Error(`fm-afk-contract.sh ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout || "";
};
const requests = () => sentToMain.filter((sent) => sent.message.customType === "fm-branch-process");
const unprocessedSeqs = () => outcomeScript(["unprocessed"]).split("\n").filter(Boolean).map((line) => JSON.parse(line).seq);
const runOf = async (fn) => { await fire("agent_start", {}); await fn?.(); await fire("agent_end", {}); await fire("agent_settled", {}); };

await fire("session_start", {}, defaultSessionCtx);

// 1. Attended: no tail, and the branch session is built from the generator.
let finishPrompt;
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishPrompt = resolve; });
const attendedOffer = dispatch("signal: attended wake");
if (!attendedOffer.accepted) throw new Error("the attended wake was refused");
await settle(() => (globalThis.__fmPrompts ?? []).length === 1, "attended branch prompt");
const session = globalThis.__fmSessions[0];
const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
if (globalThis.__fmPrompts[0].includes("POSTURE: AWAY")) throw new Error("an attended wake carried the away tail");
// The prefix is the generator's output handed to the branch's resource
// loader; the per-wake tail must never appear there.
const systemPrompt = (globalThis.__fmLoaders ?? []).at(-1)?.options?.systemPrompt;
if (typeof systemPrompt !== "string" || !systemPrompt.startsWith("You are the SUPERVISION BRANCH")) {
  throw new Error("the branch session was not built from the byte-stable generator");
}
if (systemPrompt.includes("POSTURE: AWAY.")) throw new Error("the per-wake tail leaked into the prefix");
if (!systemPrompt.includes("# Postures") || !systemPrompt.includes("# Ask-user authority policy")) {
  throw new Error("the prefix lost its fixed Postures section or the ask-user-authority policy");
}
await report.execute("r1", { task: "branch-driver", verdict: "routine", summary: "worker healthy" }, undefined, undefined, {});
finishPrompt();
await attendedOffer.settlement;
globalThis.__fmOnBranchPrompt = undefined;

// 2. A captain outcome reported while main is already streaming queues a
// followUp that joins this run. The record appearing before that follow-up
// is consumed must strip the typed processing message at the context
// boundary for followUp, nextTurn, and a dedicated processing turn.
await fire("agent_start", {}, defaultSessionCtx);
const first = await report.execute("c1", { task: "task-d", verdict: "captain", summary: "PR https://example.com/pr/1 is ready for review" }, undefined, undefined, {});
if (first.isError) throw new Error(`attended captain report failed: ${JSON.stringify(first)}`);
const seq1 = JSON.parse(outcomeScript(["list", "--recent", "1"])).seq;
if (requests().length !== 1) throw new Error(`the attended captain outcome opened ${requests().length} requests, not 1`);
const pending = requests()[0];
if (pending.message.customType !== "fm-branch-process") {
  throw new Error(`the first queued request was not a processing delivery: ${JSON.stringify(pending.message)}`);
}
if (pending.options.triggerTurn !== true || pending.options.deliverAs !== "followUp") {
  throw new Error(`the first queued request was not a streaming followUp: ${JSON.stringify(pending.options)}`);
}
if (!pending.message.content.includes(`[seq ${seq1}, recorded 0m ago] `)) {
  throw new Error(`the first queued request lost seq ${seq1}: ${pending.message.content}`);
}
const processingMsg = { role: "custom", customType: pending.message.customType, content: pending.message.content, display: false };
let aborted = false;
const abortCtx = { ...defaultSessionCtx, abort() { aborted = true; } };
await fire("agent_end", {});
await fire("before_agent_start", { messageType: "custom", message: processingMsg }, abortCtx);
await fire("agent_start", {}, defaultSessionCtx);
const attendedProcessing = await fire("context", { messages: [processingMsg] }, abortCtx);
if (aborted || attendedProcessing !== undefined) throw new Error("attended custom processing was aborted or filtered");
await fire("agent_end", {});
contract(["enter", "--words", "merge task-d when green, then cut the prerelease\n\n"]);
for (const message of [
  { ...processingMsg, customType: "unrelated" },
  { ...processingMsg, content: "unrelated processing content" },
]) {
  await fire("before_agent_start", { messageType: "custom", message }, abortCtx);
  const unrelated = await fire("context", { messages: [message, processingMsg] }, abortCtx);
  if (aborted) throw new Error("unrelated custom trigger was treated as a dedicated processing run");
  if (unrelated?.messages?.some((item) => item === processingMsg)) throw new Error("away processing was not stripped");
}
const streamingResult = await fire("context", {
  messages: [
    { role: "user", content: "captain still in this turn" },
    { role: "assistant", content: [{ type: "toolCall", id: "t1" }] },
    { role: "toolResult", toolCallId: "t1", content: "tool finished" },
    processingMsg,
  ],
}, abortCtx);
if (aborted) throw new Error("stripping processing aborted a captain-opened streaming turn after a tool call");
if (streamingResult?.messages?.some((message) => message.customType === "fm-branch-process")) {
  throw new Error(`streaming processing was not stripped: ${JSON.stringify(streamingResult)}`);
}
if (!streamingResult?.messages?.some((message) => message.role === "user")) {
  throw new Error("streaming suppression dropped the captain turn");
}
aborted = false;
const nextTurnResult = await fire("context", {
  messages: [{ role: "user", content: "watcher: FAILED - repair the cycle" }, processingMsg],
}, abortCtx);
if (aborted) throw new Error("stripping a nextTurn processing message aborted the watcher-failure turn");
if (nextTurnResult?.messages?.some((message) => message.customType === "fm-branch-process")) {
  throw new Error(`nextTurn processing was not stripped: ${JSON.stringify(nextTurnResult)}`);
}
const history = [
  { role: "user", content: "earlier captain request" },
  { role: "assistant", content: "earlier firstmate reply" },
];
aborted = false;
const openedByCaptain = await fire("context", {
  messages: [...history, { role: "user", content: "current captain prompt" }, processingMsg],
}, abortCtx);
if (aborted) throw new Error("stripping processing aborted a captain-opened turn that had history");
if (openedByCaptain?.messages?.some((message) => message.customType === "fm-branch-process")) {
  throw new Error(`captain-opened processing was not stripped: ${JSON.stringify(openedByCaptain)}`);
}
aborted = false;
await fire("before_agent_start", { messageType: "user", prompt: "captain typed this now" }, abortCtx);
const stolen = await fire("context", {
  messages: [{ role: "user", content: "captain typed this now" }, processingMsg],
}, abortCtx);
if (aborted) throw new Error("a captain prompt that opened the run was aborted after a queued processing request joined it");
if (stolen?.messages?.some((message) => message.customType === "fm-branch-process")) {
  throw new Error(`joined processing was not stripped from the captain-opened run: ${JSON.stringify(stolen)}`);
}
await fire("agent_end", {});
for (const event of [
  { prompt: pending.message.content },
  { messageType: "user", prompt: pending.message.content },
  { messageType: "custom", message: processingMsg },
]) {
  contract(["archive"]);
  aborted = false;
  await fire("before_agent_start", event, abortCtx);
  contract(["enter", "--words", "merge task-d when green, then cut the prerelease\n\n"]);
  await fire("agent_start", {}, defaultSessionCtx);
  const openedByRequest = await fire("context", { messages: [...history, processingMsg] }, abortCtx);
  if (!aborted) throw new Error(`a dedicated ${event.messageType ?? "legacy"} processing turn with history was not aborted under the record`);
  if (openedByRequest?.messages?.some((message) => message.customType === "fm-branch-process")) {
    throw new Error(`dedicated processing with history was not stripped: ${JSON.stringify(openedByRequest)}`);
  }
  await fire("agent_end", {});
}
for (const message of [
  { ...processingMsg, customType: "fixture" },
  { ...processingMsg, content: "different processing request" },
]) {
  aborted = false;
  await fire("before_agent_start", {
    type: "before_agent_start", messageType: "custom", message,
    systemPrompt: "fixture", systemPromptOptions: {},
  }, abortCtx);
  const unrelated = await fire("context", { messages: [...history, message, processingMsg] }, abortCtx);
  if (aborted) throw new Error("an unrelated custom run was aborted after a processing request joined it");
  if (unrelated?.messages?.some((item) => item.customType === "fm-branch-process")) {
    throw new Error(`joined processing was not stripped from a custom run: ${JSON.stringify(unrelated)}`);
  }
}
aborted = false;
await fire("before_agent_start", { messageType: "custom", message: processingMsg }, abortCtx);
await fire("agent_start", {}, defaultSessionCtx);
const openedByRequest = await fire("context", { messages: [...history, processingMsg] }, abortCtx);
if (!aborted) throw new Error("a dedicated processing turn with history was not aborted under the record");
if (openedByRequest?.messages?.some((message) => message.customType === "fm-branch-process")) {
  throw new Error(`dedicated processing with history was not stripped: ${JSON.stringify(openedByRequest)}`);
}
await fire("agent_end", {});
contract(["archive"]);
aborted = false;
await fire("before_agent_start", {
  type: "before_agent_start", messageType: "custom",
  message: { ...processingMsg, timestamp: Date.now() },
  systemPrompt: "fixture", systemPromptOptions: {},
}, abortCtx);
await fire("agent_start", {}, defaultSessionCtx);
await fire("turn_start", {});
await fire("message_start", { message: processingMsg }, abortCtx);
contract(["enter", "--words", "merge task-d when green, then cut the prerelease\n\n"]);
const openedByCustomRequest = await fire("context", { messages: [...history, processingMsg] }, abortCtx);
if (!aborted) throw new Error("a custom processing turn with history was not aborted when the record appeared");
if (openedByCustomRequest?.messages?.some((message) => message.customType === "fm-branch-process")) {
  throw new Error(`custom processing with history was not stripped: ${JSON.stringify(openedByCustomRequest)}`);
}
await fire("agent_end", {});
await fire("agent_settled", {});
if (requests().length !== 1) throw new Error("a request pending when the record appeared was re-presented to the parked main");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq1])) throw new Error(`the record moved the processed marker: ${unprocessedSeqs()}`);

// 3. Under the record: the tail ends with the read-back verbatim, the branch
// session is the same one (no rebuild, so the prefix is untouched), the
// check and heartbeat rows are claimed, and a claimed check row lifts task
// scoping so the branch may report fleet.
writeFileSync(
  `${home}/state/.wake-queue`,
  "1\t1\tsignal\tbranch-driver.status\tsignal: away wake\n2\t2\tcheck\tmain-only\tcheck: task-d.check.sh: PR merged\n3\t3\theartbeat\theartbeat\theartbeat\n",
);
globalThis.__fmOnBranchPrompt = () => new Promise((resolve) => { finishPrompt = resolve; });
const awayOffer = {
  message: "signal: away wake",
  projects: [approvedProject],
  heartbeat: false,
  eligible: true,
  accepted: false,
  settlement: Promise.resolve(),
  accept(settlement = Promise.resolve()) {
    awayOffer.accepted = true;
    awayOffer.settlement = settlement;
  },
};
bus.emit("fm-branch-supervision:dispatch", awayOffer);
if (!awayOffer.accepted) throw new Error("the away wake was refused");
await settle(() => (globalThis.__fmPrompts ?? []).length === 2, "away branch prompt");
if (globalThis.__fmSessions.length !== 1) throw new Error("the away posture rebuilt the branch session");
const awayPrompt = globalThis.__fmPrompts[1];
const head = "FIRSTMATE SUPERVISION WAKE: signal: away wake\n\nHandle this per your operating procedure and finish with fm_branch_report.\n\nPOSTURE: AWAY. ";
if (!awayPrompt.startsWith(head)) throw new Error(`the away wake lost its shape or its tail: ${awayPrompt}`);
const readback = contract(["readback"]);
if (!readback.endsWith("    merge task-d when green, then cut the prerelease\n    \n")) throw new Error(`the read-back lost the captain's words or their trailing blank line: ${JSON.stringify(readback)}`);
if (!awayPrompt.includes("act on them by your own judgment")) throw new Error(`the away tail lost the words-execution rule: ${awayPrompt}`);
if (awayPrompt.includes("does not execute them")) throw new Error(`the away tail still calls the words inert: ${awayPrompt}`);
if (!awayPrompt.endsWith(`The record, verbatim:\n${readback}`)) throw new Error(`the tail does not end with the record's read-back verbatim, trailing whitespace included: ${JSON.stringify(awayPrompt)}`);
const snapshot = readFileSync(`${home}/state/.branch-eligible-rows`, "utf8").trim().split("\n").join(",");
if (snapshot !== "1,2,3") throw new Error(`the away wake claimed rows ${snapshot}, not every row`);
const fleet = await report.execute("c2", { task: "fleet", verdict: "captain", summary: "per your away instructions: merged task-d's PR once green" }, undefined, undefined, {});
if (fleet.isError) throw new Error(`a fleet report under a claimed check row was refused: ${JSON.stringify(fleet)}`);
finishPrompt();
await awayOffer.settlement;
globalThis.__fmOnBranchPrompt = undefined;
const seq2 = JSON.parse(outcomeScript(["list", "--recent", "1"])).seq;

// 4. No processing turn under the record: not at report time, not at a run
// boundary, not at session start. The visible entry still persists.
if (requests().length !== 1) throw new Error("a captain outcome under the record opened a processing turn on the parked main");
if (!mainEntries.some((entry) => entry.customType === "fm-branch-visible-outcome" && entry.data.seq === seq2)) {
  throw new Error("the captain row's visible entry was not persisted under the record");
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq1, seq2])) throw new Error(`the rows did not accumulate unprocessed: ${unprocessedSeqs()}`);
await runOf();
if (requests().length !== 1) throw new Error("a run boundary under the record opened a processing turn");
await fire("session_shutdown", {});
await fire("session_start", {}, defaultSessionCtx);
if (requests().length !== 1) throw new Error("session start under the record opened a processing turn");
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify([seq1, seq2])) throw new Error("the record moved the processed marker across a session start");

// 5. The return archives the record; the first run boundary presents the
// accumulated set as one request with a fresh triggered budget.
contract(["archive"]);
await runOf();
if (requests().length !== 2) throw new Error(`the run boundary after archive presented ${requests().length - 1} requests, not 1`);
const presented = requests()[1];
if (presented.options.triggerTurn !== true || presented.options.deliverAs !== "followUp") {
  throw new Error(`the post-archive presentation did not open its own turn: ${JSON.stringify(presented.options)}`);
}
for (const needle of [`[seq ${seq1}, recorded 0m ago] task-d:`, `[seq ${seq2}, recorded 0m ago] fleet:`, `through=${seq2}`]) {
  if (!presented.message.content.includes(needle)) throw new Error(`the post-archive request lost ${needle}: ${presented.message.content}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "the away posture must park main and present after archive: $out"
  pass "under the away-posture record the wake carries the verbatim read-back tail, claims every row, opens no processing turn, cancels a pending request, and presents the accumulated rows after archive"
}

# The 2026-09-25 away-window flood on the Pi report path: a held, green PR on a
# finished task was re-escalated on every inactive-outcome cadence, because
# the branch acknowledgement consumed the check row but left its
# terminal-outcome receipt pending, so each later scan re-queued the same
# fingerprint. Through the real reconcile scan, extension dispatch and grant,
# fm_branch_report, and drain, that unchanged situation now reaches the
# captain exactly once, and a new event on the same task - a red check -
# still reaches the captain path afterwards.
test_away_unchanged_held_outcome_reaches_the_captain_once_until_a_new_event() {
  local repo home out status old
  repo="$TMP_ROOT/away-held-once-root"
  home="$TMP_ROOT/away-held-once-home"
  mkdir -p "$home/state" "$home/config" "$home/fakebin" "$home/projects/held"
  install_pi_branch_extension_fixture "$repo"
  git -C "$home/projects/held" init -q
  git -C "$home/projects/held" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  fm_write_meta "$home/state/held.meta" \
    'window=fm-held' "worktree=$home/projects/held" "project=$home/projects/held" \
    'harness=pi' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=g1' \
    'pr=https://example.test/o/r/pull/153'
  printf 'done: PR https://example.test/o/r/pull/153 open, green, mergeable\n' > "$home/state/held.status"
  old=$(( $(date +%s) - 600 ))
  perl -e 'my $t = shift; utime $t, $t, @ARGV or exit 1' "$old" "$home/state/held.meta" "$home/state/held.status" \
    || fail "fixture: could not age the held task's records"
  printf '#!/usr/bin/env bash\nprintf "state: done · source: fake\\n"\n' > "$home/fakebin/fm-crew-state.sh"
  chmod +x "$home/fakebin/fm-crew-state.sh"
  PLUGIN="$repo/.pi/extensions/fm-branch-supervision.ts" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    DRIVER_PRELUDE="$DRIVER_PRELUDE" node --input-type=module > "$TMP_ROOT/node-output" 2>&1 <<'EOF'
const prelude = process.env.DRIVER_PRELUDE;
await eval(`(async () => { ${prelude}; globalThis.__t = { fire, bus, makeOffer, outcomeScript, defaultSessionCtx, home, realRoot, approvedProject }; })()`);
const { fire, bus, makeOffer, outcomeScript, defaultSessionCtx, home, realRoot, approvedProject } = globalThis.__t;
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, utimesSync } from "node:fs";

const state = `${home}/state`;
const env = { ...process.env, FM_HOME: home, FM_STATE_OVERRIDE: state, FM_CONFIG_OVERRIDE: `${home}/config` };
const run = (args, label, extra = {}) => {
  const result = spawnSync("bash", args, { encoding: "utf8", env: { ...env, ...extra } });
  if (result.status !== 0) throw new Error(`${label} failed: ${result.stderr}`);
  return result.stdout || "";
};
const queued = () => (existsSync(`${state}/.wake-queue`) ? readFileSync(`${state}/.wake-queue`, "utf8") : "")
  .split("\n").filter(Boolean);
const outcomes = () => outcomeScript(["list", "--recent", "100"]).split("\n").filter(Boolean).map((line) => JSON.parse(line));
const captains = () => outcomes().filter((row) => row.verdict === "captain");
const unprocessedSeqs = () => outcomeScript(["unprocessed"]).split("\n").filter(Boolean).map((line) => JSON.parse(line).seq);

run([`${realRoot}/bin/fm-afk-contract.sh`, "enter", "--words", "watch the fleet; merge nothing"], "away record");
await fire("session_start", {}, defaultSessionCtx);

globalThis.__fmExecuteBranchBash = async (context) => {
  const result = spawnSync("bash", ["-c", context.command], { encoding: "utf8", cwd: context.cwd, env: context.env });
  return {
    content: [{ type: "text", text: `${result.stdout}${result.stderr}` }],
    details: { stdout: result.stdout, stderr: result.stderr, exitCode: result.status },
    isError: result.status !== 0,
  };
};
let commands = 0;
async function runFleetCommand(session, args) {
  const bash = session.options.customTools.find((tool) => tool.name === "bash");
  const result = await bash.execute(`fleet-${commands++}`, { command: ["bin/fm-wake-drain.sh", ...args].join(" ") }, undefined, undefined, {});
  if (result.isError) throw new Error(`fleet command failed: ${JSON.stringify(result)}`);
  return result.details;
}
// The branch's model: every presented wake is escalated to the captain, as
// the flood's held-PR report was, then acknowledged exactly as printed.
globalThis.__fmOnBranchPrompt = async ({ session }) => {
  const drained = await runFleetCommand(session, []);
  const ack = drained.stderr.match(/--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)/);
  if (!ack) throw new Error(`drain did not return its acknowledgement command: ${drained.stderr}`);
  const report = session.options.customTools.find((tool) => tool.name === "fm_branch_report");
  const result = await report.execute(
    `held-${commands}`,
    { task: "held", verdict: "captain", summary: `escalated: ${drained.stdout.trim().slice(0, 400)}` },
    undefined,
    undefined,
    {},
  );
  if (result.isError) throw new Error(`branch report failed: ${JSON.stringify(result)}`);
  await runFleetCommand(session, ["--ack-through", ack[1], "--recovery-generation", ack[2]]);
};
async function wakeBranch(message) {
  const offer = makeOffer(message, [approvedProject]);
  bus.emit("fm-branch-supervision:dispatch", offer);
  if (!offer.accepted) throw new Error(`the away wake "${message}" was refused`);
  await offer.settlement;
  if (queued().length !== 0) throw new Error(`the branch left rows queued: ${queued()}`);
}
// One watcher cadence: the scan marker is past due, the real scan runs, and
// whatever it queued wakes the branch as the watcher's close would.
async function cadence(n) {
  const marker = `${state}/.inactive-outcome-reconcile`;
  if (existsSync(marker)) {
    const past = Math.floor(Date.now() / 1000) - 120;
    utimesSync(marker, past, past);
  }
  run([`${realRoot}/bin/fm-inactive-reconcile.sh`, "scan"], `cadence ${n}`, {
    FM_INACTIVE_RECONCILE_SECS: "60",
    FM_INACTIVE_CREW_STATE_BIN: `${home}/fakebin/fm-crew-state.sh`,
  });
  if (queued().length > 0) await wakeBranch("check: inactive-outcome");
}

await cadence(1);
if (captains().length !== 1 || !captains()[0].summary.includes("child=held")) {
  throw new Error(`the first cadence did not escalate the held outcome once: ${JSON.stringify(outcomes())}`);
}
for (let n = 2; n <= 5; n += 1) {
  await cadence(n);
  if (captains().length !== 1) {
    throw new Error(`cadence ${n} re-escalated the unchanged held outcome: ${JSON.stringify(captains())}`);
  }
}

run(["-c", '. "$1"; fm_wake_append check "$2" "$3"', "_", `${realRoot}/bin/fm-wake-lib.sh`,
  "pr-check:held", "check: held PR https://example.test/o/r/pull/153 check ci/test turned red"], "red check row");
await wakeBranch("check: held PR https://example.test/o/r/pull/153 check ci/test turned red");
const escalated = captains();
if (escalated.length !== 2 || !escalated[1].summary.includes("turned red")) {
  throw new Error(`the red check did not reach the captain path: ${JSON.stringify(outcomes())}`);
}
if (JSON.stringify(unprocessedSeqs()) !== JSON.stringify(escalated.map((row) => row.seq))) {
  throw new Error(`the captain rows are not both awaiting the captain: ${unprocessedSeqs()}`);
}
process.exit(0);
EOF
  status=$?
  out=$(cat "$TMP_ROOT/node-output")
  expect_code 0 "$status" "an unchanged held outcome must reach the captain once, and a new event must still reach it: $out"
  pass "Pi branch: an unchanged held outcome reaches the captain once across cadences, and a later red check on the task still does"
}
