<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: second mates that are still ordinary direct reports, but run from their own isolated firstmate homes on this machine or another SSH-reachable host.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
firstmate is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, and helper scripts that dsh follows.
Launching dsh inside it for your primary session instantiates your first mate - and makes you the captain.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own Herdr tab you can watch or interact with, and each interactive session's coordinator is a watchable conversation in the DSH subagents menu.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver authorized changes; scout tasks leave standalone investigation reports when the intake contract warrants separate research.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag, an optional `branch=<prefix>` override for the default `fm/` ship-branch prefix, and an optional `forge=gerrit` binding under which the worker publishes a Gerrit change instead of opening a pull request, plus an optional `pr=manual` token under which the worker writes the PR title and body instead of the pipeline.
- **Self-repo boundary** - a home runs as firstmate user/operator by default, so a firstmate bug is diagnosed and patched locally but never pushed, PRed, issued, commented, or forked upstream on its own; publishing to firstmate's own repository needs the `config/firstmate-role` maintainer opt-in or a per-task captain consent ([schema](docs/configuration.md#firstmate-role-configfirstmate-role)).
- **Optional secondmates** - opt in to persistent second mates that run from isolated firstmate homes with their own `FM_HOME`, state, and projects, either locally or as a whole home on an SSH-reachable host, with guarded updates and recovery that never turns an unavailable remote route into a local replacement.
- **Native, watchable supervision** - the dsh plugin gives each interactive session its own coordinator child that absorbs routine fleet traffic; a model-free tick means a quiet fleet costs no agent turns, and your conversation only receives outcomes that need you.
- **Optional Relay** - opt in with one local `.env` pairing token so firstmate can answer your public mentions on X and Discord alike, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-Relay behavior; a final reply promised in a thread becomes durable state that is reconciled from disk, so a restart or a compacted conversation cannot lose it; dry-run preview records would-be replies and dismissals locally before go-live.
- **Strict project boundary** - the first mate is read-only over your projects except for the narrow guarded and captain-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including fleet sync's guarded safe branch pruning; crewmates make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk; the dsh plugin re-owns a session's persisted coordinator after a restart, so the next session reconciles rather than reconstructing, while ordinary supervision recovers confirmed-dead secondmate agents without waiting for one.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- dsh as the primary runtime, with the tracked [dsh plugin](dsh-plugin/README.md) installed.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- Herdr, the only runtime backend, for worker sessions.

