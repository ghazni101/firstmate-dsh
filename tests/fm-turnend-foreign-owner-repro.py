#!/usr/bin/env python3
"""Executable regression for Claude turn-end supervision ownership.

The retired fleet session lock is gone: a native session owns its home by
identity, and the identity is the harness process this firing descends from
(bin/fm-proc-lib.sh fm_harness_ancestry_pid). This reproduction drives the
shipped auto-arm ledger and the shipped turn-end guard against isolated
synthetic primary homes and harness-shaped processes, and pins what remains:

  - a generation claim records the claiming process identity (ledger line 2)
    and the harness identity it was taken under (line 3), and is OPEN only
    while its owner is live, identity-matched, and reachable from the current
    harness process;
  - a concurrent firing from the same session defers to the open claim, and the
    guard steps aside for it; once the session dies the claim closes and the
    guard blocks again;
  - a fresh terminal rewake explains the stale beacon to the guard, and an aged
    one does not;
  - a legacy state/.lock naming a live foreign holder is inert: it is not
    created, not consulted by the claim, and not modified;
  - the guard's strict watcher-lock model still accepts only a live,
    identity-matched watcher with a fresh beacon.

It is adapted from Appendix A of the downstream reproduction report.
"""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
LAB = pathlib.Path(tempfile.mkdtemp(prefix="fm-turnend-ownership-"))
OUT = LAB / "evidence"
OUT.mkdir()
# Basename must be an exact FM_HARNESS_NAMES entry. Linux procps comm= is the
# 15-char kernel name, so the symlink stays short and unambiguous.
FAKE = LAB / "claude"
FAKE.symlink_to("/bin/bash")
PROCS = []

# The suite may itself run inside a harness session. Its markers are scrubbed so
# only the synthetic harness processes below can answer an ancestry walk.
BASE_ENV = {
    k: v
    for k, v in os.environ.items()
    if not k.startswith(
        ("FM_", "HERDR_", "PI_", "CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "GROK_", "CURSOR_")
    )
}
BASE_ENV.pop("CLAUDECODE", None)

PAYLOAD = json.dumps({"session_id": "synthetic-native", "stop_hook_active": True})


def make(name):
    root = LAB / name
    root.mkdir()
    for directory in ("state", "config", "data", "projects"):
        (root / directory).mkdir()
    subprocess.run(["git", "init", "-q", str(root)], check=True, env=BASE_ENV)
    (root / "AGENTS.md").write_text("Synthetic diagnostic fixture. No fleet or project operations.\n")
    (root / "bin").symlink_to(REPO / "bin", target_is_directory=True)
    (root / "state/task.meta").write_text("project=synthetic\n")
    (root / "state/home-summary.json").write_text("{}\n")
    env = BASE_ENV | {
        "FM_HOME": str(root),
        "FM_ROOT_OVERRIDE": str(root),
        "FM_STATE_OVERRIDE": str(root / "state"),
        "FM_CONFIG_OVERRIDE": str(root / "config"),
        "FM_DATA_OVERRIDE": str(root / "data"),
        "FM_PROJECTS_OVERRIDE": str(root / "projects"),
        "FM_POLL": "1",
        "FM_HEARTBEAT": "999999",
        "FM_HOME_SUMMARY_INTERVAL": "999999",
        "FM_CHECK_INTERVAL": "999999",
        "FM_CLAUDE_AUTOARM_SYNC_WAIT_MS": "0",
    }
    return root, env


def run(env, command, timeout=60):
    return subprocess.run(
        [str(FAKE), "-c", command],
        env=env,
        text=True,
        capture_output=True,
        timeout=timeout,
    )


def start(env, command, name):
    output = (OUT / name).open("w")
    process = subprocess.Popen(
        [str(FAKE), "-c", command],
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        text=True,
    )
    output.close()
    PROCS.append(process)
    return process


def until(test, seconds=20, message="condition timed out"):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.05)
    raise RuntimeError(message() if callable(message) else message)


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def field(epoch, name):
    for token in epoch.splitlines()[0].split():
        if token.startswith(name + "="):
            return token.split("=", 1)[1]
    return ""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def guard(env, label):
    process = run(
        env,
        "printf '%s\\n' '" + PAYLOAD + "' | \"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh\" --claude",
    )
    print(
        label,
        "rc=" + str(process.returncode),
        "stdout=" + repr(process.stdout[:400]),
        "stderr=" + repr(process.stderr[:400]),
        flush=True,
    )
    return process


