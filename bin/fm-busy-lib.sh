#!/usr/bin/env bash
# fm-busy-lib.sh - the ONE owner of firstmate's semantic busy-state contract.
#
# Design source: the captain-approved semantic busy-state redesign
# (2026-07-28): each harness adapter reports turn lifecycle through a
# machine-readable semantic source it owns, classification always exposes
# which source produced it, and missing, malformed, stale, unsupported, or
# unverified semantic data is UNKNOWN - never idle. Endpoint death is the only
# process-level override and yields dead, never busy. Child processes, CPU,
# process sleep state, marker mtimes, and the old global UI-regex OR are not
# state signals here; state/<id>.turn-ended files remain wake NOTIFICATIONS
# owned by the watcher, not current-state truth.
#
# Record file: state/<id>.busy-state - exactly one line, atomically replaced
# by bin/fm-busy-event.sh (the only writer):
#
#   v1 gen=<token> seq=<uint> state=<busy|idle|unknown> source=<token> event=<token> ts=<epoch>
#
# Gen sidecar: state/<id>.busy-gen - one token minted when the task's busy
# wiring is armed (fm-spawn, or a documented recovery re-arm). Every event
# must present the current gen; an event or record carrying any other gen is
# a stale incarnation and is rejected (written events) or classified unknown
# (read records). seq is a strictly increasing integer per gen, advanced
# under the writer's lock: it records apply order, not harness emission order,
# and cannot stop a late apply from overwriting a newer harness event.
# OpenCode's emission-order queue is owned by the generated plugins in
# bin/fm-spawn.sh; tests/fm-busy-adapter-wiring.test.sh covers unawaited bursts
# and the OpenCode 2 server/setup entry points.
#
# Semantic sources written by adapters (fm_busy_sources_for_harness owns the
# per-harness trust table; a record whose source is not trusted for the
# task's recorded harness classifies unknown, so one adapter's writer can
# never classify another adapter):
#   pi-ext           Pi per-task extension (agent_start/agent_settled)
#   omp-ext          omp (Oh My Pi) per-task extension (agent_start/agent_end without willContinue)
#   claude-hook      Claude lifecycle hooks (UserPromptSubmit/Stop/StopFailure/SessionEnd)
# Firstmate-owned sources accepted for every converted adapter:
#   fm-spawn         the launch-brief turn seeded at spawn
#   fm-interrupt     the legacy Claude fm-send --key Escape idle event
#   fm-recovery      a documented recovery reset after relaunch
# Classifier-only sources (never written into a record):
#   endpoint-gone, herdr-native, cursor-transcript, missing, malformed,
#   gen-mismatch, source-mismatch, capture-failed, no-target, launch-prompt
#
# Classification (fm_busy_classify): busy | idle | unknown | dead, always
# with the producing source as the second token. Precedence:
#   1. dead endpoint (fm_busy_classify_live only) -> dead endpoint-gone
#   2. a valid, gen-matching, source-trusted record -> its state and source,
#      UNLESS the record is still the untouched seed fm-spawn wrote at arm
#      time (state=busy source=fm-spawn - no adapter hook has posted since
#      launch) AND the caller supplied a captured tail that matches that
#      harness's own recognized interactive-prompt signature (a trust
#      dialog, sign-in screen, or first-run menu - fm_busy_launch_prompt_parked
#      owns the per-harness table). That combination classifies unknown
#      launch-prompt instead: the launch never actually started the brief, so
#      it must not read as proof of an active turn. A record that has
#      advanced past fm-spawn (any real hook event) is NEVER reclassified
#      this way, however its rendered tail looks, so a genuinely working turn
#      keeps its ordinary busy verdict and the general BUSY_TURN_MAX_SECS
#      bound is unchanged.
#   5. no record at all: a native busy verdict from herdr is trusted as busy
#      (generation state is sufficient for busy, not for idle), then the
#      cursor transcript pull source, then unknown missing
#   6. malformed, stale, or untrusted records -> unknown, never a fallback
#
# fm_busy_launch_prompt_parked (the launch-prompt classifier-only source): a
# launch whose busy record never advanced past the fm-spawn seed is
# indistinguishable, from the record alone, between "still reading its
# brief" and "parked on an interactive prompt the harness never gets past
# without a human" - a Claude/Pi workspace-trust dialog, a sign-in or
# auth-method picker, or a first-run setup menu. Left alone this reads as
# ordinary busy for the full BUSY_TURN_MAX_SECS (one hour) before the
# separate wedge-suspect bound even looks at it. The signature table matches
# each harness's own verified rendered dialog text (see
# .agents/skills/harness-adapters/references/harness/*.md and
# docs/verification/*.md for the evidence), scoped to the exact harness that
# renders it so one adapter's ordinary output can never match another's
# dialog. This is a best-effort backstop, not prevention: it never suppresses
# a real busy verdict once any hook has posted, and it defers to whatever
# harness-specific trust pre-registration already exists (fm-claude-trust.sh)
# to stop the dialog from appearing at all.
#
# The cursor pull source is semantic: it folds
# cursor's own durable per-conversation transcript, which brackets each turn
# with a role:user open and a typed turn_ended close that covers aborts. It has
# no writer, no arm, and no gen, so nothing is seeded that could never be
# cleared. See fm_busy_cursor_turn_state for the fold. Cursor's rendered
# `ctrl+c to stop` footer is deliberately not a state source here.
#
# Sourcing: set -u and set -e safe; no subshell-unfriendly globals.

