#!/usr/bin/env bash
# test/env-derive.test.sh — contract test for bin/quetrex-env-derive, the
# tool that turns a repo's own COMMITTED evidence (a tracked
# .env.example/.env.sample plus a fallback-less env read in tracked source)
# into a candidate NAME a human can confirm — and never, on its own, decides
# which verify[] command needs which variable.
#
# Run: bash test/env-derive.test.sh
#
# THIS SUITE REPLACES THE PRIOR ROUND'S TESTS OUTRIGHT. The prior tool had a
# static command-attribution engine (leafPathArgs/resolveScope/inScope/
# attributeToCommands) that was provably wrong in BOTH directions — see
# .quetrex/plan/VERIFY-GATE-QUIET.json for the full history. That engine,
# and the auto-writing `verify-json` subcommand it fed, are DELETED outright,
# not tuned, so the tests that exercised them are gone too. What is proved
# here instead:
#   AC20 — the attribution engine and the auto-writer are actually gone
#          (source-level), the tool is re-exercised on the reviewer's two
#          exact fixtures (under- and over-attribution), and a negative
#          control shows those assertions are not vacuous.
#   AC21 — `declare` is the ONLY writer of requiredEnv, fails closed on
#          everything it cannot independently prove, and a zero-pair call
#          (the non-interactive default) writes nothing at all.
#   AC22 — `propose`/`declare` read the SAME committed evidence base
#          verify-gate.sh reads (SEC-4): a human can never be shown, or
#          confirm, a pairing the gate would then silently refuse.
#   AC23 — init.md's seed block never invokes the seeder with an empty
#          command (the `"${CONFIRMED_STEPS[@]:-}"` merge-deadlock defect),
#          and `seed-chain` independently refuses an empty command itself.
#   AC24 — init.md's step 5 is PROPOSE -> HUMAN CONFIRM -> WRITE, and its
#          non-interactive branch proposes nothing and writes nothing.
#
# SECURITY POSTURE THIS SUITE HOLDS THE LINE ON. Over-attribution (a wrong
# command silently skipped) is the dangerous direction; under-attribution
# (nothing derived, chain goes red) is merely annoying. Both are now
# structurally impossible because no code path maps a NAME to a COMMAND
# except a human-typed `--cmd`/`--env` pair. Every assertion below that
# checks an ABSENCE — no name in .candidates that is not committed, 0
# requiredEnv writes with zero pairs, 0 leaked values — is checking the
# conservative, safe-by-default direction; the negative controls exist
# specifically to prove those absences are not vacuous.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$TOOLROOT/bin/quetrex-env-derive"
HOOK="${QX_VERIFY_GATE_HOOK:-$TOOLROOT/.claude/hooks/verify-gate.sh}"
MERGE_HOOK="${QX_MERGE_GATE_HOOK:-$TOOLROOT/.claude/hooks/merge-gate.sh}"
INIT_MD="$TOOLROOT/.claude/commands/init.md"

if [ ! -f "$TOOL" ]; then
  echo "FAIL: tool not found at $TOOL"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — quetrex-env-derive requires node, nothing to test"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — this suite is jq-assisted, nothing to test"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/env-derive-test.XXXXXX")"
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

count_skip_lines() {  # count_skip_lines <combined> -> N matching ^VERIFY SKIPPED
  printf '%s\n' "$1" | grep -c '^VERIFY SKIPPED'
}

run_hook() {  # run_hook <cwd> <event>
  local cwd="$1" event="$2" payload
  payload="$(jq -cn --arg cwd "$cwd" --arg event "$event" '{cwd:$cwd,hook_event_name:$event}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" QUETREX_VERIFY_MAX=3 "$HOOK" 2>&1
}

ledger_exit_codes_for() {  # ledger_exit_codes_for <cwd> <cmd> -> newline list of .exit values
  local f="$1/.quetrex/verify-ledger.jsonl" cmd="$2"
  [ -f "$f" ] || return 0
  jq -r --arg c "$cmd" 'select(.cmd==$c) | .exit' "$f" 2>/dev/null
}

ledger_line_count() {  # ledger_line_count <cwd> -> N total lines
  local f="$1/.quetrex/verify-ledger.jsonl"
  [ -f "$f" ] || { echo 0; return; }
  wc -l < "$f" | tr -d ' '
}

# =============================================================================
# AC20 — the attribution engine and the auto-writer are DELETED (source-
# level), the tool is re-exercised on the reviewer's two exact fixtures, and
# a negative control proves the deletion — not the fixture — is what makes
# fixture (ii) safe.
# =============================================================================

# --- SOURCE-LEVEL -----------------------------------------------------------
for banned in leafPathArgs resolveScope resolveMakeTarget inScope attributeToCommands QX_SCOPE_FILTER_ENABLED readMakefile verify-json; do
  n="$(grep -c "$banned" "$TOOL")"
  if [ "$n" = "0" ]; then
    pass "AC20: '$banned' does not appear anywhere in bin/quetrex-env-derive (0 occurrences)"
  else
    fail "AC20: '$banned' appears $n time(s) in bin/quetrex-env-derive — the attribution engine must be deleted outright"
  fi