try:
    root, env = make("native")
    state = root / "state"
    (state / "payload.json").write_text(PAYLOAD + "\n")
    session_script = (
        'FAKE="' + str(FAKE) + '"\n'
        '. "$FM_HOME/bin/fm-wake-lib.sh"\n'
        '. "$FM_HOME/bin/fm-proc-lib.sh"\n'
        'printf "%s\\n" "$$" > "$FM_HOME/state/harness-pid"\n'
        'fm_autoarm_claim_next "$FM_HOME/state" synthetic-native '
        '|| { printf "claim_next failed\\n" > "$FM_HOME/state/error"; exit 1; }\n'
        'printf "%s\\n" "$FM_AUTOARM_MY_GEN" > "$FM_HOME/state/gen"\n'
        '"$FAKE" -c \'. "$FM_HOME/bin/fm-wake-lib.sh"; '
        'fm_autoarm_claim_open "$FM_HOME/state" synthetic-native; '
        'printf "%s\\n" "$?" > "$FM_HOME/state/open-rc"\'\n'
        '"$FAKE" -c \'. "$FM_HOME/bin/fm-wake-lib.sh"; '
        'fm_autoarm_claim_next "$FM_HOME/state" synthetic-native; '
        'printf "%s\\n" "$?" > "$FM_HOME/state/next-rc"\'\n'
        '"$FAKE" -c \'cat "$FM_HOME/state/payload.json" | '
        '"$FM_ROOT_OVERRIDE/bin/fm-turnend-guard.sh" --claude; '
        'printf "%s\\n" "$?" > "$FM_HOME/state/guard-open-rc"\'\n'
        "while :; do sleep 0.2; done\n"
    )
    session = start(env, session_script, "session.txt")
    until(lambda: (state / "guard-open-rc").is_file(), message="the live session never finished its probes")
    until(lambda: (state / "harness-pid").is_file(), message="the live session never recorded its harness pid")

    harness_pid = (state / "harness-pid").read_text().strip()
    require((state / "gen").read_text().strip() == "1", "the first firing did not claim generation 1")
    require((state / "open-rc").read_text().strip() == "0", "the live session's own claim was not open")
    require(
        (state / "next-rc").read_text().strip() == "2",
        "a concurrent firing from the same session did not defer to the open claim",
    )
    require(
        (state / "guard-open-rc").read_text().strip() == "0",
        "the guard did not step aside for the open generation claim",
    )
    require(not (state / ".lock").exists(), "the native home grew a fleet session lock")
    epoch_text = (state / ".claude-autoarm-epoch").read_text()
    require(field(epoch_text, "owner_pid") == harness_pid, "the arming claim did not bind the harness process")
    lines = epoch_text.splitlines()
    require(len(lines) >= 2 and lines[1].strip(), "the arming claim recorded no mandatory owner identity")
    require(len(lines) >= 3 and lines[2].strip(), "the arming claim recorded no harness identity")
    print("SETUP live session=", harness_pid, "claim=", epoch_text.splitlines()[0], flush=True)

    # The session dies: the open claim closes and the guard blocks again.
    stop(session)
    blocked = guard(env, "dead-session guard")
    require(blocked.returncode == 2, "a claim whose session died must not keep the guard silent")
    require("TURN WOULD END BLIND - SUPERVISION IS OFF" in blocked.stderr, "the dead-session guard lost its watcher banner")

    # A fresh terminal rewake (committed by the Stop-owned auto-arm) explains the
    # stale beacon for one handling turn; an aged one does not.
    (state / ".claude-autoarm-epoch").write_text(
        "epoch=2 owner_pid=1 outcome=rewake updated_at=%d\nlinux-starttime=1 cmdline-hex=00\n" % int(time.time())
    )
    fresh = guard(env, "fresh rewake guard")
    require(fresh.returncode == 0, "a fresh terminal rewake did not explain the stale beacon")
    require(fresh.stdout == "" and fresh.stderr == "", "a healthy handling turn produced output: " + repr(fresh.stdout + fresh.stderr))
    old = time.time() - 600
    os.utime(state / ".claude-autoarm-epoch", (old, old))
    aged = guard(env, "aged rewake guard")
    require(aged.returncode == 2, "an aged rewake still silenced the guard")
    require("TURN WOULD END BLIND - SUPERVISION IS OFF" in aged.stderr, "the aged-rewake guard lost its watcher banner")

    # A legacy lock naming a live foreign holder is inert: the claim never reads
    # it and never touches it.
    (state / ".lock").write_text("%d\n" % os.getpid())
    claimed = run(
        env,
        '. "$FM_HOME/bin/fm-wake-lib.sh"; '
        'fm_autoarm_claim_next "$FM_HOME/state"; printf "claim_rc=%s\\n" "$?"',
    )
    print("legacy foreign lock claim", "stdout=" + repr(claimed.stdout), "stderr=" + repr(claimed.stderr), flush=True)
    require("claim_rc=0" in claimed.stdout, "a legacy foreign lock still blocked the generation claim")
    require(
        (state / ".lock").read_text().strip() == str(os.getpid()),
        "the generation claim modified the inert legacy lock",
    )
    require(
        int(field((state / ".claude-autoarm-epoch").read_text(), "epoch")) >= 3,
        "the generation claim after the legacy lock did not advance the ledger",
    )

    # The strict watcher-lock model: a live identity-matched watcher with a fresh
    # beacon is healthy; a dead one is not, however fresh the beacon.
    watcher = start(env, "sleep 60", "watcher.txt")
    identity = run(env, '. "$FM_HOME/bin/fm-wake-lib.sh"; fm_pid_identity %d' % watcher.pid).stdout.strip()
    require(identity, "could not compute the synthetic watcher identity")
    lockdir = state / ".watch.lock"
    lockdir.mkdir()
    (lockdir / "pid").write_text("%d\n" % watcher.pid)
    (lockdir / "fm-home").write_text(str(root) + "\n")
    (lockdir / "watcher-path").write_text(str(root / "bin/fm-watch.sh") + "\n")
    (lockdir / "pid-identity").write_text(identity + "\n")
    (state / ".last-watcher-beat").touch()
    healthy = guard(env, "live watcher guard")
    require(healthy.returncode == 0, "a live identity-matched watcher with a fresh beacon was not healthy")
    stop(watcher)
    dead = guard(env, "dead watcher guard")
    require(dead.returncode == 2, "a dead watcher lock did not block the turn end")
    require("TURN WOULD END BLIND - SUPERVISION IS OFF" in dead.stderr, "the dead-watcher guard lost its banner")
    print("FIXED native identity, generation claims, and the watcher-lock model behave", flush=True)
    print("COMPLETE", flush=True)
finally:
    for process in reversed(PROCS):
        stop(process)
    shutil.rmtree(LAB, ignore_errors=True)
