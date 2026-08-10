#!/usr/bin/env bash
# test/verify-gate.test.sh — contract test for .claude/hooks/verify-gate.sh
#
# Run: bash test/verify-gate.test.sh
#
# THE OPERATOR-VISIBLE DEFECT THIS PINS DOWN. verify-gate.sh used to interpolate
# a failing command's raw captured output (up to 20 lines, stack traces and
# all) directly into the {"decision":"block","reason":...} payload that Stop /
# SubagentStop surface. A Node stack trace read by the operator as "my cloud
# build failed" when it had not — costing two rounds of doubt and nearly
# firing a duplicate cloud routine on a healthy run. This suite proves the
# fixes without weakening the gate itself:
#   (a) QUIET — a genuinely red chain still blocks, but the reason is a short,
#       labelled summary; the raw command output never reaches stdout/stderr,
#       only a log file on disk (AC1, AC2).
#   (b) NO MAIN-CHECKOUT DEFERRAL, EVER — the main-checkout worktree-deferral
#       skip (formerly AC3) was DELETED OUTRIGHT (SEC-1, high): no filesystem
#       state a gated agent can create — a stale entry, a decoy worktree, a
#       decoy with genuine ledger proof, a hand-fabricated ledger line, or an
#       abandoned once-proven worktree — can ever again ungate the main
#       checkout. The chain now runs there in every state (AC10), and AC4(i)/
#       AC4(ii) confirm the guard's removal narrows nothing else. ADV-A,
#       ADV-E, ADV-F, ADV-I and ADV-J are the permanent anti-reintroduction
#       controls for this class.
#   (c) DECLARATIVE ENV SKIP — a command whose declared `requiredEnv` var is
#       genuinely absent from this checkout is skipped pre-flight, never
#       executed, never laundered from its own output (AC5); the skip cannot
#       be abused to escape the gate (AC6) and is not a green: it writes no
#       ledger line and never clears a prior escalation (AC7).
#
# The gate ships in TWO places: this repo (the `quetrex` plugin) and
# quetrex-factory/scripts/verify-gate.sh (the engine plugin every armed repo
# runs, currently drifted — see .quetrex/plan/VERIFY-GATE-QUIET.json). Point
# the identical suite at either copy so a fix can be PROVEN in the one teams
# actually execute, not just the canonical one:
#   QX_VERIFY_GATE_HOOK=/path/to/verify-gate.sh bash test/verify-gate.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/.claude/hooks/verify-gate.sh}"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — verify-gate.sh is jq-preferred, nothing to test"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }
# Distinct from both: an assertion that is only meaningful for quetrex-base's
# OWN copy (e.g. a line-count delta against a quetrex-base commit sha) is
# N/A, not proven, against a foreign hook pointed at by QX_VERIFY_GATE_HOOK.
# Printing 'ok' would be a silent false pass; printing 'NOT OK' would fail a
# file for not being a copy it was never claimed to be. SKIP is neither —
# it does not touch FAIL and is not counted by a plain `grep -c '^ok '`.
skip() { printf 'SKIP - %s\n' "$1"; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-gate-test.XXXXXX")"
cleanup() { rm -rf "$TMPROOT"; }
trap cleanup EXIT

git_init_repo() {  # git_init_repo <path>
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Fixture"
  echo "fixture" > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m "chore: fixture commit"
}

line_count() {  # line_count <file> -> 0 if absent
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0
}

# run_hook <cwd> <event> — invoke the hook under test with a minimal Stop /
# SubagentStop payload, FIXTURE_DB_URL guaranteed NOT ambiently set.
run_hook() {
  local cwd="$1" event="$2" payload
  payload="$(jq -cn --arg cwd "$cwd" --arg event "$event" '{cwd:$cwd,hook_event_name:$event}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" QUETREX_VERIFY_MAX="${QUETREX_VERIFY_MAX:-3}" "$HOOK"
}

# run_hook_dbvar <cwd> <event> <value> — same, but with FIXTURE_DB_URL exported
# to the hook's own environment for the duration of the call.
run_hook_dbvar() {
  local cwd="$1" event="$2" val="$3" payload
  payload="$(jq -cn --arg cwd "$cwd" --arg event "$event" '{cwd:$cwd,hook_event_name:$event}')"
  printf '%s' "$payload" | FIXTURE_DB_URL="$val" CLAUDE_PROJECT_DIR="$cwd" QUETREX_VERIFY_MAX="${QUETREX_VERIFY_MAX:-3}" "$HOOK"
}

is_block_json() {  # is_block_json <line> -> true if it parses as a block decision
  printf '%s' "$1" | jq -e '.decision == "block"' >/dev/null 2>&1
}

count_block_decisions() {  # count_block_decisions <combined-stdout> -> N
  local out="$1" n=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    is_block_json "$line" && n=$((n + 1))
  done <<EOF
$out
EOF
  printf '%s' "$n"
}

count_skip_lines() {  # count_skip_lines <combined-stdout> -> N matching ^VERIFY SKIPPED
  printf '%s\n' "$1" | grep -c '^VERIFY SKIPPED'
}

# =============================================================================
# AC1 — QUIET: a raw interpreter stack trace never reaches stdout/stderr; the
# full output lands on disk instead, and the block reason stays short and
# names the log.
# =============================================================================
F1="$TMPROOT/ac1"
git_init_repo "$F1"
mkdir -p "$F1/.quetrex"
cat > "$F1/node_fail.sh" <<'SCRIPT'
#!/usr/bin/env bash
{
  echo "/app/src/index.js:42"
  echo "TypeError: undefined is not a function"
  echo "    throw new Error('boom');"
  echo "    ^"
  echo ""
  echo "Error: boom"
  echo "    at Object.<anonymous> (/app/src/index.js:42:9)"
  echo "    at Module._compile (node:internal/modules/cjs/loader:1105:14)"
  echo "    at Module._extensions..js (node:internal/modules/cjs/loader:1159:10)"
  echo "    at Module.load (node:internal/modules/cjs/loader:981:32)"
  echo "    at Function.Module._load (node:internal/modules/cjs/loader:822:12)"
  echo "Node.js v24.11.1"
} >&2
exit 1
SCRIPT
chmod +x "$F1/node_fail.sh"
NODE_CMD="bash \"$F1/node_fail.sh\""
jq -cn --arg c "$NODE_CMD" '{verify:[$c]}' > "$F1/.quetrex/verify.json"

OUT1="$(run_hook "$F1" "Stop" 2>&1)"; CODE1=$?

for lit in 'throw new Error(' 'at Object.<anonymous>' 'Node.js v'; do
  n="$(printf '%s' "$OUT1" | grep -c -- "$lit")"
  if [ "$n" -eq 0 ]; then
    pass "AC1: literal '$lit' never reaches stdout/stderr"
  else
    fail "AC1: literal '$lit' leaked into stdout/stderr ($n occurrence(s))"
  fi
done

REASON1="$(printf '%s' "$OUT1" | jq -r '.reason // empty' 2>/dev/null)"
REASON1_LINES="$(printf '%s' "$REASON1" | grep -c '' 2>/dev/null || echo 0)"
if [ -n "$REASON1" ] && [ "$REASON1_LINES" -le 3 ]; then
  pass "AC1: block .reason is <= 3 newline-separated lines (got $REASON1_LINES)"
else
  fail "AC1: block .reason should be <= 3 lines and non-empty, got ($REASON1_LINES lines): [$REASON1]"
fi

if printf '%s' "$REASON1" | grep -q '\.quetrex/verify-gate-failed\.log'; then
  pass "AC1: block .reason references .quetrex/verify-gate-failed.log (the preserved-failure slot, AC26)"
else
  fail "AC1: block .reason does not reference .quetrex/verify-gate-failed.log: [$REASON1]"
fi

LOG1="$F1/.quetrex/verify-gate.log"
if [ -f "$LOG1" ]; then
  pass "AC1: .quetrex/verify-gate.log exists on disk"
  if [ "$(grep -c 'at Object.<anonymous>' "$LOG1" 2>/dev/null)" -ge 1 ]; then
    pass "AC1: the full stack trace is captured in the log file"
  else
    fail "AC1: the log file does not contain the failing command's output"
  fi
else
  fail "AC1: .quetrex/verify-gate.log was not created"
fi

if [ "$CODE1" -eq 0 ]; then
  pass "AC1: hook exit code == 0 (block form delivered via JSON, not a hook error)"
else
  fail "AC1: expected hook exit code 0, got $CODE1"
fi

# =============================================================================
# AC2 — quieting the output changes NOTHING about the blocking decision: the
# same red fixture blocks on all 3 attempts and escalates on the 3rd, exactly
# as before.
# =============================================================================
F2="$TMPROOT/ac2"
git_init_repo "$F2"
mkdir -p "$F2/.quetrex"
cat > "$F2/node_fail.sh" <<'SCRIPT'
#!/usr/bin/env bash
{
  echo "throw new Error('boom');"
  echo "    at Object.<anonymous> (/app/src/index.js:1:1)"
  echo "Node.js v24.11.1"
} >&2
exit 1
SCRIPT
chmod +x "$F2/node_fail.sh"
NODE_CMD2="bash \"$F2/node_fail.sh\""
jq -cn --arg c "$NODE_CMD2" '{verify:[$c]}' > "$F2/.quetrex/verify.json"

QUETREX_VERIFY_MAX=3
ALL_BLOCKED=1
for i in 1 2 3; do
  OUT2="$(run_hook "$F2" "Stop" 2>&1)"; CODE2=$?
  DECIDES_BLOCK=0
  if printf '%s' "$OUT2" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    DECIDES_BLOCK=1
  elif [ "$CODE2" -eq 2 ]; then
    DECIDES_BLOCK=1
  fi
  if [ "$DECIDES_BLOCK" -ne 1 ]; then
    ALL_BLOCKED=0
    fail "AC2: invocation $i/3 did not block (exit $CODE2, out: [$OUT2])"
  fi
done
[ "$ALL_BLOCKED" -eq 1 ] && pass "AC2: all 3/3 invocations produced a block decision"

ATTEMPTS2="$(cat "$F2/.quetrex/verify-attempts" 2>/dev/null || echo '')"
if [ "$ATTEMPTS2" = "3" ]; then
  pass "AC2: .quetrex/verify-attempts contains exactly '3' after the third invocation"
else
  fail "AC2: expected verify-attempts == '3', got [$ATTEMPTS2]"
fi

ESC_COUNT2="$(ls -1 "$F2/.quetrex/ESCALATION" 2>/dev/null | wc -l | tr -d ' ')"
if [ "$ESC_COUNT2" = "1" ]; then
  pass "AC2: .quetrex/ESCALATION exists after the third invocation"
else
  fail "AC2: expected exactly 1 ESCALATION file, found $ESC_COUNT2"
fi

LEDGER2="$F2/.quetrex/verify-ledger.jsonl"
LEDGER2_LINES="$(line_count "$LEDGER2")"
if [ "$LEDGER2_LINES" = "3" ]; then
  pass "AC2: verify-ledger.jsonl gained exactly 1 line per invocation (3 total)"
else
  fail "AC2: expected 3 ledger lines (one per invocation), found $LEDGER2_LINES"
fi
LEDGER2_OK=1
if [ -f "$LEDGER2" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    ex="$(printf '%s' "$l" | jq -r '.exit')"
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    [ "$ex" = "1" ] || LEDGER2_OK=0
    [ "$cm" = "$NODE_CMD2" ] || LEDGER2_OK=0
  done < "$LEDGER2"
fi
if [ "$LEDGER2_OK" -eq 1 ]; then
  pass "AC2: every ledger line has .exit == 1 and .cmd byte-for-byte equal to the failing command"
else
  fail "AC2: a ledger line had an unexpected .exit or .cmd"
fi

# =============================================================================
# AC4 — the removal of the main-checkout deferral (see AC10) narrows nothing
# else: a linked pipeline worktree still runs its own chain normally when
# invoked directly (AC4(ii)), and the main checkout runs its own chain
# normally once that worktree is gone (AC4(i)). (AC3, which used to assert
# that the main checkout DEFERRED to the worktree instead of running, is
# MOOT now that the deferral is deleted outright — see AC10 for its inverse.)
# =============================================================================
MAIN3="$TMPROOT/ac3-main"
git_init_repo "$MAIN3"
mkdir -p "$MAIN3/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$MAIN3/.quetrex/project.json"
printf '{"verify":["false"]}' > "$MAIN3/.quetrex/verify.json"
git -C "$MAIN3" add .quetrex/project.json .quetrex/verify.json
git -C "$MAIN3" commit -q -m "chore: add quetrex config"
WT3="${MAIN3}-wt"
git -C "$MAIN3" worktree add -q -b claude/T-1-x "$WT3" >/dev/null 2>&1

# --- AC4(ii): invoked from INSIDE the linked worktree -> chain runs & blocks -
LEDGER_WT3="$WT3/.quetrex/verify-ledger.jsonl"
BEFORE_WT_LEDGER="$(line_count "$LEDGER_WT3")"
OUT4ii="$(run_hook "$WT3" "Stop" 2>&1)"; CODE4ii=$?
BLOCKS4ii="$(count_block_decisions "$OUT4ii")"
SKIPS4ii="$(count_skip_lines "$OUT4ii")"
AFTER_WT_LEDGER="$(line_count "$LEDGER_WT3")"
if [ "$CODE4ii" -eq 0 ] && [ "$BLOCKS4ii" = "1" ]; then
  pass "AC4(ii): invoked inside the worktree itself -> chain runs and blocks normally"
else
  fail "AC4(ii): expected exit 0 + 1 block decision, got exit $CODE4ii blocks $BLOCKS4ii (out: [$OUT4ii])"
fi
if [ "$SKIPS4ii" = "0" ]; then
  pass "AC4(ii): no VERIFY SKIPPED line when invoked inside the worktree"
else
  fail "AC4(ii): unexpected VERIFY SKIPPED line inside the worktree"
fi
if [ "$AFTER_WT_LEDGER" = "$((BEFORE_WT_LEDGER + 1))" ]; then
  pass "AC4(ii): exactly 1 ledger line appended in the worktree"
else
  fail "AC4(ii): expected ledger to gain exactly 1 line, went $BEFORE_WT_LEDGER -> $AFTER_WT_LEDGER"
fi

# --- AC4(i): the linked worktree is REMOVED -> main checkout runs normally --
git -C "$MAIN3" worktree remove "$WT3" --force >/dev/null 2>&1
LEDGER3="$MAIN3/.quetrex/verify-ledger.jsonl"
BEFORE_LEDGER4i="$(line_count "$LEDGER3")"
OUT4i="$(run_hook "$MAIN3" "Stop" 2>&1)"; CODE4i=$?
BLOCKS4i="$(count_block_decisions "$OUT4i")"
SKIPS4i="$(count_skip_lines "$OUT4i")"
AFTER_LEDGER4i="$(line_count "$LEDGER3")"
if [ "$CODE4i" -eq 0 ] && [ "$BLOCKS4i" = "1" ]; then
  pass "AC4(i): no linked worktree -> the main checkout runs the chain and blocks normally"
else
  fail "AC4(i): expected exit 0 + 1 block decision, got exit $CODE4i blocks $BLOCKS4i (out: [$OUT4i])"
fi
if [ "$SKIPS4i" = "0" ]; then
  pass "AC4(i): no VERIFY SKIPPED line once the pipeline worktree is gone"
else
  fail "AC4(i): unexpected VERIFY SKIPPED line with no pipeline worktree present"
fi
if [ "$AFTER_LEDGER4i" = "$((BEFORE_LEDGER4i + 1))" ]; then
  pass "AC4(i): exactly 1 ledger line appended"
else
  fail "AC4(i): expected ledger to gain exactly 1 line, went $BEFORE_LEDGER4i -> $AFTER_LEDGER4i"
fi

# =============================================================================
# AC5 — DECLARATIVE ENV SKIP: a command whose requiredEnv var is genuinely
# unavailable is skipped pre-flight and never executed.
# =============================================================================
mk_env_fixture() {  # mk_env_fixture <path> <requiredEnvKey> <requiredEnvVar> <envExampleVar>
  local d="$1" key="$2" var="$3" exvar="$4"
  git_init_repo "$d"
  mkdir -p "$d/.quetrex"
  jq -cn --arg k "$key" --arg v "$var" \
    '{verify:["true","false"],requiredEnv:{($k):[$v]}}' \
    > "$d/.quetrex/verify.json"
  printf '%s=\n' "$exvar" > "$d/.env.example"
  # BOTH files TRACKED AND COMMITTED, per security_surface constraint #2
  # ("visible in a reviewed diff") and SEC-2 (the requiredEnv mapping itself
  # must be read from the committed blob) — see ADV-B/ADV-C/ADV-G, which
  # assert the untracked/uncommitted cases separately.
  git -C "$d" add .env.example .quetrex/verify.json
  git -C "$d" commit -q -m "chore: declare $exvar in .env.example and requiredEnv in verify.json"
}

F5="$TMPROOT/ac5"
mk_env_fixture "$F5" "false" "FIXTURE_DB_URL" "FIXTURE_DB_URL"

OUT5="$(run_hook "$F5" "Stop" 2>&1)"; CODE5=$?

if [ "$CODE5" -eq 0 ]; then
  pass "AC5: hook exit code == 0"
else
  fail "AC5: expected exit 0, got $CODE5"
fi

BLOCKS5="$(count_block_decisions "$OUT5")"
if [ "$BLOCKS5" = "0" ]; then
  pass "AC5: 0 block decisions"
else
  fail "AC5: expected 0 block decisions, got $BLOCKS5 (out: [$OUT5])"
fi

SKIPS5="$(count_skip_lines "$OUT5")"
SKIP_LINE5="$(printf '%s\n' "$OUT5" | grep '^VERIFY SKIPPED' | head -n1)"
if [ "$SKIPS5" = "1" ] && printf '%s' "$SKIP_LINE5" | grep -q 'FIXTURE_DB_URL'; then
  pass "AC5: exactly 1 VERIFY SKIPPED line naming FIXTURE_DB_URL"
else
  fail "AC5: expected exactly 1 VERIFY SKIPPED line naming the var, got $SKIPS5 (out: [$OUT5])"
fi

LEDGER5="$F5/.quetrex/verify-ledger.jsonl"
LEDGER5_LINES="$(line_count "$LEDGER5")"
TRUE_OK=0; FALSE_COUNT=0
if [ -f "$LEDGER5" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    ex="$(printf '%s' "$l" | jq -r '.exit')"
    if [ "$cm" = "true" ] && [ "$ex" = "0" ]; then TRUE_OK=1; fi
    if [ "$cm" = "false" ]; then FALSE_COUNT=$((FALSE_COUNT + 1)); fi
  done < "$LEDGER5"
fi
if [ "$LEDGER5_LINES" = "1" ] && [ "$TRUE_OK" -eq 1 ] && [ "$FALSE_COUNT" -eq 0 ]; then
  pass "AC5: ledger contains exactly 1 new line ('true', exit 0) and 0 lines for the skipped command"
else
  fail "AC5: unexpected ledger content (lines=$LEDGER5_LINES trueOk=$TRUE_OK falseCount=$FALSE_COUNT)"
fi

# =============================================================================
# AC6 — requiredEnv cannot be used to ESCAPE the gate. In every variant the
# command still runs and its non-zero exit still blocks.
# =============================================================================
assert_ac6_blocks() {  # assert_ac6_blocks <label> <fixture>
  local label="$1" d="$2"
  local ledger="$d/.quetrex/verify-ledger.jsonl"
  local out code blocks skips
  out="$(run_hook "$d" "Stop" 2>&1)"; code=$?
  blocks="$(count_block_decisions "$out")"
  skips="$(count_skip_lines "$out")"
  if [ "$code" -eq 0 ] && [ "$blocks" = "1" ]; then
    pass "AC6($label): the command still ran and blocked"
  else
    fail "AC6($label): expected exit 0 + 1 block decision, got exit $code blocks $blocks (out: [$out])"
  fi
  if [ "$skips" = "0" ]; then
    pass "AC6($label): no VERIFY SKIPPED line"
  else
    fail "AC6($label): unexpected VERIFY SKIPPED line"
  fi
  local false_ok=0
  if [ -f "$ledger" ]; then
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      cm="$(printf '%s' "$l" | jq -r '.cmd')"
      ex="$(printf '%s' "$l" | jq -r '.exit')"
      if [ "$cm" = "false" ] && [ "$ex" = "1" ]; then false_ok=1; fi
    done < "$ledger"
  fi
  if [ "$false_ok" -eq 1 ]; then
    pass "AC6($label): ledger has exactly 1 line for the command with .exit == 1"
  else
    fail "AC6($label): expected a ledger line for 'false' with exit 1"
  fi
}

# (i) requiredEnv names a variable that does NOT appear as a key in .env.example
F6i="$TMPROOT/ac6i"
mk_env_fixture "$F6i" "false" "OTHER_VAR_NOT_IN_EXAMPLE" "FIXTURE_DB_URL"
assert_ac6_blocks "i-var-not-in-env-example" "$F6i"

# (ii) the requiredEnv key is not a byte-for-byte member of .verify[]
F6ii="$TMPROOT/ac6ii"
mk_env_fixture "$F6ii" "totally-different-command" "FIXTURE_DB_URL" "FIXTURE_DB_URL"
assert_ac6_blocks "ii-key-not-in-verify" "$F6ii"

# (iii) FIXTURE_DB_URL IS exported in the hook's environment
F6iii="$TMPROOT/ac6iii"
mk_env_fixture "$F6iii" "false" "FIXTURE_DB_URL" "FIXTURE_DB_URL"
LEDGER6iii="$F6iii/.quetrex/verify-ledger.jsonl"
OUT6iii="$(run_hook_dbvar "$F6iii" "Stop" "postgres://example" 2>&1)"; CODE6iii=$?
BLOCKS6iii="$(count_block_decisions "$OUT6iii")"
SKIPS6iii="$(count_skip_lines "$OUT6iii")"
if [ "$CODE6iii" -eq 0 ] && [ "$BLOCKS6iii" = "1" ]; then
  pass "AC6(iii-var-exported): the command still ran and blocked"
else
  fail "AC6(iii-var-exported): expected exit 0 + 1 block decision, got exit $CODE6iii blocks $BLOCKS6iii (out: [$OUT6iii])"
fi
if [ "$SKIPS6iii" = "0" ]; then
  pass "AC6(iii-var-exported): no VERIFY SKIPPED line"
else
  fail "AC6(iii-var-exported): unexpected VERIFY SKIPPED line"
fi

# (iv) FIXTURE_DB_URL unset in env, but declared as a key in a .env.local
F6iv="$TMPROOT/ac6iv"
mk_env_fixture "$F6iv" "false" "FIXTURE_DB_URL" "FIXTURE_DB_URL"
printf 'FIXTURE_DB_URL=local-value\n' > "$F6iv/.env.local"
assert_ac6_blocks "iv-declared-in-dotenv-local" "$F6iv"

# =============================================================================
# AC7 — a skip is not a green: no ledger line for the skipped command ever
# reads exit 0, and it must not clear a prior ESCALATION.
# =============================================================================
F7="$TMPROOT/ac7"
mk_env_fixture "$F7" "false" "FIXTURE_DB_URL" "FIXTURE_DB_URL"
mkdir -p "$F7/.quetrex"
touch "$F7/.quetrex/ESCALATION"

OUT7="$(run_hook "$F7" "Stop" 2>&1)"; CODE7=$?

LEDGER7="$F7/.quetrex/verify-ledger.jsonl"
FALSE_GREEN=0
if [ -f "$LEDGER7" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    ex="$(printf '%s' "$l" | jq -r '.exit')"
    if [ "$cm" = "false" ] && [ "$ex" = "0" ]; then FALSE_GREEN=1; fi
  done < "$LEDGER7"
fi
if [ "$FALSE_GREEN" -eq 0 ]; then
  pass "AC7: no ledger line has the skipped command at exit 0 (merge-gate GATE 3 cannot be satisfied by a skip)"
else
  fail "AC7: a skip produced a green ledger line for the skipped command"
fi

if [ -f "$F7/.quetrex/ESCALATION" ]; then
  pass "AC7: .quetrex/ESCALATION still exists after a skip-only run"
else
  fail "AC7: a skip-only run incorrectly cleared .quetrex/ESCALATION"
fi

SCHEMA_OK=1
if [ -f "$LEDGER7" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    keys="$(printf '%s' "$l" | jq -r 'keys | sort | join(",")' 2>/dev/null)"
    [ "$keys" = "cmd,cwd,exit,sha,tail,ts" ] || SCHEMA_OK=0
  done < "$LEDGER7"
fi
if [ "$SCHEMA_OK" -eq 1 ]; then
  pass "AC7: every new ledger line keeps the exact schema {ts,cmd,cwd,sha,exit,tail}"
else
  fail "AC7: a ledger line's key schema changed"
fi

if [ "$CODE7" -eq 0 ]; then
  pass "AC7: hook still exits 0 (allows the finish; a skip is not itself a block)"
else
  fail "AC7: expected exit 0, got $CODE7"
fi

# =============================================================================
# ADV-A — ANTI-REINTRODUCTION CONTROL (was: QA adversarial finding against the
# now-DELETED main-checkout deferral). A STALE/PRUNABLE linked-worktree entry
# (the worktree directory was removed with `rm -rf` instead of `git worktree
# remove`, so `git worktree list --porcelain` still reports it) must still
# result in the main checkout running its own chain — there is no code path
# left that could defer to it. If this ever regresses (the deferral is
# reintroduced), this is the state that would silently swallow a genuinely
# red chain: a candidate path that no longer exists on disk.
# =============================================================================
MAIN_A="$TMPROOT/adva-main"
git_init_repo "$MAIN_A"
mkdir -p "$MAIN_A/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$MAIN_A/.quetrex/project.json"
printf '{"verify":["false"]}' > "$MAIN_A/.quetrex/verify.json"
git -C "$MAIN_A" add .quetrex/project.json .quetrex/verify.json
git -C "$MAIN_A" commit -q -m "chore: add quetrex config"
WT_A="${MAIN_A}-wt"
git -C "$MAIN_A" worktree add -q -b claude/T-stale-adv "$WT_A" >/dev/null 2>&1
# Simulate a botched teardown: the worktree dir is gone but git still lists
# the (now prunable) entry until an explicit `git worktree prune` runs.
rm -rf "$WT_A"

LEDGER_A="$MAIN_A/.quetrex/verify-ledger.jsonl"
BEFORE_A="$(line_count "$LEDGER_A")"
OUTA="$(run_hook "$MAIN_A" "Stop" 2>&1)"; CODEA=$?
BLOCKSA="$(count_block_decisions "$OUTA")"
SKIPSA="$(count_skip_lines "$OUTA")"
AFTER_A="$(line_count "$LEDGER_A")"

if [ "$SKIPSA" = "0" ]; then
  pass "ADV-A: a stale/prunable worktree entry (dir gone, git still lists it) does NOT trigger VERIFY SKIPPED"
else
  fail "ADV-A: a stale/prunable worktree entry incorrectly deferred to a non-existent path — verification ran NOWHERE (out: [$OUTA])"
fi
if [ "$CODEA" -eq 0 ] && [ "$BLOCKSA" = "1" ]; then
  pass "ADV-A: the main checkout ran the chain itself and blocked on the real failure"
else
  fail "ADV-A: expected exit 0 + 1 block decision from main (no live worktree to defer to), got exit $CODEA blocks $BLOCKSA (out: [$OUTA])"
fi
if [ "$AFTER_A" = "$((BEFORE_A + 1))" ]; then
  pass "ADV-A: exactly 1 ledger line appended (chain genuinely ran somewhere)"
else
  fail "ADV-A: ledger did not gain a line — the chain ran NOWHERE ($BEFORE_A -> $AFTER_A)"
fi

# =============================================================================
# ADV-B — QA ADVERSARIAL: requiredEnv's `.env.example` declaration must be a
# TRACKED file (per .quetrex/plan/VERIFY-GATE-QUIET.json security_surface
# constraint #2: "visible in a reviewed diff"). An UNTRACKED .env.example
# sitting on disk (never `git add`ed) must NOT be honored as the repo's
# declaration of required config — otherwise an agent (running under
# bypassPermissions) could drop an invisible file that never appears in any
# reviewed diff and use it to skip a command whose real failure should block.
# =============================================================================
F_B="$TMPROOT/advb"
git_init_repo "$F_B"
mkdir -p "$F_B/.quetrex"
jq -cn '{verify:["true","false"],requiredEnv:{"false":["FIXTURE_DB_URL"]}}' \
  > "$F_B/.quetrex/verify.json"
# .env.example exists on disk but is deliberately left UNTRACKED (no git add).
printf 'FIXTURE_DB_URL=\n' > "$F_B/.env.example"
UNTRACKED_B="$(git -C "$F_B" status --porcelain -- .env.example)"
if [ -n "$UNTRACKED_B" ]; then
  pass "ADV-B: fixture sanity check — .env.example is genuinely untracked ($UNTRACKED_B)"
else
  fail "ADV-B: fixture setup bug — .env.example unexpectedly tracked"
fi

LEDGER_B="$F_B/.quetrex/verify-ledger.jsonl"
OUTB="$(run_hook "$F_B" "Stop" 2>&1)"; CODEB=$?
BLOCKSB="$(count_block_decisions "$OUTB")"
SKIPSB="$(count_skip_lines "$OUTB")"

if [ "$SKIPSB" = "0" ]; then
  pass "ADV-B: an UNTRACKED .env.example does not authorize a requiredEnv skip"
else
  fail "ADV-B: an untracked (never-reviewed) .env.example was honored to skip \`false\` — requiredEnv can be escaped invisibly (out: [$OUTB])"
fi
if [ "$CODEB" -eq 0 ] && [ "$BLOCKSB" = "1" ]; then
  pass "ADV-B: the command still ran and its real failure still blocked"
else
  fail "ADV-B: expected exit 0 + 1 block decision, got exit $CODEB blocks $BLOCKSB (out: [$OUTB])"
fi

# =============================================================================
# ADV-C — QA ADVERSARIAL (round 2): requiredEnv's `git ls-files --error-unmatch`
# fix checks that .env.example is a TRACKED PATH, but `should_skip_for_env`
# then greps the LIVE WORKING-TREE file for the declaring line, not the
# committed blob. A .env.example that is genuinely tracked, but whose
# FIXTURE_DB_URL= line was only ever ADDED to the working tree (never staged
# or committed — `git status` shows it modified), still satisfies both the
# tracking check and the grep, and still authorizes a skip. That declaration
# is NOT "visible in a reviewed diff" (security_surface[0] constraint #2):
# nothing was ever committed, so it can never appear in any PR. An agent
# running under bypassPermissions could leave this uncommitted forever and
# get a silent, un-reviewable skip on every Stop/SubagentStop indefinitely.
# =============================================================================
F_C="$TMPROOT/advc"
git_init_repo "$F_C"
# .env.example committed WITHOUT the var line.
printf '# example env\n' > "$F_C/.env.example"
git -C "$F_C" add .env.example
git -C "$F_C" commit -q -m "chore: add empty .env.example"
mkdir -p "$F_C/.quetrex"
jq -cn '{verify:["true","false"],requiredEnv:{"false":["FIXTURE_DB_URL"]}}' \
  > "$F_C/.quetrex/verify.json"
# Now append the declaring line to the WORKING TREE ONLY. Never staged, never
# committed. The file is genuinely tracked; this one line is not.
printf 'FIXTURE_DB_URL=\n' >> "$F_C/.env.example"
DIRTY_C="$(git -C "$F_C" status --porcelain -- .env.example)"
if [ -n "$DIRTY_C" ]; then
  pass "ADV-C: fixture sanity check — .env.example is tracked but has an uncommitted modification ($DIRTY_C)"
else
  fail "ADV-C: fixture setup bug — .env.example unexpectedly clean"
fi

OUTC="$(run_hook "$F_C" "Stop" 2>&1)"; CODEC=$?
BLOCKSC="$(count_block_decisions "$OUTC")"
SKIPSC="$(count_skip_lines "$OUTC")"

if [ "$SKIPSC" = "0" ]; then
  pass "ADV-C: an UNCOMMITTED declaring line in an otherwise-tracked .env.example does not authorize a requiredEnv skip"
else
  fail "ADV-C: an uncommitted (never-reviewed) declaring line was honored to skip \`false\` — requiredEnv can be escaped via a dirty working tree even though the file itself is tracked (out: [$OUTC])"
fi
if [ "$CODEC" -eq 0 ] && [ "$BLOCKSC" = "1" ]; then
  pass "ADV-C: the command still ran and its real failure still blocked"
else
  fail "ADV-C: expected exit 0 + 1 block decision, got exit $CODEC blocks $BLOCKSC (out: [$OUTC])"
fi

# =============================================================================
# ADV-D — REVIEWER FINDING #1 (CONFIRMED): a non-ARRAY `.verify` degrades jq's
# `index()` to a SUBSTRING search, silently breaking the "byte-for-byte member
# of verify[]" constraint. Reproduced by the reviewer end-to-end: `.verify` as
# the STRING "true ; sh -c 'exit 1'" makes requiredEnv["sh -c 'exit 1'"]
# authorize a skip of that command, because it is merely a SUBSTRING of the
# string `.verify`, never an array element. Because a string `.verify` also
# makes resolve_from_verify_json's own array check fail, the actual CHAIN in
# this fixture is resolved from the committed CLAUDE.md "## Verification"
# fence instead (exactly reproducing the reviewer's repro), while the
# malicious `.verify`/requiredEnv pairing lives in the committed verify.json.
# =============================================================================
F_D="$TMPROOT/advd"
git_init_repo "$F_D"
mkdir -p "$F_D/.quetrex" "$F_D/.claude"
SKIPCMD_D="sh -c 'exit 1'"
jq -cn --arg v "true ; ${SKIPCMD_D}" --arg k "$SKIPCMD_D" --arg var "FIXTURE_DB_URL" \
  '{verify: $v, requiredEnv: {($k): [$var]}}' \
  > "$F_D/.quetrex/verify.json"
git -C "$F_D" add .quetrex/verify.json
git -C "$F_D" commit -q -m "chore: add verify.json (STRING .verify, adversarial)"
printf 'FIXTURE_DB_URL=\n' > "$F_D/.env.example"
git -C "$F_D" add .env.example
git -C "$F_D" commit -q -m "chore: declare FIXTURE_DB_URL"
cat > "$F_D/.claude/CLAUDE.md" <<MD
# fixture

## Verification

\`\`\`
true
${SKIPCMD_D}
\`\`\`
MD
git -C "$F_D" add .claude/CLAUDE.md
git -C "$F_D" commit -q -m "chore: add CLAUDE.md verification fence"

LEDGER_D="$F_D/.quetrex/verify-ledger.jsonl"
OUTD="$(run_hook "$F_D" "Stop" 2>&1)"; CODED=$?
BLOCKSD="$(count_block_decisions "$OUTD")"
SKIPSD="$(count_skip_lines "$OUTD")"

if [ "$SKIPSD" = "0" ]; then
  pass "ADV-D: a STRING .verify does not let a requiredEnv substring match authorize a skip"
else
  fail "ADV-D: a STRING .verify's substring match incorrectly authorized a skip of \`$SKIPCMD_D\` (out: [$OUTD])"
fi
if [ "$CODED" -eq 0 ] && [ "$BLOCKSD" = "1" ]; then
  pass "ADV-D: the command still ran and its real failure still blocked"
else
  fail "ADV-D: expected exit 0 + 1 block decision, got exit $CODED blocks $BLOCKSD (out: [$OUTD])"
fi
SKIPCMD_D_RAN=0
if [ -f "$LEDGER_D" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    [ "$cm" = "$SKIPCMD_D" ] && SKIPCMD_D_RAN=1
  done < "$LEDGER_D"
fi
if [ "$SKIPCMD_D_RAN" -eq 1 ]; then
  pass "ADV-D: the ledger shows \`$SKIPCMD_D\` genuinely ran (not silently skipped)"
else
  fail "ADV-D: the ledger has no line for \`$SKIPCMD_D\` — it never ran"
fi

# =============================================================================
# ADV-E — ANTI-REINTRODUCTION CONTROL (was: SEC-1, CONFIRMED, HIGH). The
# original main-checkout deferral was manufacturable by the gated agent with
# one allow-listed command: `git worktree add -b claude/x decoy` costs
# exactly one command, and a freshly created worktree has NEVER had its own
# Stop/SubagentStop hook fire, so it holds ZERO lines in its own
# verify-ledger.jsonl. That whole deferral is now DELETED, so this decoy
# worktree (still created, still on-branch) has no code path left to defer
# to — the main checkout runs its own chain regardless of anything a decoy
# worktree does or does not contain.
# =============================================================================
F_E="$TMPROOT/adve-main"
git_init_repo "$F_E"
mkdir -p "$F_E/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$F_E/.quetrex/project.json"
printf '{"verify":["false"]}' > "$F_E/.quetrex/verify.json"
git -C "$F_E" add .quetrex/project.json .quetrex/verify.json
git -C "$F_E" commit -q -m "chore: add quetrex config"
DECOY_E="${F_E}-decoy"
git -C "$F_E" worktree add -q -b claude/decoy-adv-e "$DECOY_E" >/dev/null 2>&1
# NOTE: deliberately no `run_hook "$DECOY_E" ...` here — this decoy has never
# run its own gate, exactly as an attacker's `git worktree add` would leave it.

LEDGER_E="$F_E/.quetrex/verify-ledger.jsonl"
BEFORE_E="$(line_count "$LEDGER_E")"
OUTE="$(run_hook "$F_E" "Stop" 2>&1)"; CODEE=$?
BLOCKSE="$(count_block_decisions "$OUTE")"
SKIPSE="$(count_skip_lines "$OUTE")"
AFTER_E="$(line_count "$LEDGER_E")"

if [ "$SKIPSE" = "0" ]; then
  pass "ADV-E: a manufactured decoy worktree with no ledger proof does NOT trigger VERIFY SKIPPED"
else
  fail "ADV-E: a decoy worktree with zero prior verification was trusted — main deferred to it and never ran its own chain (out: [$OUTE])"
fi
if [ "$CODEE" -eq 0 ] && [ "$BLOCKSE" = "1" ]; then
  pass "ADV-E: the main checkout ran its own chain and blocked on the real failure"
else
  fail "ADV-E: expected exit 0 + 1 block decision from main, got exit $CODEE blocks $BLOCKSE (out: [$OUTE])"
fi
if [ "$AFTER_E" = "$((BEFORE_E + 1))" ]; then
  pass "ADV-E: exactly 1 ledger line appended in main (chain genuinely ran there)"
else
  fail "ADV-E: ledger did not gain a line in main ($BEFORE_E -> $AFTER_E)"
fi

# =============================================================================
# ADV-F — ANTI-REINTRODUCTION CONTROL (was: SEC-1). The original deferral read
# branchPrefix from the COMMITTED project.json specifically so an agent's
# uncommitted, working-tree-only edit widening/redirecting the prefix (e.g.
# to "evil/") could not sweep in an otherwise-unreachable decoy. That whole
# mechanism — committed-branchPrefix read, worktree-list loop, everything —
# is now DELETED, so an uncommitted project.json edit plus a decoy on a
# matching branch, even one carrying genuine ledger proof pinned to its own
# HEAD, has no code path left that could ever defer to it.
# =============================================================================
F_F="$TMPROOT/advf-main"
git_init_repo "$F_F"
mkdir -p "$F_F/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$F_F/.quetrex/project.json"
printf '{"verify":["false"]}' > "$F_F/.quetrex/verify.json"
git -C "$F_F" add .quetrex/project.json .quetrex/verify.json
git -C "$F_F" commit -q -m "chore: add quetrex config (committed branchPrefix claude/)"
# Rewrite the WORKING-TREE COPY ONLY (never committed) to a wider prefix.
printf '{"branchPrefix":"evil/"}' > "$F_F/.quetrex/project.json"

DECOY_F="${F_F}-decoy"
git -C "$F_F" worktree add -q -b evil/decoy "$DECOY_F" >/dev/null 2>&1
DECOY_F_HEAD="$(git -C "$DECOY_F" rev-parse HEAD)"
mkdir -p "$DECOY_F/.quetrex"
jq -cn --arg sha "$DECOY_F_HEAD" --arg cwd "$DECOY_F" \
  '{ts:"2026-01-01T00:00:00Z",cmd:"false",cwd:$cwd,sha:$sha,exit:1,tail:"boom"}' \
  > "$DECOY_F/.quetrex/verify-ledger.jsonl"

LEDGER_F="$F_F/.quetrex/verify-ledger.jsonl"
BEFORE_F="$(line_count "$LEDGER_F")"
OUTF="$(run_hook "$F_F" "Stop" 2>&1)"; CODEF=$?
BLOCKSF="$(count_block_decisions "$OUTF")"
SKIPSF="$(count_skip_lines "$OUTF")"
AFTER_F="$(line_count "$LEDGER_F")"

if [ "$SKIPSF" = "0" ]; then
  pass "ADV-F: branchPrefix is read from the COMMITTED project.json — an uncommitted widening does not authorize a skip"
else
  fail "ADV-F: an uncommitted branchPrefix widening authorized a skip to a decoy on a branch the committed config never matches (out: [$OUTF])"
fi
if [ "$CODEF" -eq 0 ] && [ "$BLOCKSF" = "1" ]; then
  pass "ADV-F: the main checkout ran its own chain and blocked"
else
  fail "ADV-F: expected exit 0 + 1 block decision, got exit $CODEF blocks $BLOCKSF (out: [$OUTF])"
fi
if [ "$AFTER_F" = "$((BEFORE_F + 1))" ]; then
  pass "ADV-F: exactly 1 ledger line appended in main"
else
  fail "ADV-F: ledger did not gain a line in main ($BEFORE_F -> $AFTER_F)"
fi

# =============================================================================
# ADV-G — SEC-2 (CONFIRMED, MEDIUM): the requiredEnv MAPPING (command <->
# variable) must be read from the COMMITTED verify.json, not the working
# tree. Committed baseline declares verify[] and a legitimate .env.example
# with NO requiredEnv at all; the association pairing a genuinely-failing
# command to that var is added ONLY in an uncommitted edit — so the only
# reviewable hunk in this history is the innocuous .env.example addition.
#
# The skip-target is placed LAST in the chain (matching ADV-B/ADV-C/ADV-D),
# NOT followed by another failing command: if the escape reopened, the whole
# run would go fully GREEN (SKIPPED, nothing else red) and hit the visible
# allow-path "VERIFY SKIPPED" line asserted below. Putting a second failing
# command after the skip-target would instead mask a silent skip behind that
# LATER failure's block reason — that masking is exactly what AC9 exists to
# fix separately, and mixing the two here would make this test pass/fail for
# the wrong reason regardless of whether SEC-2 is actually closed.
# =============================================================================
F_G="$TMPROOT/advg"
git_init_repo "$F_G"
mkdir -p "$F_G/.quetrex"
SKIPCMD_G="sh -c 'exit 9'"
jq -cn --arg skipcmd "$SKIPCMD_G" '{verify: ["true", $skipcmd]}' > "$F_G/.quetrex/verify.json"
git -C "$F_G" add .quetrex/verify.json
git -C "$F_G" commit -q -m "chore: add verify.json (no requiredEnv yet)"
printf 'FIXTURE_DB_URL=\n' > "$F_G/.env.example"
git -C "$F_G" add .env.example
git -C "$F_G" commit -q -m "chore: declare FIXTURE_DB_URL (innocuous, reviewable hunk)"
# WITHOUT COMMITTING, add the requiredEnv association that would skip the
# (genuinely failing, if it ran) sh -c 'exit 9' command. This association
# never appears in any reviewed diff.
jq -cn --arg skipcmd "$SKIPCMD_G" --arg var "FIXTURE_DB_URL" \
  '{verify: ["true", $skipcmd], requiredEnv: {($skipcmd): [$var]}}' \
  > "$F_G/.quetrex/verify.json"

LEDGER_G="$F_G/.quetrex/verify-ledger.jsonl"
OUTG_2="$(run_hook "$F_G" "Stop" 2>&1)"; CODEG_2=$?
BLOCKSG="$(count_block_decisions "$OUTG_2")"
SKIPSG="$(count_skip_lines "$OUTG_2")"

if [ "$SKIPSG" = "0" ]; then
  pass "ADV-G: an UNCOMMITTED requiredEnv association does not authorize a skip, even with a committed .env.example"
else
  fail "ADV-G: an uncommitted requiredEnv mapping laundered a skip past a committed, reviewable .env.example (out: [$OUTG_2])"
fi
if [ "$CODEG_2" -eq 0 ] && [ "$BLOCKSG" = "1" ]; then
  pass "ADV-G: the command ran for real and its failure still blocked"
else
  fail "ADV-G: expected exit 0 + 1 block decision, got exit $CODEG_2 blocks $BLOCKSG (out: [$OUTG_2])"
fi
SKIPCMD_G_RAN=0
if [ -f "$LEDGER_G" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    [ "$cm" = "$SKIPCMD_G" ] && SKIPCMD_G_RAN=1
  done < "$LEDGER_G"
fi
if [ "$SKIPCMD_G_RAN" -eq 1 ]; then
  pass "ADV-G: the ledger shows \`$SKIPCMD_G\` genuinely ran (not silently skipped)"
else
  fail "ADV-G: the ledger has no line for \`$SKIPCMD_G\` — it never ran"
fi

# =============================================================================
# ADV-H — SEC-3 (CONFIRMED, LOW): `: > "$LOG"` follows symlinks, so a symlink
# planted at .quetrex/verify-gate.log lets the hook truncate, chmod 600, and
# append captured build output to any file the user can write.
# =============================================================================
F_H="$TMPROOT/advh"
git_init_repo "$F_H"
mkdir -p "$F_H/.quetrex"
printf '{"verify":["false"]}' > "$F_H/.quetrex/verify.json"
VICTIM_H="$TMPROOT/advh-victim"
printf 'PRECIOUS DATA -- DO NOT TOUCH\n' > "$VICTIM_H"
chmod 644 "$VICTIM_H"
ln -s "$VICTIM_H" "$F_H/.quetrex/verify-gate.log"

OUTH_3="$(run_hook "$F_H" "Stop" 2>&1)"; CODEH_3=$?
VICTIM_CONTENT_H="$(cat "$VICTIM_H" 2>/dev/null)"

if [ "$VICTIM_CONTENT_H" = "PRECIOUS DATA -- DO NOT TOUCH" ]; then
  pass "ADV-H: a symlinked verify-gate.log does not truncate/overwrite the symlink target"
else
  fail "ADV-H: the symlink target was modified (content: [$VICTIM_CONTENT_H])"
fi
if [ -f "$F_H/.quetrex/verify-gate.log" ] && [ ! -L "$F_H/.quetrex/verify-gate.log" ]; then
  pass "ADV-H: verify-gate.log is now a regular file, not a symlink"
else
  fail "ADV-H: verify-gate.log is still a symlink (or missing)"
fi
LOG_MODE_H="$(stat -c '%a' "$F_H/.quetrex/verify-gate.log" 2>/dev/null || stat -f '%Lp' "$F_H/.quetrex/verify-gate.log" 2>/dev/null)"
if [ "$LOG_MODE_H" = "600" ]; then
  pass "ADV-H: verify-gate.log is mode 600"
else
  fail "ADV-H: expected verify-gate.log mode 600, got [$LOG_MODE_H]"
fi
BLOCKSH_3="$(count_block_decisions "$OUTH_3")"
if [ "$CODEH_3" -eq 0 ] && [ "$BLOCKSH_3" = "1" ]; then
  pass "ADV-H: the chain still ran and blocked normally despite the symlink attempt"
else
  fail "ADV-H: expected exit 0 + 1 block decision, got exit $CODEH_3 blocks $BLOCKSH_3 (out: [$OUTH_3])"
fi

# =============================================================================
# ADV-I — ANTI-REINTRODUCTION CONTROL (was: QA ADVERSARIAL round 4, SEC-1's
# ledger-proof requirement proven FABRICABLE). The deleted guard's comment
# claimed a trusted candidate's ledger line was "proof its gate has genuinely
# run against the exact state it is in right now" — but the implementation
# only ever checked that SOME line with the right shape and a matching `sha`
# existed in a file the SAME gated agent fully controlled. Nothing bound that
# line to an actual `verify-gate.sh` invocation: `git worktree add -b
# claude/x decoy` (one allow-listed command) followed by ONE handwritten JSON
# line with `sha` set to the decoy's own HEAD was sufficient — no chain
# command ever genuinely ran, anywhere. No attestation scheme can close this
# class (any secret the check reads is readable by the agent it polices), so
# the mechanism itself is gone: a hand-fabricated ledger line in a decoy now
# has no code path left that could ever authorize a skip.
# =============================================================================
F_I="$TMPROOT/advi-main"
git_init_repo "$F_I"
mkdir -p "$F_I/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$F_I/.quetrex/project.json"
printf '{"verify":["false"]}' > "$F_I/.quetrex/verify.json"
git -C "$F_I" add .quetrex/project.json .quetrex/verify.json
git -C "$F_I" commit -q -m "chore: add quetrex config"
DECOY_I="${F_I}-decoy"
git -C "$F_I" worktree add -q -b claude/decoy-adv-i "$DECOY_I" >/dev/null 2>&1
DECOY_I_HEAD="$(git -C "$DECOY_I" rev-parse HEAD)"
mkdir -p "$DECOY_I/.quetrex"
# Fabricate a single ledger line by hand -- the decoy's OWN hook is NEVER
# invoked. `sha` is set to the decoy's own current HEAD, which is all the
# production check verifies.
jq -cn --arg sha "$DECOY_I_HEAD" --arg cwd "$DECOY_I" \
  '{ts:"2026-01-01T00:00:00Z",cmd:"npm test",cwd:$cwd,sha:$sha,exit:0,tail:"fabricated: never actually ran"}' \
  > "$DECOY_I/.quetrex/verify-ledger.jsonl"

LEDGER_I="$F_I/.quetrex/verify-ledger.jsonl"
BEFORE_I="$(line_count "$LEDGER_I")"
OUTI="$(run_hook "$F_I" "Stop" 2>&1)"; CODEI=$?
BLOCKSI="$(count_block_decisions "$OUTI")"
SKIPSI="$(count_skip_lines "$OUTI")"
AFTER_I="$(line_count "$LEDGER_I")"

if [ "$SKIPSI" = "0" ]; then
  pass "ADV-I: a hand-fabricated ledger line (never produced by a real hook run) does NOT authorize a skip"
else
  fail "ADV-I: main deferred to a decoy whose only 'proof' was one handwritten JSON line with a matching sha -- the ledger-proof requirement is fabricable, not genuine (out: [$OUTI])"
fi
if [ "$CODEI" -eq 0 ] && [ "$BLOCKSI" = "1" ]; then
  pass "ADV-I: the main checkout ran its own chain and blocked on the real failure"
else
  fail "ADV-I: expected exit 0 + 1 block decision from main, got exit $CODEI blocks $BLOCKSI (out: [$OUTI])"
fi
if [ "$AFTER_I" = "$((BEFORE_I + 1))" ]; then
  pass "ADV-I: exactly 1 ledger line appended in main (chain genuinely ran there)"
else
  fail "ADV-I: ledger did not gain a line in main ($BEFORE_I -> $AFTER_I)"
fi

# =============================================================================
# ADV-J — QA rung 12, scenario S5, ANTI-REINTRODUCTION CONTROL: an ABANDONED
# worktree that WAS legitimately, genuinely proven at some point (its own
# Stop hook really did fire, really did write a ledger line sha-pinned to
# its OWN HEAD at the time) but was never torn down afterwards. This is the
# reviewer's own "benign case that matters most in practice": nothing
# malicious happened here, a developer simply forgot `git worktree remove`.
# Under the deleted guard this genuine, once-real proof would go on
# authorizing the main-checkout skip FOREVER (as long as the worktree's HEAD
# never moved again), silently disabling main's own gate indefinitely with
# no expiry and no re-verification. That whole mechanism is gone: a
# genuinely-once-proven-but-abandoned worktree now has no code path left
# that could defer main's chain to it, no matter how real its old proof was.
# =============================================================================
F_J="$TMPROOT/advj-main"
git_init_repo "$F_J"
mkdir -p "$F_J/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$F_J/.quetrex/project.json"
printf '{"verify":["false"]}' > "$F_J/.quetrex/verify.json"
git -C "$F_J" add .quetrex/project.json .quetrex/verify.json
git -C "$F_J" commit -q -m "chore: add quetrex config"
DECOY_J="${F_J}-decoy"
git -C "$F_J" worktree add -q -b claude/abandoned-adv-j "$DECOY_J" >/dev/null 2>&1
# Genuinely prove the worktree ONCE, exactly like a real pipeline run would:
# invoke the hook for real inside it, so its own ledger really does gain a
# line sha-pinned to its own (current, at-the-time) HEAD.
run_hook "$DECOY_J" "Stop" >/dev/null 2>&1 || true
# Simulate abandonment: the worktree is never torn down (no `git worktree
# remove`), and its HEAD never moves again — the exact condition under which
# the deleted guard's proof would have stayed "valid" forever.

LEDGER_J="$F_J/.quetrex/verify-ledger.jsonl"
BEFORE_J="$(line_count "$LEDGER_J")"
OUTJ="$(run_hook "$F_J" "Stop" 2>&1)"; CODEJ=$?
BLOCKSJ="$(count_block_decisions "$OUTJ")"
SKIPSJ="$(count_skip_lines "$OUTJ")"
AFTER_J="$(line_count "$LEDGER_J")"

if [ "$SKIPSJ" = "0" ]; then
  pass "ADV-J: an abandoned, once-genuinely-proven worktree does NOT trigger VERIFY SKIPPED"
else
  fail "ADV-J: main deferred forever to a genuinely-proven-but-abandoned worktree (out: [$OUTJ])"
fi
if [ "$CODEJ" -eq 0 ] && [ "$BLOCKSJ" = "1" ]; then
  pass "ADV-J: the main checkout ran its own chain and blocked on the real failure"
else
  fail "ADV-J: expected exit 0 + 1 block decision from main, got exit $CODEJ blocks $BLOCKSJ (out: [$OUTJ])"
fi
if [ "$AFTER_J" = "$((BEFORE_J + 1))" ]; then
  pass "ADV-J: exactly 1 ledger line appended in main (chain genuinely ran there)"
else
  fail "ADV-J: ledger did not gain a line in main ($BEFORE_J -> $AFTER_J)"
fi

# =============================================================================
# AC10 — SOURCE-LEVEL PROOF the main-checkout deferral is GONE, not merely
# unreachable. The runtime proof that no filesystem state can ungate the main
# checkout lives in ADV-A (stale entry), ADV-E (fresh decoy), ADV-F (evil/
# prefix decoy with genuine proof) ADV-I (hand-fabricated ledger line) and
# ADV-J (abandoned-but-once-proven worktree) above — all five already assert
# exit 0, exactly 1 block decision, 0 VERIFY SKIPPED lines, and the ledger
# gaining exactly 1 line against the MAIN checkout. This section proves the
# removal at the source level: the guard's own vocabulary must not appear in
# the hook AT ALL, and the file must be measurably smaller.
# =============================================================================
# SOURCE-LEVEL checks must inspect the file actually under test — $HOOK,
# which honors QX_VERIFY_GATE_HOOK — never a hardcoded quetrex-base path.
# Pointing this suite at a foreign copy (e.g. the quetrex-factory plugin's
# drifted copy) while these two lines stayed pinned to
# $REPO_ROOT/.claude/hooks/verify-gate.sh would silently re-inspect
# quetrex-base's OWN file and report a pass that proves nothing about the
# file under test — a false green, not an honest failure.
HOOK_SRC="$HOOK"
for needle in 'git worktree list' '--git-common-dir' 'QUETREX_VERIFY_FORCE' 'MAIN checkout'; do
  n="$(grep -c -- "$needle" "$HOOK_SRC" 2>/dev/null)"
  n="${n:-0}"
  if [ "$n" = "0" ]; then
    pass "AC10: '$needle' does not appear anywhere in verify-gate.sh (0 occurrences)"
  else
    fail "AC10: '$needle' still appears in verify-gate.sh ($n occurrence(s)) — the deferral is not fully removed"
  fi
done

# The threshold here is a secondary proxy for the deletion, not the load-
# bearing proof (the 4 grep-count checks above are that). It was 80 before
# this round added AC26's second, bounded log slot and AC28's SEC-2 $HEAD_SHA
# pin — both genuinely necessary growth — so it is lowered to 50 to absorb
# that growth while still requiring the file to be measurably, substantially
# smaller than the pre-deletion baseline.
#
# MEANINGFUL ONLY FOR QUETREX-BASE'S OWN COPY. 63bb114 is a commit in THIS
# repo's history; a foreign hook (e.g. quetrex-factory's plugin copy, or any
# other project's) has a different size and no relationship to that sha at
# all, so comparing against it would be either a category error (foreign
# file just happens to be smaller: a meaningless pass) or an unfair failure
# (foreign file is a legitimately different size: a meaningless fail).
# `-ef` compares by inode, not by string, so this still recognizes $HOOK as
# native through a symlink or a relative-vs-absolute path difference.
if [ "$HOOK" -ef "$REPO_ROOT/.claude/hooks/verify-gate.sh" ]; then
  HOOK_LINES="$(wc -l < "$HOOK_SRC" | tr -d ' ')"
  OLD_HOOK_LINES="$(git -C "$REPO_ROOT" show 63bb114:.claude/hooks/verify-gate.sh 2>/dev/null | wc -l | tr -d ' ')"
  case "$OLD_HOOK_LINES" in ''|0|*[!0-9]*) OLD_HOOK_LINES=724 ;; esac
  DELTA=$((OLD_HOOK_LINES - HOOK_LINES))
  if [ "$DELTA" -ge 50 ]; then
    pass "AC10: verify-gate.sh is at least 50 lines shorter than at 63bb114 (delta $DELTA)"
  else
    fail "AC10: verify-gate.sh is only $DELTA lines shorter than at 63bb114 (need >= 50)"
  fi
else
  skip "AC10: line-delta-vs-63bb114 check not applicable — \$HOOK ($HOOK) is not quetrex-base's own copy"
fi

# =============================================================================
# AC9 — REVIEWER (non-blocking): a RED chain's block reason must also surface
# any EARLIER command that was declaratively skipped. Quieting the output
# must not withhold, from a genuinely red run, the one piece of context this
# whole task exists to preserve: whether something in the chain did not run.
# =============================================================================
F_9="$TMPROOT/ac9"
git_init_repo "$F_9"
mkdir -p "$F_9/.quetrex"
SKIPCMD_9="sh -c 'exit 9'"
jq -cn --arg skipcmd "$SKIPCMD_9" --arg redcmd "false" --arg var "FIXTURE_DB_URL" \
  '{verify: [$skipcmd, $redcmd], requiredEnv: {($skipcmd): [$var]}}' \
  > "$F_9/.quetrex/verify.json"
git -C "$F_9" add .quetrex/verify.json
git -C "$F_9" commit -q -m "chore: add verify.json (skip-then-red chain)"
printf 'FIXTURE_DB_URL=\n' > "$F_9/.env.example"
git -C "$F_9" add .env.example
git -C "$F_9" commit -q -m "chore: declare FIXTURE_DB_URL"

OUT9="$(run_hook "$F_9" "Stop" 2>&1)"; CODE9=$?
REASON9="$(printf '%s' "$OUT9" | jq -r '.reason // empty' 2>/dev/null)"
REASON9_LINES="$(printf '%s' "$REASON9" | grep -c '' 2>/dev/null || echo 0)"

if [ "$CODE9" -eq 0 ] && printf '%s' "$OUT9" | jq -e '.decision == "block"' >/dev/null 2>&1; then
  pass "AC9: the chain still blocks on the real (second) failure"
else
  fail "AC9: expected a block decision, got exit $CODE9 (out: [$OUT9])"
fi
if printf '%s' "$REASON9" | grep -q "$SKIPCMD_9"; then
  pass "AC9: the block reason names the earlier SKIPPED command"
else
  fail "AC9: the block reason does not mention the earlier skipped command [$REASON9]"
fi
if [ -n "$REASON9" ] && [ "$REASON9_LINES" -le 3 ]; then
  pass "AC9: the block reason stays within the <=3-line quiet-output budget even with a skip note"
else
  fail "AC9: block reason exceeded the 3-line budget (got $REASON9_LINES lines): [$REASON9]"
fi

# =============================================================================
# AC26 — THE LOG SURVIVES THE VERY NEXT INVOCATION. verify-gate.log is
# unlinked+recreated on EVERY run, so the SubagentStop that ordinarily follows
# a blocking Stop (an agent dispatching a subagent to investigate) erases the
# failure and leaves an all-green quick-chain log at exactly the path the
# block reason pointed at — the operator's original complaint, recreated. A
# RED run's own failing-command output must now also be PRESERVED into a
# second, single, mode-600 slot that the block reason names instead, bounded
# at two files, replaced only by a NEWER genuine failure, never by a green.
# =============================================================================
count_glob_files() {  # count_glob_files <dir> <pattern> -> N (maxdepth 1)
  find "$1" -maxdepth 1 -name "$2" 2>/dev/null | wc -l | tr -d ' '
}
log_tokens() {  # log_tokens <text> -> whitespace-split tokens ending in .log
  printf '%s' "$1" | tr -s ' \t\n' '\n' | grep -c '\.log$' 2>/dev/null || echo 0
}
first_log_token() {  # first_log_token <text> -> first whitespace token ending in .log
  printf '%s' "$1" | tr -s ' \t\n' '\n' | grep '\.log$' 2>/dev/null | head -n1
}
all_mode_600() {  # all_mode_600 <dir> <pattern> -> "1" iff every match is mode 600 (and >=1 match)
  local d="$1" pat="$2" f mode ok=1 n=0
  for f in "$d"/$pat; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    # ORDER IS LOAD-BEARING: try GNU `stat -c` FIRST, BSD `stat -f` second.
    # `-f` is a VALID flag on GNU stat too, but means something else entirely
    # ("show filesystem status", not "custom format for THIS file") — so on
    # Linux, `stat -f '%Lp' "$f"` does not error, it silently prints a whole
    # filesystem-info block and exits 0, which means the `||` fallback to the
    # correct `stat -c '%a'` never fires and $mode is never a real octal mode
    # (this masked several AC26/ADV-H assertions on Linux CI entirely, hidden
    # behind an earlier, now-fixed AC20(ii) failure that halted the test
    # loop before this file ever ran). `stat -c` has no such trap: it is
    # GNU-only and fails cleanly ("illegal option") on BSD stat, so leading
    # with it is portable in both directions.
    mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
    [ "$mode" = "600" ] || ok=0
  done
  [ "$n" -ge 1 ] && [ "$ok" -eq 1 ] && printf '1' || printf '0'
}

F26="$TMPROOT/ac26"
git_init_repo "$F26"
mkdir -p "$F26/.quetrex"
# The failing command's OWN STRING must never contain the marker text — the
# log's "cmd: <string>" header line echoes the command verbatim, so a marker
# embedded in the command string itself would double-count against the
# marker's grep -c, masking whether the OUTPUT genuinely carries it (matches
# the AC1 fixture's wrapper-script pattern above for the same reason).
cat > "$F26/fail26.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "THE-REAL-STACK-TRACE-LINE-1"
echo "TRACE-2" >&2
exit 3
SCRIPT
chmod +x "$F26/fail26.sh"
FAILCMD26="bash \"$F26/fail26.sh\""
jq -cn --arg failcmd "$FAILCMD26" '{verify: ["echo QUICKOK", $failcmd], verifyQuick: ["echo QUICKOK"]}' \
  > "$F26/.quetrex/verify.json"

# --- RUN 1: Stop, full chain, blocks on the real failure -------------------
OUT26_1="$(run_hook "$F26" "Stop" 2>&1)"; CODE26_1=$?
BLOCKS26_1="$(count_block_decisions "$OUT26_1")"
REASON26_1="$(printf '%s' "$OUT26_1" | jq -r '.reason // empty' 2>/dev/null)"

if [ "$CODE26_1" -eq 0 ] && [ "$BLOCKS26_1" = "1" ]; then
  pass "AC26 RUN1: exactly 1 block decision on the real failure"
else
  fail "AC26 RUN1: expected exit 0 + 1 block decision, got exit $CODE26_1 blocks $BLOCKS26_1 (out: [$OUT26_1])"
fi

TOKENS26_1="$(log_tokens "$REASON26_1")"
PRESERVED26_1="$(first_log_token "$REASON26_1")"
if [ "$TOKENS26_1" = "1" ]; then
  pass "AC26 RUN1: block .reason contains exactly 1 token ending in '.log'"
else
  fail "AC26 RUN1: expected exactly 1 '.log' token in reason, got $TOKENS26_1 [$REASON26_1]"
fi

if [ -f "$PRESERVED26_1" ] && [ "$(grep -c 'THE-REAL-STACK-TRACE-LINE-1' "$PRESERVED26_1" 2>/dev/null)" = "1" ] \
   && [ "$(grep -c 'TRACE-2' "$PRESERVED26_1" 2>/dev/null)" = "1" ]; then
  pass "AC26 RUN1: the preserved-failure log named in the reason contains the real failure's output"
else
  fail "AC26 RUN1: preserved log [$PRESERVED26_1] missing expected failure content"
fi

MODE26_1="$(stat -c '%a' "$PRESERVED26_1" 2>/dev/null || stat -f '%Lp' "$PRESERVED26_1" 2>/dev/null)"
if [ "$MODE26_1" = "600" ]; then
  pass "AC26 RUN1: preserved-failure log is mode 600"
else
  fail "AC26 RUN1: expected mode 600, got [$MODE26_1]"
fi

# --- RUN 2: SubagentStop, quick chain (single passing command), green ------
OUT26_2="$(run_hook "$F26" "SubagentStop" 2>&1)"; CODE26_2=$?
BLOCKS26_2="$(count_block_decisions "$OUT26_2")"
if [ "$CODE26_2" -eq 0 ] && [ "$BLOCKS26_2" = "0" ]; then
  pass "AC26 RUN2: quick chain is green — exit 0, 0 block decisions"
else
  fail "AC26 RUN2: expected exit 0 + 0 blocks, got exit $CODE26_2 blocks $BLOCKS26_2 (out: [$OUT26_2])"
fi

if [ -f "$PRESERVED26_1" ] && [ "$(grep -c 'THE-REAL-STACK-TRACE-LINE-1' "$PRESERVED26_1" 2>/dev/null)" = "1" ]; then
  pass "AC26 AFTER-RUN2: the path named in RUN1's reason still contains the real failure"
else
  fail "AC26 AFTER-RUN2: preserved log lost its content after the green SubagentStop run"
fi
if [ "$(grep -c 'QUICKOK' "$PRESERVED26_1" 2>/dev/null)" = "0" ]; then
  pass "AC26 AFTER-RUN2: the preserved-failure log contains 0 lines from the green run"
else
  fail "AC26 AFTER-RUN2: the green run's output leaked into the preserved-failure log"
fi
MODE26_2="$(stat -c '%a' "$PRESERVED26_1" 2>/dev/null || stat -f '%Lp' "$PRESERVED26_1" 2>/dev/null)"
if [ "$MODE26_2" = "600" ]; then
  pass "AC26 AFTER-RUN2: preserved-failure log is still mode 600"
else
  fail "AC26 AFTER-RUN2: expected mode 600, got [$MODE26_2]"
fi

# --- BOUNDED: at most 2 verify-gate*.log files, all mode 600, after every run
for label in RUN1 RUN2; do
  n="$(count_glob_files "$F26/.quetrex" 'verify-gate*.log')"
  if [ "$n" -le 2 ]; then
    pass "AC26 $label: at most 2 verify-gate*.log files on disk (got $n)"
  else
    fail "AC26 $label: expected <=2 verify-gate*.log files, got $n"
  fi
done
if [ "$(all_mode_600 "$F26/.quetrex" 'verify-gate*.log')" = "1" ]; then
  pass "AC26: every verify-gate*.log file is mode 600"
else
  fail "AC26: at least one verify-gate*.log file is not mode 600"
fi
if [ "$(git -C "$F26" status --porcelain 2>/dev/null | grep -c 'verify-gate')" = "0" ]; then
  pass "AC26: neither log file is ever staged/tracked (.quetrex/* is gitignored)"
else
  fail "AC26: a verify-gate log leaked into git status"
fi

# --- RUN 3: a NEW Stop whose failing command prints a DIFFERENT marker -----
cat > "$F26/fail26-round3.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "ROUND3-MARKER"
exit 4
SCRIPT
chmod +x "$F26/fail26-round3.sh"
FAILCMD26_R3="bash \"$F26/fail26-round3.sh\""
jq -cn --arg failcmd "$FAILCMD26_R3" '{verify: ["echo QUICKOK", $failcmd], verifyQuick: ["echo QUICKOK"]}' \
  > "$F26/.quetrex/verify.json"
OUT26_3="$(run_hook "$F26" "Stop" 2>&1)"; CODE26_3=$?
REASON26_3="$(printf '%s' "$OUT26_3" | jq -r '.reason // empty' 2>/dev/null)"
PRESERVED26_3="$(first_log_token "$REASON26_3")"

if [ -f "$PRESERVED26_3" ] \
   && [ "$(grep -c 'THE-REAL-STACK-TRACE-LINE-1' "$PRESERVED26_3" 2>/dev/null)" = "0" ] \
   && [ "$(grep -c 'ROUND3-MARKER' "$PRESERVED26_3" 2>/dev/null)" = "1" ]; then
  pass "AC26 RUN3: a newer real failure REPLACES the older one in the preserved slot"
else
  fail "AC26 RUN3: preserved log [$PRESERVED26_3] does not reflect a clean replacement"
fi
n26_3="$(count_glob_files "$F26/.quetrex" 'verify-gate*.log')"
if [ "$n26_3" -le 2 ]; then
  pass "AC26 RUN3: still at most 2 verify-gate*.log files on disk (got $n26_3)"
else
  fail "AC26 RUN3: expected <=2 verify-gate*.log files, got $n26_3"
fi

# --- SYMLINK SAFETY (SEC-3 extended to the preserved-failure path) ---------
F26S="$TMPROOT/ac26-sym"
git_init_repo "$F26S"
mkdir -p "$F26S/.quetrex"
jq -cn '{verify: ["false"]}' > "$F26S/.quetrex/verify.json"
VICTIM26="$TMPROOT/ac26-sym-victim"
printf 'PRECIOUS DATA -- DO NOT TOUCH\n' > "$VICTIM26"
chmod 644 "$VICTIM26"
ln -s "$VICTIM26" "$F26S/.quetrex/verify-gate-failed.log"

OUT26S="$(run_hook "$F26S" "Stop" 2>&1)"; CODE26S=$?
VICTIM26_CONTENT="$(cat "$VICTIM26" 2>/dev/null)"
if [ "$VICTIM26_CONTENT" = "PRECIOUS DATA -- DO NOT TOUCH" ]; then
  pass "AC26 SYMLINK: a symlinked preserved-failure path does not truncate/overwrite its target"
else
  fail "AC26 SYMLINK: the symlink target was modified (content: [$VICTIM26_CONTENT])"
fi
FAILLOG26S="$F26S/.quetrex/verify-gate-failed.log"
if [ -f "$FAILLOG26S" ] && [ ! -L "$FAILLOG26S" ]; then
  pass "AC26 SYMLINK: the preserved-failure path is now a regular file, not a symlink"
else
  fail "AC26 SYMLINK: the preserved-failure path is still a symlink (or missing)"
fi
MODE26S="$(stat -c '%a' "$FAILLOG26S" 2>/dev/null || stat -f '%Lp' "$FAILLOG26S" 2>/dev/null)"
if [ "$MODE26S" = "600" ]; then
  pass "AC26 SYMLINK: the preserved-failure path is mode 600"
else
  fail "AC26 SYMLINK: expected mode 600, got [$MODE26S]"
fi
if [ "$CODE26S" -eq 0 ] && [ "$(count_block_decisions "$OUT26S")" = "1" ]; then
  pass "AC26 SYMLINK: the chain still ran and blocked normally despite the symlink attempt"
else
  fail "AC26 SYMLINK: expected exit 0 + 1 block decision, got exit $CODE26S (out: [$OUT26S])"
fi

# =============================================================================
# AC28 — SEC-2: every committed read `should_skip_for_env` makes is now pinned
# to $HEAD_SHA (captured once, before the chain runs) instead of a freshly
# re-resolved `HEAD`, so a chain command that commits mid-run cannot author
# the authorization for a LATER command in the SAME invocation. The reviewer's
# exact repro: ./mutate.sh rewrites+commits a requiredEnv mapping for the
# command that runs immediately after it and would otherwise be skipped.
# =============================================================================
F28="$TMPROOT/ac28"
git_init_repo "$F28"
mkdir -p "$F28/.quetrex"
SKIPCMD_28="sh -c 'exit 7'"
cat > "$F28/mutate.sh" <<'MUTATESCRIPT'
#!/usr/bin/env bash
set -e
jq -n --arg skipcmd "sh -c 'exit 7'" \
  '{verify: ["./mutate.sh", $skipcmd], requiredEnv: {($skipcmd): ["A_URL"]}}' \
  > .quetrex/verify.json
git add .quetrex/verify.json
git commit -q -m "mutate: add requiredEnv mapping mid-run"
exit 0
MUTATESCRIPT
chmod +x "$F28/mutate.sh"
jq -cn --arg skipcmd "$SKIPCMD_28" '{verify: ["./mutate.sh", $skipcmd]}' > "$F28/.quetrex/verify.json"
printf 'A_URL=\n' > "$F28/.env.example"
git -C "$F28" add mutate.sh .quetrex/verify.json .env.example
git -C "$F28" commit -q -m "chore: add mutate fixture (no requiredEnv yet)"

OUT28="$(run_hook "$F28" "Stop" 2>&1)"; CODE28=$?
BLOCKS28="$(count_block_decisions "$OUT28")"
SKIPS28="$(count_skip_lines "$OUT28")"
REASON28="$(printf '%s' "$OUT28" | jq -r '.reason // empty' 2>/dev/null)"

if [ "$CODE28" -eq 0 ] && [ "$BLOCKS28" = "1" ]; then
  pass "AC28: exactly 1 block decision — the mid-run commit did not authorize a skip"
else
  fail "AC28: expected exit 0 + 1 block decision, got exit $CODE28 blocks $BLOCKS28 (out: [$OUT28])"
fi
if printf '%s' "$REASON28" | grep -q "$SKIPCMD_28" && printf '%s' "$REASON28" | grep -qE 'exited 7\b'; then
  pass "AC28: the block reason names \`$SKIPCMD_28\` and its exit code 7"
else
  fail "AC28: block reason does not name the failing command/exit code [$REASON28]"
fi
if [ "$SKIPS28" = "0" ]; then
  pass "AC28: 0 'VERIFY SKIPPED' lines — the pinned \$HEAD_SHA closes the TOCTOU"
else
  fail "AC28: the mid-run commit laundered a skip past the pinned HEAD_SHA (out: [$OUT28])"
fi

# --- SOURCE-LEVEL: every committed read is pinned to $HEAD_SHA, none to a
# freshly re-resolved literal `"HEAD:` -----------------------------------
# Same rule as AC10 above: inspect $HOOK, the file actually under test, never
# a hardcoded quetrex-base path — otherwise pointing this suite at a foreign
# hook would silently re-prove quetrex-base's own SEC-2 fix and report a pass
# that says nothing about the file under test.
HOOK_SRC28="$HOOK"
N_LITERAL_HEAD="$(grep -c 'show "HEAD:' "$HOOK_SRC28" 2>/dev/null)"; N_LITERAL_HEAD="${N_LITERAL_HEAD:-0}"
N_PINNED="$(grep -c '\$HEAD_SHA:' "$HOOK_SRC28" 2>/dev/null)"; N_PINNED="${N_PINNED:-0}"
if [ "$N_LITERAL_HEAD" = "0" ]; then
  pass "AC28: 0 occurrences of the literal 'show \"HEAD:' in verify-gate.sh"
else
  fail "AC28: found $N_LITERAL_HEAD occurrence(s) of 'show \"HEAD:' — an unpinned read remains"
fi
if [ "$N_PINNED" -ge 2 ]; then
  pass "AC28: >= 2 occurrences of the pinned '\$HEAD_SHA:' read pattern (got $N_PINNED)"
else
  fail "AC28: expected >= 2 '\$HEAD_SHA:' reads, got $N_PINNED"
fi

# --- EMPTY-HEAD TRAP CLOSED: a repo with NO commits at all -----------------
F28B="$TMPROOT/ac28-empty-head"
mkdir -p "$F28B/.quetrex"
git -C "$F28B" init -q -b main
git -C "$F28B" config user.email "test@example.com"
git -C "$F28B" config user.name "Fixture"
SKIPCMD_28B="sh -c 'exit 5'"
jq -cn --arg skipcmd "$SKIPCMD_28B" '{verify: [$skipcmd], requiredEnv: {($skipcmd): ["A_URL"]}}' \
  > "$F28B/.quetrex/verify.json"
printf 'A_URL=\n' > "$F28B/.env.example"

OUT28B="$(run_hook "$F28B" "Stop" 2>&1)"; CODE28B=$?
SKIPS28B="$(count_skip_lines "$OUT28B")"
BLOCKS28B="$(count_block_decisions "$OUT28B")"
if [ "$SKIPS28B" = "0" ]; then
  pass "AC28 EMPTY-HEAD: an empty \$HEAD_SHA (no commits) never authorizes a skip"
else
  fail "AC28 EMPTY-HEAD: a repo with no commits produced a VERIFY SKIPPED line (out: [$OUT28B])"
fi
if [ "$CODE28B" -eq 0 ] && [ "$BLOCKS28B" = "1" ]; then
  pass "AC28 EMPTY-HEAD: the chain still ran for real and blocked (fail-closed, not fail-open)"
else
  fail "AC28 EMPTY-HEAD: expected exit 0 + 1 block decision, got exit $CODE28B blocks $BLOCKS28B (out: [$OUT28B])"
fi

# =============================================================================
# ADV-K — ANTI-REINTRODUCTION CONTROL: resolve_from_claude_md()'s awk RULE
# ORDER. Found while porting this hook to quetrex-factory's drifted copy,
# which still has the OLD order (heading rule evaluated unconditionally,
# before the fence toggle): any `#`-prefixed line inside a fenced
# Verification block matches the heading pattern and resets insec=0,
# silently ending the section. A completely ordinary CLAUDE.md — one
# explanatory comment per command, no malice required — captures ZERO
# commands under the old order and falls through with NO error surfaced.
# This exact fixture is the empirical repro: three commands, each preceded
# by a plain comment.
# =============================================================================
F_K="$TMPROOT/advk"
git_init_repo "$F_K"
mkdir -p "$F_K/.claude"
cat > "$F_K/.claude/CLAUDE.md" <<'MD'
# fixture

## Verification

```
# lint first
echo LINT_MARKER
# then build
echo BUILD_MARKER
# finally the tests
sh -c 'echo TEST_MARKER; exit 7'
```
MD
git -C "$F_K" add .claude/CLAUDE.md
git -C "$F_K" commit -q -m "chore: add a commented CLAUDE.md verification fence"

LEDGER_K="$F_K/.quetrex/verify-ledger.jsonl"
OUTK="$(run_hook "$F_K" "Stop" 2>&1)"; CODEK=$?
BLOCKSK="$(count_block_decisions "$OUTK")"
REASONK="$(printf '%s' "$OUTK" | jq -r '.reason // empty' 2>/dev/null)"

if [ "$CODEK" -eq 0 ] && [ "$BLOCKSK" = "1" ]; then
  pass "ADV-K: a commented CLAUDE.md Verification fence still blocks on its real (3rd) failure"
else
  fail "ADV-K: expected exit 0 + 1 block decision, got exit $CODEK blocks $BLOCKSK (out: [$OUTK]) — the fence was likely swallowed to 0 commands (awk rule order regression)"
fi
if printf '%s' "$REASONK" | grep -q "exited 7"; then
  pass "ADV-K: the block reason names the 3rd command's real exit code (7), not a spurious 'nothing to gate'"
else
  fail "ADV-K: block reason does not name exit 7 [$REASONK]"
fi
LEDGER_K_LINES=0
LINT_RAN=0
BUILD_RAN=0
TEST_RAN=0
if [ -f "$LEDGER_K" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    LEDGER_K_LINES=$((LEDGER_K_LINES + 1))
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    case "$cm" in
      "echo LINT_MARKER") LINT_RAN=1 ;;
      "echo BUILD_MARKER") BUILD_RAN=1 ;;
      "sh -c 'echo TEST_MARKER; exit 7'") TEST_RAN=1 ;;
    esac
  done < "$LEDGER_K"
fi
if [ "$LEDGER_K_LINES" = "3" ]; then
  pass "ADV-K: the ledger gained exactly 3 lines — all 3 commented commands ran, none swallowed by the comment lines"
else
  fail "ADV-K: expected exactly 3 ledger lines (one per command), got $LEDGER_K_LINES — a fence-order regression captures 0"
fi
if [ "$LINT_RAN" = "1" ] && [ "$BUILD_RAN" = "1" ] && [ "$TEST_RAN" = "1" ]; then
  pass "ADV-K: all three specific commands (lint, build, test markers) are present in the ledger, in order, not just a count"
else
  fail "ADV-K: expected all 3 marker commands in the ledger, got lint=$LINT_RAN build=$BUILD_RAN test=$TEST_RAN"
fi

# =============================================================================
# ADV-L — ANTI-REINTRODUCTION CONTROL: resolve_from_verify_json()'s verifyQuick
# SUBSET ENFORCEMENT. Found in the same drift audit: the factory's unfixed
# copy trusts verifyQuick[] verbatim as the whole SubagentStop chain whenever
# it is present and non-empty, with no relationship to verify[] required —
# `"verifyQuick":["true"]` (or any stale entry left by an ordinary rename)
# would pass every SubagentStop while the REAL verify[] chain (which would
# have failed) is never run and never proven. Every verifyQuick entry must be
# a byte-for-byte member of verify[]; on any mismatch the FULL verify[] chain
# must run instead.
# =============================================================================
F_L="$TMPROOT/advl"
git_init_repo "$F_L"
mkdir -p "$F_L/.quetrex"
REALCMD_L="sh -c 'exit 9'"
jq -cn --arg real "$REALCMD_L" '{verify: [$real], verifyQuick: ["true"]}' \
  > "$F_L/.quetrex/verify.json"
git -C "$F_L" add .quetrex/verify.json
git -C "$F_L" commit -q -m "chore: verifyQuick is NOT a subset of verify (adversarial)"

LEDGER_L="$F_L/.quetrex/verify-ledger.jsonl"
OUTL="$(run_hook "$F_L" "SubagentStop" 2>&1)"; CODEL=$?
BLOCKSL="$(count_block_decisions "$OUTL")"
REASONL="$(printf '%s' "$OUTL" | jq -r '.reason // empty' 2>/dev/null)"

if [ "$CODEL" -eq 0 ] && [ "$BLOCKSL" = "1" ]; then
  pass "ADV-L: a non-subset verifyQuick does not pass SubagentStop — the FULL verify[] chain ran and its real failure blocked"
else
  fail "ADV-L: expected exit 0 + 1 block decision, got exit $CODEL blocks $BLOCKSL (out: [$OUTL]) — verifyQuick was likely trusted verbatim (subset-enforcement regression)"
fi
if printf '%s' "$REASONL" | grep -qE 'exited 9\b'; then
  pass "ADV-L: the block reason names the REAL chain's exit code (9), proving verify[] ran, not verifyQuick's \`true\`"
else
  fail "ADV-L: block reason does not name exit 9 [$REASONL]"
fi
if printf '%s' "$REASONL" | grep -qi 'not a subset'; then
  pass "ADV-L: the block reason names the subset mismatch (QUICK_NOTE) so the misconfiguration is visible, not silent"
else
  fail "ADV-L: block reason does not mention the subset mismatch [$REASONL]"
fi
REALCMD_L_RAN=0
TRUE_ALONE_RAN=0
if [ -f "$LEDGER_L" ]; then
  while IFS= read -r l; do
    [ -z "$l" ] && continue
    cm="$(printf '%s' "$l" | jq -r '.cmd')"
    [ "$cm" = "$REALCMD_L" ] && REALCMD_L_RAN=1
    [ "$cm" = "true" ] && TRUE_ALONE_RAN=1
  done < "$LEDGER_L"
fi
if [ "$REALCMD_L_RAN" = "1" ]; then
  pass "ADV-L: the ledger shows \`$REALCMD_L\` (the real chain) genuinely ran"
else
  fail "ADV-L: the ledger has no line for \`$REALCMD_L\` — the real chain never ran"
fi
if [ "$TRUE_ALONE_RAN" = "0" ]; then
  pass "ADV-L: the ledger has no line for bare \`true\` — verifyQuick's rejected chain never ran on its own"
else
  fail "ADV-L: the ledger shows verifyQuick's \`true\` ran — the non-subset chain was trusted"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "verify-gate.test.sh: all checks passed"
else
  echo "verify-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