FM_BUSY_LIB_VERSION=v1

fm_busy_record_path() {  # <state-dir> <id>
  printf '%s/%s.busy-state' "$1" "$2"
}

fm_busy_gen_path() {  # <state-dir> <id>
  printf '%s/%s.busy-gen' "$1" "$2"
}

# Optional Pi model-stream contract. The busy writer owns every mutation under
# its incarnation lock. model-stream is active evidence; model-stream-order
# retains the latest request and active/closed phase after the marker is cleared.
#   order: v1 gen=<token> request=<positive uint> phase=<active|closed>
#   stream / model-progress: v1 gen=<token> request=<uint> rev=<uint> ts=<epoch>
# Requests strictly increase within a generation. Progress/close must match the
# open request; closed and older requests cannot reopen or refresh evidence.
# model-progress is separate from native progress and is read ONLY by opted-in
# watchers. Missing, malformed, locked, idle, foreign, or stale evidence conveys
# no model-phase observation, leaving the general busy bound applicable.
fm_busy_pi_stream_version_supported() {
  [ "${1:-}" = 1.2.0 ]
}

fm_busy_stream_seconds() {  # <configured seconds>; off/invalid prints 0
  local value=${1:-}
  case "$value" in ''|*[!0-9]*) printf '0'; return ;; esac
  [ "${#value}" -le 9 ] || { printf '0'; return; }
  printf '%s' "$((10#$value))"
}

fm_busy_stream_uint_valid() {
  case "${1:-}" in ''|0*|*[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 15 ]
}

fm_busy_stream_order_read() {  # <state-dir> <id>
  local line version gen request phase extra
  line=$(cat "$1/$2.model-stream-order" 2>/dev/null) || return 1
  read -r version gen request phase extra <<< "$line"
  [ "$version" = v1 ] && [ -z "$extra" ] || return 1
  gen=${gen#gen=} request=${request#request=} phase=${phase#phase=}
  fm_busy_token_valid "$gen" && fm_busy_stream_uint_valid "$request" || return 1
  case "$phase" in active|closed) : ;; *) return 1 ;; esac
  [ "$line" = "v1 gen=$gen request=$request phase=$phase" ] || return 1
  printf '%s %s %s' "$gen" "$request" "$phase"
}

