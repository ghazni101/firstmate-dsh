#!/usr/bin/env bash
# Spawn a direct report: a crewmate in a treehouse or Orca worktree, or a
# secondmate in its isolated firstmate home.
# Usage: fm-spawn.sh <task-id> <project-dir> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off> [--branch-prefix <prefix>] [--base-branch <branch>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--dispatch-override <reason>] [--hermes-profile <name>] [--account <entry>] [--backend <name>] [--herdr-resume-lock-wait]
#        fm-spawn.sh <task-id> <project-dir> --scout [--base-branch <branch>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--dispatch-override <reason>] [--hermes-profile <name>] [--account <entry>] [--backend <name>] [--herdr-resume-lock-wait]
#        fm-spawn.sh <task-id> [<firstmate-home>] [--harness <name>|harness|launch-command] [--model <name>] [--effort <level>] [--backend <name>] --secondmate
#   --mode and --yolo are this task's delivery contract, REQUIRED for every ship
#   spawn and refused on --scout and --secondmate spawns. Firstmate resolves both
#   per task at intake (AGENTS.md section 7); data/projects.md holds the captain's
#   standing posture as context, not as this task's answer, so a spawn never looks
#   the mode up. A ship spawn additionally reads the brief's recorded
#   "Delivery contract: mode=<mode>" line and REFUSES a mismatch, so the worker's
#   instructions and the recorded task delivery cannot drift apart; a brief
#   scaffolded before that line existed warns once and launches on the flag.
#   The project's forge IS read from data/projects.md, because it is the
#   captain's confirmed project fact rather than a per-task choice: a spawn
#   refuses a brief whose `forge=` disagrees with the registered binding in
#   either direction, and refuses --yolo on for a forge=gerrit or
#   forge=external project, where yolo is inactive (bin/fm-project-mode.sh's
#   header carries that decision). The project's pr=manual binding is read the
#   same way and agrees with the brief's " pr=manual" contract suffix in either
#   direction; only a no-mistakes ship takes it, so a no-mistakes-prod-only
#   project's direct-PR task expects none. A forge=external ship also refuses a missing
#   review tool adapter and an unusable personal backup remote, installs the
#   per-task pre-push guard (bin/fm-git-push-guard.sh) even when the home keeps
#   AI trailers, and records forge=external, backup_remote=, and backup_prefix=
#   in the task metadata for bin/fm-dod-lib.sh's ready-report gate. A
#   registry entry the parser refuses stops the spawn rather than launching on a
#   guessed posture. A
#   ship or scout spawn also refuses leftover `{TASK}` / `{FIRSTMATE_SPEC}`
#   placeholders, an empty Task, an incomplete pair of Task subsections, or a
#   `## Captain's intent` line opening with a Captain label or address.
#   When config/herdr-lifecycle-spawn-guard exists, a brief naming
#   bin/fm-herdr-lab.sh or a listed Herdr session/server lifecycle command must
#   carry the Herdr isolation contract emitted by bin/fm-brief.sh --herdr-lab;
#   the refusal names the first such match.
#   Every ship or scout spawn renders `launch-brief.md`; for a no-mistakes ship
#   it also carries the current `--intent` contract and the extracted captain
#   intent. A legacy mixed Task is accepted there only under bin/fm-dod-lib.sh's
#   provenance-marking rules; unmarked legacy Tasks stop for migration rather
#   than becoming intent. That library owns the parsing and intent rules. When
#   the explicit mode carries less rigor than the project's standing posture, a
#   loud one-line deviation notice is printed and the spawn continues.
#   no-mistakes-prod-only is a registry policy rather than a task mode and is
#   refused as a flag value.
#   --branch-prefix is the optional prefix selected at intake for this ship's
#   immutable branch, defaulting to "fm/". It must agree with the branch recorded
#   in the brief, and is refused on scouts, secondmates, and relaunches. When the
#   selected branch does not match the project's registered prefix, the spawn
#   prints a one-line deviation notice and continues, because the registered
#   prefix is the captain's standing preference and the brief agreement above
#   already guarantees the worker's instructions match the branch.
#   --base-branch is the optional branch selected at intake for a ship or scout
#   to start from and target instead of origin's default branch. A fresh launch
#   resets its pooled copy to origin/<branch>, refusing when the project has no
#   origin or origin lacks that branch, or when the project's registered forge
#   cannot carry it. It must agree with every Setup "Base branch:" line in the
#   brief (bin/fm-brief.sh --base-branch writes one; other such lines are prose),
#   and a brief with such a line refuses a spawn without the flag. The spawn records it as
#   base_branch= in state/<id>.meta, which a relaunch reuses and later review and
#   cleanup read; it is refused on secondmates and relaunches, and without it
#   nothing changes.
#   Ship/scout launches always put fm-dod-lib.sh's current worker role scope
#   first in the private launch-brief overlay, including the exact task-owned
#   steering inbox. This never rewrites a project's instruction files or a
#   secondmate's charter.
#        fm-spawn.sh <task-id> --relaunch [--harness <name>] [--model <name>] [--effort <level>] [--account <entry>]
#   --relaunch launches a replacement agent for an EXISTING task into that
#   task's own recorded worktree, reusing its recorded endpoint when that
#   endpoint still exists, instead of creating either from scratch. It is
#   the launch half of the control plane (bin/fm-control.sh relaunch), which
#   owns the checkpoint, the progress note, stopping the previous agent, and the
#   transaction; call fm-control rather than this flag directly unless you are
#   deliberately re-launching an already-stopped task. Every identity axis -
#   backend, kind, project or home, worktree, endpoint - comes from the task's
#   validated state/<id>.meta, so --backend, --scout, --secondmate, a project
#   positional, and batch pairs are all refused alongside it; only harness,
#   model, effort, and a declared Claude account may change, which is what
#   makes a harness switch one ordinary relaunch. It refuses unless the
#   recorded endpoint is positively agent-free on a backend with both a
#   recovery-grade agent-state classifier and replacement-agent support
#   (tmux or herdr), and clears the previous harness's per-task wiring
#   before arming the new incarnation. T3 Code has the classifier but refuses
#   relaunch because a thread keeps its conversation across turns and provider
#   changes. Two verdicts are agent-free: a `dead`
#   endpoint is ADOPTED as-is, while an endpoint PROVEN gone is RE-CREATED in the recorded
#   worktree and the republished record rebinds the task to it. That proof is
#   its own step, because a backend's `missing` also covers an endpoint that is
#   merely unreachable from here - and it is only available on HERDR, which must
#   still read the recorded pane as gone once that session's server is running
#   again. A tmux `missing` always refuses: a task record carries no socket
#   identity for its endpoint, so no read here can tell a destroyed window from
#   one on a tmux server this process cannot address. An endpoint that turns out
#   to have survived refuses too. The worktree is reused untouched either way; a
#   rebind is a recovery, never a teardown. Only a crewmate or scout rebinds: a
#   secondmate whose endpoint is gone is respawned by its own owner
#   (`--secondmate`, driven by the session-start liveness sweep).
#   Every fresh ship/scout launch and replacement explicitly enters the recorded
#   worktree immediately before trust setup and brief delivery, and a pre-launch
#   cwd check refuses any endpoint that still reports another copy; a Herdr shell
#   that has drifted out of the recorded worktree is told once to return, and
#   only a shell that will not go refuses.
#   --harness <name> is the explicit per-spawn harness/profile adapter. The old
#   positional harness arg still works for back-compat.
#   --hermes-profile <name> selects Hermes's native -p profile for a tmux
#   crewmate/scout; omission keeps Hermes's default selection. Names follow the
#   native lowercase 1-64 character grammar. The resolved home is pinned for
#   launch, and hermes_profile= is replayed on relaunch. Non-default --model is
#   refused; effort is recorded but the profile owns model and reasoning.
#   Native pre_llm_call/on_session_end hooks live in a private managed-scope
#   overlay; an existing managed scope is refused. The profile's own gateway
#   may run only while idle; a mid-turn, ambiguous or unreadable gateway is
#   refused without changing it. No profile config or SOUL is edited.
#   --model <name> and --effort <low|medium|high|xhigh|max|ultra> are concrete profile
#   axes chosen by firstmate at intake. They are only threaded into harnesses whose
#   installed CLIs were verified to support that axis; unsupported axes are omitted
#   from that harness's launch rather than guessed. Ultra is the explicit
#   exception: bin/fm-harness.sh validate-native-effort owns its model scope;
#   supported Pi launches receive --codex-effort ultra, never --thinking ultra.
#   OpenCode 2 has no interactive model or effort flag, so its selected model
#   and effort are written as the build agent's model and variant inside the
#   OPENCODE_CONFIG_CONTENT JSON its launch already carries (config schema
#   re-verified on opencode 2.0.21); without a model the effort axis is recorded
#   but omitted.
#   --backend <name> is the explicit runtime session-provider backend for this
#   exact task only (docs/configuration.md "Runtime backend" owns when that flag
#   is authorized). Without it, the script resolves FM_BACKEND, then
#   config/backend, then runtime auto-detection from the runtime firstmate's
#   environment: $TMUX, HERDR_ENV=1, TERM_PROGRAM=rex with REX_BLOCK, cmux
#   runtime signals, or the Herdr app signals (via
#   bin/fm-backend.sh's fm_backend_detect, with cmux fallback details in
#   docs/cmux-backend.md and the app signals in docs/hc-backend.md),
#   then tmux.
#   Spawn-capable backends are the reference tmux adapter, verified herdr
#   adapter, and experimental zellij, orca, cmux, paseo, rex, t3code, tern,
#   and hc adapters. Orca owns both the task worktree and terminal, so ship/scout Orca
#   spawns do not run treehouse get; cmux, paseo, rex, tern, and hc are session
#   providers only, exactly like herdr/zellij, so they do. Auto-detected herdr
#   and rex stay silent like tmux; auto-detected cmux and Herdr-app-driven hc
#   print a loud stderr notice; zellij, orca, paseo, t3code, and tern are never
#   auto-detected (the paseo and tern markers, like bare hc markers, leak into
#   every descendant process). An app-detected hc also records its signal in
#   meta's backend_detect= line.
#   Herdr leases its slot durably (treehouse get --lease) and moves the pane's
#   top-level shell into it, because a restart restores that shell's cwd.
#   codex-app is not a known backend yet; docs/codex-app-backend.md owns that
#   blocked backend contract. Default tmux spawns do not write backend= to meta;
#   absent backend= means tmux. Orca, cmux, paseo, tern, and hc do not support
#   --secondmate spawns.
#   A rex crewmate or scout opens one tab in the Rex session the launching
#   firstmate runs in when it runs directly inside Rex, otherwise in its home's
#   own Rex session; a --secondmate launch opens its tab in that secondmate
#   home's own Rex session (bin/backends/rex.sh owns placement).
#   t3code is experimental (docs/t3code-backend.md): T3 Code
#   owns the agent session, so the spawn leases a treehouse slot durably,
#   launches a T3 thread on it, and sends the launch brief over T3's /mcp
#   endpoint instead of typing into a pane; only claude and codex harnesses.
#   The exports a pane would receive before launch travel as per-directory
#   harness config instead (spawn_t3code_env_install).
#   A backend spawn refusal (missing dependency, version gate, unauthenticated
#   socket, or unsupported secondmate mode) is terminal for that selected backend;
#   callers must surface it instead of silently retrying another backend.
#   A herdr crewmate or scout is placed in the exact workspace of the firstmate
#   or secondmate process launching it, resolved from that process's own herdr
#   pane rather than from a workspace label (herdr enforces no label uniqueness,
#   so a label cannot tell two same-labeled home workspaces apart). A claimed parent
#   identity that is unreadable, contradictory, stale, or from another herdr
#   session stops the spawn before any worker endpoint exists. A launcher
#   outside herdr has no workspace to inherit and uses this home's own labeled
#   workspace, which must then match exactly one. --secondmate is the deliberate
#   exception: it stands up that secondmate home's own workspace.
#   Herdr additionally uses a presentation-only layout by default when the
#   selected client and running server meet the Herdr 0.8.0 floor. The local
#   config/herdr-presentation-spaces file can say off to disable it or on to
#   opt in below that floor; an empty file remains the historical opt-in form.
#   A clean fresh task first writes state/<id>.herdr-presentation atomically,
#   then creates a disposable
#   workspace containing only the ordinary task pane. A successful clean create
#   upgrades its attempt journal with exact home, session, workspace, tab, pane,
#   parent, and label bindings. On a same-identity restart, that complete binding
#   plus authoritative metadata may replace one exact agent-free husk in place.
#   The journal, visible token, and labels alone are never endpoint or ownership
#   authority, and every ambiguous recovery stays on the flat fallback after
#   duplicate-agent risk is independently absent. Treehouse allocation and task
#   metadata are unchanged.
#   A clean projected create and an exact resume both hold the one
#   session-scoped presentation-order lock (keyed by named session plus
#   canonical socket, outside any home's state/) through launch handoff.
#   On contention a create makes one bounded attempt and falls back to the
#   ordinary flat layout before any projection mutation. A resume refuses by
#   default on the same contention (it does not degrade flat; a concurrent
#   resume is a hard failure). Pass --herdr-resume-lock-wait to opt that
#   resume into waiting for the lock instead, so two concurrent recoveries
#   can serialize and each still replace its own exact husk. The flag acts
#   only on that fresh ship or scout spawn path: --relaunch reuses the
#   recorded endpoint without taking this lock, so the flag has no effect
#   there, and a secondmate spawn never projects. Unbounded
#   blocking on a third-party session lock is never the default. The exact
#   response-derived new workspace is inserted immediately after its owning
#   parent's contiguous child block. Ordering never
#   authorizes lifecycle cleanup, and any unavailable, ambiguous, or failed
#   move warns while the spawn continues.
#   Every projected create, prune, and move captures and verifies the named
#   session's exact active workspace and tab. A detected focus change restores
#   only that exact tab id; an ambiguous pre-operation snapshot refuses the
#   focus-sensitive presentation mutation.
#   Every single-task invocation holds one task-id-scoped lock across backend
#   creation through metadata publication, so concurrent same-id spawns serialize
#   even when they select different backends. A fresh spawn first takes the
#   per-home task-set lock and refuses rather than waits when another operation
#   owns it. The refusal names another spawn or forced teardown when the recorded
#   holder role is known, otherwise another operation. --relaunch is exempt
#   because the existing task's control lock covers it.
#   A fresh Treehouse-backed spawn also takes the project-identity lock in the local
#   root Firstmate home's state directory before slot allocation and holds it through
#   task metadata publication. Teardown holds that same lock while proving and
#   returning a slot, so allocation cannot reuse a slot before its owner record
#   is published. Under that same lock it writes the slot's owner claim, which is
#   what lets teardown leave a slot reassigned since untouched; bin/fm-wake-lib.sh
#   owns the claim and bin/fm-teardown.sh owns what it protects. A slot that
#   cannot be claimed refuses the spawn rather than launching a worker whose slot
#   could later be released out from under its successor. A spawn that aborts
#   while it still holds the allocation lock drops its own claim; an abort after
#   metadata publication has released that lock leaves the claim in place, and
#   the next spawn's claim replaces it. A fresh polytoken spawn that fails and
#   leaves no task record restores the pool as it found it: it retakes that lock
#   once to drop its claim after metadata publication too, and before its launch
#   is delivered it closes the endpoint whose `treehouse get` shell leases the
#   slot and removes the wiring, task temp root, and staged launch file it wrote.
#   The local root is whatever bin/fm-wake-lib.sh's
#   fm_firstmate_root_home resolves, so a home seeded from another machine anchors
#   that lock itself rather than failing to resolve one;
#   contention refuses rather than waits.
#   Project capacity: when this machine declares how many workers a project
#   admits at once (config/project-capacity; bin/fm-project-capacity-lib.sh owns
#   the declaration, what holds a place, and the race argument), a fresh ship or
#   scout spawn counts the places already held while holding that same
#   project-identity lock - taken on every backend whenever the declaration caps
#   any project, Orca included, because an uncapped clone's worker still holds a
#   place for a capped clone of the same origin - and holds it through metadata
#   publication. A spawn that finds
#   every place held prints one `deferred:` line and exits 75 before any brief
#   render, endpoint, worktree, record, or backlog move exists, so the task stays
#   exactly as queued as it was; an unreadable declaration refuses with exit 1.
#   Lane capacity: only when this home's config/lane-capacity declares
#   admit-spawns (bin/fm-capacity.sh --spawn-gate-enabled answers; that script
#   owns the declaration and the verdict), a fresh ship or
#   scout spawn runs `fm-capacity.sh --spawn-gate` while holding the machine-wide
#   lane-admission lock in the local root home's state/ (waiting up to 120 s for
#   it) and keeps holding it through metadata publication; a verdict that does
#   not admit prints `deferred:` and exits 75 with the task exactly as queued,
#   and an unreadable declaration refuses with exit 1.
#   A batch reports such a pair as `batch: DEFERRED` and exits 75 when nothing
#   else failed. A relaunch and a --secondmate spawn are never counted against
#   either capacity.
#   With no harness arg, a crewmate/scout spawn resolves the CREW harness only when
#   config/crew-dispatch.json is absent. When that file exists, crewmate/scout
#   spawns require an explicit harness so firstmate cannot silently skip dispatch
#   profile consultation. A --secondmate spawn is exempt and resolves the SECONDMATE
#   harness (config/secondmate-harness -> config/crew-harness -> own), so the
#   secondmate-vs-crewmate split is DURABLE across every respawn (recovery,
#   /updatefirstmate, restart). A bare adapter name (claude|codex|opencode|pi|pi-signed|grok|kimi|cursor|gemini|muse|rovo|omp|agy|devin|commandcode|cortex|kiro)
#   overrides it for this spawn (either kind). A non-flag string containing
#   whitespace is treated as a RAW launch command - the escape hatch for verifying
#   new adapters. For pi and pi-signed, fm-spawn resolves the selected executable
#   name from PATH once, probes that concrete path with --help, and launches the
#   same path. It adds --tui-mode regular only when that help advertises the flag;
#   a failed or inconclusive probe omits it so older Pi versions remain launchable.
#   A --secondmate launch of a Firstmate-seeded home (the existing
#   .fm-secondmate-home marker validate_firstmate_home_for_spawn already requires)
#   also adds --approve when that help advertises it, so the first unattended
#   launch does not stall on Pi's "Trust project folder?" dialog for that home
#   path; --approve is session-scoped to the launch cwd and does not rewrite the
#   operator's trust.json. Ordinary Pi worker launches never receive --approve.
#   A missing selected executable refuses before endpoint creation, and pi-signed
#   never falls back to pi.
#   Devin is worker-only: --permission-mode dangerous and
#   --respect-workspace-trust false allow unattended tools in a fresh worktree.
#   --config points at a private per-task snapshot of the user config with
#   lifecycle hooks appended; no global or project config is edited.
#   config/claude-permission-mode is not mapped: Devin auto approves read-only
#   tools, unlike Claude auto. Effort is part of Devin model ids, so the
#   independent --effort axis is recorded but omitted from argv.
#   Command Code (`commandcode`) is worker-only and tmux/herdr-only (see the
#   backend refusal below): --yolo and --trust allow
#   unattended tools in a fresh worktree, and --mod loads the tracked
#   bin/fm-commandcode-mod.ts busy-state writer for that one process with the
#   task's generation in --mod-option values; no global or project config is
#   edited. Its --effort is passed only where the model's accepted set is
#   verified, because an unknown value exits the launch.
#   Cortex Code (cortex) is worker-only and tmux/herdr-only too (see the
#   backend refusal below): --dangerously-allow-all-tool-calls
#   (the --bypass alias) approves tool calls and also skips its project-trust
#   dialog, so a fresh worktree needs no pre-registration and no entry is
#   written to ~/.snowflake/cortex/cortex.json. --plugin-dir points at a
#   private per-task plugin (bin/fm-cortex-plugin.sh) carrying the busy-state
#   hooks, because Cortex's own settings file takes no hooks through --config.
#   The launch does not pass --sql-read-only: SQL write policy stays the
#   captain's own Cortex configuration. config/claude-permission-mode is not
#   mapped. --effort maps low|medium|high|max; xhigh is omitted (cortex has
#   no such level). A bad --model is not refused at launch: Cortex starts,
#   then answers the first prompt with the account's available model ids.
#   For omp (Oh My Pi), fm-spawn resolves the `omp` executable from PATH once and
#   refuses when it is absent. Every omp launch clears the foreign harness
#   markers (omp publishes none of its own), sets the Firstmate-owned
#   FM_OMP_HARNESS=omp detection marker, suppresses the first-run provider
#   wizard with OMP_SKIP_SETUP=1, forces --auto-approve, pins the working
#   directory with --cwd, and passes the tracked worker posture overlay
#   .omp/fm-worker-overlay.yml through --config. That overlay pins composer
#   shape, plan mode off, prewalk off, and the non-interactive usage-reserve
#   policy for the one session only (--auto-approve alone owns approval); the
#   captain's own ~/.omp/agent/config.yml (model roles, providers, theme) is
#   never written.
#   A model written as <provider>/<id> is validated against `omp models --json`
#   only when that provider appears in the listing; a provider absent from the
#   listing (an extension-registered provider such as claude-bridge, which omp
#   never lists) passes through unvalidated with a stderr notice, and a bare
#   fuzzy pattern is left to omp's own matcher. A crewmate or scout loads its
#   per-task busy-state extension with -e from state/ (outside the worktree, so
#   auto-discovery cannot load it a second time); a secondmate names only that
#   state/<id>.omp-ext.ts busy extension with -e and relies on omp
#   auto-discovering the home's tracked .omp/extensions/ for the rest
#   (verified, omp 18.1.11: a file named both ways loads twice, and discovery is
#   cwd-only with no trust dialog).
#   config/secondmate-harness may also carry an optional model and effort as extra
#   whitespace-separated tokens ("<harness> [<model>] [<effort>]"). For a
#   --secondmate spawn, those tokens apply only when this spawn also resolves its
#   harness from config/secondmate-harness. An explicit per-spawn --harness,
#   positional harness arg, or raw launch command starts with clean model/effort
#   defaults unless the caller also passes explicit --model/--effort flags. When
#   the file governs the spawn, its model/effort tokens are re-resolved on every
#   respawn exactly like the harness axis, and explicit --model/--effort flags
#   still win over the file's tokens.
#   A --secondmate spawn also propagates the primary's declared inherited local
#   material, so the secondmate's OWN crewmates inherit primary config and the
#   secondmate receives the primary's read-only shared captain-preference file
#   (fm-config-inherit-lib.sh). A successful launch clears pending inherited
#   config reread generations because the new agent reads the converged files.
#   --scout records kind=scout in the task's meta (report deliverable, scratch worktree;
#   see AGENTS.md task lifecycle); --secondmate records kind=secondmate and launches in a
#   provisioned firstmate home; the default is kind=ship.
#   Before a secondmate launch, the home is fast-forwarded to the primary's
#   default-branch commit when safe: directly for a local home, or through the
#   configured host for a remote home. Skipped syncs warn and launch unchanged.
#   Ship/scout spawns refuse to launch unless the resolved task path is a real
#   git worktree root distinct from both the spawning project and its repository's
#   primary checkout, including when the spawning project is a linked worktree.
#   On the backends that discover that path by reading the task pane's own cwd,
#   the same isolation test screens every read: a pane still showing the project
#   or the repository primary while `treehouse get` prepares the slot is waited
#   out as a transient rather than adopted and then refused, so a home that is
#   itself a linked worktree of the project repository still launches. A pane
#   that never reaches an isolated worktree refuses at the end of that wait,
#   naming the last path seen and why it was rejected.
#   That placement is proven only at launch. Every ship or scout therefore
#   receives `FM_TASK_ID=<task-id>` before launch, on the same backend-specific
#   environment channel as GOTMPDIR, and bin/fm-test-run.sh refuses to execute the
#   behavior suite from the repository primary checkout while that marker is
#   set (its header owns the refusal). A secondmate runs in its own home and is
#   not marked.
#   Only after this isolation check, every fresh ship or scout requires a clean
#   task worktree. When an origin configuration is detected, spawn fetches it,
#   resolves the current remote default branch (or uses --base-branch, described
#   above), and resets to its tip. A home that creates the default-off
#   config/spawn-base-primary-checkout flag (docs/configuration.md) instead
#   resets a local-only ship or a scout without --base-branch to that same
#   branch in the primary checkout when it strictly contains origin's tip: a
#   local-only project lands work there through bin/fm-merge-local.sh and never
#   pushes, so origin stays frozen at the last push. A publishing mode
#   (bin/fm-dod-lib.sh fm_mode_publishes) and a named base branch keep origin's
#   tip, because that work is delivered against origin. Two branches that have
#   diverged also keep origin's tip, with a note counting both sides. The
#   primary's commit is read from the local object store, so nothing more is
#   fetched, and every base this picks contains origin's tip, so the reset
#   discards nothing the origin-only rule would have kept. When no origin
#   configuration is detected, spawn skips that remote freshness check and
#   launches from the clean worktree's current HEAD. Relaunch reuses the
#   recorded worktree without fetching or resetting its base. An unreachable
#   detected origin, unresolved default branch, or non-clean worktree refuses
#   a fresh spawn rather than risking a PR based on stale history or
#   discarding local work.
#   A slot whose only deviation is a stale submodule gitlink is refused by that
#   same clean check, but is reported as a stale checkout naming each submodule
#   and both pins; nothing is converged or removed, and no remedy is suggested.
#   That report is only reached when each submodule's checked-out commit is
#   already contained in one of its remotes, so a submodule carrying an unpushed
#   commit keeps the conservative uncommitted-work refusal instead. That
#   containment test reads local refs only and never fetches, so this gate stays
#   usable offline; a stale remote-tracking ref can therefore make an unpushed
#   commit look contained, which is exactly why no remedy command is printed.
# Batch dispatch: pass one or more `id=repo` pairs instead of a single <id> <project>, e.g.
#     fm-spawn.sh fix-a-k3=projects/foo add-b-q7=projects/bar [--scout]
#   Each pair re-execs this script in single-task mode, so the single path stays the only
#   source of truth; shared --scout/--harness/--model/--effort/--backend/--mode/--yolo
#   applies to every pair. A ship batch therefore carries one delivery contract, and each
#   pair still checks it against its own brief; a batch spanning modes is two invocations.
#   If config/crew-dispatch.json exists, shared --harness is required for crewmate
#   and scout batches. The loop lives here, in bash, so callers never hand-write a
#   multi-task shell loop (the tool shell is zsh, which does not word-split unquoted
#   $vars and silently breaks ad-hoc `for ... in $pairs` loops).
# Launch delivery:
#   Every pane-backed launch receives its complete command from a never-reused
#   0600 file in a 0700 home-scoped task namespace under /tmp, while the pane
#   receives only a short source line. T3 Code sends a thread message over
#   /mcp instead and carries the encoded brief directly.
#   This keeps commands beyond the terminal's roughly 1,024-byte input boundary
#   intact, prevents a delayed source line from being rebound by a relaunch, and
#   prevents equal task ids in different Firstmate homes from sharing a file.
#   Spawn refuses an unsafe pre-existing task temp root or launch namespace, and
#   task teardown removes only the current home's launch namespace.
# Launch environment (config/launch-env-allowlist):
#   Absent means unchanged ambient inheritance. A present readable regular file
#   opts every supported command-line launch (ship, scout, secondmate, raw
#   command, and relaunch) into /usr/bin/env -i followed by /bin/sh -c of the
#   existing launch command. T3 Code refuses the file because T3 owns the
#   provider process environment.
#   Each line is one POSIX environment name, never a value or shell expression;
#   blank lines and lines beginning with # are ignored. Invalid input refuses
#   before launch, as do path inspection errors such as inaccessible config
#   directories. An empty file retains only the operational floor below.
#   Names are read once per spawn; unless the Orca source below applies, values
#   are expanded in the destination pane, not copied from the invoking process
#   or written into the launch text.
#   Unset names stay unset and empty values stay empty.
#   The fixed operational floor is HOME PATH USER LOGNAME SHELL TERM COLORTERM
#   LANG LC_ALL LC_CTYPE TMPDIR TMP TEMP GOTMPDIR, plus backend identity/routing:
#   TMUX TMUX_PANE HERDR_ENV HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID
#   CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_TAB_ID CMUX_PANEL_ID CMUX_SOCKET_PATH
#   ZELLIJ ZELLIJ_SESSION_NAME ZELLIJ_PANE_ID FM_ZELLIJ_SESSION TERM_PROGRAM
#   REX_SESSION REX_BLOCK REX_SERVER REX_BIN_DIR TERN_IDENTITY TERN_PANE
#   TERN_PANE_SOCKET TERN_WINDOW_KEY TERN_WINDOW_SOCKET HC_SESSION
#   HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SCOPE, plus the task
#   marker FM_TASK_ID that ship and scout panes receive above, plus the
#   compact-adviser kill switch COMPACT_ADVISER_DISABLE, which the floor also
#   pins to 1 with a literal assignment so it survives the cleared environment
#   even on a host that never had it set.
#   An enabled task trace also retains TRACEPARENT. Explicit Firstmate launch
#   assignments still apply inside the filtered environment, including the
#   FM_TASK_INBOX export every launch carries (the absolute state/<id>.inbox
#   path the steering doorbell names). Raw commands must
#   be POSIX sh compatible under this opt-in; the absent-file path is unchanged.
#   This is an exec environment boundary, not a sandbox for the pane's startup
#   shell, credential files, same-user processes, or later shell initialization.
#   See docs/configuration.md for provider/Git setup and supported limits.
#   On backend=orca the destination is an Orca terminal whose environment comes
#   from the Orca app and shell startup, not this home, so a nonempty allowlist
#   without the source below prints a stderr warning and launches unchanged.
# Orca environment source (config/launch-env-tmux-session):
#   Optional local file containing one exact tmux session name (letters, digits,
#   underscores or hyphens). Only fresh Orca spawns use it; other backends are
#   unchanged. It requires config/launch-env-allowlist and refuses without one,
#   so tmux's automatic update-environment names (SSH_AUTH_SOCK) never ride
#   along. Before allocation, each allowlisted name is read from that session's
#   local environment (tmux -u show-environment -t =<session> <name>), never
#   tmux's server-global or the invoking process's environment; -u keeps values
#   intact under absent or C locales. A missing name, unreadable session, or
#   malformed selector refuses before the Orca worktree or terminal exists,
#   while an explicit -NAME record deliberately leaves that name unset. Launch
#   keeps env -i and the operational floor, replaces destination expansion of
#   allowlisted names with the snapshotted values, and sets
#   GIT_CONFIG_NOSYSTEM=1 so a system credential helper cannot answer for the
#   worker. Values are shell-quoted only in the owner-only staged launch file,
#   never terminal input, and the pane deletes that file as sourcing starts,
#   before the worker executes; a deletion failure refuses the worker launch and
#   keeps the interactive shell, even with errexit set (a Bash 3.2 or dash
#   errexit pane still exits if spawn reclaims the file in the instant between
#   the pane's existence check and its source). Spawn waits up to 30
#   seconds for that deletion; if the pane never ran the command or could not
#   delete the file, or HUP, INT or TERM interrupts spawn first, spawn removes
#   it unless the pane already did, refuses the worker launch, and leaves the
#   Orca terminal open.
#   The selector is not inherited into secondmate homes. This is not a
#   filesystem sandbox; project and harness sandbox
#   settings still own access to personal credential files.
# Codex permission mode: docs/configuration.md owns config/codex-permission-mode.
#
# Claude permission mode (config/claude-permission-mode):
#   One token selecting the permission flag every claude launch (ship, scout,
#   secondmate, and relaunch) carries. Absent or `bypass` selects
#   `--dangerously-skip-permissions`; `auto` selects `--permission-mode auto`,
#   the model-reviewed remedy for managed machines. Every other part of the claude launch
#   is unchanged. The token is the file's whitespace-trimmed content; any other
#   value, or an unreadable file, refuses the spawn before any endpoint,
#   worktree, or record exists and names the accepted values. The file is read
#   on every spawn and relaunch, so a change reaches the next launch without a
#   restart, and it is inherited into secondmate homes (bin/fm-config-inherit-lib.sh).
# Codex approval mode (config/codex-approval-mode):
#   One whitespace-trimmed token: absent or `bypass` selects
#   --dangerously-bypass-approvals-and-sandbox; `approve-for-me` selects
#   --approve-for-me, with model-reviewed approvals in workspace-write.
#   Any other value or unreadable file refuses before mutation, like the Claude
#   file. Both files apply to ships, scouts, secondmates, and relaunches.
#   bin/fm-approval-failover.sh owns captain-approved durable failover after
#   firstmate observes a bypass approval prompt or policy refusal; no polling.
#   T3 Code always uses full-access, so it refuses Claude `auto` and Codex
#   `approve-for-me` or `restricted` before mutation.
# Worker tool exclusions:
#   docs/configuration.md "Worker tool exclusions" owns config/crew-exclude-tools
#   and its operator contract. Resolve it with bin/fm-exclude-tools-lib.sh
#   before provisioning; __PIEXCLUDE__ and __CLAUDEEXCLUDE__ below own the Pi and
#   Claude launch substitutions.
# Worker account pin (config/claude-account, config/pi-account):
#   Opt-in. docs/configuration.md's "Worker account pin" section owns unpinned
#   account selection. A present file pins every supported launch of
#   that runner from this home - ship, scout, local secondmate, raw Claude
#   command, and relaunch - to the declared account root, and the spawn
#   refuses before any endpoint, worktree, or record exists when the file is
#   malformed, the root is unusable, or the runner's own check says it is not
#   signed in. A pinned Claude launch sheds the environment credentials Claude
#   ranks above the root's login; a pinned Pi launch needs --model
#   <provider>/<id> for a declared provider and also carries --provider, and a
#   raw Pi command refuses. The pin is recorded as account= (and Pi's
#   account_provider=) in the task record and on the spawned line. A local
#   secondmate first checks config/secondmate-accounts/<id>/<runner>-account
#   in this launching home, then falls back to its home-wide pin when absent.
#   Pins are never inherited; remote per-mate overrides refuse locally.
#   T3 Code refuses a pin because its provider instance owns the account.
#   bin/fm-worker-account-lib.sh owns parsing, the check, and the shed list.
# Claude account list (config/claude-accounts, --account <entry>):
#   Opt-in and Claude-only. When the list is present, a Claude ship or scout
#   spawn must name one declared entry with --account, chosen at intake, and
#   that entry is checked, launched, and recorded exactly like a pin; a
#   relaunch reuses the recorded entry unless --account moves it. Without the
#   list, --account refuses and nothing else changes. docs/configuration.md
#   "Several Claude accounts" owns the contract.
# Per-secondmate omp profile (config/secondmate-accounts/<id>/omp-profile):
#   Opt-in, and read only for a local secondmate's own omp agent;
#   bin/fm-omp-profile-lib.sh owns the file and its refusals. A pinned launch
#   carries --profile <name> right after the omp executable (__OMPPROFILE__),
#   the catalog check runs under the same profile, and the pin is recorded as
#   omp_profile= in the task record and on the spawned line. Every spawn,
#   relaunch, and recovery re-reads the file; an absent file changes nothing.
#   Launch templates live in launch_template() below; placeholders replaced before launch:
#     __BRIEF__    absolute path to data/<task-id>/brief.md
#     __CLAUDEPERMFLAG__ the claude permission flag selected by config/claude-permission-mode
#     __CLAUDEADDDIRS__ quoted --add-dir flags granting exactly this task's
#                  Firstmate channel directories (claude_add_dirs_flag below;
#                  supplies its own trailing space, empty never used)
#     __CLAUDESETTINGS__ the single claude --settings value: a quoted inline
#                  JSON object for a crewmate or scout, or a quoted path to
#                  state/<task-id>.claude-settings.json for a secondmate
#     __PIBIN__    quoted concrete Pi-family executable path resolved from PATH
#     __PITUIMODE__ optional --tui-mode regular when that executable advertises it
#     __PIAPPROVE__ optional --approve on a seeded Pi/pi-signed secondmate when
#                  that executable advertises the flag (empty otherwise; session
#                  trust for the launch cwd only, never a trust.json rewrite)
#     __PIEXCLUDE__ optional ` --exclude-tools '<comma-joined names>'` from
#                  config/crew-exclude-tools on Pi/pi-signed ship and scout
#                  launches (supplies its own leading space, empty otherwise)
#     __CLAUDEEXCLUDE__ optional `--disallowedTools '<comma-joined names>' ` from
#                  config/crew-exclude-tools on Claude ship and scout launches
#                  (supplies its own trailing space, empty otherwise). Claude
#                  Code drops a disallowed tool's schema from every request, and
#                  a later flag always follows so the variadic option cannot
#                  swallow the launch prompt.
#     __PIRESUME__ optional relaunch-only `--session <reference>` that keeps a
#                  Pi replacement on the session the endpoint's runtime already
#                  reports (relaunch_resume_args below owns it; it supplies its
#                  own leading space, and is empty on every fresh spawn and for
#                  every other harness)
#     __TURNEND__  absolute path to state/<task-id>.turn-ended (for harnesses whose
#                  turn-end signal rides the launch command, e.g. codex -c notify=[...])
#     __PIEXT__    absolute path to state/<task-id>.pi-ext.ts (pi busy-state extension,
#                  written by this script; outside the worktree to avoid pi's trust gate;
#                  a secondmate loads it beside its two primary extensions)
#     __PITURNEND__ absolute path to .pi/extensions/fm-primary-turnend-guard.ts in a pi secondmate home
#     __PIWATCH__   absolute path to .pi/extensions/fm-primary-pi-watch.ts in a pi secondmate home
#     __OMPBIN__   quoted concrete omp executable path resolved from PATH
#     __OMPPROFILE__ optional ` --profile '<name>'` from the per-secondmate omp
#                  profile pin (supplies its own leading space, empty otherwise)
#     __OMPEXT__   absolute path to state/<task-id>.omp-ext.ts (omp busy-state extension,
#                  written by this script; outside the worktree so omp's cwd-only
#                  auto-discovery cannot load it a second time; a secondmate names
#                  this -e and still does not name its auto-discovered primary extensions)
#     __OMPWORKERCFG__ absolute path to the tracked .omp/fm-worker-overlay.yml posture overlay
#     __OPINPUT__   absolute path to the canonical operational-input encoder
#     __BRIEFDOORBELL__ quoted printable doorbell naming the launch-brief record this
#                  script published into the receiving home's operational inbox
#     __WORKTREE__  absolute path to the task worktree
#     __CURSORBIN__ resolved, cursor-verified executable for a cursor launch
#     __GEMINISETTINGS__ firstmate-owned per-task gemini settings file (busy-state hooks)
#     __ROVOBIN__   resolved, rovo-verified executable for a rovo launch
#     __DEVINBIN__ resolved Devin executable
#     __DEVINCONFIG__ private per-task Devin config with lifecycle hooks
#     __COMMANDCODEBIN__ resolved Command Code executable
#     __COMMANDCODEMOD__ --mod and --mod-option arguments of the busy-state mod
#     __CORTEXBIN__ resolved Cortex Code executable
#     __CORTEXPLUGIN__ private per-task Cortex plugin directory with lifecycle hooks
#     __AGYBIN__    resolved, agy-verified executable for an agy launch
#     __OPENCODEBIN__ quoted concrete opencode executable path resolved from PATH -
#                  the same binary the version-gate probe reads, so the recorded
#                  major can never describe a different executable than the pane
#                  runs (empty resolution falls back to a bare `opencode`)
#     __POLYTOKENBIN__ resolved, polytoken-verified executable for a polytoken launch
#     __POLYTOKENCONFIG__ firstmate-owned per-task polytoken config dir (mirrored
#                  operator config with the unattended permission posture enforced)
#     __POLYTOKENSESSIONS__ firstmate-owned per-task sessions root (the daemon
#                  writes the versioned `<root>-v1` sibling beside it)
#     __POLYTOKENFACETS__ the worktree's `.polytoken/facets` dir carrying the
#                  generated firstmate-worker facet (the project facet layer)
#     __KIROBIN__   resolved, kiro-verified executable for a kiro launch
#     __KIROHOME__  firstmate-owned per-task KIRO_HOME dir (hook agent config + trust setting)
# Verified per-harness turn-end hooks are installed automatically where enabled; some live outside the worktree.
# A --secondmate launch arms the same semantic busy contract (bin/fm-busy-lib.sh) in THIS
# parent home for claude, opencode, pi, pi-signed, and omp, so the parent's active-turn
# gate can read a busy verdict. Those hooks do not touch the parent's turn-ended marker:
# a mate's completed turns stay in its own home. Codex stays unknown until a semantic
# source exists. Grok keeps its rendered-tail fallback and is not given a parent
# turn-end hook. Cursor's transcript binding is written for a secondmate the same way
# as for a crewmate. Muse, gemini, devin, cortex, and rovo are refused as secondmates.
# A raw launch command for a claude, pi, pi-signed, or omp secondmate is not armed
# and retires any arm an earlier launch of that mate left, so its verdict is unknown:
# the raw command carries no --settings or -e flag to load the wiring.
# A claude secondmate gets no Stop busy hook; its home's tracked Stop guard is its
# only Stop writer, through the .fm-busy-stop pointer in that home. A home whose
# guard predates that pointer keeps the ordinary Stop idle hook instead.
# Kimi uses one surgically installed Firstmate region in $HOME/.kimi-code/config.toml,
# a firstmate-owned global hook and registry, and a gitignored per-task pointer.
# Kimi also gates a fresh worktree on an interactive folder-trust prompt, whose
# wordings bin/fm-kimi-trust-lib.sh recognizes (2.0.0 and 2.3.0 recorded).
# Its launch-readiness loop reads the visible viewport - so the spawn refuses at
# preflight on a backend with no viewport-bounded capture - recognizes the
# complete dialog, re-selects the already highlighted affirmative option on
# every poll the complete dialog is still there, refuses any ready verdict while
# dialog text is on that pane, and requires two consecutive captures that are
# each ready and dialog-free before the ordinary readiness gates can pass. A
# prompt that announces project MCP servers (Kimi 2.3.0 reads a root .mcp.json
# as well as .kimi-code/mcp.json) or that pages its disclosure receives no key
# and fails readiness with the reason: answering it starts those servers, and
# Kimi's per-folder trust is not a consent decision that covers them. A
# blank viewport read proves nothing either way: it costs the poll and restarts
# that count. A viewport read that fails outright fails readiness at once.
# grok uses a firstmate-owned global hook under ${GROK_HOME:-$HOME/.grok}/hooks
# plus a gitignored .fm-grok-turnend worktree pointer and a state token.
# muse installs no hook at all - its plugin engine is off in the default build - so
# it writes state/<id>.muse-session to bind the pane to muse's own session event
# log; muse, gemini, devin, commandcode, cortex, and kiro are crewmate/scout only and are refused for --secondmate.
# rovo installs no hook either - its eventHooks fire at tool granularity only,
# never turn-end - so it carries no busy-source wiring at all and no turn-end
# hook. A positional brief is dead-on-arrival (rovo loads, never works, and drops
# to an idle shell), so rovo launches BARE and receives an absolute brief pointer
# only after a TUI readiness gate, then a delivery-confirmation gate - the same
# launch-then-send shape as kimi. Its busy state is a screen-scrape fallback like
# grok. rovo is crewmate/scout only and is refused for --secondmate, like muse.
# agy installs no per-task worker hook; its brief rides the launch command, and a
# fresh worktree or secondmate home would park it on a folder-trust dialog, so the
# spawn pre-registers the worktree or secondmate home in agy's own trust store
# through bin/fm-agy-trust.sh (the claude shape, but non-fatal) and then waits for
# a busy turn - answering the dialog first if it renders anyway - before reporting
# success (the rovo/kimi launch-then-confirm shape). Its busy state is a
# screen-scrape fallback like grok and rovo, while an agy SECONDMATE runs the
# tracked project-scope .agents/hooks.json in its own home, whose stop-hook park
# owns that home's supervision (docs/supervision-protocols/agy.md).
# kiro (Kiro CLI, V2 engine) IS claude-shaped: its V2 agent-config hooks
# (userPromptSubmit opens a turn, stop closes it and keeps the turn-ended
# notification touch) are the per-task turn-end wiring. That config must not go
# into the worktree's own .kiro/, so - mirroring gemini - the spawn writes a
# firstmate-owned per-task agent config under state/<id>.kiro-home/agents/ and
# reaches it by relocating KIRO_HOME onto that dir on the launch command; the
# captain's real ~/.kiro is never touched, and auth is unaffected on AL2 where
# it lives in the XDG data dir - where macOS carries auth is unestablished, so
# a macOS worker may hit an auth prompt (docs/verification/kiro.md owns that
# gap). --agent is name-only (a path is rejected), and --trust-all-tools
# would otherwise block on a modal, so the spawn seeds
# chat.disableTrustAllConfirmation into that per-task home's settings. kiro is
# crewmate/scout only and refused for --secondmate. The kiro-hook record is its
# only busy-state source (bin/fm-busy-lib.sh).
# cursor installs no per-task hook either: it writes state/<id>.cursor-session to
# bind the pane to cursor's own conversation transcript (projects root, the exact
# workspace path cursor records in .workspace-trusted, and the conversations that
# already existed for that workspace). It is launched through the verified binary
# resolver because `cursor` is not the CLI name. A cursor SECONDMATE instead runs
# the tracked project-scope .cursor/hooks.json in its own home, whose stop-hook
# park owns that home's supervision (docs/supervision-protocols/cursor.md).
# claude is the one harness whose pre-launch setup can REFUSE the spawn: before
# any per-task state exists, and before its busy hooks are written, every
# claude launch pre-registers its launch directory -
# the task worktree, or the secondmate home for a --secondmate spawn -
# in the launching user's own Claude trust store through bin/fm-claude-trust.sh,
# because Claude's interactive workspace-trust dialog gates a folder it has never
# seen and firstmate cannot answer it. That helper's header owns the structural
# scope test for both shapes and every refusal; a failed registration stops this
# spawn rather than launching a worker that would wedge on the dialog.
# polytoken (the captain-approved TUI-pane-plus-REST hybrid) is the one harness
# whose worker's unattended permission posture cannot ride a launch flag: a
# per-task config dir is generated under state/ mirroring the operator's global
# config with `default_permission_matcher` enforced to `bypass` (a project
# config.yaml fully replaces the global config and no `new` flag reaches the
# permission matcher, verified live). Its brief rides `--prompt` (auto-submitted
# after the TUI attaches), its busy wiring is the worktree `.polytoken/hooks.json`
# binding the verified pre_user_prompt / pre_model_turn (open) and stop (close)
# events to a generated no-argv writer (handlers receive no argv, verified live),
# and its control verbs ride the daemon REST API with the session id, port, and
# credential recorded into task metadata after launch through
# `polytoken sessions --format json`. The license dialog is a BLOCKER by captain
# decision (2026-10-07): `--accept-license-terms` is never passed, and the
# readiness gate fails loudly on any first-start dialog the launch cannot get
# past. bin/fm-polytoken-lib.sh owns every generated artifact and the verified
# facts; .agents/skills/harness-adapters/references/harness/polytoken.md owns the
# knowledge record. polytoken is crewmate/scout only and is refused for
# --secondmate, like devin.
# Unless config/keep-ai-trailers is present, every claude launch carries the
# attribution-off policy in its per-launch --settings JSON, so a spawned worker
# never writes a Co-Authored-By trailer, Claude-Session link, or generated-with
# line into a commit or PR body; launch_template() below owns the reason it
# cannot come from the captain's own settings.
# Cursor and the other non-Claude runtimes have no equivalent per-launch
# settings overlay: Cursor injects a Co-Authored-By trailer at the tooling
# layer after the worker types a clean message, and a per-machine
# ~/.cursor/cli-config.json attribution-off is not durable (it does not travel
# with this repo, defaults back to on when unset, and only feeds the CLI's
# request to the server, so it suppresses the trailer rather than preventing
# it). Unless config/keep-ai-trailers is present, every spawn installs
# state/<id>.git-hooks as an appended GIT_CONFIG core.hooksPath entry for the pane, so git
# commit-msg strips known AI trailers at the commit object for every launched
# runtime, Claude included as defense in depth. bin/fm-git-strip-ai-trailers.sh
# owns the identities, the hook install, and chaining the repository git is
# actually running in so a project husky hook still runs. Author identity is
# not rewritten. A forge=external ship installs that directory even under
# config/keep-ai-trailers, because its pre-push wrapper carries the push guard.
# T3 Code owns its provider command, so it cannot receive Claude's inline
# attribution settings; the Git hook and environment overlay still apply.
# Publishing the record and moving this home's backlog item to In flight are one
# step, not two: bin/fm-backlog-transition-lib.sh owns that invariant, and this
# script performs the transition under the task's own meta lock before it reports
# success. A ship or scout dispatch therefore REFUSES up front, before any
# endpoint, worktree, or record exists, unless the home's backlog has an
# unheld, unblocked Queued or In flight item for the id; a transition that fails
# after publication removes the record it just wrote rather than leaving a
# worker the backlog does not own. A relaunch re-reads the row instead of
# re-running the transition, so an eligible In-flight item is left untouched.
# The transition is
# skipped entirely for --secondmate spawns (persistent agents are not work
# items), on a config/backlog-backend=manual home, and in a markdown home that
# keeps no data/backlog.md. A configured non-markdown adapter remains
# active without a markdown file; any active automatic backend without
# compatible tasks-axi refuses before creating lifecycle state.
# On success prints: spawned <id> harness=<name> kind=<ship|scout|secondmate> [mode=<mode> yolo=<on|off>] window=<backend-target> worktree=<path>
# A ship task records the explicit mode/yolo it was passed; a secondmate spawn records
# mode=secondmate, yolo=off, home=, and projects=; a scout records neither, and both the
# success line and state/<id>.meta omit them.
# Every fresh spawn or relaunch records a new spawn_gen= incarnation token so durable
# consumers can distinguish a replacement worker that reuses the same task id.
# When the home session's frozen trace-context decision is enabled (see
# docs/configuration.md and bin/fm-trace-context-lib.sh), the meta also records
# one W3C traceparent= carrier, the same value injected into the pane as
# TRACEPARENT; the default-off path writes neither, leaving the generated meta
# and launch environment unchanged.
#   --traceparent <carrier> delivers a carrier that a REMOTE parent already
#   resolved and will record, instead of resolving one from this home's frozen
#   decision. It is accepted only for --secondmate spawns, only as a strictly
#   validated W3C traceparent, and exists because a remote secondmate's task
#   identity is owned by the parent home that holds its task metadata, while the
#   pane export happens on the remote host (bin/fm-remote-secondmate-control.sh).
#   Local spawns never pass it and resolve their own carrier exactly as before.
#
# Module layout: this file owns the spawn sequence - the prologue that resolves
# the home and config, the order in which each phase runs, and the small
# invariants between phases. Each phase's functions and any top-level phase
# block live in a bin/fm-spawn-<topic>.sh module (remote secondmate, abort
# cleanup, admission policy, harness resolution, preflight, worktree, herdr,
# delivery, launch environment, relaunch, report), sourced once at the top
# before the sequence runs. That is a lint-cost contract as much as a structure:
# ShellCheck's extended dataflow grows faster than the file, and a single
# 8000-line root allocated gigabytes while its per-module roots stay small. A
# phase block is wrapped in a spawn_step_* function and called from its original
# position, so execution order and global scope are unchanged.
# Because the phases share one set of globals across those files, SC2034
# (assigned but unused) and SC2153 (possible misspelling) cannot be judged per
# file and are disabled in every spawn phase file. Everything else still runs,
# and each module stays its own canonical lint root.

