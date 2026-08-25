#!/usr/bin/env bash
# test/armed-only-floor.test.sh — ARMED-ONLY (ONE-COPY): every floor script
# gates an ARMED repo (has .quetrex/project.json) exactly as before, and gates
# NOTHING in an UNARMED repo (no .quetrex/project.json) — per the operator
# rule "unarmed repo = no gates at all".
#
# Run: bash test/armed-only-floor.test.sh
#
# COVERAGE. deny-guard.sh and secret-scan.sh had NO repo-root resolution at
# all before this change (they judged the payload alone, everywhere) — this
# is genuinely new behavior for both, not a tightened existing check.
# enforce-branch.sh, merge-gate.sh and verify-gate.sh already resolved a
# root; this file proves each now additionally requires
# `$ROOT/.quetrex/project.json` to exist before making ANY decision.
# verify-gate-quick-chain.sh is sourced-only (not a standalone hook) and has
# and needs no independent armed check of its own — it inherits verify-gate.sh's
# gate by construction (see that file's own header note); it is not exercised
# directly here.
#
# FAIL-FIRST (AC9): run this file with QX_*_HOOK pointed at the pre-change
# script recovered via `git show <merge-base>:.claude/hooks/<name>.sh` — see
# the developer's report for the exact NOT OK lines this produces (deny-guard
# and secret-scan have no armed gate at all yet, so EVERY unarmed-repo case
# for those two goes red; enforce-branch/merge-gate/verify-gate go red on the
# unarmed cases too, since their pre-change root-resolution had no
# project.json check).

set -uo pipefail

# ONE-COPY round 2 hygiene (reviewer-reported): this session's ambient
# environment can carry QUETREX_UNLOCK_FLOOR=1 from unrelated prior work in
# the SAME shell (it is not cleared between unrelated commands), and every
# floor script honors it as the intentional operator unlock. A test that
# asserts a floor DENY without isolating this var silently asserts nothing
# once that happens - unset it here so this file's own "locked" assertions
# are never contaminated by ambient state; any assertion that WANTS the
# unlocked case still sets QUETREX_UNLOCK_FLOOR=1 explicitly on that one
# invocation, which overrides this.
unset QUETREX_UNLOCK_FLOOR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
SECRET_SCAN="${QX_SECRET_SCAN_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/secret-scan.sh}"
ENFORCE_BRANCH="${QX_ENFORCE_BRANCH_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/enforce-branch.sh}"
MERGE_GATE="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh}"
VERIFY_GATE="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"

for h in "$DENY_GUARD" "$SECRET_SCAN" "$ENFORCE_BRANCH" "$MERGE_GATE" "$VERIFY_GATE"; do
  if [ ! -f "$h" ]; then
    echo "FAIL: hook not found at $h"
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — these hooks are jq-preferred and their armed-gate behavior is most reliably proven with it available"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/armed-only-floor.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo "fixture" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: fixture commit"