fm_busy_stream_record_read() {  # <record path>
  local line version gen request rev ts extra
  line=$(cat "$1" 2>/dev/null) || return 1
  read -r version gen request rev ts extra <<< "$line"
  [ "$version" = v1 ] && [ -z "$extra" ] || return 1
  gen=${gen#gen=} request=${request#request=} rev=${rev#rev=} ts=${ts#ts=}
  fm_busy_token_valid "$gen" && fm_busy_stream_uint_valid "$request" &&
    fm_busy_stream_uint_valid "$rev" && fm_busy_stream_uint_valid "$ts" || return 1
  [ "$line" = "v1 gen=$gen request=$request rev=$rev ts=$ts" ] || return 1
  printf '%s %s %s %s' "$gen" "$request" "$rev" "$ts"
}

fm_busy_stream_read() {  # <state-dir> <id> <harness>; gen request rev ts
  local state=$1 id=$2 harness=$3 snapshot gen request rev ts order current
  case "$harness" in pi) : ;; *) return 1 ;; esac
  [ ! -e "$state/$id.busy-state.lock" ] || return 1
  current=$(fm_busy_current_gen "$state" "$id") || return 1
  order=$(fm_busy_stream_order_read "$state" "$id") || return 1
  snapshot=$(fm_busy_stream_record_read "$state/$id.model-stream") || return 1
  read -r gen request rev ts <<< "$snapshot"
  [ "$gen" = "$current" ] && [ "$order" = "$gen $request active" ] || return 1
  case "$(fm_busy_record_read "$state" "$id")" in 'busy pi-ext '*) : ;; *) return 1 ;; esac
  [ ! -e "$state/$id.busy-state.lock" ] &&
    [ "$(fm_busy_current_gen "$state" "$id")" = "$current" ] &&
    [ "$(fm_busy_stream_order_read "$state" "$id")" = "$order" ] &&
    [ "$(fm_busy_stream_record_read "$state/$id.model-stream")" = "$snapshot" ] || return 1
  printf '%s' "$snapshot"
}

fm_busy_model_progress_ts() {  # <state-dir> <id> <harness>
  local snapshot gen request rev ts current
  case "$3" in pi) : ;; *) return 1 ;; esac
  [ ! -e "$1/$2.busy-state.lock" ] || return 1
  current=$(fm_busy_current_gen "$1" "$2") || return 1
  snapshot=$(fm_busy_stream_record_read "$1/$2.model-progress") || return 1
  read -r gen request rev ts <<< "$snapshot"
  [ "$gen" = "$current" ] && [ ! -e "$1/$2.busy-state.lock" ] &&
    [ "$(fm_busy_current_gen "$1" "$2")" = "$current" ] || return 1
  printf '%s' "$ts"
}

# fm_busy_token_valid: conservative token charset shared by gen, source, and
# event fields. Anything else is malformed.
fm_busy_token_valid() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_busy_current_gen: the task's armed gen token, or failure when the busy
# contract has never been armed for this task.
fm_busy_current_gen() {  # <state-dir> <id>
  local gen_file gen
  gen_file=$(fm_busy_gen_path "$1" "$2")
  [ -f "$gen_file" ] || return 1
  IFS= read -r gen < "$gen_file" 2>/dev/null || gen=
  fm_busy_token_valid "$gen" || return 1
  printf '%s' "$gen"
}

# fm_busy_sources_for_harness: the semantic sources trusted to classify a
# task recorded with <harness>. One line, space-separated, possibly empty.
# The firstmate-owned sources are appended for every converted adapter.
fm_busy_sources_for_harness() {  # <harness>
  local adapter=
  case "${1:-}" in
    claude*) adapter=claude-hook ;;
    pi) adapter=pi-ext ;;
    omp) adapter=omp-ext ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s fm-spawn fm-interrupt fm-recovery' "$adapter"
}

