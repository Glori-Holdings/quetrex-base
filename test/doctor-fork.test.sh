#!/usr/bin/env bash
# test/doctor-fork.test.sh — behavioural test for plugins/quetrex-setup/commands/doctor.md
# Check 15 ("No local fork of the floor or the engine agents").
#
# Run: bash test/doctor-fork.test.sh
#
# THE DEFECT (REVIEW-2026-09 §3.1). An armed repo (quetrex-factory enabled)
# runs the plugin's own copy of every floor hook and every engine agent. A
# project-local file of the same basename under .claude/hooks/ or
# .claude/agents/ silently shadows the plugin's copy: a floor hook runs
# TWICE per event, or a project agent overrides the reviewed engine agent
# with no signal to the operator. The pre-change doctor had no check for
# this at all — Check 15 is new.
#
# FAIL-FIRST section below extracts the same "## Check 15" fence from the
# doctor.md that shipped at 7e69a624e9053a2f3589c1d677ef4228510630f7 (the
# fixed SHA this task branched from, NOT main) and proves the extraction is
# empty and the fixture prints zero ✗ lines against it — the old doctor was
# blind to the exact reproduction this test drives against the new one.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_MD="$TOOLROOT/plugins/quetrex-setup/commands/doctor.md"
BASELINE_SHA="7e69a624e9053a2f3589c1d677ef4228510630f7"

if [ ! -f "$DOCTOR_MD" ]; then
  echo "FAIL: doctor.md not found at $DOCTOR_MD"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — doctor.md's Check 15 is node-assisted"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — the fail-first baseline is read via git show"
  exit 0
fi
if command -v zsh >/dev/null 2>&1; then ZSH_AVAILABLE=1; else ZSH_AVAILABLE=0; fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-doctor-fork.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Extract the "## Check 15" bash fence — own copy of the technique used by
# test/doctor-checks.test.sh and test/doctor-tracked.test.sh, so this is
# proven against the REAL shipped prose, never a copy that can drift from it.
# -----------------------------------------------------------------------------
extract_section() {  # extract_section <doctor.md-path> <heading-literal>
  local file="$1" heading="$2"
  awk -v heading="$heading" '
    index($0, heading) == 1 { insec = 1; next }
    insec && /^## / { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$file"
}

CHECK15_SCRIPT="$(extract_section "$DOCTOR_MD" '## Check 15')"

if [ -z "$CHECK15_SCRIPT" ]; then
  fail "setup: could not extract Check 15's bash fence from $DOCTOR_MD — doctor still has no local-fork check"
else
  pass "setup: extracted Check 15's bash fence from doctor.md"
fi

NODE_DIR="$(dirname "$(command -v node)")"
GIT_DIR_BIN="$(dirname "$(command -v git)")"
ISOLATED_PATH="$TOOLROOT/bin:$NODE_DIR:$GIT_DIR_BIN:/usr/bin:/bin"

# run_check15 <script> <fixture-repo-root> [shell]
run_check15() {
  local script="$1" repo="$2" shell="${3:-bash}"
  (
    REPO_ROOT="$repo"; export REPO_ROOT
    SETTINGS="$repo/.claude/settings.json"; export SETTINGS
    PATH="$ISOLATED_PATH"; export PATH
    "$shell" -c "$script"
  )
}

ARMED_SETTINGS='{ "enabledPlugins": { "quetrex@quetrex": true, "quetrex-factory@quetrex": true } }'
UNARMED_SETTINGS='{ "enabledPlugins": {} }'

mk_fixture() {  # mk_fixture <dir> <settings-json>
  local r="$1" settings="$2"
  mkdir -p "$r/.claude/hooks" "$r/.claude/agents"
  printf '%s\n' "$settings" > "$r/.claude/settings.json"
}

# =============================================================================
# STATE 1 — armed + a forked floor hook (merge-gate.sh) -> exactly 1 ✗ naming
# the file and exactly 1 Fix: rm line.
# =============================================================================
S1="$WORK/s1"
mk_fixture "$S1" "$ARMED_SETTINGS"
: > "$S1/.claude/hooks/merge-gate.sh"

OUT_S1="$(run_check15 "$CHECK15_SCRIPT" "$S1" bash 2>&1)"
N_X_S1="$(printf '%s\n' "$OUT_S1" | grep -c '^✗')"
if [ "$N_X_S1" -eq 1 ] && printf '%s' "$OUT_S1" | grep -q '✗.*\.claude/hooks/merge-gate\.sh'; then
  pass "STATE 1: armed + local merge-gate.sh -> exactly 1 ✗ naming .claude/hooks/merge-gate.sh"
