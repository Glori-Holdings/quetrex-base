#!/usr/bin/env bash
# test/verify-gate-env-derive-integration.test.sh — QA-authored INTEGRATION
# proof for the one load-bearing interaction the VERIFY-GATE-QUIET task
# actually depends on for safety.
#
# THE RISK THIS PINS DOWN. `gate` deleted the main-checkout worktree-deferral
# skip (behavior b) entirely, which means the MAIN checkout now runs the
# verify chain again on every Stop/SubagentStop. That is safe ONLY if the
# declarative per-command `requiredEnv` skip (behavior c) actually fires for
# a command whose declared variable is legitimately unset in this checkout —
# `derive` is what is supposed to make that true by writing `requiredEnv`
# into the COMMITTED .quetrex/verify.json. Each workstream (`gate`, `derive`)
# proved its own half in isolation before merge; NEITHER side proves the
# other's half actually connects. This file connects them, end to end,
# against a FRESH fixture repo this suite builds itself — never reusing a
# fixture or helper from test/verify-gate.test.sh or test/env-derive.test.sh
# — and additionally chains the result into the REAL merge-gate.sh hook to
# prove skip containment holds all the way to the merge boundary, not just
# inside verify-gate.sh.
#
# Every rung below is a BEFORE/AFTER pair: prove the chain genuinely runs and
# blocks BEFORE the derivation exists, then prove — and only then — that the
# derivation's own committed output is what changes the outcome. A test that
# only checked the AFTER state could not tell "the skip fired for the right
# reason" from "the fixture never actually blocked in the first place".
#
# Run: bash test/verify-gate-env-derive-integration.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE_HOOK="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/.claude/hooks/verify-gate.sh}"
MERGE_HOOK="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/.claude/hooks/merge-gate.sh}"
DERIVE="$REPO_ROOT/bin/quetrex-env-derive"

if [ ! -f "$GATE_HOOK" ]; then echo "FAIL: verify-gate hook not found at $GATE_HOOK"; exit 1; fi
if [ ! -f "$MERGE_HOOK" ]; then echo "FAIL: merge-gate hook not found at $MERGE_HOOK"; exit 1; fi
if [ ! -f "$DERIVE" ]; then echo "FAIL: quetrex-env-derive not found at $DERIVE"; exit 1; fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — both hooks are jq-preferred, nothing to test"
  exit 0
fi
if ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: npm is not on PATH — the fixture's chain command is an npm script"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-vg-envderive-integ.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FIX="$WORK/fixture"
mkdir -p "$FIX/src"
git -C . rev-parse >/dev/null 2>&1 || true
(
  cd "$FIX"
  git init -q -b main
  git config user.email "qa-integration@example.com"
  git config user.name "QA Integration Fixture"
)

# The real read lives in a source file, and the chain command is a wrapper
# SCRIPT with no explicit path args of its own — the whole-tracked-tree scope
# case AC13/AC14 already prove in isolation. Deliberately a DIFFERENT
# variable name and DIFFERENT file layout than any fixture in
# test/env-derive.test.sh or test/verify-gate.test.sh, so this is not
# silently riding their setup.
cat > "$FIX/src/config.js" <<'EOF'
const url = process.env.QX_INTEG_DATABASE_URL;
if (!url) {
  console.error('QX_INTEG_DATABASE_URL is not set');
  process.exit(1);
}
console.log('config ok');
EOF

cat > "$FIX/run-build.sh" <<'EOF'
#!/usr/bin/env bash
exec node src/config.js
EOF
chmod +x "$FIX/run-build.sh"

cat > "$FIX/.env.example" <<'EOF'
QX_INTEG_DATABASE_URL=
EOF

cat > "$FIX/package.json" <<'EOF'
{
  "name": "qx-integ-fixture",
  "scripts": { "build": "./run-build.sh" }
}
EOF

mkdir -p "$FIX/.quetrex"
cat > "$FIX/.quetrex/verify.json" <<'EOF'
{ "verify": ["npm run build"] }
EOF

(
  cd "$FIX"
  git add -A
  git commit -q -m "qx-integ fixture: no requiredEnv yet"
)

hook_payload() {  # hook_payload <cwd>
  jq -cn --arg cwd "$1" --arg event "Stop" '{cwd:$cwd,hook_event_name:$event}'
}