fm_busy_source_trusted() {  # <harness> <source>
  local trusted
  trusted=$(fm_busy_sources_for_harness "$1")
  case " $trusted " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# fm_busy_record_read: parse and validate state/<id>.busy-state against the
# armed gen. Prints "<state> <source> <event> <seq>" for a valid record.
# Non-zero returns name the reason on stdout instead:
#   missing      no record file (or no armed gen and no record)
#   malformed    unparseable line, bad tokens, or a missing armed gen for an
#                existing record
#   gen-mismatch a record from a stale incarnation
fm_busy_record_read() {  # <state-dir> <id>
  local state=$1 id=$2 rec gen line extra ver f
  local r_gen='' r_seq='' r_state='' r_source='' r_event='' r_ts=''
  rec=$(fm_busy_record_path "$state" "$id")
  if [ ! -f "$rec" ]; then
    printf 'missing'
    return 1
  fi
  if ! gen=$(fm_busy_current_gen "$state" "$id"); then
    # A record without an armed gen has no incarnation to bind to.
    printf 'malformed'
    return 1
  fi
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$rec" 2>/dev/null || {
    printf 'malformed'
    return 1
  }
  # `read -a` rather than `set --`: it never glob-expands a field and never
  # touches the caller's positional parameters or shell options.
  local -a fields
  IFS=' ' read -r -a fields <<< "$line"
  ver=${fields[0]:-}
  [ "$ver" = "$FM_BUSY_LIB_VERSION" ] || { printf 'malformed'; return 1; }
  for f in "${fields[@]:1}"; do
    case "$f" in
      gen=*) r_gen=${f#gen=} ;;
      seq=*) r_seq=${f#seq=} ;;
      state=*) r_state=${f#state=} ;;
      source=*) r_source=${f#source=} ;;
      event=*) r_event=${f#event=} ;;
      ts=*) r_ts=${f#ts=} ;;
      *) printf 'malformed'; return 1 ;;
    esac
  done
  fm_busy_token_valid "$r_gen" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_source" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_event" || { printf 'malformed'; return 1; }
  case "$r_seq" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_ts" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_state" in busy|idle|unknown) : ;; *) printf 'malformed'; return 1 ;; esac
  if [ "$r_gen" != "$gen" ]; then
    printf 'gen-mismatch'
    return 1
  fi
  printf '%s %s %s %s' "$r_state" "$r_source" "$r_event" "$r_seq"
}

# cursor conversation-transcript busy source
#
# cursor-agent persists an append-only JSONL transcript per conversation at
# <projects-root>/<workspace-slug>/agent-transcripts/<conversation-id>/<id>.jsonl
# and brackets every submitted turn. Verified live on cursor-agent
# 2026.08.11-e8db854:
#   {"role":"user", ...}                                    <- turn opens
#   {"role":"assistant", ...}                               <- work
#   {"type":"turn_ended","status":"success"}                <- turn closes
# An Escape interrupt closes the turn with status "aborted", so unlike
# Claude's Stop hook this source covers the manual interrupt path. Nothing is
# installed and no trust grant is needed: cursor writes this transcript on
# its own.
#
# Resolution deliberately does NOT reconstruct cursor's workspace-slug directory
# name. That slug is a lossy transformation of the workspace path (separators
# collapse), so rebuilding it would be a guess that silently binds the wrong
# pane. cursor writes the exact absolute path into each project directory's
# .workspace-trusted, so the binding matches on that recorded value instead.
#
# fm_busy_cursor_binding_path: the per-task sidecar fm-spawn writes. It records
# projects_root=<abs>, workspace_root=<abs>, and one prior_conversation=<id> for
# each conversation that already existed for that workspace when this pane
# launched, so a relaunched task cannot fold its predecessor's transcript.
fm_busy_cursor_binding_path() {  # <state-dir> <id>
  printf '%s/%s.cursor-session' "$1" "$2"
}

