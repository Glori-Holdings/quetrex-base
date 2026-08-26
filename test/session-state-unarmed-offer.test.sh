#!/usr/bin/env bash
# session-state-unarmed-offer.test.sh — proves the split of ONE-COPY.json's
# AC13 offer behaviour across the two SessionStart hooks the setup-plugin
# split produced:
#
#   * plugins/quetrex-setup/scripts/unarmed-offer.sh (quetrex-setup, enabled
#     machine-wide) now OWNS the offer: a git repo with NO
#     .quetrex/project.json (never armed, or not yet initialized) gets
#     exactly one offer line, on every SessionStart source
#     (startup/resume/compact), naming /quetrex-setup:init; an ARMED repo or a
#     non-git directory gets 0 bytes.
#   * .claude/hooks/session-state.sh (`quetrex`, loaded only once armed) keeps
#     ONLY the armed half: silent (0 bytes) when unarmed, and its existing
#     [quetrex-state] briefing (plus ESCALATION-first ordering) when armed.
#
# WHY THIS MATTERS. session-state.sh used to gate on `[ -d .quetrex ]` — a
# directory, not the arming artifact — and used to own the unarmed offer
# itself. Both defects are fixed the same way responsibility now is: one
# script per repo state, no directory-only gate, and the offer follows the
# operator into every repo on the machine instead of only repos that already
# loaded `quetrex`.
#
# EVERY ASSERTION DRIVES THE SHIPPED SCRIPTS end to end via a real
# SessionStart stdin payload (QX_UNARMED_OFFER_HOOK / QX_SESSION_STATE_HOOK
# override the targets for the fail-first section below).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OFFER_HOOK="${QX_UNARMED_OFFER_HOOK:-$ROOT/plugins/quetrex-setup/scripts/unarmed-offer.sh}"
STATE_HOOK="${QX_SESSION_STATE_HOOK:-$ROOT/.claude/hooks/session-state.sh}"
EXPECTED='Quetrex: this repo is not armed (no .quetrex/project.json). Offer the user /quetrex-setup:init; if they say yes, run it.'

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

if [ ! -f "$OFFER_HOOK" ]; then
  echo "NOT OK - unarmed-offer.sh not found at $OFFER_HOOK"
  echo
  echo "session-state-unarmed-offer.test.sh: 0 passed, 1 failed"
  exit 1
fi
if [ ! -f "$STATE_HOOK" ]; then
  echo "NOT OK - session-state.sh not found at $STATE_HOOK"
  echo
  echo "session-state-unarmed-offer.test.sh: 0 passed, 1 failed"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fire() {  # fire <hook> <repo> <source> -> stdout
  local hook="$1" repo="$2" source="$3"
  ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" \
      bash "$hook" "$source" <<<"$(printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$source" "$repo")" 2>/dev/null )
}

# Deliberately WITHOUT CLAUDE_PROJECT_DIR: both hooks' own CLAUDE_PROJECT_DIR
# branch falls back to that literal directory even when `git rev-parse` fails
# inside it (a trusted-context fallback, correct for a real Claude Code
# session where CLAUDE_PROJECT_DIR is always the real project root). Testing
# "not a git repo at all" therefore means a payload that carries ONLY .cwd,
# exactly like a real hook invocation with no CLAUDE_PROJECT_DIR exported.
fire_no_project_dir() {  # fire_no_project_dir <hook> <dir> <source> -> stdout
  local hook="$1" dir="$2" source="$3"
  ( cd "$dir" && env -u CLAUDE_PROJECT_DIR \
      bash "$hook" "$source" <<<"$(printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$source" "$dir")" 2>/dev/null )
}

UNARMED="$TMP/unarmed"; mkdir -p "$UNARMED"
git -C "$UNARMED" init -q -b main 2>/dev/null || git -C "$UNARMED" init -q 2>/dev/null
git -C "$UNARMED" config user.email t@t; git -C "$UNARMED" config user.name t
git -C "$UNARMED" commit -q --allow-empty -m init

ARMED="$TMP/armed"; mkdir -p "$ARMED/.quetrex"
git -C "$ARMED" init -q -b main 2>/dev/null || git -C "$ARMED" init -q 2>/dev/null
git -C "$ARMED" config user.email t@t; git -C "$ARMED" config user.name t
echo '{"code":"QUE"}' > "$ARMED/.quetrex/project.json"
git -C "$ARMED" add -A; git -C "$ARMED" commit -q -m init

NOTGIT="$TMP/not-a-repo"; mkdir -p "$NOTGIT"