done

USAGE_LINE="$(grep -m1 '^\[ -n "\$SUB" \]' "$TOOL")"
SUBS_PRESENT=0
for sub in scan propose seed-chain declare missing plan; do
  printf '%s' "$USAGE_LINE" | grep -q -- "$sub" && SUBS_PRESENT=$((SUBS_PRESENT + 1))
done
if [ "$SUBS_PRESENT" = "6" ]; then
  pass "AC20: the no-argument usage string names all 6 shipped subcommands (6 of 6 present)"
else
  fail "AC20: expected 6 of 6 subcommand names in the usage string, found $SUBS_PRESENT (line: [$USAGE_LINE])"
fi

CASE_ARMS="$(grep -c '^  case "' "$TOOL")"
if [ "$CASE_ARMS" = "6" ]; then
  pass "AC20: the dispatch switch has exactly 6 case arms"
else
  fail "AC20: expected exactly 6 case arms, got $CASE_ARMS"
fi

# --- FIXTURE (i) — UNDER-ATTRIBUTION: the Next/Vite shape that previously
# derived NOTHING. `propose` must now find the candidate regardless of the
# chain command's own shape, because it never resolves a command to a leaf
# at all. -----------------------------------------------------------------
F20i="$TMPROOT/ac20i"
git_init_repo "$F20i"
mkdir -p "$F20i/src" "$F20i/.quetrex"
cat > "$F20i/package.json" <<'EOF'
{
  "scripts": {
    "build": "next build",
    "lint": "next lint",
    "test": "vitest run"
  }
}
EOF
printf 'DEMO_DATABASE_URL=\n' > "$F20i/.env.example"
cat > "$F20i/src/db.js" <<'EOF'
const url = process.env.DEMO_DATABASE_URL;
module.exports = { url };
EOF
jq -cn '{verify:["npm run build","npm run lint","npm run test"]}' > "$F20i/.quetrex/verify.json"
git -C "$F20i" add package.json .env.example src/db.js .quetrex/verify.json
git -C "$F20i" commit -q -m "chore: AC20(i) under-attribution fixture"

PRE20i="$(cat "$F20i/.quetrex/verify.json")"
OUT20i="$("$TOOL" propose "$F20i" 2>/dev/null)"; CODE20i=$?
POST20i="$(cat "$F20i/.quetrex/verify.json")"

if [ "$CODE20i" -eq 0 ]; then
  pass "AC20(i): propose exits 0 on the Next/Vite shape"
else
  fail "AC20(i): expected exit 0, got $CODE20i"
fi
if printf '%s' "$OUT20i" | jq -e . >/dev/null 2>&1; then
  pass "AC20(i): propose stdout parses as JSON"
else
  fail "AC20(i): propose stdout does not parse as JSON: [$OUT20i]"
fi
CANDLEN20i="$(printf '%s' "$OUT20i" | jq '.candidates | length' 2>/dev/null)"
if [ "$CANDLEN20i" = "1" ]; then
  pass "AC20(i): .candidates|length == 1 — the Next/Vite shape is no longer invisible"
else
  fail "AC20(i): expected .candidates|length == 1, got '$CANDLEN20i' (out: [$OUT20i])"
fi
CANDNAME20i="$(printf '%s' "$OUT20i" | jq -r '.candidates[0].name' 2>/dev/null)"
if [ "$CANDNAME20i" = "DEMO_DATABASE_URL" ]; then
  pass "AC20(i): .candidates[0].name == DEMO_DATABASE_URL"
else
  fail "AC20(i): expected DEMO_DATABASE_URL, got '$CANDNAME20i'"
fi
if [ "$PRE20i" = "$POST20i" ]; then
  pass "AC20(i): .quetrex/verify.json is byte-identical before and after propose (writes nothing)"
else
  fail "AC20(i): .quetrex/verify.json changed — propose must never write"
fi

# --- FIXTURE (ii) — OVER-ATTRIBUTION: tsc/eslint/jest, all genuinely
# exiting 127. After `propose` with NO human confirmation, the real hook
# must BLOCK on the first genuine failure — never silently skip. ----------
if ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: AC20(ii)/negative-control require npm on PATH (the chain commands are npm scripts) — skipping those checks only"
else
  F20ii="$TMPROOT/ac20ii"
  git_init_repo "$F20ii"
  mkdir -p "$F20ii/src" "$F20ii/.quetrex"
  cat > "$F20ii/package.json" <<'EOF'
{
  "scripts": {
    "typecheck": "tsc --noEmit",
    "lint": "eslint .",
    "test": "jest"
  }
}
EOF
  printf 'DATABASE_URL=\n' > "$F20ii/.env.example"
  cat > "$F20ii/src/app.js" <<'EOF'