# shellcheck disable=SC2034,SC2153 # cross-phase globals; this header owns the split contract
set -eu

# Template replacements must stay literal on Bash 5.2+ and stock macOS Bash.
shopt -u patsub_replacement 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Phase modules: definitions only. They are sourced before the sequence runs,
# so every phase function exists no matter where its globals are assigned, and
# each module is linted as its own canonical root instead of being re-parsed
# inside this file.
for _fm_spawn_module in \
  remote abort policy harness \
  harness-resolve preflight worktree herdr \
  delivery launch-env relaunch report \
  ; do
  # shellcheck source=/dev/null
  . "$SCRIPT_DIR/fm-spawn-$_fm_spawn_module.sh" || {
    echo "error: missing spawn phase module: $SCRIPT_DIR/fm-spawn-$_fm_spawn_module.sh" >&2
    exit 1
  }
done
unset _fm_spawn_module

usage() {
  # The whole leading comment block, ending at the first line that is not a
  # comment. Derived rather than a fixed line range, which silently truncated
  # this help mid-sentence every time the header above grew.
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

resolve_directory_input() {
  local name=$1 path=$2 resolved raw_bytes
  raw_bytes=$(fm_backlog_bytes_of_string "$path") || return 1
  if ! fm_backlog_control_bytes_valid 0 "$raw_bytes"; then
    echo "error: $name directory contains an invalid control byte" >&2
    return 1
  fi
  case "$path" in
  /*)
    printf '%s\n' "$path"
    return 0
    ;;
  esac
  resolved=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || {
    echo "error: $name directory cannot be resolved: $path" >&2
    return 1
  }
  printf '%s\n' "$resolved"
}

FM_HOME=$(resolve_directory_input FM_HOME "$FM_HOME") || exit 1
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  FM_STATE_OVERRIDE=$(resolve_directory_input FM_STATE_OVERRIDE "$FM_STATE_OVERRIDE") || exit 1
fi
if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
  FM_DATA_OVERRIDE=$(resolve_directory_input FM_DATA_OVERRIDE "$FM_DATA_OVERRIDE") || exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-config-inherit-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-exclude-tools-lib.sh"
if ! LAUNCH_ENV_ENABLED=$(fm_config_source_present "$CONFIG/launch-env-allowlist"); then
  exit 1
fi
LAUNCH_ENV_NAMES=
if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
  if [ ! -f "$CONFIG/launch-env-allowlist" ] || [ ! -r "$CONFIG/launch-env-allowlist" ]; then
    echo "error: config/launch-env-allowlist must be a readable regular file" >&2
    exit 1
  fi
  if ! LAUNCH_ENV_NAMES=$(jq -Rrs '
    split("\n") | map(select(. != "" and (startswith("#") | not))) |
    if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
    else error("expected environment names only") end
  ' "$CONFIG/launch-env-allowlist" 2>/dev/null); then
    echo "error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments" >&2
    exit 1
  fi
fi
# config/claude-permission-mode (header above): resolved once per spawn or
# relaunch, before any mutation, so a malformed file refuses instead of
# launching a worker on a permission posture the captain did not choose.
if ! CLAUDE_PERM_PRESENT=$(fm_config_source_present "$CONFIG/claude-permission-mode"); then
  exit 1
fi
CLAUDE_PERMISSION_MODE=bypass
if [ "$CLAUDE_PERM_PRESENT" = 1 ]; then
  if [ ! -f "$CONFIG/claude-permission-mode" ] || [ ! -r "$CONFIG/claude-permission-mode" ]; then
    echo "error: config/claude-permission-mode must be a readable regular file holding one of: bypass, auto" >&2
    exit 1
  fi
  CLAUDE_PERMISSION_MODE=$(tr -d '[:space:]' <"$CONFIG/claude-permission-mode" || true)
  case "$CLAUDE_PERMISSION_MODE" in
  bypass | auto) ;;
  *)
    echo "error: config/claude-permission-mode holds '$CLAUDE_PERMISSION_MODE'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" >&2
    exit 1
    ;;
  esac
fi
case "$CLAUDE_PERMISSION_MODE" in
auto) CLAUDE_PERM_FLAG='--permission-mode auto' ;;
*) CLAUDE_PERM_FLAG='--dangerously-skip-permissions' ;;
esac
if ! CODEX_APPROVAL_PRESENT=$(fm_config_source_present "$CONFIG/codex-approval-mode"); then
  exit 1
fi
CODEX_APPROVAL_MODE=bypass
if [ "$CODEX_APPROVAL_PRESENT" = 1 ]; then
  if [ ! -f "$CONFIG/codex-approval-mode" ] || [ ! -r "$CONFIG/codex-approval-mode" ]; then
    echo "error: config/codex-approval-mode must be a readable regular file holding one of: bypass, approve-for-me" >&2
    exit 1
  fi
  if ! CODEX_APPROVAL_MODE=$(perl -0777 -pe 's/\A\s+|\s+\z//g' <"$CONFIG/codex-approval-mode"); then
    echo 'error: could not read config/codex-approval-mode' >&2
    exit 1
  fi
  case "$CODEX_APPROVAL_MODE" in
    bypass | approve-for-me) ;;
    *)
      echo "error: config/codex-approval-mode holds '$CODEX_APPROVAL_MODE'; accepted values are: bypass (the default), approve-for-me" >&2
      exit 1
      ;;
  esac
fi
case "$CODEX_APPROVAL_MODE" in
  approve-for-me) CODEX_APPROVAL_FLAG='--approve-for-me' ;;
  *) CODEX_APPROVAL_FLAG='--dangerously-bypass-approvals-and-sandbox' ;;
esac
# Resolve the opt-in Codex posture before any spawn or relaunch mutation.
# docs/configuration.md owns config/codex-permission-mode and its limits.
CODEX_PERMISSION_MODE=bypass
if ! CODEX_PERM_PRESENT=$(fm_config_source_present "$CONFIG/codex-permission-mode"); then
  exit 1
fi
if [ "$CODEX_PERM_PRESENT" = 1 ]; then
  if [ ! -f "$CONFIG/codex-permission-mode" ] || [ ! -r "$CONFIG/codex-permission-mode" ]; then
    echo "error: config/codex-permission-mode must be a readable regular file holding bypass or restricted" >&2
    exit 1
  fi
  CODEX_PERMISSION_MODE=$(cat "$CONFIG/codex-permission-mode") || exit 1
  case "$CODEX_PERMISSION_MODE" in
  bypass | restricted) ;;
  *)
    echo "error: config/codex-permission-mode must contain bypass or restricted" >&2
    exit 1
    ;;
  esac
fi
# Restricted replaces whichever approval flag was selected above, and the task
# record reports it so approval failover never treats the launch as bypass.
if [ "$CODEX_PERMISSION_MODE" = restricted ]; then
  CODEX_APPROVAL_MODE=restricted
  CODEX_APPROVAL_FLAG='--sandbox workspace-write --ask-for-approval on-request'
fi
# config/lavish-axi-host is the primary-owned per-machine address for the
# shared Lavish server. Read it once per launch and refuse malformed values so
# every worker reaches the same server instead of starting a second one.
if ! LAVISH_AXI_HOST_CONFIG_PRESENT=$(fm_config_source_present "$CONFIG/lavish-axi-host"); then
  exit 1
fi
if [ "$LAVISH_AXI_HOST_CONFIG_PRESENT" = 1 ]; then
  if [ ! -f "$CONFIG/lavish-axi-host" ] || [ ! -r "$CONFIG/lavish-axi-host" ]; then
    echo "error: config/lavish-axi-host must be a readable regular file" >&2
    exit 1
  fi
  LAVISH_AXI_HOST=$(cat "$CONFIG/lavish-axi-host") || exit 1
  case "$LAVISH_AXI_HOST" in
    ''|*[[:space:][:cntrl:]]*)
      echo "error: config/lavish-axi-host must contain one non-empty address without whitespace" >&2
      exit 1
      ;;
  esac
fi
if ! KEEP_AI_TRAILERS=$(fm_config_source_present "$CONFIG/keep-ai-trailers"); then
  exit 1
fi
# Set by the forge agreement below for a forge=external ship.
EXTERNAL_REVIEW=0
EXTERNAL_BACKUP_REMOTE=
EXTERNAL_BACKUP_PREFIX=
SUB_HOME_MARKER=".fm-secondmate-home"
if [ -e "$STATE" ] || [ -L "$STATE" ]; then
  fm_backlog_directory_present "$STATE" "state directory" || {
    echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    exit 1
  }
fi
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-classify-lib.sh"
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: spawn refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-secondmate-nudge-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-kimi-trust-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-polytoken-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-dod-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-role-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-remote-readiness-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-remote-herdr-identity-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-project-capacity-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-worker-account-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-omp-profile-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never spawn
# a direct report (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent
# Skip the watcher guard when re-exec'd for one pair of a batch (FM_SPAWN_NO_GUARD is
# set by the batch loop below), so the guard runs once for the batch, not once per pair.
[ -n "${FM_SPAWN_NO_GUARD:-}" ] || "$FM_ROOT/bin/fm-guard.sh" || true
KIND=ship
KIND_SET=0
HARNESS_ARG=
MODEL=
EFFORT=
DISPATCH_OVERRIDE=
BACKEND_ARG=
MODE=
YOLO=
BRANCH_PREFIX=fm/
TRACEPARENT_ARG=
HARNESS_SET=0
MODEL_SET=0
EFFORT_SET=0
HERMES_PROFILE=
HERMES_PROFILE_SET=0
BACKEND_SET=0
MODE_SET=0
YOLO_SET=0
BRANCH_PREFIX_SET=0
BASE_BRANCH=
BASE_BRANCH_SET=0
UPSTREAM_CONSENT=
UPSTREAM_CONSENT_SET=0
TRACEPARENT_SET=0
ACCOUNT_ARG=
ACCOUNT_SET=0
RELAUNCH=0
# Opt-in only: exact-resume presentation-order lock waits instead of refusing.
# Absent/unset keeps upstream refuse-on-contention. See header.
HERDR_RESUME_LOCK_WAIT=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
    --*)
      echo "error: --$want_value requires a value" >&2
      exit 1
      ;;
    esac
    case "$want_value" in
    harness)
      HARNESS_ARG=$a
      HARNESS_SET=1
      ;;
    model)
      MODEL=$a
      MODEL_SET=1
      ;;
    effort)
      EFFORT=$a
      EFFORT_SET=1
      ;;
    dispatch-override) DISPATCH_OVERRIDE=$a ;;
    hermes-profile)
      HERMES_PROFILE=$a
      HERMES_PROFILE_SET=1
      ;;
    backend)
      BACKEND_ARG=$a
      BACKEND_SET=1
      ;;
    mode)
      MODE=$a
      MODE_SET=1
      ;;
    yolo)
      YOLO=$a
      YOLO_SET=1
      ;;
    branch-prefix)
      BRANCH_PREFIX=$a
      BRANCH_PREFIX_SET=1
      ;;
    base-branch)
      BASE_BRANCH=$a
      BASE_BRANCH_SET=1
      ;;
    upstream-consent)
      UPSTREAM_CONSENT=$a
      UPSTREAM_CONSENT_SET=1
      ;;
    traceparent)
      TRACEPARENT_ARG=$a
      TRACEPARENT_SET=1
      ;;
    account)
      ACCOUNT_ARG=$a
      ACCOUNT_SET=1
      ;;
    *)
      echo "error: internal parser state for --$want_value" >&2
      exit 1
      ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
  --scout)
    KIND=scout
    KIND_SET=1
    ;;
  --secondmate)
    KIND=secondmate
    KIND_SET=1
    ;;
  --relaunch) RELAUNCH=1 ;;
  --herdr-resume-lock-wait) HERDR_RESUME_LOCK_WAIT=1 ;;
  --harness) want_value=harness ;;
  --harness=*)
    HARNESS_ARG=${a#--harness=}
    HARNESS_SET=1
    ;;
  --model) want_value=model ;;
  --model=*)
    MODEL=${a#--model=}
    MODEL_SET=1
    ;;
  --effort) want_value=effort ;;
  --effort=*)
    EFFORT=${a#--effort=}
    EFFORT_SET=1
    ;;
  --dispatch-override) want_value=dispatch-override ;;
  --dispatch-override=*) DISPATCH_OVERRIDE=${a#--dispatch-override=} ;;
  --hermes-profile) want_value=hermes-profile ;;
  --hermes-profile=*) HERMES_PROFILE=${a#--hermes-profile=}; HERMES_PROFILE_SET=1 ;;
  --backend) want_value=backend ;;
  --backend=*)
    BACKEND_ARG=${a#--backend=}
    BACKEND_SET=1
    ;;
  --mode) want_value=mode ;;
  --mode=*)
    MODE=${a#--mode=}
    MODE_SET=1
    ;;
  --yolo) want_value=yolo ;;
  --yolo=*)
    YOLO=${a#--yolo=}
    YOLO_SET=1
    ;;
  --branch-prefix) want_value="branch-prefix" ;;
  --branch-prefix=*)
    BRANCH_PREFIX=${a#--branch-prefix=}
    BRANCH_PREFIX_SET=1
    ;;
  --base-branch) want_value="base-branch" ;;
  --base-branch=*)
    BASE_BRANCH=${a#--base-branch=}
    BASE_BRANCH_SET=1
    ;;
  --upstream-consent) want_value="upstream-consent" ;;
  --upstream-consent=*)
    UPSTREAM_CONSENT=${a#--upstream-consent=}
    UPSTREAM_CONSENT_SET=1
    ;;
  --traceparent) want_value=traceparent ;;
  --traceparent=*)
    TRACEPARENT_ARG=${a#--traceparent=}
    TRACEPARENT_SET=1
    ;;
  --account) want_value=account ;;
  --account=*)
    ACCOUNT_ARG=${a#--account=}
    ACCOUNT_SET=1
    ;;
  *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || {
  echo "error: --$want_value requires a value" >&2
  exit 1
}
[ "$HARNESS_SET" -eq 0 ] || [ -n "$HARNESS_ARG" ] || {
  echo "error: --harness requires a non-empty value" >&2
  exit 1
}
[ "$MODEL_SET" -eq 0 ] || [ -n "$MODEL" ] || {
  echo "error: --model requires a non-empty value" >&2
  exit 1
}
[ "$HERMES_PROFILE_SET" -eq 0 ] || [ -n "$HERMES_PROFILE" ] || {
  echo "error: --hermes-profile requires a non-empty value" >&2
  exit 1
}
if [ "$KIND" = secondmate ] && [ "$HERMES_PROFILE_SET" = 1 ]; then
  echo 'error: --hermes-profile is for crewmate/scout launches, never a secondmate' >&2
  exit 1
fi
[ "$EFFORT_SET" -eq 0 ] || [ -n "$EFFORT" ] || {
  echo "error: --effort requires a non-empty value" >&2
  exit 1
}
[ "$BACKEND_SET" -eq 0 ] || [ -n "$BACKEND_ARG" ] || {
  echo "error: --backend requires a non-empty value" >&2
  exit 1
}
[ "$MODE_SET" -eq 0 ] || [ -n "$MODE" ] || {
  echo "error: --mode requires a non-empty value" >&2
  exit 1
}
[ "$YOLO_SET" -eq 0 ] || [ -n "$YOLO" ] || {
  echo "error: --yolo requires a non-empty value" >&2
  exit 1
}
[ "$UPSTREAM_CONSENT_SET" -eq 0 ] || [ -n "$UPSTREAM_CONSENT" ] || {
  echo "error: --upstream-consent requires a non-empty <host>/<owner>/<repo> value" >&2
  exit 1
}
[ "$TRACEPARENT_SET" -eq 0 ] || [ -n "$TRACEPARENT_ARG" ] || {
  echo "error: --traceparent requires a non-empty value" >&2
  exit 1
}
[ "$ACCOUNT_SET" -eq 0 ] || [ -n "$ACCOUNT_ARG" ] || {
  echo "error: --account requires a non-empty value" >&2
  exit 1
}
# A secondmate, local or remote, launches on its own per-mate pin, so --account
# is refused here, before the remote route could ignore it.
[ "$ACCOUNT_SET" -eq 0 ] || [ "$KIND" != secondmate ] || {
  echo "error: --account applies to ships and scouts; secondmate ${POS[0]:-} launches on its own config/secondmate-accounts/<id>/claude-account pin" >&2
  exit 1
}
# A parent-delivered carrier replaces this home's own resolution, so it is
# refused unless it is a secondmate spawn carrying a strictly valid W3C value.
# Nothing else may reach the pane's TRACEPARENT export.
if [ "$TRACEPARENT_SET" -eq 1 ]; then
  [ "$KIND" = secondmate ] || {
    echo "error: --traceparent applies only to --secondmate spawns; every other spawn resolves its own carrier from this home's frozen trace-context decision" >&2
    exit 1
  }
  fm_trace_context_valid "$TRACEPARENT_ARG" || {
    echo "error: --traceparent is not a valid W3C traceparent" >&2
    exit 1
  }
fi
case "$EFFORT" in
'' | low | medium | high | xhigh | max | ultra) ;;
*)
  echo "error: --effort must be one of low, medium, high, xhigh, max, ultra" >&2
  exit 1
  ;;
esac

# --relaunch reuses an existing task's endpoint, worktree, project, and kind,
# so every axis this block resolves for a fresh spawn instead comes from that
# task's own durable record below. Contradicting it on the command line is a
# refusal rather than a silently-ignored flag.
if [ "$RELAUNCH" -eq 1 ]; then
  [ "$BACKEND_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded backend; --backend cannot override it" >&2
    exit 1
  }
  [ "$KIND_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded kind; --scout/--secondmate cannot override it" >&2
    exit 1
  }
  [ "$MODE_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded delivery mode; --mode cannot override it" >&2
    exit 1
  }
  [ "$YOLO_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded yolo posture; --yolo cannot override it" >&2
    exit 1
  }
  [ "$BRANCH_PREFIX_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded ship branch; --branch-prefix cannot override it" >&2
    exit 1
  }
  [ "$BASE_BRANCH_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded base branch; --base-branch cannot override it" >&2
    exit 1
  }
  [ "$UPSTREAM_CONSENT_SET" -eq 0 ] || {
    echo "error: --relaunch reuses the task's recorded upstream consent; --upstream-consent cannot override it" >&2
    exit 1
  }
else
  # Delivery contract (AGENTS.md section 7). A ship task's mode and yolo are
  # firstmate's per-task decision, so they are required and closed-set validated
  # here rather than resolved from the project registry. Scouts deliver a report
  # and record no delivery posture; secondmate spawns hardcode theirs.
  if [ "$KIND" = ship ]; then
    [ "$MODE_SET" -eq 1 ] || {
      echo "error: ship spawns require --mode <no-mistakes|direct-PR|local-only>; resolve it at intake from the captain's instruction and the project's registered posture in data/projects.md" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 1 ] || {
      echo "error: ship spawns require --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
      exit 1
    }
    case "$MODE" in
    no-mistakes | direct-PR | local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR at intake" >&2
      exit 1
      ;;
    *)
      echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2
      exit 1
      ;;
    esac
    case "$YOLO" in
    on | off) ;;
    *)
      echo "error: --yolo must be on or off (got '$YOLO')" >&2
      exit 1
      ;;
    esac
    # A durable per-PR or per-task delivery decision is authoritative once
    # recorded, so an explicit spawn that contradicts it is refused instead of
    # silently overriding the switch (bin/fm-delivery-lib.sh owns resolution
    # and the record format). Registry and default postures stay intake inputs.
    if [ -x "$FM_ROOT/bin/fm-delivery.sh" ]; then
      if ! DELIVERY_REFUSAL=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" \
        "$FM_ROOT/bin/fm-delivery.sh" enforce-task "${POS[0]:-}" "$MODE" "$YOLO" 2>&1); then
        printf '%s\n' "$DELIVERY_REFUSAL" >&2
        exit 1
      fi
    fi
    if [ "$UPSTREAM_CONSENT_SET" -eq 1 ]; then
      if [ "$MODE" = local-only ]; then
        echo "error: --upstream-consent is meaningless on local-only, which publishes nothing; drop it" >&2
        exit 1
      fi
      fm_role_scope_valid "$UPSTREAM_CONSENT" || {
        echo "error: --upstream-consent must be <host>/<owner>/<repo> (got '$UPSTREAM_CONSENT')" >&2
        exit 1
      }
      UPSTREAM_CONSENT=$(fm_role_scope_norm "$UPSTREAM_CONSENT")
    fi
  else
    [ "$MODE_SET" -eq 0 ] || {
      echo "error: --mode applies only to ship spawns; a scout delivers a report and a secondmate records its own fixed posture" >&2
      exit 1
    }
    [ "$YOLO_SET" -eq 0 ] || {
      echo "error: --yolo applies only to ship spawns; a scout delivers a report and a secondmate records its own fixed posture" >&2
      exit 1
    }
    [ "$BRANCH_PREFIX_SET" -eq 0 ] || {
      echo "error: --branch-prefix applies only to ship spawns; a scout makes no branch and a secondmate records no ship branch" >&2
      exit 1
    }
    [ "$KIND" != secondmate ] || [ "$BASE_BRANCH_SET" -eq 0 ] || {
      echo "error: --base-branch applies only to ship and scout spawns; a secondmate charter has no task base" >&2
      exit 1
    }
    [ "$UPSTREAM_CONSENT_SET" -eq 0 ] || {
      echo "error: --upstream-consent applies only to ship spawns; a scout publishes nothing and a secondmate records no delivery contract" >&2
      exit 1
    }
  fi
fi


BACKEND=
ORCA_ABORT_CLEANUP=0
ORCA_WORKTREE_ID=
ORCA_TERMINAL=
T3CODE_ABORT_CLEANUP=0
T3CODE_LEASED=0
T3CODE_HOME_ENV=0
T3CODE_CLAUDE_CHANNEL_WRITTEN=0
T3CODE_CREATE_UNCERTAIN=0
T3CODE_LAUNCH_UNCONFIRMED=0
T3CODE_PROJECT_ID=
T3CODE_MODEL_SELECTION=
HERDR_LEASED=0
HERDR_PROJECTION_ABORT_CLEANUP=0
HERDR_PROJECTION_ABORT_SESSION=
HERDR_PROJECTION_ABORT_TASK_PANE=
HERDR_PROJECTION_ABORT_SEEDED_PANE=
HERDR_PRESENTATION_ORDER_LOCK=
HERDR_PRESENTATION_ORDER_LOCK_HELD=0
SPAWN_TASK_LOCK=
SPAWN_TASK_LOCK_HELD=0
SPAWN_CONTROL_LOCK=
SPAWN_CONTROL_LOCK_HELD=0
SPAWN_CONTROL_PARENT=0
SPAWN_META_TMP=
SPAWN_META_LOCK=
SPAWN_META_LOCK_HELD=0
SPAWN_META_PUBLISH_STARTED=0
SPAWN_FRESH_COMMIT_PENDING=0
SPAWN_TASK_SET_LOCK=
SPAWN_TASK_SET_LOCK_HELD=0
SPAWN_TREEHOUSE_PROJECT_LOCK=
SPAWN_TREEHOUSE_PROJECT_LOCK_HELD=0
SPAWN_LANE_ADMISSION_LOCK=
SPAWN_LANE_ADMISSION_LOCK_HELD=0
SPAWN_SLOT_CLAIMED=0
SPAWN_FRESH_ENDPOINT_OPENED=0
SPAWN_FRESH_WIRING_PENDING=0
SPAWN_TASK_TMP_CREATED=0
RELAUNCH_REPLACEMENT_PENDING=0
RELAUNCH_REPLACEMENT_BUSY_GEN=
RELAUNCH_REPLACEMENT_HARNESS=
RELAUNCH_REPLACEMENT_STATE=
RELAUNCH_REPLACEMENT_WT=
CONFIG_INHERIT_LOCK=
CONFIG_INHERIT_LOCK_HELD=0
GIT_HOOKS_DIR=
SPAWN_LAUNCH_SENT=0
SPAWN_ENDPOINT_CLOSED=0
SPAWN_STAGED_LAUNCH_FILE=




trap spawn_abort_cleanup EXIT



spawn_batch_dispatch
# Spend cap (bin/fm-afk-contract.sh's spend_max_concurrent_workers): while an
# away record exists (never a quiet-mode one, whose captain is present and
# spends as attended: bin/fm-afk-contract.sh mode), a fresh ordinary spawn
# refuses for BOTH actors once this home already holds that many ordinary task
# records, counted by that script's own `live-workers`, which is also the count
# its entry records as the cap. A relaunch replaces a worker that already
# counts, and a secondmate is a persistent home rather than spend, so both are
# exempt. Checked before any endpoint, worktree, or record
# exists, so a refusal costs nothing to unwind; rechecked after the task-set
# lock so two fresh spawns cannot both publish from a stale count.
spawn_refuse_if_away_spend_cap
spawn_admission_preflight









spawn_resolve_launch_command








spawn_validate_harness_binary







spawn_validate_secondmate_dispatch
spawn_check_delivery_agreement
spawn_ensure_session_provider






# The opt-in half of the base rule the header owns: return 0 and set
# SPAWN_PRIMARY_BASE_REV when <project>'s own <default> should be this fresh
# slot's base instead of origin's tip <origin-rev>. A pool slot shares the
# primary checkout's object store, so reading that commit fetches nothing, and a
# commit the slot cannot read keeps origin's tip.
SPAWN_PRIMARY_BASE_REV=



spawn_backlog_preflight
SPAWN_HC_LINE_SUBMITTED=0







# The folder-prompt predicates (complete dialog, any dialog marker, paged
# disclosure, project-server announcement) come from bin/fm-kimi-trust-lib.sh,
# which the live guard shares. The complete dialog decides whether to press
# Enter. Any single marker of it on the visible pane decides whether that pane
# is safe to call ready: a capture caught mid-redraw and one that has painted
# only the dialog's title both fail the complete-dialog test while the dialog
# is still up and waiting, with Kimi's startup banner sitting above it in that
# same capture. Treating such a pane as ready would type the brief pointer
# into the dialog and lose it.














spawn_agy_launch_delivery




spawn_polytoken_launch_delivery



spawn_orca_relaunch_projection
spawn_install_launch_environment
spawn_preserve_relaunch_state

spawn_finalize_record
spawn_launch_home_token_step
spawn_post_launch_report