else
  fail "STATE 1: expected exactly 1 ✗ naming .claude/hooks/merge-gate.sh (got $N_X_S1 ✗ line(s); out: [$OUT_S1])"
fi
N_FIX_S1="$(printf '%s\n' "$OUT_S1" | grep -c 'Fix: rm')"
if [ "$N_FIX_S1" -eq 1 ] && printf '%s' "$OUT_S1" | grep -q 'Fix: rm \.claude/hooks/merge-gate\.sh'; then
  pass "STATE 1: exactly 1 'Fix: rm .claude/hooks/merge-gate.sh' line"
else
  fail "STATE 1: expected exactly 1 'Fix: rm .claude/hooks/merge-gate.sh' line (got $N_FIX_S1; out: [$OUT_S1])"
fi

if [ "$ZSH_AVAILABLE" -eq 1 ]; then
  OUT_S1_ZSH="$(run_check15 "$CHECK15_SCRIPT" "$S1" zsh 2>&1)"
  if [ -n "$OUT_S1" ] && [ "$OUT_S1" = "$OUT_S1_ZSH" ]; then
    pass "PARITY: bash and zsh produce byte-identical output for the STATE 1 fixture"
  else
    fail "PARITY: bash and zsh diverged on the STATE 1 fixture (bash: [$OUT_S1], zsh: [$OUT_S1_ZSH])"
  fi
else
  echo "SKIP-note: zsh not installed — the bash/zsh parity assertion did not run"
fi

# =============================================================================
# STATE 2 — armed + a forked engine agent (reviewer.md) -> exactly 1 ✗
# naming the file.
# =============================================================================
S2="$WORK/s2"
mk_fixture "$S2" "$ARMED_SETTINGS"
: > "$S2/.claude/agents/reviewer.md"

OUT_S2="$(run_check15 "$CHECK15_SCRIPT" "$S2" bash 2>&1)"
N_X_S2="$(printf '%s\n' "$OUT_S2" | grep -c '^✗')"
if [ "$N_X_S2" -eq 1 ] && printf '%s' "$OUT_S2" | grep -q '✗.*\.claude/agents/reviewer\.md'; then
  pass "STATE 2: armed + local agents/reviewer.md -> exactly 1 ✗ naming .claude/agents/reviewer.md"
else
  fail "STATE 2: expected exactly 1 ✗ naming .claude/agents/reviewer.md (got $N_X_S2 ✗ line(s); out: [$OUT_S2])"
fi

# =============================================================================
# STATE 3 — armed + only a non-floor hook (serialize.sh) -> 0 ✗, 1 ✓.
# =============================================================================
S3="$WORK/s3"
mk_fixture "$S3" "$ARMED_SETTINGS"
: > "$S3/.claude/hooks/serialize.sh"

OUT_S3="$(run_check15 "$CHECK15_SCRIPT" "$S3" bash 2>&1)"
N_X_S3="$(printf '%s\n' "$OUT_S3" | grep -c '^✗')"
N_CHECK_S3="$(printf '%s\n' "$OUT_S3" | grep -c '^✓')"
if [ "$N_X_S3" -eq 0 ] && [ "$N_CHECK_S3" -eq 1 ]; then
  pass "STATE 3: armed + serialize.sh only -> 0 ✗, 1 ✓ (serialize.sh is not a floor script)"
else
  fail "STATE 3: expected 0 ✗ and 1 ✓ for a non-floor hook (got $N_X_S3 ✗, $N_CHECK_S3 ✓; out: [$OUT_S3])"
fi

# =============================================================================
# STATE 4 — unarmed + 5 stale floor hooks on disk -> 0 ✗, 1 ✓ (nothing to
# shadow because quetrex-factory is not running here at all).
# =============================================================================
S4="$WORK/s4"
mk_fixture "$S4" "$UNARMED_SETTINGS"
for h in deny-guard secret-scan enforce-branch merge-gate verify-gate; do
  : > "$S4/.claude/hooks/$h.sh"
done