run_gate() {  # run_gate <cwd> -> combined stdout+stderr on stdout
  local cwd="$1"
  env -u QX_INTEG_DATABASE_URL bash -c '
    printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" QUETREX_VERIFY_MAX=3 "$3"
  ' _ "$(hook_payload "$cwd")" "$cwd" "$GATE_HOOK" 2>&1
}

block_decisions() {  # block_decisions <combined-output> -> count
  local out="$1" n=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '%s' "$line" | jq -e '.decision=="block"' >/dev/null 2>&1 && n=$((n+1))
  done <<EOF
$out
EOF
  printf '%s' "$n"
}

skip_lines() { printf '%s\n' "$1" | grep -c '^VERIFY SKIPPED'; }

ledger_lines_for_build() {  # ledger_lines_for_build <cwd> -> count of ledger
  # lines whose .cmd == "npm run build" (any exit code)
  [ -f "$1/.quetrex/verify-ledger.jsonl" ] || { echo 0; return; }
  jq -s '[.[] | select(.cmd=="npm run build")] | length' "$1/.quetrex/verify-ledger.jsonl" 2>/dev/null || echo 0
}

reset_gate_state() {  # reset_gate_state <cwd>
  rm -f "$1/.quetrex/verify-ledger.jsonl" "$1/.quetrex/verify-attempts" "$1/.quetrex/ESCALATION" "$1/.quetrex/verify-gate.log"
}

# =============================================================================
# RUNG 1 — BEFORE any derivation exists: the chain must genuinely run and
# block. This is the control that proves the fixture is real (not something
# that would have passed or been silently skipped regardless).
# =============================================================================
reset_gate_state "$FIX"
OUT1="$(run_gate "$FIX")"
CODE1=$?
BLOCKS1="$(block_decisions "$OUT1")"
SKIPS1="$(skip_lines "$OUT1")"
LEDGER1="$(ledger_lines_for_build "$FIX")"

[ "$CODE1" = 0 ] && [ "$BLOCKS1" = 1 ] && [ "$SKIPS1" = 0 ] && [ "$LEDGER1" = 1 ] \
  && pass "RUNG1: before derivation, the chain genuinely runs and blocks (exit $CODE1, blocks $BLOCKS1, skips $SKIPS1, ledger $LEDGER1)" \
  || fail "RUNG1: expected exit 0 / 1 block / 0 skip / 1 ledger line, got exit $CODE1 blocks $BLOCKS1 skips $SKIPS1 ledger $LEDGER1 (out: [$OUT1])"

# =============================================================================
# RUNG 2 — quetrex-env-derive scan discovers exactly the one candidate, from
# the real static scan, not an assumption about what it should find.
# =============================================================================
SCAN_OUT="$("$DERIVE" scan "$FIX" 2>&1)"
SCAN_CODE=$?
[ "$SCAN_CODE" = 0 ] && printf '%s' "$SCAN_OUT" | grep -qE '^QX_INTEG_DATABASE_URL[[:space:]]+src/config\.js:1$' \
  && pass "RUNG2: scan discovers QX_INTEG_DATABASE_URL at src/config.js:1 (exit $SCAN_CODE)" \
  || fail "RUNG2: expected exit 0 and 'QX_INTEG_DATABASE_URL\tsrc/config.js:1', got exit $SCAN_CODE (out: [$SCAN_OUT])"

# =============================================================================
# RUNG 3 — verify-json writes the requiredEnv entry for the REAL chain
# command, and .verify[] itself is untouched.
# =============================================================================
VERIFY_BEFORE="$(jq -S '.verify' "$FIX/.quetrex/verify.json")"
VJ_OUT="$("$DERIVE" verify-json "$FIX" 2>&1)"
VJ_CODE=$?
VERIFY_AFTER="$(jq -S '.verify' "$FIX/.quetrex/verify.json")"
REQ_ENTRY="$(jq -c '.requiredEnv["npm run build"] // empty' "$FIX/.quetrex/verify.json" 2>/dev/null)"

[ "$VJ_CODE" = 0 ] && pass "RUNG3: verify-json exits 0" || fail "RUNG3: verify-json exited $VJ_CODE (out: [$VJ_OUT])"
[ "$VERIFY_BEFORE" = "$VERIFY_AFTER" ] && pass "RUNG3: .verify[] is byte-identical after verify-json" \
  || fail "RUNG3: .verify[] changed: before=[$VERIFY_BEFORE] after=[$VERIFY_AFTER]"
