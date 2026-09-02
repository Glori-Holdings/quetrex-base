#!/usr/bin/env bash
# test/deny-guard-self-contained-fallback.test.sh — SEC-QUE1-1 FOLLOWUP
# (task QUE-1, orchestrator-reported 2026-09-01): deny-guard.sh referenced
# qx_normalize_path 8-9 times but never defined it, and its own sourcing
# fallback (for when plugins/quetrex-factory/scripts/qx-armed.sh cannot be
# found next to it — a non-standard install layout, a marketplace clone
# missing a file, or simply running the script in isolation) defined a
# fallback ONLY for qx_repo_armed, never for qx_normalize_path.
#
# EXECUTED, both against the pre-existing SHIPPED code (58609c3 — this bug
# PRE-DATES the transcript-protection task and is not new to it) and
# against the standalone scratch copy this task produced before this fix:
# run deny-guard.sh with no qx-armed.sh sibling, in an ARMED repo, against
# an EXISTING kill-switch rule (`mv .quetrex/project.json /tmp/x`) — bash
# printed "qx_normalize_path: command not found" to stderr, the broken
# command substitution silently resolved the checked path to an EMPTY
# string, nothing matched, and the write that should have been denied was
# ALLOWED (exit 0). A safety-floor script whose one missing helper turns a
# DENY into a silent ALLOW, while also leaking a raw interpreter error to
# the operator, is doubly wrong — this repo's own rule is that a hook must
# NEVER surface a raw interpreter stack trace, and a floor guard must NEVER
# fail open on a missing dependency.
#
# THE FIX, two layers:
#   1. deny-guard.sh's sourcing-failure fallback now ALSO defines
#      qx_normalize_path (a verbatim, dedent-identical copy of qx-armed.sh's
#      canonical definition — the SAME "duplicate verbatim, pin with a
#      parity test" convention this repo already uses for
#      split_segments_quote_aware/normalize_segment across merge-gate.sh,
#      protected-files-guard.sh and verify-gate-quick-chain.sh). This is
#      now the THIRD copy of qx_normalize_path (qx-armed.sh is canonical;
#      protected-files-guard.sh already carried an identical fallback).
#   2. A DEFENSIVE FLOOR immediately below: if either qx_repo_armed or
#      qx_normalize_path is STILL unavailable after that fallback (should
#      never happen, but a safety floor never depends on "should"), the
#      hook denies with ONE clean, labelled reason and exits — never
#      reaching a call to an undefined function.
#
# Run: bash test/deny-guard-self-contained-fallback.test.sh
#
# FAIL-FIRST (baseline pinned to the fixed sha 58609c3, never `main`): the
# pre-existing shipped deny-guard.sh at 58609c3, run standalone (no
# qx-armed.sh sibling — see AC5 below), fails open on the SAME pre-existing
# kill-switch rule this file already ships and tests elsewhere.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
QX_ARMED_SRC="${QX_ARMED_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/qx-armed.sh}"
BASELINE_SHA="58609c3"
BASELINE_SHA_FULL="58609c3e7d611340e91e07c8517bcb45a96c2e2a"