fm_busy_cursor_binding_field() {  # <state-dir> <id> <key>
  local path value
  path=$(fm_busy_cursor_binding_path "$1" "$2")
  [ -f "$path" ] || return 1
  value=$(LC_ALL=C awk -F= -v k="$3" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$path")
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# fm_busy_cursor_project_dir: the project directory whose recorded
# .workspace-trusted workspacePath is exactly <workspace-root>. Exact-match
# only: a prefix or slug comparison would bind a nested worktree to its parent.
fm_busy_cursor_project_dir() {  # <projects-root> <workspace-root>
  local root=$1 want=$2 marker dir path
  [ -d "$root" ] || return 1
  for marker in "$root"/*/.workspace-trusted; do
    [ -f "$marker" ] || continue
    path=$(LC_ALL=C sed -n 's/.*"workspacePath"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' "$marker" | head -1)
    [ -n "$path" ] || continue
    [ "$path" = "$want" ] || continue
    dir=${marker%/.workspace-trusted}
    printf '%s' "$dir"
    return 0
  done
  return 1
}

# fm_busy_cursor_transcript: the ONE transcript this pane owns, or failure.
# A conversation recorded as prior_conversation is excluded, so a relaunch in a
# reused worktree folds its own turn rather than the previous pane's. Requiring
# a UNIQUE remaining conversation is what keeps the binding honest: zero means
# no turn has been submitted yet and several means the pane cannot be told
# apart, and neither proves anything about the current turn.
fm_busy_cursor_transcript() {  # <state-dir> <id>
  local root workspace project dir conv found='' count=0 prior
  root=$(fm_busy_cursor_binding_field "$1" "$2" projects_root) || return 1
  workspace=$(fm_busy_cursor_binding_field "$1" "$2" workspace_root) || return 1
  project=$(fm_busy_cursor_project_dir "$root" "$workspace") || return 1
  prior=$(LC_ALL=C awk -F= '$1 == "prior_conversation" { sub(/^[^=]*=/, ""); print }' \
    "$(fm_busy_cursor_binding_path "$1" "$2")" 2>/dev/null)
  for dir in "$project"/agent-transcripts/*/; do
    [ -d "$dir" ] || continue
    conv=$(basename -- "${dir%/}")
    printf '%s\n' "$prior" | grep -Fqx "$conv" && continue
    [ -f "$dir$conv.jsonl" ] || continue
    found="$dir$conv.jsonl"
    count=$((count + 1))
  done
  [ "$count" = 1 ] && [ -n "$found" ] || return 1
  printf '%s' "$found"
}

# fm_busy_cursor_turn_state: fold the transcript into busy | settled | none.
# Lifecycle records are matched on top-level fields of structurally valid JSON,
# so a turn whose own text mentions turn_ended cannot close it.
fm_busy_cursor_turn_state() {  # <transcript>
  [ -f "$1" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    LC_ALL=C jq -Rr '
      try (
        fromjson
        | if type == "object" and .type? == "turn_ended" then "close"
          elif type == "object" and .role? == "user" then "open"
          else "other"
          end
      ) catch "malformed"
    ' "$1"
  else
    LC_ALL=C awk '
      function ws(    c) {
        while (p <= n) {
          c = substr(line, p, 1)
          if (c != " " && c != "\t" && c != "\r") break
          p++
        }
      }
      function hex(c) {
        if (c >= "0" && c <= "9") return c + 0
        c = tolower(c)
        return index("abcdef", c) + 9
      }
      function string(    c, e, h, i, code, out) {
        if (substr(line, p, 1) != "\"") return 0
        p++; out = ""
        while (p <= n) {
          c = substr(line, p++, 1)
          if (c == "\"") { value = out; kind = "string"; return 1 }
          if (c ~ /[[:cntrl:]]/) return 0
          if (c != "\\") { out = out c; continue }
          if (p > n) return 0
          e = substr(line, p++, 1)
          if (e == "\"" || e == "\\" || e == "/") out = out e
          else if (e ~ /^[bfnrt]$/) out = out "?"
          else if (e == "u") {
            h = substr(line, p, 4)
            if (length(h) != 4 || h !~ /^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/) return 0
            code = 0
            for (i = 1; i <= 4; i++) code = code * 16 + hex(substr(h, i, 1))
            out = out (code < 128 ? sprintf("%c", code) : "?")
            p += 4
          } else return 0
        }
        return 0
      }
      function number(    c) {
        if (substr(line, p, 1) == "-") p++
        c = substr(line, p, 1)
        if (c == "0") {
          p++
          if (substr(line, p, 1) ~ /^[0-9]$/) return 0
        } else if (c ~ /^[1-9]$/) {
          do { p++; c = substr(line, p, 1) } while (c ~ /^[0-9]$/)
        } else return 0
        if (substr(line, p, 1) == ".") {
          p++
          if (substr(line, p, 1) !~ /^[0-9]$/) return 0
          while (substr(line, p, 1) ~ /^[0-9]$/) p++
        }
        c = substr(line, p, 1)
        if (c == "e" || c == "E") {
          p++; c = substr(line, p, 1)
          if (c == "+" || c == "-") p++
          if (substr(line, p, 1) !~ /^[0-9]$/) return 0
          while (substr(line, p, 1) ~ /^[0-9]$/) p++
        }
        kind = "number"; value = ""
        return 1
      }
      function array(depth,    c) {
        p++; ws()
        if (substr(line, p, 1) == "]") { p++; return 1 }
        while (p <= n) {
          if (!json(depth + 1)) return 0
          ws(); c = substr(line, p, 1)
          if (c == "]") { p++; return 1 }
          if (c != ",") return 0
          p++; ws()
        }
        return 0
      }
      function object(depth,    c, key, vkind, vvalue, is_close, is_open) {
        p++; ws()
        if (substr(line, p, 1) == "}") { p++; kind = "object"; return 1 }
        while (p <= n) {
          if (!string()) return 0
          key = value; ws()
          if (substr(line, p, 1) != ":") return 0
          p++; ws()
          if (!json(depth + 1)) return 0
          vkind = kind; vvalue = value
          if (depth == 0 && key == "type") is_close = (vkind == "string" && vvalue == "turn_ended")
          if (depth == 0 && key == "role") is_open = (vkind == "string" && vvalue == "user")
          ws(); c = substr(line, p, 1)
          if (c == "}") {
            p++; kind = "object"; value = ""
            if (depth == 0) event = (is_close ? "close" : (is_open ? "open" : "other"))
            return 1
          }
          if (c != ",") return 0
          p++; ws()
        }
        return 0
      }
      function json(depth,    c, word) {
        ws(); c = substr(line, p, 1)
        if (c == "\"") return string()
        if (c == "{") return object(depth)
        if (c == "[") { kind = "array"; value = ""; return array(depth) }
        if (c == "-" || c ~ /^[0-9]$/) return number()
        word = substr(line, p)
        if (substr(word, 1, 4) == "true" || substr(word, 1, 4) == "null") { p += 4; kind = "literal"; value = ""; return 1 }
        if (substr(word, 1, 5) == "false") { p += 5; kind = "literal"; value = ""; return 1 }
        return 0
      }
      {
        line = $0; p = 1; n = length(line); event = "other"; kind = ""; value = ""
        valid = json(0); ws()
        print (valid && p > n ? event : "malformed")
      }
    ' "$1"
  fi | LC_ALL=C awk '
    $0 == "close" { open = 0; seen = 1; malformed = 0; next }
    $0 == "open" { open = 1; seen = 1; next }
    $0 == "malformed" { if (!open) malformed = 1; next }
    END {
      if (!seen || (!open && malformed)) { print "none"; exit }
      print (open ? "busy" : "settled")
    }
  '
}


# --- launch-prompt signatures (fm_busy_launch_prompt_parked) ----------------
#
# Each function consumes a captured pane tail on stdin (the caller's whole
# tail40): a bordered dialog box renders many short lines of
# pure border/padding (`│  ...  │`) that are NOT whitespace-only, so a 12-line
# non-blank reduction was verified live to push the box's own heading text
# (e.g. Gemini's "How would you like to authenticate for this project?")
# outside the window entirely, silently defeating the match. Matching the
# full capture avoids that trap; a signature is still best-effort exactly like
# the footer fallbacks - a screen taller than the capture can still scroll a
# signature out, so absence never proves the pane is NOT parked, only that
# this check cannot confirm it.

# fm_busy_claude_launch_prompt_tail: Claude's workspace-trust dialog
# ("Quick safety check: Is this a project you created or one you trust?",
# re-verified live on Claude Code 2.1.278, docs/verification/runtime-backends.md
# "Launch-prompt backstop signatures") and its separate external-CLAUDE.md-
# imports dialog ("Allow external CLAUDE.md file imports?", verified by
# disassembly, .agents/skills/harness-adapters/references/harness/claude.md
# "Hook trust" sibling section). fm-claude-trust.sh pre-registers both before
# launch; this is the backstop for when that registration did not take effect.
# Each dialog's own question text is paired with one of its own rendered
# option/footer lines, both required together: the question text alone is
# plausible self-referential prose a firstmate-repo worker could easily render
# on its own (fm-claude-trust.sh's header literally quotes both questions),
# but the option/footer pairing only ever renders inside the real dialog.
fm_busy_claude_launch_prompt_tail() {
  local buf
  buf=$(cat)
  if printf '%s' "$buf" | grep -qiE "${FM_BUSY_CLAUDE_TRUST_PROMPT_REGEX:-Quick safety check: Is this a project you created or one you trust\\?}" \
    && printf '%s' "$buf" | grep -qiE 'No, exit|Enter to confirm'; then
    return 0
  fi
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_CLAUDE_IMPORTS_PROMPT_REGEX:-Allow external CLAUDE\\.md file imports\\?}" \
    && printf '%s' "$buf" | grep -qiE 'No, disable external imports|Yes, allow external imports'
}

# fm_busy_pi_launch_prompt_tail: Pi's project-trust dialog. Live-verified on
# pi 0.86.1 (2026-09-22) in a fresh untrusted worktree carrying a project-local
# .pi/extensions/ file (the shape a real ship/scout spawn always launches
# into): the rendered heading is "Trust project folder?" and its declining
# option is literally "Do not trust". An initial guess sourced only from the
# installed binary's UI strings ("Project trust", the internal panel-title
# component name, not this dialog's own rendered heading) was proven wrong by
# that live run and never matched the real screen - which is exactly why this
# class of check must be proven end to end rather than read off strings or a
# name. Matching BOTH the heading and "Do not trust" keeps this from firing on
# a worker's own prose that happens to use the common word "trust" alone.
# Covers omp too: it shares Pi's engine and the same project-trust gate.
fm_busy_pi_launch_prompt_tail() {
  local buf
  buf=$(cat)
  printf '%s' "$buf" | grep -qiE "${FM_BUSY_PI_LAUNCH_PROMPT_REGEX:-Trust project folder\\?}" \
    && printf '%s' "$buf" | grep -qiE 'Do not trust'
}


# fm_busy_launch_prompt_parked: dispatch to the signature above for <harness>,
# or fail when this harness has none. Consumes the tail on stdin. Scoped to
# exactly the harnesses fm-spawn.sh arms with the fm-spawn busy source
# (claude*, pi, omp) since only those can ever read a pinned "busy fm-spawn"
# record.
fm_busy_launch_prompt_parked() {  # <harness>
  case "${1:-}" in
    claude*) fm_busy_claude_launch_prompt_tail ;;
    pi | omp) fm_busy_pi_launch_prompt_tail ;;
    *) return 1 ;;
  esac
}