[ "$REQ_ENTRY" = '["QX_INTEG_DATABASE_URL"]' ] && pass "RUNG3: requiredEnv[\"npm run build\"] == [\"QX_INTEG_DATABASE_URL\"]" \
  || fail "RUNG3: expected requiredEnv[\"npm run build\"] == [\"QX_INTEG_DATABASE_URL\"], got [$REQ_ENTRY]"

# =============================================================================
# RUNG 4 — SEC-2 HOLDS ACROSS THE BOUNDARY: the write from rung 3 is staged
# but NOT YET COMMITTED. The hook must still run the real command and block —
# an uncommitted requiredEnv association must never authorize a skip, exactly
# as ADV-G proves for the `gate` side in isolation. This is the one assertion
# in this file that a bug straddling BOTH workstreams (derive writes it,
# gate reads it) could slip through if either side were tested alone.
# =============================================================================
git -C "$FIX" add .quetrex/verify.json
PORCELAIN="$(git -C "$FIX" status --porcelain -- .quetrex/verify.json)"
[ -n "$PORCELAIN" ] && pass "RUNG4: fixture sanity — requiredEnv change is staged but uncommitted ($PORCELAIN)" \
  || fail "RUNG4: fixture setup bug — expected a staged, uncommitted change"

reset_gate_state "$FIX"
OUT4="$(run_gate "$FIX")"
CODE4=$?
BLOCKS4="$(block_decisions "$OUT4")"
SKIPS4="$(skip_lines "$OUT4")"
LEDGER4="$(ledger_lines_for_build "$FIX")"

[ "$CODE4" = 0 ] && [ "$BLOCKS4" = 1 ] && [ "$SKIPS4" = 0 ] && [ "$LEDGER4" = 1 ] \
  && pass "RUNG4: an UNCOMMITTED requiredEnv (staged, not committed) does NOT authorize a skip — the chain still runs and blocks" \
  || fail "RUNG4: uncommitted requiredEnv incorrectly influenced the outcome — exit $CODE4 blocks $BLOCKS4 skips $SKIPS4 ledger $LEDGER4 (out: [$OUT4])"

# =============================================================================
# RUNG 5 — commit it. THIS is the moment the declaration becomes reviewable
# (SEC-2's whole point), and the only moment the skip is allowed to fire.
# =============================================================================
git -C "$FIX" commit -q -m "declare requiredEnv for npm run build"

reset_gate_state "$FIX"
# Pre-seed ESCALATION to prove a skip-only run does not clear it (mirrors
# AC7/AC15's own assertion, re-proven here against THIS fresh fixture).
: > "$FIX/.quetrex/ESCALATION"

OUT5="$(run_gate "$FIX")"
CODE5=$?
BLOCKS5="$(block_decisions "$OUT5")"
SKIPS5="$(skip_lines "$OUT5")"
LEDGER5="$(ledger_lines_for_build "$FIX")"
NAMES_VAR5="$(printf '%s\n' "$OUT5" | grep -c 'QX_INTEG_DATABASE_URL')"

[ "$CODE5" = 0 ] && pass "RUNG5: hook exit code == 0 once requiredEnv is committed" \
  || fail "RUNG5: hook exited $CODE5, expected 0 (out: [$OUT5])"
[ "$BLOCKS5" = 0 ] && pass "RUNG5: 0 block decisions" \
  || fail "RUNG5: expected 0 block decisions, got $BLOCKS5 (out: [$OUT5])"
[ "$SKIPS5" = 1 ] && pass "RUNG5: exactly 1 VERIFY SKIPPED line" \
  || fail "RUNG5: expected exactly 1 VERIFY SKIPPED line, got $SKIPS5 (out: [$OUT5])"
[ "$NAMES_VAR5" -ge 1 ] && pass "RUNG5: the skip line names QX_INTEG_DATABASE_URL" \
  || fail "RUNG5: the skip line never names the variable (out: [$OUT5])"
[ "$LEDGER5" = 0 ] && pass "RUNG5: the ledger has 0 lines for the skipped command (skip containment)" \
  || fail "RUNG5: expected 0 ledger lines for npm run build, got $LEDGER5"