# =============================================================================
# AC9 — unarmed-offer.sh (quetrex-setup): exactly the one offer line in an
# UNARMED git repo on all three sources; 0 bytes in an ARMED repo; 0 bytes in
# a non-git directory. Exit 0 in every case.
# =============================================================================
for src in startup resume compact; do
  OUT="$(fire "$OFFER_HOOK" "$UNARMED" "$src")"; RC=$?
  LINES=$(printf '%s\n' "$OUT" | grep -c .)
  [ "$RC" -eq 0 ] && ok "AC9: unarmed-offer.sh source=$src exits 0" \
    || notok "AC9: unarmed-offer.sh source=$src expected exit 0, got $RC"
  if [ "$OUT" = "$EXPECTED" ]; then
    ok "AC9: unarmed-offer.sh source=$src stdout is byte-identical to the unarmed-offer string"
  else
    notok "AC9: unarmed-offer.sh source=$src stdout does not match the unarmed-offer string exactly (got: [$OUT])"
  fi
  [ "$LINES" -eq 1 ] \
    && ok "AC9: unarmed-offer.sh source=$src stdout is exactly 1 line" \
    || notok "AC9: unarmed-offer.sh source=$src expected exactly 1 line, got $LINES (out: [$OUT])"
done

OUT_ARMED_OFFER="$(fire "$OFFER_HOOK" "$ARMED" startup)"; RC_ARMED_OFFER=$?
BYTES_ARMED_OFFER=$(printf '%s' "$OUT_ARMED_OFFER" | wc -c | tr -d ' ')
[ "$RC_ARMED_OFFER" -eq 0 ] && [ "$BYTES_ARMED_OFFER" -eq 0 ] \
  && ok "AC9: unarmed-offer.sh on an ARMED repo prints 0 bytes and exits 0" \
  || notok "AC9: unarmed-offer.sh on an ARMED repo expected 0 bytes/exit 0, got bytes=$BYTES_ARMED_OFFER rc=$RC_ARMED_OFFER (out: [$OUT_ARMED_OFFER])"

OUT_NOTGIT_OFFER="$(fire_no_project_dir "$OFFER_HOOK" "$NOTGIT" startup)"; RC_NOTGIT_OFFER=$?
BYTES_NOTGIT_OFFER=$(printf '%s' "$OUT_NOTGIT_OFFER" | wc -c | tr -d ' ')
[ "$RC_NOTGIT_OFFER" -eq 0 ] && [ "$BYTES_NOTGIT_OFFER" -eq 0 ] \
  && ok "AC9: unarmed-offer.sh on a non-git directory prints 0 bytes and exits 0" \
  || notok "AC9: unarmed-offer.sh on a non-git directory expected 0 bytes/exit 0, got bytes=$BYTES_NOTGIT_OFFER rc=$RC_NOTGIT_OFFER (out: [$OUT_NOTGIT_OFFER])"

# =============================================================================
# AC10 — session-state.sh (armed half only): UNARMED git repo -> 0 bytes, exit
# 0 (the offer is no longer this script's job); ARMED repo -> stdout contains
# '[quetrex-state]'; ARMED repo with .quetrex/ESCALATION -> stdout contains
# 'ESCALATION IS ACTIVE' AND that line precedes the task/plan lines.
# =============================================================================
OUT_UNARMED_STATE="$(fire "$STATE_HOOK" "$UNARMED" startup)"; RC_UNARMED_STATE=$?
BYTES_UNARMED_STATE=$(printf '%s' "$OUT_UNARMED_STATE" | wc -c | tr -d ' ')
[ "$RC_UNARMED_STATE" -eq 0 ] && [ "$BYTES_UNARMED_STATE" -eq 0 ] \
  && ok "AC10: session-state.sh on an UNARMED repo prints 0 bytes and exits 0 (silent — no longer offers)" \
  || notok "AC10: session-state.sh on an UNARMED repo expected 0 bytes/exit 0, got bytes=$BYTES_UNARMED_STATE rc=$RC_UNARMED_STATE (out: [$OUT_UNARMED_STATE])"
printf '%s' "$OUT_UNARMED_STATE" | grep -q 'not armed' \
  && notok "AC10: session-state.sh on an UNARMED repo incorrectly printed 'not armed' — that responsibility moved to unarmed-offer.sh (out: [$OUT_UNARMED_STATE])" \
  || ok "AC10: session-state.sh on an UNARMED repo does not print the (now unarmed-offer.sh-owned) 'not armed' line"

OUT_ARMED_STATE="$(fire "$STATE_HOOK" "$ARMED" startup)"
LINES_ARMED_STATE=$(printf '%s\n' "$OUT_ARMED_STATE" | grep -c .)
[ "$LINES_ARMED_STATE" -ge 1 ] && printf '%s' "$OUT_ARMED_STATE" | grep -q '\[quetrex-state\]' \
  && ok "AC10: session-state.sh on an ARMED repo still emits its existing [quetrex-state] briefing (>= 1 line)" \
  || notok "AC10: session-state.sh on an ARMED repo did not emit the expected [quetrex-state] briefing (out: [$OUT_ARMED_STATE])"