The first mate detects missing or outdated tools and offers their install or upgrade after you approve.
Backend setup is linked in [Documentation](#documentation).

### Worker harnesses

Crewmates, scouts, and secondmates run on one of four verified harnesses: Claude Code (`claude`), Cursor Agent CLI (`cursor-agent`), Pi (`pi`), or Oh My Pi (`omp`).
Pick whichever matches each task's subscription and workflow; a config value naming any other harness is refused, and herdr is the only backend.
The dsh plugin is the sole primary-harness surface; the other harnesses have no session-open adapters.

### Install and launch

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
```

Then launch dsh with this checkout as its working directory; AGENTS.md takes over from there:

```sh
dsh
```

The dsh plugin gives the session its native supervisor tools and its own coordinator, and the first mate owns the crew from there.
Worker harness setup is documented in [docs/configuration.md](docs/configuration.md#harness-support).

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing or upgrading anything),
# clones the project under projects/ and spawns two isolated workers in the active backend.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - checks green)

> alright merge it
```

### Runtime backend

Herdr is the only runtime backend; its setup is linked in [Documentation](#documentation) below.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   one visible task endpoint each
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, keeps routine supervision in each session's own coordinator so the captain's conversation sees only outcomes, and brings you finished PRs, approved local merges, or investigation reports.
Optional secondmates extend this to persistent local or whole-home remote second mates, dispatch profiles let you steer which harness handles which task, and opt-in Relay lets the same fleet answer public mentions.
The treehouse worktree pool is not a runtime backend; herdr is the only runtime backend.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional Relay, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Use the slash form shown here; the worker harnesses do not install project hooks for the primary session.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the session's coordinator or the away daemon handles wakes while you step away; see the [away procedure](.agents/skills/afk/SKILL.md) for the posture and return contract |
| `/quiet`           | Keep routine wakes off main while staying and chatting; requested actions proceed now rather than waiting for your return. Where an [attended supervision host](docs/supervision-host.md#quiet-mode) already does this, it only says so; otherwise it starts the quiet daemon, which stays active through ordinary chat until `/quiet off` |
| `/ahoy`            | Recap visible session events since the prior real captain message plus visibly unanswered captain decisions, then guide the captain through any open decisions one at a time in agent-judged impact order; fall back to Bearings when invoked as the session's first real captain message |
| `/bearings`        | Generate a concise four-section chat digest from bounded fleet state, including registered remote-home ledgers and measured follow-up for owned contributions; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` for live GitHub enrichment |
| `/lavish-url <url> [--mobile]` | Capture an http or https page without URL credentials, public or local, into an annotatable Lavish review snapshot with `[Fix Layout]`, `[Update Text]`, and `[Mobile Bug]` chips and project-aware element labels; add `--mobile` for mobile emulation. Feedback returns as a notification and is filed to the backlog of the registered project that owns the site, or surfaced for a decision when the site's project is not certain |
| `/updatefirstmate` | Guardedly update the running firstmate and its secondmates - fast-forward, or reconcile a redundant post-squash-merge divergence - then persist and restart every live mate successfully left on the target commit - including already-current homes - with an honest re-read nudge only when restart cannot be proven |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered second mates, and report what is safe to reset |

Bearings invocation examples:

- `/bearings` returns the fresh four-section digest in chat only.
- Owned-contribution follow-up comes from the cached coverage projection; `include PRs` remains the opt-in for repository-wide live PR enrichment.
- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/bearings file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.
- `/bearings file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the crew, supervision, worktrees, secondmates, and project modes.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/dsh-native-architecture.md](docs/dsh-native-architecture.md) - maintainer architecture for the DSH-native supervisor path and the dsh plugin.
- [docs/extension-bindings.md](docs/extension-bindings.md) - maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) - current setup, routing, transfer, recovery, and safety behavior for whole-home remote second mates.
- [docs/calm.md](docs/calm.md) - current `/calm` behavior and its supported presentation limits.
- [docs/voice-relay.md](docs/voice-relay.md) - the optional spoken interface: setup on both machines, measured round-trip cost, what a spoken answer may read, and what this build does not do yet.
- [docs/fleet-ledger.md](docs/fleet-ledger.md) - the opt-in activity ledger outside tools can read to follow a home's tasks, and its record contract.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/usage-warner.md](docs/usage-warner.md) - configure the opt-in local threshold warner for usage windows.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, test coverage, safety boundaries, and limits for the Herdr backend.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [docs/gerrit-forge-integration.md](docs/gerrit-forge-integration.md) - maintainer architecture for the forge axis: why change-shaped review is not a forge variant, the mode/forge/shape composition test, and where responsibility for forge mechanics sits.
- [docs/external-review-forge.md](docs/external-review-forge.md) - maintainer architecture for `forge=external`, where a review tool uploads its own snapshot: the no-push invariant and its three layers, the personal backup remote, and the accepted residual.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) - maintainer verification for watching and merging GitLab merge requests on arbitrary instances.
- [docs/gerrit-change-watch.md](docs/gerrit-change-watch.md) - maintainer verification for watching Gerrit changes read-only, and why the merge path refuses one.
- [docs/forgejo-tea-integration.md](docs/forgejo-tea-integration.md) - maintainer verification for watching and merging Forgejo/Gitea pull requests via `tea`.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's current "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered watcher protocols for the kept worker harnesses and the unknown-harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the supervisor contract, role boundary, and routing index for conditional procedures.
- [`VISION.md`](VISION.md) - the product vision and the principles a change is judged against.

## Contributing

Changes to firstmate's shared tracked material - `AGENTS.md`, `README.md`, `VISION.md`, `.tasks.toml`, `bin/`, `.agents/skills/`, and `skills/` - ship through this repository's registered delivery path on a feature branch, with the same merge authority as any other project.
Load the agent-only `firstmate-coding-guidelines` skill before editing that material; it owns the knowledge-placement rules that keep `AGENTS.md` from regrowing.
Everything personal to one captain's fleet - `.env`, `data/`, `state/`, `config/`, `projects/`, and `.no-mistakes/` - is gitignored; never commit it.
This repository runs no CI, so a pull request here produces no commit status and the configured merge authority reviews it by hand.

Check and test a change locally before pushing:

```sh
bin/fm-lint.sh   # the shell and workflow lint definition, with pinned versions
bin/fm-test-run.sh tests/<subject>.test.sh   # one subject, timed
bin/fm-test-run.sh --changed   # changed-file path with bounded concurrency
```

`bin/fm-test-run.sh` owns suite selection, lanes, concurrency, and the coverage guard; its `--help` lists the families and flags.
Run `bin/fm-doc-audience-check.sh` after documentation changes.
Put each full sentence on its own line in Markdown, and keep `README.md` a concise overview with pointers into `docs/`.

## License

MIT - see [LICENSE](LICENSE).

## Star History

<a href="https://www.star-history.com/?repos=kunchenguid%2Ffirstmate&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&theme=light&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=kunchenguid/firstmate&type=date&legend=top-left" />
 </picture>
</a>