const url = process.env.DATABASE_URL;
module.exports = { url };
EOF
  jq -cn '{verify:["npm run typecheck","npm run lint","npm run test"]}' > "$F20ii/.quetrex/verify.json"
  git -C "$F20ii" add package.json .env.example src/app.js .quetrex/verify.json
  git -C "$F20ii" commit -q -m "chore: AC20(ii) over-attribution fixture"

  "$TOOL" propose "$F20ii" >/dev/null 2>&1

  OUT20ii="$(run_hook "$F20ii" "Stop")"
  BLOCKS20ii="$(count_block_decisions "$OUT20ii")"
  SKIPS20ii="$(count_skip_lines "$OUT20ii")"
  LEDGER_EXITS20ii="$(ledger_exit_codes_for "$F20ii" "npm run typecheck")"
  LEDGER_LINES20ii="$(ledger_line_count "$F20ii")"

  if [ "$BLOCKS20ii" = "1" ]; then
    pass "AC20(ii): exactly 1 block decision (with NO human confirmation, the real failure blocks)"
  else
    fail "AC20(ii): expected exactly 1 block decision, got $BLOCKS20ii (out: [$OUT20ii])"
  fi
  if [ "$SKIPS20ii" = "0" ]; then
    pass "AC20(ii): 0 'VERIFY SKIPPED' lines — nothing was silently ungated"
  else
    fail "AC20(ii): expected 0 VERIFY SKIPPED lines, got $SKIPS20ii (out: [$OUT20ii])"
  fi
  if [ "$LEDGER_LINES20ii" = "1" ] && [ "$LEDGER_EXITS20ii" = "127" ]; then
    pass "AC20(ii): the ledger gains exactly 1 line with .exit == 127"
  else
    fail "AC20(ii): expected 1 ledger line with exit 127, got $LEDGER_LINES20ii line(s), exits=[$LEDGER_EXITS20ii]"
  fi

  # --- NEGATIVE CONTROL --------------------------------------------------
  # The attribution engine that produced 3 skips / 0 blocks at 9d3ef10 no
  # longer exists to mutate back in (it was deleted, not tuned — that is
  # the whole point). What DOES exist to prove these assertions are not
  # vacuous is: reproduce the EFFECT that engine had on THIS exact fixture
  # (every leaf here has empty scope, so the old inScope()'s
  # empty-scope-means-everything rule attributed every candidate to every
  # command) by hand-writing the requiredEnv map it would have auto-written,
  # and showing the real hook then DOES silently ungate the whole chain —
  # which is exactly what the current design makes structurally impossible
  # (nothing writes an association nobody typed).
  F20neg="$TMPROOT/ac20neg"
  git_init_repo "$F20neg"
  mkdir -p "$F20neg/src" "$F20neg/.quetrex"
  cp "$F20ii/package.json" "$F20neg/package.json"
  cp "$F20ii/.env.example" "$F20neg/.env.example"
  cp "$F20ii/src/app.js" "$F20neg/src/app.js"
  jq -cn '{verify:["npm run typecheck","npm run lint","npm run test"]}' > "$F20neg/.quetrex/verify.json"
  git -C "$F20neg" add package.json .env.example src/app.js .quetrex/verify.json
  git -C "$F20neg" commit -q -m "chore: AC20 negative control base (before the simulated over-attribution write)"

  CANDS20neg="$("$TOOL" scan "$F20neg" 2>/dev/null | cut -f1)"
  jq -cn --arg n "$CANDS20neg" '
    {
      verify: ["npm run typecheck","npm run lint","npm run test"],
      requiredEnv: (["npm run typecheck","npm run lint","npm run test"] | map({(.): [$n]}) | add)
    }' > "$F20neg/.quetrex/verify.json"
  git -C "$F20neg" add .quetrex/verify.json
  git -C "$F20neg" commit -q -m "chore: AC20 negative control — simulated 9d3ef10 over-attribution write"

  OUT20neg="$(run_hook "$F20neg" "Stop")"
  BLOCKS20neg="$(count_block_decisions "$OUT20neg")"
  SKIPS20neg="$(count_skip_lines "$OUT20neg")"

  if [ "$SKIPS20neg" = "3" ] && [ "$BLOCKS20neg" = "0" ]; then
    pass "AC20 NEGATIVE CONTROL: simulating 9d3ef10's over-attribution write reproduces 3 skips / 0 blocks — proving the positive fixture's 1-block/0-skip result is the deletion's doing, not an accident of the fixture"
  else
    fail "AC20 NEGATIVE CONTROL: expected 3 skips / 0 blocks from the simulated over-attribution write, got skips=$SKIPS20neg blocks=$BLOCKS20neg (out: [$OUT20neg])"
  fi
fi