is_unarmed() { [ ! -f "$FIXTURE/.quetrex/project.json" ]; }
arm()    { mkdir -p "$FIXTURE/.quetrex"; printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json"; }
disarm() { rm -rf "$FIXTURE/.quetrex"; }

assert_silent() {  # assert_silent <label> <code> <out> <err>
  local label="$1" code="$2" out="$3" err="$4"
  if [ "$code" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ] && is_unarmed; then
    ok "$label: unarmed repo — exit 0, 0 bytes stdout, 0 bytes stderr, no .quetrex/ side effect"
  else
    notok "$label: unarmed repo — expected exit 0 + silence + no .quetrex/, got exit=$code stdout=[$out] stderr=[$err] quetrex_dir_exists=$([ -d "$FIXTURE/.quetrex" ] && echo yes || echo no)"
  fi
}

assert_blocks() {  # assert_blocks <label> <code> <out>
  local label="$1" code="$2" out="$3"
  if { [ "$code" -eq 0 ] && printf '%s' "$out" | grep -qE '"(permissionDecision|decision)"[[:space:]]*:[[:space:]]*"(deny|block)"'; } || [ "$code" -eq 2 ]; then
    ok "$label: armed repo — still gates (exit=$code)"
  else
    notok "$label: armed repo — expected a deny/block decision or exit 2, got exit=$code out=[$out]"
  fi
}

# =============================================================================
# deny-guard.sh: `git push --force origin main`
# =============================================================================
DG_PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git push --force origin main"}}'
disarm
OUT="$(printf '%s' "$DG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$DENY_GUARD" 2>/tmp/armed-only-floor.stderr.$$)"; CODE=$?
ERR="$(cat /tmp/armed-only-floor.stderr.$$ 2>/dev/null)"; rm -f /tmp/armed-only-floor.stderr.$$
assert_silent "deny-guard (force-push)" "$CODE" "$OUT" "$ERR"

arm
OUT="$(printf '%s' "$DG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$DENY_GUARD" 2>&1)"; CODE=$?
assert_blocks "deny-guard (force-push)" "$CODE" "$OUT"
disarm

# =============================================================================
# secret-scan.sh: a Write of an AWS-shaped access key id. Built by
# concatenation at RUNTIME (never spelled literally in this source file) so
# this test file itself never trips a secret scanner on its own source.
# =============================================================================
AWS_KEY_PREFIX="AKIA"
AWS_KEY_BODY="IOSFODNN7EXAMPLE"  # the standard AWS-docs sample key body, not a real credential
SS_PAYLOAD="$(jq -cn --arg k "${AWS_KEY_PREFIX}${AWS_KEY_BODY}" '{tool_name:"Write",tool_input:{file_path:"secrets.env",content:("AWS_KEY=" + $k)}}')"
disarm
OUT="$(printf '%s' "$SS_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$SECRET_SCAN" 2>/tmp/armed-only-floor.stderr.$$)"; CODE=$?
ERR="$(cat /tmp/armed-only-floor.stderr.$$ 2>/dev/null)"; rm -f /tmp/armed-only-floor.stderr.$$
assert_silent "secret-scan (AWS key write)" "$CODE" "$OUT" "$ERR"

arm
OUT="$(printf '%s' "$SS_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$SECRET_SCAN" 2>&1)"; CODE=$?
assert_blocks "secret-scan (AWS key write)" "$CODE" "$OUT"
disarm

# =============================================================================
# enforce-branch.sh: `git commit` while checked out on main (with existing
# history, so the fresh-repo exemption does not apply)
# =============================================================================
EB_PAYLOAD="$(jq -cn --arg cwd "$FIXTURE" '{tool_name:"Bash",tool_input:{command:"git commit -m test"},cwd:$cwd}')"
disarm
OUT="$(printf '%s' "$EB_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$ENFORCE_BRANCH" 2>/tmp/armed-only-floor.stderr.$$)"; CODE=$?
ERR="$(cat /tmp/armed-only-floor.stderr.$$ 2>/dev/null)"; rm -f /tmp/armed-only-floor.stderr.$$
assert_silent "enforce-branch (commit on main)" "$CODE" "$OUT" "$ERR"

arm
OUT="$(printf '%s' "$EB_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$ENFORCE_BRANCH" 2>&1)"; CODE=$?
assert_blocks "enforce-branch (commit on main)" "$CODE" "$OUT"
disarm

# =============================================================================
# merge-gate.sh: `gh pr merge 1 --squash`, no gate artifacts present. The
# armed check runs BEFORE the gate ever calls `gh`, so this needs no gh mock
# for the unarmed case; for the armed case an unresolvable/absent `gh` still
# denies fail-closed (ESCALATE_HUMAN), which still counts as "still gates".
# =============================================================================
MG_PAYLOAD="$(jq -cn --arg cwd "$FIXTURE" '{tool_input:{command:"gh pr merge 1 --squash"},cwd:$cwd}')"
disarm
OUT="$(printf '%s' "$MG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$MERGE_GATE" 2>/tmp/armed-only-floor.stderr.$$)"; CODE=$?
ERR="$(cat /tmp/armed-only-floor.stderr.$$ 2>/dev/null)"; rm -f /tmp/armed-only-floor.stderr.$$
assert_silent "merge-gate (gh pr merge, no artifacts)" "$CODE" "$OUT" "$ERR"

arm
OUT="$(printf '%s' "$MG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$MERGE_GATE" 2>&1)"; CODE=$?
assert_blocks "merge-gate (gh pr merge, no artifacts)" "$CODE" "$OUT"
disarm

# SHARPER CASE (the actual pre-change gap): a .quetrex/ DIRECTORY exists
# (e.g. left over from a prior run) but .quetrex/project.json does NOT. The
# pre-change gate keyed off `[ -d "$QDIR" ]` alone, so this shape was already
# treated as "managed" and evaluated (denying on missing artifacts, for the
# wrong reason). The post-change gate must treat this as UNARMED — silent,
# exit 0 — since only project.json's presence means "armed" now.
mkdir -p "$FIXTURE/.quetrex"
OUT="$(printf '%s' "$MG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$MERGE_GATE" 2>/tmp/armed-only-floor.stderr.$$)"; CODE=$?
ERR="$(cat /tmp/armed-only-floor.stderr.$$ 2>/dev/null)"; rm -f /tmp/armed-only-floor.stderr.$$
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]; then
  ok "merge-gate (gh pr merge, .quetrex/ dir exists but no project.json): treated as unarmed — exit 0, silent"
