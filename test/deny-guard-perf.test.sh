#!/usr/bin/env bash
# test/deny-guard-perf.test.sh — PERF-ONECOPY-1 (High) and PERF-ONECOPY-2
# (Medium), found by the round-3/round-4 reviewer against
# plugins/quetrex-factory/scripts/deny-guard.sh and qx-armed.sh.
#
# PERF-ONECOPY-1. deny-guard's C2 glob-safety branch (commit ea374c8) called
# qx_normalize_path — a command substitution, i.e. a FORK — once per
# filesystem match, with no prefilter. _kg_is_protected_literal can only
# ever return true for a path with a `.quetrex` component, so normalizing a
# match that plainly has no such component was pure waste. Cost was linear
# in match count at ~2ms/entry: an ordinary `rm -rf *` in a 20000-entry
# directory took 39.3s at 1339f76 (0.07s at e384c11, before this branch
# existed) — inside Claude Code's default 60s PreToolUse hook timeout, but
# not by much, and a larger directory times the hook out and surfaces a
# BENIGN command as a tool failure. Fail-first quote against the shipped
# hook at 1339f76 (git show 1339f76:plugins/.../deny-guard.sh), measured on
# this same machine before the fix in this file's own commit:
#     entries=1000   1339f76: ~1.9s    (fixed: ~0.08s)
#     entries=5000   1339f76: ~9.5s    (fixed: ~0.17s)
#     entries=20000  1339f76: ~38.8s   (fixed: ~0.58s)
# AC1-AC3 below reproduce the 5000-entry case directly against the shipped
# hook and assert a bound two orders of magnitude below the pre-fix time,
# with generous slack for a loaded CI box. AC4/AC5 prove the fix did not
# also make the check permissive: the exact shapes that motivated the glob
# branch in the first place must still DENY.
#
# PERF-ONECOPY-2. qx_repo_armed (plugins/quetrex-factory/scripts/qx-armed.sh)
# ran up to 7 git subprocesses per call (a cat-file at HEAD, up to 5
# rev-parse --verify probes, a second cat-file) with NO memoization, and
# deny-guard calls target_armed() — which calls qx_repo_armed() — once per
# command SEGMENT (each `cd`, each redirection check), so a multi-step
# command paid that cost once per segment even though every segment before
# the first real `-C`/`--git-dir` target resolves to the SAME session root.
# Measured with a git-invocation-counting shim, on this machine, before the
# fix in this file's own commit:
#     `echo hello`, unarmed target                 1339f76: 13 git calls
#     `cd a && cd b && cd c && cd d && echo hi`,
#       unarmed target                             1339f76: 37 git calls
# AC6/AC7 below reproduce both with the shim and assert a bound that is
# only reachable if qx_repo_armed's answer for the session root is reused
# across segments instead of re-probed from scratch every time.
#
# Run: bash test/deny-guard-perf.test.sh

set -uo pipefail

# ONE-COPY hygiene (see other test/*.test.sh files in this repo for the
# same note): never let an ambient QUETREX_UNLOCK_FLOOR from an unrelated
# prior command in this same shell silently defang a DENY assertion here.
unset QUETREX_UNLOCK_FLOOR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh"

if [ ! -f "$DENY_GUARD" ]; then
  echo "NOT OK - required file not found: $DENY_GUARD"
  echo "deny-guard-perf.test.sh: FAILURES above"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — the PreToolUse payloads are built with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- fixtures ----------------------------------------------------------
ARMED="$WORKDIR/armed"
UNARMED="$WORKDIR/unarmed"
mkdir -p "$ARMED/.quetrex" "$ARMED/big" "$UNARMED"
git -C "$ARMED" init -q -b main >/dev/null 2>&1
printf '{"branchPrefix":"claude/"}' > "$ARMED/.quetrex/project.json"
git -C "$UNARMED" init -q -b main >/dev/null 2>&1
git -C "$UNARMED" -c user.email=a@a.test -c user.name=qa commit -q --allow-empty -m init >/dev/null 2>&1

# 5000 zero-byte files, none of them anywhere near .quetrex — an ordinary
# build/vendor directory shape, not an adversarial one.
for i in $(seq 1 5000); do : > "$ARMED/big/f$i.txt"; done

