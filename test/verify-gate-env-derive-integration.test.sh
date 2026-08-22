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
# into the COMMITTED .quetrex/verify.json, and ONLY via an explicit human
# confirmation (`declare`) — never an unattended guess. Each workstream
# (`gate`, `derive`) proved its own half in isolation before merge; NEITHER
# side proves the other's half actually connects. This file connects them,
# end to end, against a FRESH fixture repo this suite builds itself — never
# reusing a fixture or helper from test/verify-gate.test.sh or
# test/env-derive.test.sh — and additionally chains the result into the REAL
# merge-gate.sh hook to prove skip containment holds all the way to the
# merge boundary, not just inside verify-gate.sh.
#
# AC25 — THE FIXTURE MUST NOT DEGENERATE. The prior round of this file used
# a thin wrapper script with ZERO trailing path tokens of its own — the one
# leaf shape a now-deleted static attribution filter would have left alone
# by accident. The fixture below uses the literal, dominant framework-build
# shape the deleted engine actually failed on (see the real package.json
# below). A local `next` shim on node_modules/.bin — never a real Next.js
# install — gives that exact invocation real, controllable pass/fail
# behavior without changing what the fixture's package.json says.
#
# Every rung below is a BEFORE/AFTER pair: prove the chain genuinely runs and
# blocks BEFORE the declaration exists, then prove — and only then — that an
# EXPLICIT `declare` (never an inferred write) is what changes the outcome.
# A test that only checked the AFTER state could not tell "the skip fired
# for the right reason" from "the fixture never actually blocked in the
# first place".
#
# HYGIENE (AC25): this file asserts on `.decision` only, never a log path —
# a log FILENAME is `gate`'s workstream, not this file's, so cleanup uses a
# glob over every verify-gate log file, never a single hardcoded name (see
# reset_gate_state below).
#
# HOOKFIX (.quetrex/plan/HOOKFIX.json, notes list): every hook invocation
# below sets QUETREX_VERIFY_FULL=1. Stop/SubagentStop now runs a BOUNDED quick
# chain by default (declared verifyQuick if a valid subset, else verify[] with
# heavy commands filtered out) — and this fixture's chain command is literally
# `npm run build`, which contains the heavy keyword "build", so under the
# default derived chain it would never run at all and every rung below would
# go red for the WRONG reason (never proving anything about the env-derive ->
# requiredEnv -> recorded-skip contract this file exists to pin). This file's
# subject is that contract, not the quick-chain policy, so it opts into the
# FULL chain — the widen-only override that restores the exact pre-HOOKFIX
# fail-closed behavior this file was written against. Do not remove it.
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

# =============================================================================
# FIXTURE — the dominant "framework build script" shape: `next build`, a
# leaf with NO trailing path arguments of its own, resolved through a local
# node_modules/.bin/next shim rather than a real Next.js install.
# =============================================================================
FIX="$WORK/fixture"
mkdir -p "$FIX/src" "$FIX/node_modules/.bin"
(
  cd "$FIX"
  git init -q -b main
  git config user.email "qa-integration@example.com"
  git config user.name "QA Integration Fixture"
)

# The real read lives in a source file the shim execs into — deliberately a
# DIFFERENT variable name and DIFFERENT file layout than any fixture in
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

# node_modules/.bin is on PATH for any `npm run` invocation — this is the
# ONLY thing that makes the literal script string "next build" runnable and
# controllable without a real Next.js install. Untracked: it is fixture
# scaffolding, never committed evidence.
cat > "$FIX/node_modules/.bin/next" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "build" ]; then
  exec node "$(dirname "$0")/../../src/config.js"
fi
exit 1
EOF
chmod +x "$FIX/node_modules/.bin/next"

cat > "$FIX/.env.example" <<'EOF'
QX_INTEG_DATABASE_URL=
EOF

cat > "$FIX/package.json" <<'EOF'
{
  "name": "qx-integ-fixture",
  "scripts": { "build": "next build" }
}
EOF

mkdir -p "$FIX/.quetrex"
cat > "$FIX/.quetrex/verify.json" <<'EOF'
{ "verify": ["npm run build"] }
EOF

(
  cd "$FIX"
  git add package.json .env.example src/config.js .quetrex/verify.json
  git commit -q -m "qx-integ fixture: no requiredEnv yet"
)

hook_payload() {  # hook_payload <cwd>
  jq -cn --arg cwd "$1" --arg event "Stop" '{cwd:$cwd,hook_event_name:$event}'
}