[ -f "$FIX/.quetrex/ESCALATION" ] && pass "RUNG5: a skip-only run does not clear a pre-seeded ESCALATION" \
  || fail "RUNG5: ESCALATION was cleared by a run that only skipped (never proved anything green)"

# =============================================================================
# RUNG 6 — SKIP CONTAINMENT ACROSS THE MERGE BOUNDARY: chain the rung-5
# post-skip state directly into the REAL merge-gate.sh with an otherwise
# legitimate, HEAD-pinned AUTO_MERGE verdict. If the skip could ever be
# laundered into a mergeable state, this is where it would show up — and
# neither test/verify-gate.test.sh nor test/env-derive.test.sh exercises
# merge-gate.sh at all.
# =============================================================================
HEAD_SHA="$(git -C "$FIX" rev-parse HEAD)"
jq -cn --arg sha "$HEAD_SHA" \
  '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
  > "$FIX/.quetrex/review-verdict.json"
rm -f "$FIX/.quetrex/security-findings.json"

# Constructed at runtime, not spelled literally, so this file's own text
# never contains the merge command string (mirrors test/merge-gate.test.sh's
# own convention, for the same reason: this repo's PreToolUse gate reads the
# command string of every Bash call, including the one running this test).
GH_MERGE_CMD="$(printf 'gh pr mer%s' 'ge') 999 --squash"
MERGE_PAYLOAD="$(jq -cn --arg cmd "$GH_MERGE_CMD" --arg cwd "$FIX" '{tool_input:{command:$cmd},cwd:$cwd}')"
MERGE_OUT="$(printf '%s' "$MERGE_PAYLOAD" | CLAUDE_PROJECT_DIR="$FIX" "$MERGE_HOOK" 2>&1)"
MERGE_CODE=$?

IS_DENY=0
printf '%s' "$MERGE_OUT" | grep -q '"permissionDecision":"deny"' && IS_DENY=1

[ "$MERGE_CODE" = 0 ] && [ "$IS_DENY" = 1 ] \
  && pass "RUNG6: merge-gate.sh still DENIES a post-skip state even with a HEAD-pinned AUTO_MERGE verdict (skip containment holds at the merge boundary)" \
  || fail "RUNG6: merge-gate.sh did not deny a post-skip, no-ledger-proof state — exit $MERGE_CODE deny=$IS_DENY (out: [$MERGE_OUT])"

# =============================================================================
# RUNG 7 — POSITIVE CONTROL: this is not an unconditional skip. With the
# variable genuinely present in the hook's environment, the chain runs FOR
# REAL and the command's actual (successful) exit code is what proves the
# gate, not a skip.
# =============================================================================
reset_gate_state "$FIX"
PAYLOAD7="$(hook_payload "$FIX")"
OUT7="$(printf '%s' "$PAYLOAD7" | QX_INTEG_DATABASE_URL="postgres://fixture" CLAUDE_PROJECT_DIR="$FIX" QUETREX_VERIFY_MAX=3 "$GATE_HOOK" 2>&1)"
CODE7=$?
BLOCKS7="$(block_decisions "$OUT7")"
SKIPS7="$(skip_lines "$OUT7")"
LEDGER7_ALL="$(jq -s '[.[] | select(.cmd=="npm run build")]' "$FIX/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
LEDGER7_EXIT0="$(printf '%s' "$LEDGER7_ALL" | jq '[.[] | select(.exit==0)] | length' 2>/dev/null)"

[ "$CODE7" = 0 ] && [ "$BLOCKS7" = 0 ] && [ "$SKIPS7" = 0 ] && [ "$LEDGER7_EXIT0" = 1 ] \
  && pass "RUNG7: POSITIVE CONTROL — with the variable genuinely set, the command runs for real and succeeds (no skip, exit 0 ledger line)" \
  || fail "RUNG7: expected the real command to run and pass with 0 skips when the var is set — exit $CODE7 blocks $BLOCKS7 skips $SKIPS7 ledger-exit0 $LEDGER7_EXIT0 (out: [$OUT7])"

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "verify-gate-env-derive-integration.test.sh: all checks passed"
  exit 0
else
  echo
  echo "verify-gate-env-derive-integration.test.sh: FAILURES ABOVE"
  exit 1
fi