hook_run() {  # hook_run <cwd> <command-string> -> stdout of the hook
  local cwd="$1" cmd="$2" payload
  payload="$(node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "Bash",
      tool_input: { command: process.argv[2] },
      cwd: process.argv[1]
    }));
  ' "$cwd" "$cmd")"
  printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR -u CLAUDE_PROJECT_DIR bash "$DENY_GUARD" 2>/dev/null
}

is_deny() {
  case "$1" in
    *'"permissionDecision":"deny"'*) return 0 ;;
    *) return 1 ;;
  esac
}

# =============================================================================
# PERF-ONECOPY-1 — no fork per glob match
# =============================================================================

START=$(date +%s.%N 2>/dev/null || date +%s)
OUT="$(hook_run "$ARMED/big" 'rm -rf *')"
END=$(date +%s.%N 2>/dev/null || date +%s)
ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.3f", e-s}' 2>/dev/null || echo "0")

# AC1: correctness is unchanged — an ordinary glob in a directory with no
# .quetrex component anywhere in it is still ALLOWED, never a decision
# change from the fix, only a cost change.
if is_deny "$OUT"; then
  fail "AC1: 'rm -rf *' over an ordinary 5000-entry dir was DENIED — the perf fix must never change the decision, only the cost"
else
  pass "AC1: 'rm -rf *' over an ordinary 5000-entry dir is still ALLOWED"
fi

# AC2: the actual regression this finding is about — bounded wall clock.
# Pre-fix (1339f76) measured ~9.5s for this exact fixture on this machine;
# post-fix measured ~0.17s. 2s leaves >10x headroom over the fixed time and
# is still >4x faster than the pre-fix time, so this can only pass if the
# per-match fork was actually removed, not just made a little cheaper.
if awk -v e="$ELAPSED" 'BEGIN{exit !(e < 2.0)}' 2>/dev/null; then
  pass "AC2: 'rm -rf *' over a 5000-entry dir completed in ${ELAPSED}s (< 2s bound; 1339f76 measured ~9.5s)"
else
  fail "AC2: 'rm -rf *' over a 5000-entry dir took ${ELAPSED}s (>= 2s bound) — deny-guard's glob branch is forking per match again (PERF-ONECOPY-1 regression)"
fi

# AC3: same shape, doubled — guards against a fix that only prefilters the
# FIRST match or otherwise degrades non-linearly again.
mkdir -p "$ARMED/big2"
for i in $(seq 1 5000); do : > "$ARMED/big2/f$i.txt"; done
START=$(date +%s.%N 2>/dev/null || date +%s)
OUT3="$(hook_run "$ARMED/big2" 'chmod -R 755 *')"
END=$(date +%s.%N 2>/dev/null || date +%s)
ELAPSED3=$(awk -v s="$START" -v e="$END" 'BEGIN{printf "%.3f", e-s}' 2>/dev/null || echo "0")
if is_deny "$OUT3"; then
  fail "AC3: 'chmod -R 755 *' over an ordinary 5000-entry dir was DENIED"
elif awk -v e="$ELAPSED3" 'BEGIN{exit !(e < 2.0)}' 2>/dev/null; then
  pass "AC3: a second glob shape ('chmod -R 755 *') over a 5000-entry dir completed in ${ELAPSED3}s (< 2s bound)"
else
  fail "AC3: 'chmod -R 755 *' over a 5000-entry dir took ${ELAPSED3}s (>= 2s bound)"
fi

# AC4/AC5: the floor itself must be unaffected — the exact shapes C2 added
# the glob branch to catch must still DENY, in the SAME armed fixture that
# now also holds 10000 innocuous entries.
OUT4="$(hook_run "$ARMED" 'rm -rf .quetrex/*')"
if is_deny "$OUT4"; then
  pass "AC4: 'rm -rf .quetrex/*' in the armed fixture is still DENIED"
else
  fail "AC4: 'rm -rf .quetrex/*' in the armed fixture was ALLOWED — the perf prefilter ate a real protected-glob match"
fi

OUT5="$(hook_run "$ARMED" 'cd .quetrex && rm -f *')"
if is_deny "$OUT5"; then
  pass "AC5: 'cd .quetrex && rm -f *' in the armed fixture is still DENIED"