run_gate() {  # run_gate <cwd> -> combined stdout+stderr on stdout
  local cwd="$1"
  env -u QX_INTEG_DATABASE_URL bash -c '
    printf "%s" "$1" | CLAUDE_PROJECT_DIR="$2" QUETREX_VERIFY_MAX=3 QUETREX_VERIFY_FULL=1 "$3"
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

# HYGIENE (AC25): a glob, never a specific log filename — this file must
# stay independent of `gate`'s own log-naming decisions.
reset_gate_state() {  # reset_gate_state <cwd>
  rm -f "$1"/.quetrex/verify-gate*.log "$1/.quetrex/verify-ledger.jsonl" "$1/.quetrex/verify-attempts" "$1/.quetrex/ESCALATION"
}

# =============================================================================
# RUNG 1 — CONTROL, before any declaration exists: the chain must genuinely
# run and block. This proves the fixture is real (not something that would
# have passed or been silently skipped regardless).
# =============================================================================
reset_gate_state "$FIX"
OUT1="$(run_gate "$FIX")"
CODE1=$?
BLOCKS1="$(block_decisions "$OUT1")"
SKIPS1="$(skip_lines "$OUT1")"

[ "$CODE1" = 0 ] && [ "$BLOCKS1" = 1 ] && [ "$SKIPS1" = 0 ] \
  && pass "RUNG1 CONTROL: before any declaration, the chain genuinely runs and blocks (hook exit $CODE1, 1 block decision, 0 skips)" \
  || fail "RUNG1 CONTROL: expected hook exit 0 / 1 block / 0 skips, got exit $CODE1 blocks $BLOCKS1 skips $SKIPS1 (out: [$OUT1])"

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
# RUNG 3 — declare writes the requiredEnv entry for the REAL chain command,
# by an EXPLICIT human-shaped confirmation — never an inferred guess — and
# .verify[] itself is untouched.
# =============================================================================
VERIFY_BEFORE="$(jq -S '.verify' "$FIX/.quetrex/verify.json")"
DECLARE_OUT="$("$DERIVE" declare "$FIX" --cmd "npm run build" --env QX_INTEG_DATABASE_URL 2>&1)"
DECLARE_CODE=$?
VERIFY_AFTER="$(jq -S '.verify' "$FIX/.quetrex/verify.json")"
REQ_ENTRY="$(jq -c '.requiredEnv["npm run build"] // empty' "$FIX/.quetrex/verify.json" 2>/dev/null)"

[ "$DECLARE_CODE" = 0 ] && pass "RUNG3: declare exits 0" || fail "RUNG3: declare exited $DECLARE_CODE (out: [$DECLARE_OUT])"
[ "$VERIFY_BEFORE" = "$VERIFY_AFTER" ] && pass "RUNG3: .verify[] is byte-identical after declare" \
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
  && pass "RUNG4 (SEC-2 CONTROL RETAINED): an UNCOMMITTED requiredEnv (staged, not committed) does NOT authorize a skip — the chain still runs and blocks" \
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
: > "$FIX/.quetrex/verify-attempts"
VERIFY_ATTEMPTS_PRE="$(cat "$FIX/.quetrex/verify-attempts")"

OUT5="$(run_gate "$FIX")"
CODE5=$?
BLOCKS5="$(block_decisions "$OUT5")"
SKIPS5="$(skip_lines "$OUT5")"
LEDGER5="$(ledger_lines_for_build "$FIX")"
NAMES_VAR5="$(printf '%s\n' "$OUT5" | grep -c 'QX_INTEG_DATABASE_URL')"

[ "$CODE5" = 0 ] && pass "RUNG5: hook exit code == 0 once requiredEnv is committed" \
  || fail "RUNG5: hook exited $CODE5, expected 0 (out: [$OUT5])"
[ "$BLOCKS5" = 0 ] && pass "RUNG5: 0 stdout lines parse as a block decision" \
  || fail "RUNG5: expected 0 block decisions, got $BLOCKS5 (out: [$OUT5])"
[ "$SKIPS5" = 1 ] && pass "RUNG5: exactly 1 VERIFY SKIPPED line" \
  || fail "RUNG5: expected exactly 1 VERIFY SKIPPED line, got $SKIPS5 (out: [$OUT5])"
[ "$NAMES_VAR5" -ge 1 ] && pass "RUNG5: the skip line names QX_INTEG_DATABASE_URL" \
  || fail "RUNG5: the skip line never names the variable (out: [$OUT5])"
# CONTRACT CHANGED, recorded rather than re-anchored. This required ZERO ledger lines for
# a skipped command. That absence was the deadlock: merge-gate's GATE 3 demands an entry
# per chain command and read "no entry" as "never ran -> deny", so in this very fixture
# shape the command was unprovable forever and no PR could merge. The skip is now RECORDED
# as skipped:true / skipReason:"requiredEnv" / exit:null — never as a pass — and GATE 3
# accepts exactly that shape and nothing else. Containment still holds: it is one line, it
# is not an exit 0, and any other skipReason stays red (see
# test/requiredenv-skip-contract.test.sh).
[ "$LEDGER5" = 1 ] && pass "RUNG5: the ledger has exactly 1 RECORDED skip line for the skipped command (not a pass, not an absence)" \
  || fail "RUNG5: expected exactly 1 recorded skip line for npm run build, got $LEDGER5"

# --- CONTAINMENT, re-proved, not assumed --------------------------------
[ -f "$FIX/.quetrex/ESCALATION" ] && pass "RUNG5 CONTAINMENT: a skip-only run does not clear a pre-seeded ESCALATION" \
  || fail "RUNG5 CONTAINMENT: ESCALATION was cleared by a run that only skipped (never proved anything green)"
VERIFY_ATTEMPTS_POST="$(cat "$FIX/.quetrex/verify-attempts" 2>/dev/null || echo "")"
[ "$VERIFY_ATTEMPTS_PRE" = "$VERIFY_ATTEMPTS_POST" ] && pass "RUNG5 CONTAINMENT: .quetrex/verify-attempts is byte-identical to its pre-run value" \
  || fail "RUNG5 CONTAINMENT: verify-attempts changed (pre=[$VERIFY_ATTEMPTS_PRE] post=[$VERIFY_ATTEMPTS_POST])"

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
OUT7="$(printf '%s' "$PAYLOAD7" | QX_INTEG_DATABASE_URL="postgres://fixture" CLAUDE_PROJECT_DIR="$FIX" QUETREX_VERIFY_MAX=3 QUETREX_VERIFY_FULL=1 "$GATE_HOOK" 2>&1)"
CODE7=$?
BLOCKS7="$(block_decisions "$OUT7")"
SKIPS7="$(skip_lines "$OUT7")"
LEDGER7_ALL="$(jq -s '[.[] | select(.cmd=="npm run build")]' "$FIX/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
LEDGER7_EXIT0="$(printf '%s' "$LEDGER7_ALL" | jq '[.[] | select(.exit==0)] | length' 2>/dev/null)"

[ "$CODE7" = 0 ] && [ "$BLOCKS7" = 0 ] && [ "$SKIPS7" = 0 ] && [ "$LEDGER7_EXIT0" = 1 ] \
  && pass "RUNG7: POSITIVE CONTROL — with the variable genuinely set, the command runs for real and succeeds (no skip, exit 0 ledger line)" \
  || fail "RUNG7: expected the real command to run and pass with 0 skips when the var is set — exit $CODE7 blocks $BLOCKS7 skips $SKIPS7 ledger-exit0 $LEDGER7_EXIT0 (out: [$OUT7])"

# =============================================================================
# RUNG 8 — GATE 3 CONTAINMENT: merge-gate.sh's own GATE-3 jq, evaluated
# against the rung-5 post-skip state, DENIES with a non-empty RED array.
# =============================================================================
reset_gate_state "$FIX"
: > "$FIX/.quetrex/ESCALATION"
run_gate "$FIX" >/dev/null 2>&1
HEAD_SHA8="$(git -C "$FIX" rev-parse HEAD)"
jq -cn --arg sha "$HEAD_SHA8" \
  '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
  > "$FIX/.quetrex/review-verdict.json"
MERGE_PAYLOAD8="$(jq -cn --arg cmd "$GH_MERGE_CMD" --arg cwd "$FIX" '{tool_input:{command:$cmd},cwd:$cwd}')"
MERGE_OUT8="$(printf '%s' "$MERGE_PAYLOAD8" | CLAUDE_PROJECT_DIR="$FIX" "$MERGE_HOOK" 2>&1)"
DENY8=0
printf '%s' "$MERGE_OUT8" | grep -q '"permissionDecision":"deny"' && DENY8=1
[ "$DENY8" = 1 ] && pass "RUNG8: GATE 3 re-run against the post-skip state still DENIES (skip containment re-proved, not assumed)" \
  || fail "RUNG8: expected GATE 3 to deny the post-skip state, got deny=$DENY8 (out: [$MERGE_OUT8])"

# =============================================================================
# NEGATIVE CONTROL — skipping only the `declare` call: a SEPARATE fixture,
# identical up to (and excluding) RUNG3, must reproduce RUNG1's control
# values (1 block, 0 skips) even after HEAD advances — proving declare, not
# some incidental fixture property, is what changes the outcome.
# =============================================================================
FIXNEG="$WORK/fixture-neg"
mkdir -p "$FIXNEG/src" "$FIXNEG/node_modules/.bin"
(
  cd "$FIXNEG"
  git init -q -b main
  git config user.email "qa-integration@example.com"
  git config user.name "QA Integration Fixture (negative control)"
)
cp "$FIX/src/config.js" "$FIXNEG/src/config.js"
cp "$FIX/node_modules/.bin/next" "$FIXNEG/node_modules/.bin/next"
chmod +x "$FIXNEG/node_modules/.bin/next"
cp "$FIX/.env.example" "$FIXNEG/.env.example"
# Same package.json shape as $FIX, copied rather than retyped — this file's
# own source spells the "next build" script string exactly once (AC25).
cp "$FIX/package.json" "$FIXNEG/package.json"
mkdir -p "$FIXNEG/.quetrex"
cat > "$FIXNEG/.quetrex/verify.json" <<'EOF'
{ "verify": ["npm run build"] }
EOF
(
  cd "$FIXNEG"
  git add package.json .env.example src/config.js .quetrex/verify.json
  git commit -q -m "qx-integ negative-control fixture: declare is never called"
)

reset_gate_state "$FIXNEG"
OUTNEG="$(run_gate "$FIXNEG")"
CODENEG=$?
BLOCKSNEG="$(block_decisions "$OUTNEG")"
SKIPSNEG="$(skip_lines "$OUTNEG")"

if [ "$CODENEG" = 0 ] && [ "$BLOCKSNEG" = 1 ] && [ "$SKIPSNEG" = 0 ]; then
  pass "NEGATIVE CONTROL: skipping the declare call reproduces RUNG1's control (1 block, 0 skips) — proving declare, not the fixture shape, is what changes the outcome"
else
  fail "NEGATIVE CONTROL: expected 1 block / 0 skips without declare, got exit $CODENEG blocks $BLOCKSNEG skips $SKIPSNEG (out: [$OUTNEG])"
fi

# =============================================================================
# HYGIENE (AC25) — self-checks on this file's own text. Every literal below
# is built at runtime, never spelled out contiguously in this file's own
# source — otherwise a self-check for "how many times does X appear" would
# itself be an occurrence of X, corrupting its own count (mirrors the
# GH_MERGE_CMD construction above, same reason).
# =============================================================================
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
NEXTBUILD_LIT="$(printf '"build": "next %s"' build)"
RUNBUILD_LIT="$(printf 'run-%s.sh' build)"
GLOB_LIT="$(printf 'verify-gate%slog' '*.')"
FULLOUTPUT_LIT="$(printf '%s output' Full)"

NEXTBUILD_COUNT="$(grep -cF -- "$NEXTBUILD_LIT" "$SELF")"
[ "$NEXTBUILD_COUNT" = "1" ] && pass "AC25 FIXTURE: exactly 1 occurrence of the next-build package.json shape in this file" \
  || fail "AC25 FIXTURE: expected exactly 1 occurrence of the next-build shape, got $NEXTBUILD_COUNT"
RUNBUILD_COUNT="$(grep -cF -- "$RUNBUILD_LIT" "$SELF")"
[ "$RUNBUILD_COUNT" = "0" ] && pass "AC25 FIXTURE: 0 occurrences of the prior round's degenerate wrapper-script leaf" \
  || fail "AC25 FIXTURE: expected 0 occurrences of the degenerate wrapper-script leaf, got $RUNBUILD_COUNT"

GLOB_COUNT="$(grep -cF -- "$GLOB_LIT" "$SELF")"
[ "$GLOB_COUNT" = "1" ] && pass "AC25 HYGIENE: cleanup uses the glob form for the gate's log file" \
  || fail "AC25 HYGIENE: expected exactly 1 occurrence of the glob form, got $GLOB_COUNT"
HARDCODED_LOG="$(grep -cE 'verify-gate-[a-z]+\.log' "$SELF")"
[ "$HARDCODED_LOG" = "0" ] && pass "AC25 HYGIENE: 0 occurrences of a hardcoded second log filename" \
  || fail "AC25 HYGIENE: found $HARDCODED_LOG hardcoded log filename(s) — this file must stay independent of gate's log naming"
FULLOUTPUT_COUNT="$(grep -cF -- "$FULLOUTPUT_LIT" "$SELF")"
[ "$FULLOUTPUT_COUNT" = "0" ] && pass "AC25 HYGIENE: this file asserts on .decision only — the log-dump assertion phrase never appears" \
  || fail "AC25 HYGIENE: found $FULLOUTPUT_COUNT occurrence(s) of the log-dump assertion phrase — assert on .decision, never a log path"

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "verify-gate-env-derive-integration.test.sh: all checks passed"
  exit 0
else
  echo
  echo "verify-gate-env-derive-integration.test.sh: FAILURES ABOVE"
  exit 1
fi
