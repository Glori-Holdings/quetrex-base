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
# PROVE the worktree, exactly as the production guard now requires (SEC-1):
# a candidate is only trusted once its OWN gate has genuinely fired against
# its OWN current HEAD, so invoke the hook inside WT3 ONCE here to seed that
# proof before testing whether MAIN defers to it. This is fixture setup, not
# a change to what AC3/AC4 assert — see ADV-E for the fixture that
# DELIBERATELY omits this step (a manufactured decoy with no such proof).
run_hook "$WT3" "Stop" >/dev/null 2>&1 || true

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
# ADV-E — SEC-1 (CONFIRMED, HIGH): the MAIN-checkout skip must not be
# manufacturable by the gated agent. `git worktree add -b claude/x decoy` is
# on the Bash allow-list and costs exactly one command; a freshly created
# worktree has NEVER had its own Stop/SubagentStop hook fire, so it holds
# ZERO lines in its own verify-ledger.jsonl. Unlike AC3's fixture (which
# deliberately PROVES the worktree first — see the comment at its creation),
# this fixture omits that step on purpose: it is the manufactured decoy.
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
# ADV-F — SEC-1: branchPrefix must be read from the COMMITTED project.json,
# not the working tree. An agent could otherwise widen or redirect the
# prefix match, in an uncommitted edit, to sweep in a decoy worktree that the
# COMMITTED config would never match. The decoy here is given genuine ledger
# proof pinned to its own HEAD, so this isolates the branchPrefix-source
# question from ADV-E's (separately covered) manufactured-decoy scenario.
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
LOG_MODE_H="$(stat -f '%Lp' "$F_H/.quetrex/verify-gate.log" 2>/dev/null || stat -c '%a' "$F_H/.quetrex/verify-gate.log" 2>/dev/null)"
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
# ADV-I — QA ADVERSARIAL (round 4): SEC-1's ledger-proof requirement is
# FABRICABLE. The comment at the guard's own definition claims a trusted
# candidate's ledger line is "proof its gate has genuinely run against the
# exact state it is in right now" — but the implementation only checks that
# SOME line with the right shape and a matching `sha` exists in a file the
# SAME gated agent fully controls (`$CUR_WT_PATH/.quetrex/verify-ledger.jsonl`
# is an ordinary, writable file inside the decoy worktree the agent itself
# just created). Nothing binds that line to an actual `verify-gate.sh`
# invocation: `git worktree add -b claude/x decoy` (one allow-listed command)
# followed by ONE handwritten JSON line with `sha` set to the decoy's own
# HEAD is sufficient — no chain command is ever genuinely run, anywhere.
# This is functionally a wider hole than the ORIGINAL pre-SEC-1 defect: it
# reduces "manufacture the skip" from one command to two, while the fix's own
# header comment claims the opposite (that manufacturing now requires a
# GENUINE hook run). Bounded by the pre-existing CONTAINMENT guarantee (main's
# OWN ledger still gains zero lines, so merge-gate GATE 3 still denies — see
# the direct file/merge-gate inspection in QA's report), which is why this is
# a Stop-gate integrity defect and not a proven merge-level escape, exactly
# like the class of finding QA has raised at every prior round.
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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "verify-gate.test.sh: all checks passed"
else
  echo "verify-gate.test.sh: FAILURES above"
fi
exit "$FAIL"
