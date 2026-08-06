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
# firing a duplicate cloud routine on a healthy run. This suite proves three
# fixes without weakening the gate itself:
#   (a) QUIET — a genuinely red chain still blocks, but the reason is a short,
#       labelled summary; the raw command output never reaches stdout/stderr,
#       only a log file on disk (AC1, AC2).
#   (b) NO MAIN-CHECKOUT RUNS — when the MAIN checkout has a linked pipeline
#       worktree, the chain is not executed against main; it defers with a
#       plain "VERIFY SKIPPED" line (AC3), and narrows nothing else (AC4).
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

if printf '%s' "$REASON1" | grep -q '\.quetrex/verify-gate\.log'; then
  pass "AC1: block .reason references .quetrex/verify-gate.log"
else
  fail "AC1: block .reason does not reference .quetrex/verify-gate.log: [$REASON1]"
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
# AC3 / AC4 — NO MAIN-CHECKOUT RUNS when pipeline work lives in a worktree,
# and the guard narrows nothing else.
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
# The hook resolves ROOT via `git rev-parse --show-toplevel`, which returns
# the SYMLINK-RESOLVED path (e.g. macOS /tmp -> /private/tmp). Compare against
# that same resolved form so this assertion isn't a path-cosmetics false fail.
REAL_MAIN3="$(git -C "$MAIN3" rev-parse --show-toplevel)"

for event in Stop SubagentStop; do
  LEDGER3="$MAIN3/.quetrex/verify-ledger.jsonl"
  ATT3="$MAIN3/.quetrex/verify-attempts"
  BEFORE_LEDGER="$(line_count "$LEDGER3")"
  BEFORE_ATT="$(cat "$ATT3" 2>/dev/null || echo '')"

  OUT3="$(run_hook "$MAIN3" "$event" 2>&1)"; CODE3=$?

  if [ "$CODE3" -eq 0 ]; then
    pass "AC3($event): hook exit code == 0"
  else
    fail "AC3($event): expected exit 0, got $CODE3"
  fi

  BLOCKS3="$(count_block_decisions "$OUT3")"
  if [ "$BLOCKS3" = "0" ]; then
    pass "AC3($event): 0 stdout lines parse as a block decision"
  else
    fail "AC3($event): expected 0 block decisions, got $BLOCKS3"
  fi

  SKIPS3="$(count_skip_lines "$OUT3")"
  if [ "$SKIPS3" = "1" ]; then
    pass "AC3($event): exactly 1 'VERIFY SKIPPED' line"
  else
    fail "AC3($event): expected exactly 1 VERIFY SKIPPED line, got $SKIPS3 (out: [$OUT3])"
  fi

  SKIP_LINE3="$(printf '%s\n' "$OUT3" | grep '^VERIFY SKIPPED' | head -n1)"
  if printf '%s' "$SKIP_LINE3" | grep -qF "$REAL_MAIN3" \
     && printf '%s' "$SKIP_LINE3" | grep -q 'claude/T-1-x' \
     && printf '%s' "$SKIP_LINE3" | grep -q 'BLOCKS nothing'; then
    pass "AC3($event): SKIPPED line names the main checkout path, the worktree branch, and 'BLOCKS nothing'"
  else
    fail "AC3($event): SKIPPED line missing required content: [$SKIP_LINE3]"
  fi

  AFTER_LEDGER="$(line_count "$LEDGER3")"
  if [ "$AFTER_LEDGER" = "$BEFORE_LEDGER" ]; then
    pass "AC3($event): verify-ledger.jsonl line count unchanged"
  else
    fail "AC3($event): ledger line count changed ($BEFORE_LEDGER -> $AFTER_LEDGER)"
  fi

  AFTER_ATT="$(cat "$ATT3" 2>/dev/null || echo '')"
  if [ "$AFTER_ATT" = "$BEFORE_ATT" ]; then
    pass "AC3($event): .quetrex/verify-attempts unchanged"
  else
    fail "AC3($event): verify-attempts changed ($BEFORE_ATT -> $AFTER_ATT)"
  fi
done

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
# ADV-A — QA ADVERSARIAL: a STALE/PRUNABLE linked-worktree entry (the worktree
# directory was removed with `rm -rf` instead of `git worktree remove`, so
# `git worktree list --porcelain` still reports it) must NOT trigger the
# main-checkout skip. Nothing runs its own gate at a path that no longer
# exists, so deferring to it is a silent fail-open: a genuinely red chain in
# main would never be proven anywhere.
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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "verify-gate.test.sh: all checks passed"
else
  echo "verify-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