# fm_busy_classify: semantic classification for a task whose endpoint the
# caller has already established as present. Prints "<verdict> <source>":
# busy|idle|unknown plus the producing source (see header). Never probes
# process state. <tail40> is optional pre-captured plain output; the
# launch-prompt backstop below has no capture fallback of its own - without a
# supplied tail40 it is skipped entirely and a record still pinned at the
# fm-spawn seed keeps reading busy fm-spawn, unchanged.
fm_busy_classify() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 tail40=${6-}
  local out rc r_state r_source native log
  case "$harness" in
    cursor*)
      # Semantic, on demand: fold this task's bound conversation transcript. A
      # turn open past its last close is positive proof of a turn in flight and
      # a trailing turn_ended is a finished turn. Every other outcome - no
      # sidecar, no resolvable transcript, an unreadable or record-free file -
      # is unknown, never idle. The rendered `ctrl+c to stop` footer is
      # deliberately NOT consulted here; see the source note above.
      if ! log=$(fm_busy_cursor_transcript "$state" "$id"); then
        printf 'unknown cursor-transcript'
        return 0
      fi
      case "$(fm_busy_cursor_turn_state "$log" 2>/dev/null)" in
        busy) printf 'busy cursor-transcript' ;;
        settled) printf 'idle cursor-transcript' ;;
        *) printf 'unknown cursor-transcript' ;;
      esac
      return 0
      ;;
  esac
  out=$(fm_busy_record_read "$state" "$id") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    r_state=${out%% *}
    out=${out#* }
    r_source=${out%% *}
    if fm_busy_source_trusted "$harness" "$r_source"; then
      if [ "$r_state" = busy ] && [ "$r_source" = fm-spawn ] && [ -n "$tail40" ] \
        && printf '%s' "$tail40" | fm_busy_launch_prompt_parked "$harness"; then
        printf 'unknown launch-prompt'
      else
        printf '%s %s' "$r_state" "$r_source"
      fi
    else
      printf 'unknown source-mismatch'
    fi
    return 0
  fi
  case "$out" in
    malformed|gen-mismatch)
      printf 'unknown %s' "$out"
      return 0
      ;;
  esac
  # No record at all. A native herdr busy verdict is semantic enough to trust
  # for BUSY (streaming means a turn is running); native idle is narrower than
  # turn state (a long foreground tool call reads idle) and stays unknown here.
  case "$backend" in
    herdr)
      if command -v fm_backend_busy_state >/dev/null 2>&1; then
        native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
        if [ "$native" = busy ]; then
          printf 'busy %s-native' "$backend"
          return 0
        fi
      fi
      ;;
  esac
  printf 'unknown missing'
}