[ -f "$DENY_GUARD" ] || { echo "FAIL: hook not found at $DENY_GUARD"; exit 1; }
[ -f "$QX_ARMED_SRC" ] || { echo "FAIL: qx-armed.sh not found at $QX_ARMED_SRC"; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dg-self-contained.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

ARMED="$FIXTURE/armed-repo"
mkdir -p "$ARMED/.quetrex"
printf '%s' '{"branchPrefix":"claude/"}' > "$ARMED/.quetrex/project.json"

UNARMED="$FIXTURE/unarmed-repo"
mkdir -p "$UNARMED"

# A directory that carries ONLY the hook under test — no qx-armed.sh
# sibling, no qx-armed.sh anywhere nearby — the exact "standalone scratch
# copy" shape that exposed the bug.
STANDALONE_DIR="$FIXTURE/standalone"
mkdir -p "$STANDALONE_DIR"
cp "$DENY_GUARD" "$STANDALONE_DIR/hook-under-test.sh"
chmod +x "$STANDALONE_DIR/hook-under-test.sh"
STANDALONE_HOOK="$STANDALONE_DIR/hook-under-test.sh"

fire() {  # fire <hook> <command> <cwd> [CLAUDE_PROJECT_DIR]
  local hook="$1" cmd="$2" cwd="$3" pd="${4:-}"
  jq -cn --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR ${pd:+CLAUDE_PROJECT_DIR="$pd"} bash "$hook" 2>&1
}
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
has_stack_trace() { printf '%s' "$1" | grep -qi 'command not found\|line [0-9]*:.*:'; }

# =============================================================================
# AC1: qx_normalize_path IS reachable as a function once sourced/loaded —
# sanity control against the SHIPPED (non-standalone) hook, which sits next
# to its real qx-armed.sh sibling.
# =============================================================================
R=$(fire "$DENY_GUARD" "mv .quetrex/project.json /tmp/exfil-shipped" "$ARMED" "$ARMED")
if is_deny "$R" && ! has_stack_trace "$R"; then
  ok "AC1: the shipped deny-guard.sh (real sibling present) denies the kill-switch rule cleanly, no stack trace"
else
  notok "AC1: expected a clean deny, got: $R"
fi

# =============================================================================
# AC2: the SAME rule, run STANDALONE (no qx-armed.sh sibling — sourcing
# fails, the fallback must kick in) — must STILL deny cleanly.
# =============================================================================
R=$(fire "$STANDALONE_HOOK" "mv .quetrex/project.json /tmp/exfil-standalone" "$ARMED" "$ARMED")
if is_deny "$R" && ! has_stack_trace "$R"; then
  ok "AC2: run standalone (no qx-armed.sh sibling), the kill-switch rule is STILL denied cleanly — the fallback closed the gap"
else
  notok "AC2: STANDALONE FAIL-OPEN — expected a clean deny, got: $R"
fi

# =============================================================================
# AC3: the transcript-protection rule (this task's own addition), run
# STANDALONE, ARMED — must deny cleanly (this is the exact shape the
# orchestrator's original reproduction used).
# =============================================================================
R=$(fire "$STANDALONE_HOOK" "echo x >> $HOME/.claude/projects/foo/bar.jsonl" "$ARMED" "$ARMED")
if is_deny "$R" && ! has_stack_trace "$R"; then
  ok "AC3: run standalone, a transcript-path write is denied cleanly (the orchestrator's reproduction, now fixed)"
else
  notok "AC3: STANDALONE FAIL-OPEN on the transcript rule — expected a clean deny, got: $R"
fi

# =============================================================================
# AC4: run standalone, but the repo is genuinely UNARMED — an ordinary
# command must still be ALLOWED, silently. The fix must not make the hook
# MORE aggressive in the unarmed/cloud-normal case.
# =============================================================================
R=$(fire "$STANDALONE_HOOK" "echo hi >> ordinary.txt" "$UNARMED" "$UNARMED")
if [ -z "$R" ]; then
  ok "AC4: run standalone + genuinely unarmed, an ordinary command is allowed, silently (the fix did not add a fail-closed-on-absence regression)"
else
  notok "AC4: an ordinary command in an unarmed repo was not silently allowed: $R"
fi

# =============================================================================
# AC5: DEFENSIVE FLOOR — stub qx-armed.sh so it defines NEITHER function
# (sourcing itself succeeds, exit 0, but the functions are still missing).
# The hook must still deny cleanly: not a stack trace, not an exit-0 allow.
# =============================================================================
STUB_DIR="$FIXTURE/stub"
mkdir -p "$STUB_DIR"
cp "$DENY_GUARD" "$STUB_DIR/hook-under-test.sh"
chmod +x "$STUB_DIR/hook-under-test.sh"
printf '%s\n' '#!/bin/bash' '# stub: deliberately defines neither qx_repo_armed nor qx_normalize_path' \
  > "$STUB_DIR/qx-armed.sh"
R=$(fire "$STUB_DIR/hook-under-test.sh" "mv .quetrex/project.json /tmp/exfil-stub" "$ARMED" "$ARMED")
if is_deny "$R" && ! has_stack_trace "$R"; then
  ok "AC5: with both helpers stubbed out entirely, the hook still denies cleanly (never a stack trace, never an allow)"
else
  notok "AC5: DEFENSIVE FLOOR FAILED — expected a clean deny with both helpers missing, got: $R"
fi

# =============================================================================
# AC6 (parity, ONE-COPY convention) — the fallback qx_normalize_path now
# inside deny-guard.sh is byte-identical (ignoring indentation only) to
# qx-armed.sh's canonical definition AND to protected-files-guard.sh's own
# fallback copy. A 0-byte extraction is a FAIL, not a vacuous pass.
# =============================================================================
extract_dedented() {  # extract_dedented <file> -- prints the
                       # qx_normalize_path function body with each line's
                       # leading whitespace stripped, tolerant of the
                       # different indentation levels a top-level definition
                       # (qx-armed.sh) vs. an if-nested fallback
                       # (protected-files-guard.sh, deny-guard.sh) requires.
  awk '
    /^[[:space:]]*qx_normalize_path\(\)[[:space:]]*\{[[:space:]]*$/ { on=1 }
    on { sub(/^[[:space:]]+/, ""); print }
    on && /^\}[[:space:]]*$/ { exit }
  ' "$1"
}
PROTECTED_GUARD="$REPO_ROOT/.claude/hooks/protected-files-guard.sh"
extract_dedented "$QX_ARMED_SRC" > "$FIXTURE/armed_np.txt"
extract_dedented "$DENY_GUARD" > "$FIXTURE/dg_np.txt"
NP_ARMED_N=$(wc -l < "$FIXTURE/armed_np.txt" | tr -d ' ')
NP_DG_N=$(wc -l < "$FIXTURE/dg_np.txt" | tr -d ' ')
if [ "$NP_ARMED_N" -eq 0 ] || [ "$NP_DG_N" -eq 0 ]; then
  notok "AC6: extraction of qx_normalize_path found an EMPTY region (qx-armed.sh: $NP_ARMED_N, deny-guard.sh: $NP_DG_N lines) — a 0-byte extraction is a FAIL"
else
  ok "AC6: extracted a non-empty qx_normalize_path from qx-armed.sh ($NP_ARMED_N lines) and deny-guard.sh ($NP_DG_N lines)"
  DIFFLINES=$(diff "$FIXTURE/armed_np.txt" "$FIXTURE/dg_np.txt" | grep -c . || true)
  [ "${DIFFLINES:-0}" -eq 0 ] \
    && ok "AC6: qx_normalize_path (dedented) is identical between qx-armed.sh and deny-guard.sh's fallback" \
    || notok "AC6: qx_normalize_path DIFFERS between qx-armed.sh and deny-guard.sh's fallback ($DIFFLINES diff line(s)) — the copy has drifted"
fi
if [ -f "$PROTECTED_GUARD" ]; then
  extract_dedented "$PROTECTED_GUARD" > "$FIXTURE/pg_np.txt"
  NP_PG_N=$(wc -l < "$FIXTURE/pg_np.txt" | tr -d ' ')
  if [ "$NP_PG_N" -eq 0 ]; then
    notok "AC6: extraction of qx_normalize_path from protected-files-guard.sh found an EMPTY region — a 0-byte extraction is a FAIL"
  else
    DIFFLINES2=$(diff "$FIXTURE/dg_np.txt" "$FIXTURE/pg_np.txt" | grep -c . || true)
    [ "${DIFFLINES2:-0}" -eq 0 ] \
      && ok "AC6: qx_normalize_path (dedented) is identical between deny-guard.sh's fallback and protected-files-guard.sh's fallback" \
      || notok "AC6: qx_normalize_path DIFFERS between deny-guard.sh and protected-files-guard.sh fallbacks ($DIFFLINES2 diff line(s)) — the copy has drifted"
  fi
fi

# =============================================================================
# FAIL-FIRST — the SAME kill-switch rule, run standalone against the
# pre-existing shipped code pinned at $BASELINE_SHA, fails OPEN with a raw
# interpreter error. This bug pre-dates this task; the fix (AC2/AC5 above)
# closes it for good, not just for the transcript-protection addition.
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASELINE_SHA}^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$BASELINE_SHA_FULL" 2>/dev/null || true
fi
if git -C "$REPO_ROOT" cat-file -e "${BASELINE_SHA}:plugins/quetrex-factory/scripts/deny-guard.sh" 2>/dev/null; then
  BASE_STANDALONE_DIR="$FIXTURE/baseline-standalone"
  mkdir -p "$BASE_STANDALONE_DIR"
  git -C "$REPO_ROOT" show "${BASELINE_SHA}:plugins/quetrex-factory/scripts/deny-guard.sh" > "$BASE_STANDALONE_DIR/hook-under-test.sh"
  chmod +x "$BASE_STANDALONE_DIR/hook-under-test.sh"
  BR=$(fire "$BASE_STANDALONE_DIR/hook-under-test.sh" "mv .quetrex/project.json /tmp/exfil-baseline" "$ARMED" "$ARMED")
  if ! is_deny "$BR" && has_stack_trace "$BR"; then
    ok "FAIL-FIRST: the pre-existing shipped deny-guard.sh ($BASELINE_SHA), run standalone, DOES fail open with a raw interpreter error — this is a genuine, pre-existing defect, now closed"
  else
    notok "FAIL-FIRST: the baseline did not reproduce the fail-open bug standalone (got: $BR) — cannot demonstrate the fix is real"
  fi
else
  notok "FAIL-FIRST: baseline commit ${BASELINE_SHA} (or deny-guard.sh at it) is not reachable even after a depth-1 fetch — refusing to report a pass having compared against nothing"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "deny-guard-self-contained-fallback.test.sh: $PASS passed, $FAIL failed"
else
  echo "deny-guard-self-contained-fallback.test.sh: $PASS passed, $FAIL failed"
fi
exit "$FAIL"
