#!/usr/bin/env bash
# session-state-unarmed-offer.test.sh — proves .quetrex/plan/ONE-COPY.json's
# AC13: a git repo with NO .quetrex/project.json (never armed, or not yet
# initialized) gets exactly one offer line from session-state.sh on
# SessionStart, on every source (startup/resume/compact), and nothing else.
#
# WHY THIS MATTERS. session-state.sh used to gate on `[ -d .quetrex ]` — a
# directory, not the arming artifact. A repo that has never run
# /quetrex:init (no .quetrex/ at all) got total silence: no briefing, no
# nudge, nothing telling the operator the pipeline exists. This is the ONE-
# COPY task's ITEM 5: the SessionStart hook now offers /quetrex:init exactly
# once per session-start source, in plain text (SessionStart output is added
# to context, so no JSON envelope is required).
#
# EVERY ASSERTION DRIVES THE SHIPPED SCRIPT
# .claude/hooks/session-state.sh end to end via its real SessionStart stdin
# payload (QX_SESSION_STATE_HOOK overrides the target for the fail-first
# section below).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_SESSION_STATE_HOOK:-$ROOT/.claude/hooks/session-state.sh}"
EXPECTED='Quetrex: this repo is not armed (no .quetrex/project.json). Offer the user /quetrex:init; if they say yes, run it.'

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

if [ ! -f "$HOOK" ]; then
  echo "NOT OK - session-state.sh not found at $HOOK"
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

# Deliberately WITHOUT CLAUDE_PROJECT_DIR: session-state.sh's own
# CLAUDE_PROJECT_DIR branch falls back to that literal directory even when
# `git rev-parse` fails inside it (a trusted-context fallback, correct for a
# real Claude Code session where CLAUDE_PROJECT_DIR is always the real
# project root). Testing "not a git repo at all" therefore means a payload
# that carries ONLY .cwd, exactly like a real hook invocation with no
# CLAUDE_PROJECT_DIR exported.
fire_no_project_dir() {  # fire_no_project_dir <hook> <dir> <source> -> stdout
  local hook="$1" dir="$2" source="$3"
  ( cd "$dir" && env -u CLAUDE_PROJECT_DIR \
      bash "$hook" "$source" <<<"$(printf '{"hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$source" "$dir")" 2>/dev/null )
}

# =============================================================================
# AC13(a) — an UNARMED git repo (no .quetrex/project.json) prints EXACTLY the
# one offer line, byte-identical, on all three SessionStart sources.
# =============================================================================
UNARMED="$TMP/unarmed"; mkdir -p "$UNARMED"
git -C "$UNARMED" init -q -b main 2>/dev/null || git -C "$UNARMED" init -q 2>/dev/null
git -C "$UNARMED" config user.email t@t; git -C "$UNARMED" config user.name t
git -C "$UNARMED" commit -q --allow-empty -m init

for src in startup resume compact; do
  OUT="$(fire "$HOOK" "$UNARMED" "$src")"
  LINES=$(printf '%s\n' "$OUT" | grep -c .)
  if [ "$OUT" = "$EXPECTED" ]; then
    ok "AC13: source=$src stdout is byte-identical to the unarmed-offer string"
  else
    notok "AC13: source=$src stdout does not match the unarmed-offer string exactly (got: [$OUT])"
  fi
  [ "$LINES" -eq 1 ] \
    && ok "AC13: source=$src stdout is exactly 1 line" \
    || notok "AC13: source=$src expected exactly 1 line, got $LINES (out: [$OUT])"
done

# =============================================================================
# AC13(b) — a directory that is not a git repo at all prints 0 lines (the
# existing ROOT-resolution short-circuit; the arming check must never be
# reached before it, and never emit anything of its own in this case).
# =============================================================================
NOTGIT="$TMP/not-a-repo"; mkdir -p "$NOTGIT"
OUT_NOTGIT="$(fire_no_project_dir "$HOOK" "$NOTGIT" startup)"
BYTES_NOTGIT=$(printf '%s' "$OUT_NOTGIT" | wc -c | tr -d ' ')
[ "$BYTES_NOTGIT" -eq 0 ] \
  && ok "AC13: a non-git directory prints 0 bytes (not even the unarmed offer)" \
  || notok "AC13: a non-git directory printed something (out: [$OUT_NOTGIT])"