else
  fail "AC5: 'cd .quetrex && rm -f *' in the armed fixture was ALLOWED — the perf prefilter ate a real protected-glob match"
fi

# =============================================================================
# PERF-ONECOPY-2 — qx_repo_armed memoized per resolved root, per invocation
# =============================================================================
# A git-invocation-counting shim: every real `git` call the hook makes
# increments a counter, then delegates to the real git. This measures the
# actual defect (repeated subprocess forks) directly, rather than inferring
# it from wall clock, which is noisier on a loaded CI box.
SHIM_DIR="$WORKDIR/shim"
COUNT_FILE="$WORKDIR/git-calls.count"
mkdir -p "$SHIM_DIR"
REAL_GIT="$(command -v git)"
cat > "$SHIM_DIR/git" <<SHIM
#!/bin/bash
echo x >> "$COUNT_FILE"
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$SHIM_DIR/git"

count_git_calls() {  # count_git_calls <cwd> <command-string>
  local cwd="$1" cmd="$2" payload
  : > "$COUNT_FILE"
  payload="$(node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "Bash",
      tool_input: { command: process.argv[2] },
      cwd: process.argv[1]
    }));
  ' "$cwd" "$cmd")"
  printf '%s' "$payload" | PATH="$SHIM_DIR:$PATH" env -u QUETREX_UNLOCK_FLOOR -u CLAUDE_PROJECT_DIR bash "$DENY_GUARD" >/dev/null 2>&1
  wc -l < "$COUNT_FILE" | tr -d ' '
}

# AC6: a single plain command against an UNARMED repo. 1339f76 measured 13
# git subprocesses for this exact shape (two full, un-memoized
# qx_repo_armed probes of the same session root); a single memoized probe
# is 7. Bound at 10 — well below 13, comfortably above 7 for git-version
# variance in how many rev-parse candidates resolve.
N6="$(count_git_calls "$UNARMED" 'echo hello')"
if [ "$N6" -le 10 ]; then
  pass "AC6: 'echo hello' against an unarmed target made $N6 git subprocess(es) (<= 10; 1339f76 measured 13)"
else
  fail "AC6: 'echo hello' against an unarmed target made $N6 git subprocess(es) (> 10) — qx_repo_armed is being re-probed instead of memoized (PERF-ONECOPY-2 regression)"
fi

# AC7: the shape the finding itself names — a multi-segment cd chain, none
# of whose intermediate targets exist, against an unarmed session. 1339f76
# measured 37 git subprocesses (one full un-memoized probe per segment);
# memoized-per-root should collapse this to the SAME cost as one plain
# command. Bound at 15 leaves slack while still requiring >2x reduction
# from the pre-fix count.
N7="$(count_git_calls "$UNARMED" 'cd a && cd b && cd c && cd d && echo hi')"
if [ "$N7" -le 15 ]; then
  pass "AC7: a 4-segment cd-chain against an unarmed session made $N7 git subprocess(es) (<= 15; 1339f76 measured 37)"
else
  fail "AC7: a 4-segment cd-chain against an unarmed session made $N7 git subprocess(es) (> 15) — qx_repo_armed is being re-probed per segment instead of memoized (PERF-ONECOPY-2 regression)"
fi

# AC8: memoization must never change a DENY decision. Same armed-fixture,
# same protected shapes as AC4/AC5, run again through the git-call-counting
# path so a cache keyed wrong (e.g. by cwd instead of resolved root) would
# show up as a false ALLOW here, not just as a count.
: > "$COUNT_FILE"
OUT8="$(hook_run "$ARMED" 'git -C '"$ARMED"' push --force origin main')"
if is_deny "$OUT8"; then
  pass "AC8: an unrelated real DENY rule (force-push) in the armed fixture is unaffected by memoization"
else
  fail "AC8: 'git -C <armed> push --force origin main' was ALLOWED — memoization broke an unrelated floor rule"
fi

if [ "$FAIL" -ne 0 ]; then
  echo "deny-guard-perf.test.sh: FAILURES above"
  exit 1
fi
echo "deny-guard-perf.test.sh: all assertions passed"