OUT_S4="$(run_check15 "$CHECK15_SCRIPT" "$S4" bash 2>&1)"
N_X_S4="$(printf '%s\n' "$OUT_S4" | grep -c '^✗')"
N_CHECK_S4="$(printf '%s\n' "$OUT_S4" | grep -c '^✓')"
if [ "$N_X_S4" -eq 0 ] && [ "$N_CHECK_S4" -eq 1 ]; then
  pass "STATE 4: unarmed + 5 stale hooks on disk -> 0 ✗, 1 ✓ (local hooks are this repo's only floor)"
else
  fail "STATE 4: expected 0 ✗ and 1 ✓ when unarmed (got $N_X_S4 ✗, $N_CHECK_S4 ✓; out: [$OUT_S4])"
fi

if [ "$ZSH_AVAILABLE" -eq 1 ]; then
  OUT_S4_ZSH="$(run_check15 "$CHECK15_SCRIPT" "$S4" zsh 2>&1)"
  if [ -n "$OUT_S4" ] && [ "$OUT_S4" = "$OUT_S4_ZSH" ]; then
    pass "PARITY: bash and zsh produce byte-identical output for the STATE 4 fixture"
  else
    fail "PARITY: bash and zsh diverged on the STATE 4 fixture (bash: [$OUT_S4], zsh: [$OUT_S4_ZSH])"
  fi
else
  echo "SKIP-note: zsh not installed — the bash/zsh parity assertion did not run"
fi

# =============================================================================
# SOURCE — the check must loop via `while read`, never `for x in $VAR`
# (a repo-controlled filename must never be word-split/glob-expanded).
# =============================================================================
if printf '%s\n' "$CHECK15_SCRIPT" | grep -Eq 'for [A-Za-z_]* in \$'; then
  fail "SOURCE: Check 15 uses a 'for x in \$VAR' loop — a repo-controlled filename could be word-split or glob-expanded"
else
  pass "SOURCE: Check 15 loops via while-read, not 'for x in \$VAR'"
fi

# =============================================================================
# FAIL-FIRST — the pre-change doctor at the fixed baseline SHA had no
# Check 15 at all, so it is proven blind to the exact same reproduction.
# The baseline is the literal SHA, never `main`.
# =============================================================================
BASELINE_DOCTOR="$(git -C "$TOOLROOT" show "$BASELINE_SHA:plugins/quetrex-setup/commands/doctor.md" 2>/dev/null)"
if [ -z "$BASELINE_DOCTOR" ]; then
  fail "FAIL-FIRST: could not read plugins/quetrex-setup/commands/doctor.md at $BASELINE_SHA"
else
  BASELINE_FILE="$WORK/baseline-doctor.md"
  printf '%s\n' "$BASELINE_DOCTOR" > "$BASELINE_FILE"
  BASELINE_CHECK15="$(extract_section "$BASELINE_FILE" '## Check 15')"
  if [ -z "$BASELINE_CHECK15" ]; then
    pass "FAIL-FIRST: extracting '## Check 15' from the $BASELINE_SHA copy yields 0 bytes — the old doctor had no such check"
  else
    fail "FAIL-FIRST: the $BASELINE_SHA copy already has a '## Check 15' fence — the baseline is not what this test assumes"
  fi

  # Run the (empty) baseline extraction against the armed+stale-hooks
  # reproduction anyway, mirroring the STATE 1 fixture: an empty script
  # runs and prints nothing, so it is mechanically proven to emit 0 ✗ lines
  # — the old doctor never had the machinery to flag this at all.
  S_BASELINE="$WORK/s-baseline"
  mk_fixture "$S_BASELINE" "$ARMED_SETTINGS"
  : > "$S_BASELINE/.claude/hooks/merge-gate.sh"
  : > "$S_BASELINE/.claude/agents/reviewer.md"
  OUT_BASELINE="$(run_check15 "$BASELINE_CHECK15" "$S_BASELINE" bash 2>&1)"
  N_X_BASELINE="$(printf '%s\n' "$OUT_BASELINE" | grep -c '^✗')"
  if [ "$N_X_BASELINE" -eq 0 ]; then
    pass "FAIL-FIRST: the $BASELINE_SHA doctor prints exactly 0 ✗ lines against the armed+forked-artifact reproduction (it had no check for this)"
  else
    fail "FAIL-FIRST: the baseline doctor unexpectedly reported $N_X_BASELINE ✗ line(s) — the baseline fixture is not reproducing a real prior blind spot (out: [$OUT_BASELINE])"
  fi
  echo "ok"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "doctor-fork.test.sh: all checks passed"
  exit 0
else
  echo "doctor-fork.test.sh: FAILURES above"
  exit 1
fi