# =============================================================================
# AC13(c) — an ARMED repo (.quetrex/project.json present) prints ZERO
# occurrences of "not armed" and still emits its existing [quetrex-state]
# briefing (>= 1 line) — the new gate must not regress the armed path.
# =============================================================================
ARMED="$TMP/armed"; mkdir -p "$ARMED/.quetrex"
git -C "$ARMED" init -q -b main 2>/dev/null || git -C "$ARMED" init -q 2>/dev/null
git -C "$ARMED" config user.email t@t; git -C "$ARMED" config user.name t
echo '{"code":"QUE"}' > "$ARMED/.quetrex/project.json"
git -C "$ARMED" add -A; git -C "$ARMED" commit -q -m init

OUT_ARMED="$(fire "$HOOK" "$ARMED" startup)"
LINES_ARMED=$(printf '%s\n' "$OUT_ARMED" | grep -c .)
printf '%s' "$OUT_ARMED" | grep -q 'not armed' \
  && notok "AC13: an ARMED repo incorrectly printed 'not armed' (out: [$OUT_ARMED])" \
  || ok "AC13: an ARMED repo prints 0 occurrences of 'not armed'"
[ "$LINES_ARMED" -ge 1 ] && printf '%s' "$OUT_ARMED" | grep -q '\[quetrex-state\]' \
  && ok "AC13: an ARMED repo still emits its existing [quetrex-state] briefing (>= 1 line)" \
  || notok "AC13: an ARMED repo did not emit the expected [quetrex-state] briefing (out: [$OUT_ARMED])"

# =============================================================================
# FAIL-FIRST (mechanical, per .claude/CLAUDE.md and AC9 of ONE-COPY.json):
# the SAME unarmed fixture and SAME sources, driven against the immediately
# PRE-change session-state.sh (40feac8 — main's tip before this task), must
# NOT produce the unarmed-offer line. That script's old gate was `[ -d
# .quetrex ]`, and this fixture has no .quetrex/ directory at all, so the old
# script exits silently — proving the offer is genuinely new behavior, not
# something the old script already did under a different name.
#
# `git show <sha>:<path>` exits non-zero for TWO different reasons: the path
# is absent at that sha, or the sha itself is unreachable (e.g. a shallow
# clone — the checkout shape a cloud routine uses). Self-heal with a depth-1
# fetch of that EXACT sha (never a moving ref) before giving up. Fetch by the
# FULL 40-char object id, not the 7-char abbreviation: a git server only
# honors a direct commit fetch for an exact, full object id
# (uploadpack.allowReachableSHA1InWant).
# =============================================================================
BASELINE_SHA="40feac8"
BASELINE_SHA_FULL="40feac8e99ce47c22356651fabbd2695264605a5"
if ! git -C "$ROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
  git -C "$ROOT" fetch --quiet --depth=1 origin "$BASELINE_SHA_FULL" 2>/dev/null || true
fi
if git -C "$ROOT" cat-file -e "${BASELINE_SHA}:.claude/hooks/session-state.sh" 2>/dev/null; then
  BASELINE="$TMP/baseline-session-state.sh"
  git -C "$ROOT" show "${BASELINE_SHA}:.claude/hooks/session-state.sh" > "$BASELINE"
  BASE_OUT="$(fire "$BASELINE" "$UNARMED" startup)"
  BASE_BYTES=$(printf '%s' "$BASE_OUT" | wc -c | tr -d ' ')
  if [ "$BASE_OUT" = "$EXPECTED" ]; then
    notok "FAIL-FIRST: the pre-change baseline ($BASELINE_SHA) unexpectedly ALREADY prints the unarmed-offer string — cannot demonstrate this is new behavior"
  elif [ "$BASE_BYTES" -eq 0 ]; then
    ok "FAIL-FIRST: the pre-change baseline ($BASELINE_SHA) prints 0 bytes for the same unarmed fixture (its \`[ -d .quetrex ]\` gate silently exits before ever reaching this behavior) — proving the offer is genuinely new"
  else
    notok "FAIL-FIRST: the pre-change baseline produced unexpected non-empty, non-matching output (bytes=$BASE_BYTES [$BASE_OUT]) — ambiguous, cannot cleanly demonstrate the fix"
  fi
else
  notok "FAIL-FIRST: baseline commit ${BASELINE_SHA} (or the path at it) is not reachable even after \`git fetch --depth=1 origin ${BASELINE_SHA_FULL}\` — refusing to report a pass having compared against nothing"
fi

echo
echo "session-state-unarmed-offer.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