# fm_busy_classify_live: fm_busy_classify behind the one process-level
# override - a gone endpoint is dead, never busy. Requires fm-backend.sh to
# be sourced for fm_backend_target_exists.
fm_busy_classify_live() {  # <backend> <target> <harness> <id> <state-dir> [expected-label]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 label=${6-}
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  if ! fm_backend_target_exists "$backend" "$target" "$label" 2>/dev/null; then
    printf 'dead endpoint-gone'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state"
}

# fm_busy_classify_meta: classify a task from its recorded metadata, so every
# consumer resolves backend, target, and harness the same way instead of
# re-deriving them. Requires fm-backend.sh to be sourced. <tail40> is
# optional pre-captured plain output reused by the contract's rendered-text
# checks: the Grok/Rovo/AGY busy fallbacks and the launch-prompt backstop.
fm_busy_classify_meta() {  # <meta-file> <id> <state-dir> [tail40]
  local meta=$1 id=$2 state=$3 tail40=${4-} backend target harness
  [ -f "$meta" ] || { printf 'unknown missing'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state" "$tail40"
}

# fm_busy_is_busy: boolean activity guard. Every unknown source, idle, and
# dead return 1.
fm_busy_is_busy() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local verdict
  verdict=$(fm_busy_classify "$@")
  case "$verdict" in
    busy\ *) return 0 ;;
    *) return 1 ;;
  esac
}