# --- ARMED repo with a live ESCALATION marker: it must lead, not follow -----
# A task + plan are also seeded so the "task:"/"plan:" lines actually exist to
# order against — an escalation with nothing after it would make the ordering
# assertion vacuously true.
ESC_DIR="$TMP/armed-escalation"; mkdir -p "$ESC_DIR/.quetrex/plan"
git -C "$ESC_DIR" init -q -b main 2>/dev/null || git -C "$ESC_DIR" init -q 2>/dev/null
git -C "$ESC_DIR" config user.email t@t; git -C "$ESC_DIR" config user.name t
echo '{"code":"QUE"}' > "$ESC_DIR/.quetrex/project.json"
echo '{"reason":"bounded loop hit its cap"}' > "$ESC_DIR/.quetrex/ESCALATION"
echo '{"task":"QUE-1"}' > "$ESC_DIR/.quetrex/state.json"
echo '{"workstreams":[]}' > "$ESC_DIR/.quetrex/plan/QUE-1.json"
git -C "$ESC_DIR" add -A; git -C "$ESC_DIR" commit -q -m init

OUT_ESC="$(fire "$STATE_HOOK" "$ESC_DIR" startup)"
ESC_LINE=$(printf '%s\n' "$OUT_ESC" | grep -n 'ESCALATION IS ACTIVE' | head -1 | cut -d: -f1)
TASK_PLAN_LINE=$(printf '%s\n' "$OUT_ESC" | grep -n '^\s*\(task\|plan\):' | head -1 | cut -d: -f1)
if [ -n "$ESC_LINE" ]; then
  ok "AC10: an ARMED repo with a live ESCALATION marker contains 'ESCALATION IS ACTIVE'"
else
  notok "AC10: an ARMED repo with a live ESCALATION marker did not contain 'ESCALATION IS ACTIVE' (out: [$OUT_ESC])"
fi
if [ -n "$ESC_LINE" ] && [ -n "$TASK_PLAN_LINE" ] && [ "$ESC_LINE" -lt "$TASK_PLAN_LINE" ]; then
  ok "AC10: the ESCALATION line precedes the task/plan lines"
else
  notok "AC10: the ESCALATION line does not precede the task/plan lines (ESC_LINE=$ESC_LINE TASK_PLAN_LINE=$TASK_PLAN_LINE, out: [$OUT_ESC])"
fi

# =============================================================================
# FAIL-FIRST (mechanical, per .claude/CLAUDE.md): the SAME unarmed fixture and
# SAME source, driven against the PRE-change session-state.sh at this branch's
# merge-base (1032770), must PRINT the unarmed-offer line — proving the offer
# really did live in session-state.sh before this split, and that the
# post-change session-state.sh genuinely stopped emitting it (moved to
# unarmed-offer.sh, not merely duplicated).
#
# `git show <sha>:<path>` exits non-zero for TWO different reasons: the path
# is absent at that sha, or the sha itself is unreachable (e.g. a shallow
# clone). Self-heal with a depth-1 fetch of the EXACT full sha before giving
# up; report NOT OK, never a silent pass, if it still cannot be reached.
# =============================================================================
BASELINE_SHA="1032770"
BASELINE_SHA_FULL="103277068712700cbea040efccfef91a19e8904c"
if ! git -C "$ROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
  git -C "$ROOT" fetch --quiet --depth=1 origin "$BASELINE_SHA_FULL" 2>/dev/null || true
fi
if git -C "$ROOT" cat-file -e "${BASELINE_SHA}:.claude/hooks/session-state.sh" 2>/dev/null; then
  BASELINE="$TMP/baseline-session-state.sh"
  git -C "$ROOT" show "${BASELINE_SHA}:.claude/hooks/session-state.sh" > "$BASELINE"
  BASE_OUT="$(fire "$BASELINE" "$UNARMED" startup)"
  if [ "$BASE_OUT" = "$EXPECTED" ] || printf '%s' "$BASE_OUT" | grep -q 'not armed'; then
    ok "FAIL-FIRST: the pre-change baseline ($BASELINE_SHA) session-state.sh DOES print the unarmed-offer line for the same fixture — proving the offer genuinely lived here before the split"
  else
    notok "FAIL-FIRST: the pre-change baseline ($BASELINE_SHA) session-state.sh did NOT print the unarmed-offer line (out: [$BASE_OUT]) — cannot demonstrate the split actually moved anything"
  fi
else
  notok "FAIL-FIRST: baseline commit ${BASELINE_SHA} (or the path at it) is not reachable even after \`git fetch --depth=1 origin ${BASELINE_SHA_FULL}\` — refusing to report a pass having compared against nothing"
fi

# The post-change script (already exercised above as OUT_UNARMED_STATE) must
# be silent for the identical fixture — restated here beside the baseline
# comparison so the fail-first pairing reads as one unit.
if [ "$BYTES_UNARMED_STATE" -eq 0 ]; then
  ok "FAIL-FIRST: the post-change session-state.sh prints 0 bytes for the identical unarmed fixture — the offer genuinely moved, it was not merely duplicated"
else
  notok "FAIL-FIRST: the post-change session-state.sh unexpectedly printed something for the unarmed fixture (out: [$OUT_UNARMED_STATE]) — the offer was not actually removed from this script"
fi

echo
echo "session-state-unarmed-offer.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
