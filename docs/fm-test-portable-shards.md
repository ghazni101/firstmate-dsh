# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## CI status

This repository has no CI.
The sharded GitHub Actions layout this document measured was retired with `.github/workflows/`, and the later single-job Forgejo workflow was deleted too.
No hosted CI runs the behavior suites, the lint gate, or the DSH plugin tests.
The lane, packing, coverage, and timing machinery below still governs local `bin/fm-test-run.sh` runs, and the recorded Ubuntu measurements remain its packing weights.
Later references to CI runs, refreshes, jobs, and timeouts in this document describe that retired history.

## Verification inputs

Balance hints came from serial runs of the real lanes on `ubuntu-latest`.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not serial CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Both hint tables were refreshed on 2026-09-30 from five Ubuntu CI runs: [36583881812](https://github.com/kunchenguid/firstmate/actions/runs/36583881812), [36658498535](https://github.com/kunchenguid/firstmate/actions/runs/36658498535), [36663947738](https://github.com/kunchenguid/firstmate/actions/runs/36663947738), [36664663190](https://github.com/kunchenguid/firstmate/actions/runs/36664663190), and [36669175457](https://github.com/kunchenguid/firstmate/actions/runs/36669175457).
Use the slowest successful `duration_ms` per script across their uploaded portable timing artifacts and completed `FM_TEST_END` log markers, with the two version/platform exceptions below.
All artifact records were cross-checked against the corresponding job's markers.
This covered all 24 parallel and 201 serial members at that refresh; an existing live-capability skip is a portable-runner measurement, not a timing claim for the unavailable live integration.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Two serial-5 jobs were cancelled at their 30-minute cap and uploaded no artifact.
Their completed log markers supplement the complete runs, but a cancelled job's wall time is only a lower bound and its unfinished or never-started scripts have no completed sample.
A failed script's duration is excluded even when its lane uploaded an artifact.
In particular, run 36664663190's serial 5 finished in 22m15s with an assertion failure, not a timeout; treating that as a healthy whole-lane sample would hide the failure.
Collect successful per-script measurements for every member before calculating a split.

The supervision-host suite is four serial members so no one file occupies a whole serial shard: `tests/fm-supervision-host-drain.test.sh` (report, dispatch, BRANCH OUTCOMES; 17 tests, local 19978 ms, hint 45950 ms), `tests/fm-supervision-host-hook.test.sh` (Claude Stop-hook re-arm and hand-back; 24 tests, local 175562 ms, hint 403793 ms), `tests/fm-supervision-host.test.sh` (host loop wakes, closes, mirror, return; 29 tests, local 189383 ms, hint 435581 ms), and `tests/fm-supervision-host-park.test.sh` (latch, park boundary, compaction, session identity; 20 tests, local 143185 ms, hint 329326 ms). Packing weights are local `duration_ms` scaled by ~2.3 for CI, replacing the 1192918 ms single-file sample from run [39642852135](https://github.com/kunchenguid/firstmate/actions/runs/39642852135) that sat alone in a serial shard and still overran: run 39765114423 cancelled that script at the 30-minute job cap. Keep these four recorded values until a refreshed Ubuntu measurement replaces them.
The native-Windows-only `tests/fm-pi-windows-shell-invocation.test.sh` retains its separate 5121 ms measurement from 2026-09-06T21:02Z instead of a portable capability skip.
The 2026-10-07 polytoken adapter tests carry provisional local measurements instead - 21090 ms for `tests/fm-polytoken-harness.test.sh` and the 103 ms live-guard skip for `tests/fm-polytoken-signals-live-e2e.test.sh`, both measured on the adapter-verification macOS host - until a refreshed Ubuntu measurement replaces them, because they postdate the 2026-09-30 baseline.
The 2026-10-23 `tests/fm-approval-failover.test.sh` serial hint is a provisional local measurement of 5410 ms, the slowest of five local `bin/fm-test-run.sh` samples (4991-5410 ms), until a refreshed Ubuntu measurement replaces it.
The 2026-11-08 `tests/fm-capacity-auto.test.sh` (36243 ms), `tests/fm-lane-capacity-integration.test.sh` (48000 ms), and `tests/fm-lane-vitals.test.sh` (5077 ms) serial hints are provisional local measurements from one `bin/fm-test-run.sh` run on a loaded macOS host, until a refreshed Ubuntu measurement replaces them.
The 2026-11-09 `tests/fm-stow-guard.test.sh` serial hint is a provisional local measurement of 30000 ms, above a 27436 ms `bin/fm-test-run.sh` sample on this macOS host, until a refreshed Ubuntu measurement replaces it.
The 2026-10-23 Kimi folder-prompt live guard, `tests/fm-kimi-trust-prompt-live-e2e.test.sh`, carries a provisional 60 ms skip measured on the Linux host that recorded its captures, until a refreshed Ubuntu measurement replaces it.
The 2026-11-03 `tests/fm-herdr-projected-cd-live-e2e.test.sh` serial hint is provisionally 28000 ms, above a successful 27692 ms local runner sample exercising Herdr 0.9.5 on macOS arm64, until a refreshed Ubuntu measurement replaces it.
The 2026-10-27 `tests/fm-claude-account-quota.test.sh` serial hint is a provisional local measurement of 2492 ms, the slowest of five local `bin/fm-test-run.sh` samples (1930-2492 ms) on a Linux host, until a refreshed Ubuntu measurement replaces it.
The 2026-11-04 `tests/fm-install-herdr.test.sh` serial hint is a provisional local measurement of 1000 ms, above the slowest of five `bin/fm-test-run.sh` samples (155-223 ms) on a Linux host, until a refreshed Ubuntu measurement replaces it.
The 2026-10-26 `tests/fm-test-tap-verify.test.sh` serial hint is a provisional local measurement of 1000 ms, above a 238 ms `bin/fm-test-run.sh` sample on this Linux host, until a refreshed Ubuntu measurement replaces it.
The 2026-11-08 `tests/fm-lavish-url.test.sh` serial hint is a provisional local measurement of 30000 ms, above the slowest of three `bin/fm-test-run.sh` samples (25148-26650 ms) on a Linux host, until a refreshed Ubuntu measurement replaces it.
The 2026-10-27 read-repetition suites carry provisional Linux x86_64 local runner maxima: 602 ms for `tests/fm-read-repetition.test.sh` (six successful samples, 528-602 ms) and 1110 ms for `tests/fm-read-repetition-live.test.sh` (five successful samples, 949-1110 ms).
`tests/fm-park.test.sh` is now a portable parallel member; its 70085 ms parallel hint is its completed passing Ubuntu `FM_TEST_END` sample from CI run [42730709201](https://github.com/kunchenguid/firstmate/actions/runs/42730709201), and `tests/fm-arm-pretool-check.test.sh` moved to parallel lane 2 to keep the lanes within 5%.
The live samples exercised installed Pi 1.4.0 RPC without capability skips; they are not CI timing evidence or timings for unavailable harnesses.
Both suites retain serial placement and full coverage; keep these provisional hints until a refreshed Ubuntu measurement replaces them.
The 2026-10-29 `tests/fm-live-lab-isolation.test.sh` serial hint is a provisional local measurement of 6459 ms, the slowest of six `bin/fm-test-run.sh` samples (4308-6459 ms) taken inside a private `unshare -Urm` /tmp on this Linux host, until a refreshed Ubuntu measurement replaces it.
The 2026-10-27 `tests/fm-codex-stop-park.test.sh` serial hint is a provisional local measurement of 35000 ms, above the slowest of the `bin/fm-test-run.sh` samples (20170-34700 ms) on a macOS arm64 host, until a refreshed Ubuntu measurement replaces it.
The 2026-10-28 Antigravity primary tests carry provisional serial hints - 45000 ms for `tests/fm-agy-primary.test.sh` and the 75 ms live-guard skip for `tests/fm-agy-primary-live-e2e.test.sh` - until a refreshed Ubuntu measurement replaces them.
The wedge-cap suite carries the Ubuntu measurements from CI run [39597689178](https://github.com/kunchenguid/firstmate/actions/runs/39597689178) - 374225 ms for `tests/fm-watch-wedge-cap.test.sh` and the 74 ms live-guard skip for `tests/fm-watch-wedge-cap-live.test.sh` - in place of the provisional local measurements the suite first carried (1003000 ms and the 155 ms skip), which overstated the CI cost of both.
They are not a formality: without a hint the suite is packed on the 45000 ms default, which puts it beside a shard already holding about 17 minutes of measured work, so that shard would really have run for about 23 minutes - past the 20-minute target the guard reserves - while the coverage guard still passed.
The same run measured the wedge-cap parity suite at 27763 ms, which `bin/fm-test-run.sh` packs in place of the provisional 209000 ms local measurement.
`test_portable_serial_packing_budget_boundary` now pins every other fixture script to 1 ms, so packing exactly at the 1200000 ms budget is accepted and one millisecond above it is refused even when real serial members have no hint.
The coverage-guard test owns modeled real-hint headroom under that budget.
The session-start hint retains its pre-optimization maximum until a measurement covers the shorter fixture-only home-summary bound; do not discount a local speedup from the recorded packing weights.
The T3 Code backend suites carry the slowest successful Ubuntu samples from CI runs [39463576576](https://github.com/kunchenguid/firstmate/actions/runs/39463576576), [39814995718](https://github.com/kunchenguid/firstmate/actions/runs/39814995718), and [39883948163](https://github.com/kunchenguid/firstmate/actions/runs/39883948163) - 239245 ms for `tests/fm-backend-t3code.test.sh`, 57613 ms for `tests/fm-t3-mcp.test.sh`, 283 ms for `tests/fm-watch-inbox-meta.test.sh`, and the 51 ms and 52 ms live-guard skips for `tests/fm-backend-t3code-live-e2e.test.sh` and `tests/fm-backend-t3code-pr-tools-live-e2e.test.sh`.
`tests/fm-backend-t3code.test.sh` and `tests/fm-t3-mcp.test.sh` run in the portable parallel lanes, so those two values sit in `portable_parallel_weight_hints`: every case id the backend suite spawns carries a per-run suffix and its cleanup removes only the `/tmp/fm-<id>` directories that run created, and both suites passed running concurrently with each other and beside another parallel suite (see [`fm-test-isolation-proof.md`](fm-test-isolation-proof.md)).

The new `tests/fm-remote-herdr-identity.test.sh` serial hint is provisionally 6158 ms, from a successful local macOS arm64 `bin/fm-test-run.sh` sample on 2026-11-08. Keep the recorded value until a refreshed Ubuntu measurement replaces it; this is not whole-shard timing evidence.

## Parallel lanes

The two parallel lanes use longest-processing-time assignment over those hints.
[`tests/fm-pi-primary-types.test.sh`](../tests/fm-pi-primary-types.test.sh) owns its typecheck dependencies independently of the lane's installed Pi runtime.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships and lane-specific prerequisite constraints beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order and preserve serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
`portable_parallel_weight_hints` came from the slowest completed `duration_ms` per script across several green CI runs' `fm-test-timing-portable-parallel-*` artifacts.

The remote-secondmate lifecycle hint is 1005249 ms, its completed, passing `FM_TEST_END` sample from Ubuntu run [41289019354](https://github.com/kunchenguid/firstmate/actions/runs/41289019354). Rex lifecycle coverage outgrew the previous 345655 ms hint; serial shard 9 then reached the 30-minute job cap while running later tests. Eleven serial shards accommodate the refreshed weight within the unchanged modeled budget and timeout policy. This is a completed-script measurement from a partial run, not a successful whole-shard timing or a guarantee of future headroom.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, GUI-backend, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate runs.
Each shard is still strictly serial in itself, and separate runs mean no two of these stateful scripts ever share a machine, so the split needs no concurrency isolation proof.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
The retired `.github/workflows/ci.yml` derived the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other failed the lane loudly instead of leaving part of the required suite unrun.

Assignment is longest-processing-time bin packing over per-script duration hints embedded in `bin/fm-test-run.sh`.
[Verification inputs](#verification-inputs) owns the measurement provenance and exceptions.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and outlast a practical run budget while another sits idle.
`bin/fm-test-run.sh --check-coverage` reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`.
That catches missing hints, not stale existing hints: the host suite still had a 41512 ms hint after growing to over 1000 seconds in CI, so the old split placed it beside another 12 minutes of work while passing the guard.
Refresh the hints whenever a serial member grows materially or the lane gains scripts, rather than waiting for missing-hint coverage to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size and coverage rather than a copied inventory.
Its header and `--help` own the modeled-budget check and output fields; read the current estimates from `--check-coverage` instead of retaining copied lane sums here.
[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_serial_packing_budget_boundary`, verifies acceptance exactly at the budget and refusal one millisecond above it through the executable runner.
The watch-triage suite is three serial members so no one file occupies a whole serial shard: `tests/fm-watch-triage.test.sh` (classifier, signal/turn-end absorb, wedge ladder, gone endpoints, TERM, busy-pane age, timer repair, procevent, heartbeat/afk hand-off, exit picker; hint 592950 ms), `tests/fm-watch-triage-pause.test.sh` (declared waits, captain-call holds, pause transitions, away/quiet holds, paused-until and background-job waits; hint 466750 ms), and `tests/fm-watch-triage-wedge-defer.test.sh` (wedge-threshold deferrals; 13 tests, hint 526980 ms).
Those hints are the per-file sums of per-test durations from the slowest CI sample, run [40280579086](https://github.com/kunchenguid/firstmate/actions/runs/40280579086), rounded up, replacing the 1074843 ms single-file sample that sat in a serial shard with about 27.8 minutes of tests against the 30-minute job cap.
The estimates use per-file maxima from different runs, not measured rebalanced jobs or an end-to-end latency guarantee.
Even so, maxima from five runs do not establish a P95 or guarantee future headroom.
Any timeout remains a hang tripwire under the policy in [Timeouts](#timeouts) below; it is not the desired healthy duration.
`tests/fm-ci-workflow.test.sh` compared the parsed CI matrix to the executable runner lanes; that suite was retired with the workflow, and the runner still rejects parallel `--jobs` on a serial lane even when that shard has only one member.

The CI-derived hints were refreshed by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh-axi run download "$run" -R kunchenguid/firstmate --dir "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | select(.exit == 0) | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/fm-test-timing-portable-serial-*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard may upload no artifact, so include a complete green run or the slowest scripts go unmeasured in exactly the shard that needs them most.
Completed shards from a partial run can supplement that complete baseline, but never treat missing tail scripts or the timeout duration as successful samples.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable shards skip them.

## Coverage guard

`bin/fm-test-run.sh --check-coverage` verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial shards are non-empty, disjoint, and together equal the portable serial lane.
Its hint-coverage and modeled-budget checks are described in [Portable serial shards](#portable-serial-shards); neither replaces inspection of the recorded timing artifacts.

## Timing artifacts

The retired hosted CI uploaded runner-generated timing JSON for the portable shards, each portable serial shard, and the Herdr lane.
`bin/fm-test-run.sh --aggregate-json` remains the local way to combine artifacts kept from those runs.

## Lint partitions and end-to-end latency

`bin/fm-lint.sh` owns two canonical partitions, each running full dataflow analysis without following imports, plus workflow validation and backend-purity checks.
Import following is not part of the canonical posture: each shared library is a root of its own, and following a variable-path import measured about twenty times the root's own cost.
No CI runner uses those partitions now; a local `bin/fm-lint.sh` run uses the default full canonical set, and the partitions remain complete and disjoint for two-runner use.
`FM_LINT_REQUIRE_BOUNDS=1` gives a bounded run its per-root deadline and address-space limit, so an unenforceable bound refuses lint rather than running uncapped; the script header owns the envelope, per-root execution contract, memory fallback, resident ceiling, cost scheduling, and the run-level memory scope.
Every canonical root also runs under a resident memory ceiling, so a root that would allocate gigabytes is stopped and named instead of exhausting the host.
Its `--list-files` interface exposes partition membership; `tests/fm-lint.test.sh` verifies complete/disjoint executed roots, initial analysis flags, and fallback reporting.
`--telemetry` writes the quiet metrics snapshot plus its per-root lifecycle sidecar, so any run can distinguish analysis cost, memory use, and host contention.
No fast mode, path skips, or paid runner provisioning is part of this layout.

The retired layout's longer-term performance objective was a complete green run under fifteen minutes including start delay, but the three watch-triage members still sum to about 26 minutes of test time.
The immediate packing target is the runner's modeled script budget, not a claim that more shards alone can make an indivisible script faster.
The retired layout used sixteen long-lived Linux jobs (eleven serial, two parallel, Herdr, two lint), plus short checks and macOS; insufficient shared account capacity can erase the packing gain.
Compare complete before/after runs, preserve cancelled and partial-run evidence, and measure a representative normal-run sample before claiming a P95 improvement.
The retired workflow retained per-PR supersession and kept only the newest of close main pushes' runs; the deleted Forgejo workflow declared no concurrency group.

## Local entry points

[README.md](../README.md#contributing) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

The retired GitHub CI applied a three-tier job-timeout policy; its workflow and `tests/fm-ci-workflow.test.sh` are gone with it.
The later single-job Forgejo workflow had a 60-minute `timeout-minutes` backstop, sized for the full canonical lint run with two ShellCheck workers plus the plugin tests.
That bound disappeared with the workflow, so any local run needs its own timeout; a run that reaches one needs investigation and a runtime fix, not a larger number.
A passing coverage guard does not establish a healthy job duration either.