else
  notok "merge-gate (gh pr merge, .quetrex/ dir exists but no project.json): expected exit 0 + silence (armed-only keys off project.json, not the directory), got exit=$CODE stdout=[$OUT] stderr=[$ERR]"
fi
disarm

# =============================================================================
# verify-gate.sh: a Stop event with a red chain (verify.json declares a
# failing command). The armed check runs before verify.json is even read, so
# the unarmed case needs no ledger/attempts state either.
# =============================================================================
VG_PAYLOAD="$(jq -cn --arg cwd "$FIXTURE" '{cwd:$cwd,hook_event_name:"Stop"}')"

disarm
# re-seed verify.json (disarm removes the whole .quetrex/ dir along with the
# armed marker) so the chain is genuinely red, not merely unconfigured.
mkdir -p "$FIXTURE/.quetrex"
jq -cn '{verify:["false"]}' > "$FIXTURE/.quetrex/verify.json"
OUT="$(printf '%s' "$VG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$VERIFY_GATE" 2>/tmp/armed-only-floor.stderr.$$)"; CODE=$?
ERR="$(cat /tmp/armed-only-floor.stderr.$$ 2>/dev/null)"; rm -f /tmp/armed-only-floor.stderr.$$
# This fixture already has a .quetrex/ DIRECTORY (holding verify.json) that
# is not itself the armed marker — assert the MARKER FILE's absence
# specifically (.quetrex/project.json), not the directory's.
if [ "$CODE" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] && [ ! -f "$FIXTURE/.quetrex/project.json" ]; then
  ok "verify-gate (red chain): unarmed repo — exit 0, 0 bytes stdout, 0 bytes stderr, no project.json side effect"
else
  notok "verify-gate (red chain): unarmed repo — expected exit 0 + silence, got exit=$CODE stdout=[$OUT] stderr=[$ERR]"
fi

printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json"
OUT="$(printf '%s' "$VG_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$VERIFY_GATE" 2>&1)"; CODE=$?
assert_blocks "verify-gate (red chain)" "$CODE" "$OUT"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "armed-only-floor.test.sh: all checks passed"
else
  echo "armed-only-floor.test.sh: FAILURES above"
fi
exit "$FAIL"
