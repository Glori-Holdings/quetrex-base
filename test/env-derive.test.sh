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
#   AC31 END-TO-END — `plan` PROJECTS required_env from the human's
#          COMMITTED requiredEnv declaration (never re-derives it), in the
#          exact Contract A shape `quetrex-cloud-prep hydrate` consumes, so
#          an unattended cloud build still gets a real placeholder for a
#          declared name — closing the QDM-1 regression (hydrate exporting
#          nothing because nothing ever wrote required_env) without
#          reintroducing the deleted inference.
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
CLOUD_PREP="$TOOLROOT/bin/quetrex-cloud-prep"

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

# --- FIXTURE (ii) — OVER-ATTRIBUTION: three npm scripts that must all
# genuinely fail to EXECUTE (exit 127, "command not found"), so the real
# hook is proven to BLOCK on the first genuine failure with NO human
# confirmation — never silently skip. -------------------------------------
#
# The scripts deliberately do NOT invoke tsc/eslint/jest by name. GitHub's
# hosted ubuntu-latest runner ships a global `tsc` at /usr/local/bin/tsc
# (confirmed live: `tsc --noEmit` there runs a real TypeScript 7.0.2 CLI and
# exits 1 on the unrecognized flag/missing tsconfig, not 127 for "not
# found") — so a fixture that assumes tsc/eslint/jest are ambiently ABSENT
# is only true on some machines and false on GitHub Actions, which is
# exactly the divergence that broke this assertion on main (local green,
# CI red, same commit). A command name that can never collide with a real
# preinstalled binary makes "genuinely does not execute" -> exit 127 true
# in EVERY environment, not just the ones happening to lack dev tooling.
if ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: AC20(ii)/negative-control require npm on PATH (the chain commands are npm scripts) — skipping those checks only"
else
  F20ii="$TMPROOT/ac20ii"
  git_init_repo "$F20ii"
  mkdir -p "$F20ii/src" "$F20ii/.quetrex"
  cat > "$F20ii/package.json" <<'EOF'
{
  "scripts": {
    "typecheck": "quetrex-ac20-nonexistent-binary-8f2c1 --noEmit",
    "lint": "quetrex-ac20-nonexistent-binary-8f2c1 .",
    "test": "quetrex-ac20-nonexistent-binary-8f2c1"
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
  # SEC-1/SEC-3 (security review, 2026-08-21): expected ledger line count
  # changed from 1 to 2. `npm run test` is heavy (verify-gate.sh's bounded
  # quick chain filters it at Stop) and, per the SEC-1 fix, an excluded
  # command now ALWAYS gets its own boundedQuick ledger line — the exact
  # opposite of the pre-fix behavior this assertion originally pinned ("an
  # excluded command leaves no evidence"), which was the SEC-1 vulnerability
  # itself. `npm run typecheck` is unaffected: it still genuinely runs,
  # still exits 127, and the chain still blocks immediately on it.
  LEDGER_BOUNDED20ii="$(jq -s '[.[] | select(.cmd=="npm run test" and .skipped==true and .skipReason=="boundedQuick" and .exit==null)] | length' "$F20ii/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
  if [ "$LEDGER_LINES20ii" = "2" ] && [ "$LEDGER_EXITS20ii" = "127" ] && [ "$LEDGER_BOUNDED20ii" = "1" ]; then
    pass "AC20(ii): the ledger gains exactly 2 lines — the genuine exit-127 line for typecheck, plus 1 boundedQuick line for the heavy-filtered 'npm run test' (SEC-1: the whole resolved chain is always recorded, never silently shrunk)"
  else
    fail "AC20(ii): expected 2 ledger lines (typecheck exit 127 + npm run test boundedQuick), got $LEDGER_LINES20ii line(s), typecheck exits=[$LEDGER_EXITS20ii], boundedQuick-for-test=$LEDGER_BOUNDED20ii"
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

# =============================================================================
# AC21 — `declare` is the ONLY writer of requiredEnv: fails closed on
# everything it cannot independently prove, is union-only, and a zero-pair
# call (the non-interactive default) writes nothing at all.
# =============================================================================
F21="$TMPROOT/ac21"
git_init_repo "$F21"
mkdir -p "$F21/src" "$F21/.quetrex"
cat > "$F21/.env.example" <<'EOF'
A_URL=postgres://ac21-a-value-should-never-leak
B_URL=ac21-b-value-should-never-leak
C_URL=ac21-c-value-should-never-leak
E_URL=ac21-e-value-should-never-leak
EOF
cat > "$F21/src/db.js" <<'EOF'
// db client
// A_URL: no fallback — line 3 is the provable read
const a = process.env.A_URL;
// B_URL: HAS a fallback — never provable
const b = process.env.B_URL ?? "default-b";
// E_URL: no fallback — provable, used for the union test
const e = process.env.E_URL;
EOF
jq -cn '{verify:["npm run lint -- src","npm run build"],requiredEnv:{"npm run lint -- src":["HANDWRITTEN_VAR"]}}' \
  > "$F21/.quetrex/verify.json"
git -C "$F21" add .env.example src/db.js .quetrex/verify.json
git -C "$F21" commit -q -m "chore: AC21 fixture (A_URL/E_URL provable, B_URL has a fallback, C_URL never read, D_URL undeclared)"

# --- ZERO-PAIR (the non-interactive default) --------------------------------
PRE21_ZERO="$(cat "$F21/.quetrex/verify.json")"
OUT21ZERO="$("$TOOL" declare "$F21" 2>&1)"; CODE21ZERO=$?
POST21_ZERO="$(cat "$F21/.quetrex/verify.json")"
[ "$CODE21ZERO" -eq 0 ] && pass "AC21 ZERO-PAIR: declare with no flags exits 0" \
  || fail "AC21 ZERO-PAIR: expected exit 0, got $CODE21ZERO"
LINES21ZERO="$(printf '%s\n' "$OUT21ZERO" | grep -c 'nothing declared')"
[ "$LINES21ZERO" = "1" ] && [ "$(printf '%s\n' "$OUT21ZERO" | grep -c .)" = "1" ] \
  && pass "AC21 ZERO-PAIR: prints exactly 1 line containing 'nothing declared'" \
  || fail "AC21 ZERO-PAIR: expected exactly 1 line containing 'nothing declared', got [$OUT21ZERO]"
[ "$PRE21_ZERO" = "$POST21_ZERO" ] && pass "AC21 ZERO-PAIR: .quetrex/verify.json is byte-identical" \
  || fail "AC21 ZERO-PAIR: .quetrex/verify.json changed"

# --- HAPPY PATH --------------------------------------------------------------
PRE21_VERIFY="$(jq -S '.verify' "$F21/.quetrex/verify.json")"
OUT21HP="$("$TOOL" declare "$F21" --cmd "npm run build" --env A_URL 2>&1)"; CODE21HP=$?
[ "$CODE21HP" -eq 0 ] && pass "AC21 HAPPY PATH: exits 0" || fail "AC21 HAPPY PATH: expected exit 0, got $CODE21HP (out: [$OUT21HP])"

BUILD_REQ21="$(jq -c '.requiredEnv["npm run build"] // empty' "$F21/.quetrex/verify.json")"
[ "$BUILD_REQ21" = '["A_URL"]' ] && pass 'AC21 HAPPY PATH: requiredEnv["npm run build"] == ["A_URL"] (length 1)' \
  || fail "AC21 HAPPY PATH: expected [\"A_URL\"], got '$BUILD_REQ21'"

POST21_VERIFY="$(jq -S '.verify' "$F21/.quetrex/verify.json")"
[ "$PRE21_VERIFY" = "$POST21_VERIFY" ] && pass "AC21 HAPPY PATH: .verify is byte-identical (jq -S) before/after" \
  || fail "AC21 HAPPY PATH: .verify changed"

LINT_REQ21="$(jq -c '.requiredEnv["npm run lint -- src"] // empty' "$F21/.quetrex/verify.json")"
[ "$LINT_REQ21" = '["HANDWRITTEN_VAR"]' ] && pass "AC21 HAPPY PATH: the pre-existing hand-written entry is unchanged" \
  || fail "AC21 HAPPY PATH: hand-written entry changed, got '$LINT_REQ21'"

cp "$F21/.quetrex/verify.json" "$TMPROOT/ac21-after-run1.json"
"$TOOL" declare "$F21" --cmd "npm run build" --env A_URL >/dev/null
cmp -s "$TMPROOT/ac21-after-run1.json" "$F21/.quetrex/verify.json" \
  && pass "AC21 HAPPY PATH: a second identical run leaves the file byte-identical" \
  || fail "AC21 HAPPY PATH: a second identical run changed the file"

STATUS21HP="$(git -C "$F21" status --porcelain -- .quetrex/verify.json | grep -c .)"
[ "$STATUS21HP" = "1" ] && pass "AC21 HAPPY PATH: git status --porcelain reports exactly 1 modified path" \
  || fail "AC21 HAPPY PATH: expected exactly 1 modified path, got $STATUS21HP"

# --- FOUR REFUSALS ------------------------------------------------------
refusal_test() {  # refusal_test <label> <args...>
  local label="$1"; shift
  local pre_content post_content code out
  pre_content="$(cat "$F21/.quetrex/verify.json")"
  out="$("$TOOL" declare "$F21" "$@" 2>&1)"; code=$?
  post_content="$(cat "$F21/.quetrex/verify.json")"
  if [ "$code" -ne 0 ]; then pass "AC21 REFUSAL ($label): exits non-zero"; else fail "AC21 REFUSAL ($label): expected non-zero exit, got $code (out: [$out])"; fi
  if [ "$pre_content" = "$post_content" ]; then pass "AC21 REFUSAL ($label): .quetrex/verify.json byte-identical afterwards"; else fail "AC21 REFUSAL ($label): file changed"; fi
  if [ -n "$out" ]; then pass "AC21 REFUSAL ($label): stderr names a reason"; else fail "AC21 REFUSAL ($label): no stderr output"; fi
}
refusal_test "1: cmd not in .verify[]" --cmd "npm run nope" --env A_URL
refusal_test "2: env not declared" --cmd "npm run build" --env D_URL
refusal_test "3: env has a fallback" --cmd "npm run build" --env B_URL
refusal_test "4: env never read" --cmd "npm run build" --env C_URL

# --- UNION -------------------------------------------------------------
"$TOOL" declare "$F21" --cmd "npm run build" --env E_URL >/dev/null
BUILD_REQ21U="$(jq -S -c '.requiredEnv["npm run build"]' "$F21/.quetrex/verify.json")"
if printf '%s' "$BUILD_REQ21U" | jq -e '. == ["A_URL","E_URL"] or . == ["E_URL","A_URL"]' >/dev/null 2>&1 \
   && [ "$(printf '%s' "$BUILD_REQ21U" | jq 'length')" = "2" ]; then
  pass "AC21 UNION: a second valid name yields length 2 with the first name still present"
else
  fail "AC21 UNION: expected length 2 containing A_URL and E_URL, got '$BUILD_REQ21U'"
fi

# --- INVARIANTS ----------------------------------------------------------
FOREIGN21="$(jq '(.requiredEnv | keys) - .verify | length' "$F21/.quetrex/verify.json")"
[ "$FOREIGN21" = "0" ] && pass "AC21 INVARIANTS: every requiredEnv key is a byte-for-byte member of .verify[]" \
  || fail "AC21 INVARIANTS: $FOREIGN21 requiredEnv key(s) are not members of .verify[]"

LEAK21="$(grep -cE 'ac21-(a|e)-value-should-never-leak' "$F21/.quetrex/verify.json")"
[ "$LEAK21" = "0" ] && pass "AC21 INVARIANTS: 0 occurrences of any VALUE string from .env.example in the written file" \
  || fail "AC21 INVARIANTS: a value leaked into verify.json ($LEAK21 occurrence(s))"

for fixname in A_URL B_URL C_URL D_URL; do
  n="$(grep -c "$fixname" "$TOOL")"
  [ "$n" = "0" ] && pass "AC21 INVARIANTS: fixture name $fixname is not hardcoded in bin/quetrex-env-derive" \
    || fail "AC21 INVARIANTS: fixture name $fixname appears $n time(s) in the tool"
done

# --- DECLINE ---------------------------------------------------------------
PRE21DEC_REQLEN="$(jq '.requiredEnv // {} | length' "$F21/.quetrex/verify.json")"
"$TOOL" declare "$F21" --decline C_URL >/dev/null
POST21DEC_REQLEN="$(jq '.requiredEnv // {} | length' "$F21/.quetrex/verify.json")"
[ "$PRE21DEC_REQLEN" = "$POST21DEC_REQLEN" ] && pass "AC21 DECLINE: requiredEnv length unchanged by a decline" \
  || fail "AC21 DECLINE: requiredEnv length changed ($PRE21DEC_REQLEN -> $POST21DEC_REQLEN)"
DECL21="$(jq '.requiredEnvDeclined | index("C_URL") != null' "$F21/.quetrex/verify.json")"
[ "$DECL21" = "true" ] && pass "AC21 DECLINE: requiredEnvDeclined contains C_URL" \
  || fail "AC21 DECLINE: requiredEnvDeclined does not contain C_URL"

"$TOOL" declare "$F21" --decline D_URL >/dev/null
DECL21LEN="$(jq '.requiredEnvDeclined | length' "$F21/.quetrex/verify.json")"
[ "$DECL21LEN" = "2" ] && pass "AC21 DECLINE: union-only — a second decline yields length 2" \
  || fail "AC21 DECLINE: expected requiredEnvDeclined length 2, got $DECL21LEN"

MISSING21="$("$TOOL" missing "$F21")"
MISS21_A="$(printf '%s\n' "$MISSING21" | grep -c '^A_URL$')"
MISS21_C="$(printf '%s\n' "$MISSING21" | grep -c '^C_URL$')"
[ "$MISS21_A" = "0" ] && [ "$MISS21_C" = "0" ] \
  && pass "AC21 DECLINE: missing prints 0 lines for a name covered by requiredEnv (A_URL) or declined (C_URL) — 2 of 2" \
  || fail "AC21 DECLINE: expected 0/0, got A_URL=$MISS21_A C_URL=$MISS21_C (missing output: [$MISSING21])"

# --- NEGATIVE CONTROL --------------------------------------------------
MUT21="$TMPROOT/quetrex-env-derive.no-membership-check"
sed -E 's/^var QX_DECLARE_VERIFY_MEMBERSHIP_ENABLED = true;$/var QX_DECLARE_VERIFY_MEMBERSHIP_ENABLED = false;/' "$TOOL" > "$MUT21"
chmod +x "$MUT21"
MUT21_DIFF="$(diff "$TOOL" "$MUT21" | grep -c '^[<>]')"
[ "$MUT21_DIFF" = "2" ] && pass "AC21 NEGATIVE CONTROL: the membership-check mutation changes exactly one line in the tool" \
  || fail "AC21 NEGATIVE CONTROL: expected the mutation to touch exactly 1 line (2 diff lines), got $MUT21_DIFF"

F21neg="$TMPROOT/ac21neg"
git_init_repo "$F21neg"
mkdir -p "$F21neg/src" "$F21neg/.quetrex"
cp "$F21/.env.example" "$F21neg/.env.example" 2>/dev/null || printf 'A_URL=x\n' > "$F21neg/.env.example"
cat > "$F21neg/src/db.js" <<'EOF'
const a = process.env.A_URL;
EOF
jq -cn '{verify:["npm run build"]}' > "$F21neg/.quetrex/verify.json"
git -C "$F21neg" add .env.example src/db.js .quetrex/verify.json
git -C "$F21neg" commit -q -m "chore: AC21 negative-control fixture"

"$MUT21" declare "$F21neg" --cmd "npm run nope" --env A_URL >/dev/null 2>&1
NOPE21NEG="$(jq -c '.requiredEnv["npm run nope"] // empty' "$F21neg/.quetrex/verify.json")"
[ "$NOPE21NEG" = '["A_URL"]' ] \
  && pass "AC21 NEGATIVE CONTROL: disabling the membership check wrongly writes a key for a command not in .verify[] — proves the check is load-bearing" \
  || fail "AC21 NEGATIVE CONTROL: expected the mutated tool to (wrongly) write requiredEnv[\"npm run nope\"], got '$NOPE21NEG'"

# =============================================================================
# AC22 — SEC-4: propose/declare read the SAME committed evidence base
# verify-gate.sh reads. A human confirming a `propose` candidate can never be
# shown, and never confirm, a pairing the gate would then silently refuse.
# =============================================================================
F22="$TMPROOT/ac22"
git_init_repo "$F22"
mkdir -p "$F22/src" "$F22/.quetrex"
printf 'A_URL=ac22-a-value-should-never-leak\n' > "$F22/.env.example"
cat > "$F22/src/db.js" <<'EOF'
// db client
// A_URL: no fallback — line 3 is the provable, committed read
const a = process.env.A_URL;
EOF
jq -cn '{verify:["npm run build"]}' > "$F22/.quetrex/verify.json"
git -C "$F22" add .env.example src/db.js .quetrex/verify.json
git -C "$F22" commit -q -m "chore: AC22 fixture — A_URL fully committed"

# Uncommitted second key + uncommitted read, exactly the SEC-4 shape:
# .env.example gets a WORKING-TREE-ONLY edit, and the read lives in an
# UNTRACKED file — neither half of U_ONLY ever touched HEAD.
printf 'U_ONLY=ac22-u-value-should-never-leak\n' >> "$F22/.env.example"
cat > "$F22/src/u.js" <<'EOF'
const u = process.env.U_ONLY;
EOF

OUT22="$("$TOOL" propose "$F22" 2>"$TMPROOT/ac22.stderr")"; CODE22=$?
ERR22="$(cat "$TMPROOT/ac22.stderr")"

[ "$CODE22" -eq 0 ] && pass "AC22: propose exits 0" || fail "AC22: expected exit 0, got $CODE22 (out: [$OUT22])"
CANDLEN22="$(printf '%s' "$OUT22" | jq '.candidates | length' 2>/dev/null)"
[ "$CANDLEN22" = "1" ] && pass "AC22: .candidates|length == 1" \
  || fail "AC22: expected .candidates|length == 1, got '$CANDLEN22' (out: [$OUT22])"
CANDNAME22="$(printf '%s' "$OUT22" | jq -r '.candidates[0].name' 2>/dev/null)"
[ "$CANDNAME22" = "A_URL" ] && pass "AC22: .candidates[0].name == A_URL" \
  || fail "AC22: expected A_URL, got '$CANDNAME22'"
CANDPROJ22="$(printf '%s' "$OUT22" | jq -c '.candidates' 2>/dev/null)"
U22="$(printf '%s' "$CANDPROJ22" | grep -c 'U_ONLY')"
[ "$U22" = "0" ] && pass "AC22: U_ONLY does not appear in the .candidates projection" \
  || fail "AC22: U_ONLY leaked into .candidates: [$CANDPROJ22]"

ERRLINES22="$(printf '%s\n' "$ERR22" | grep -c .)"
ERRHINT22="$(printf '%s\n' "$ERR22" | grep -c 'U_ONLY.*not committed')"
[ "$ERRLINES22" = "1" ] && [ "$ERRHINT22" = "1" ] \
  && pass "AC22: exactly 1 stderr line naming U_ONLY and containing 'not committed'" \
  || fail "AC22: expected exactly 1 stderr line naming U_ONLY / 'not committed', got $ERRLINES22 line(s) (stderr: [$ERR22])"

PRE22="$(cat "$F22/.quetrex/verify.json")"
"$TOOL" declare "$F22" --cmd "npm run build" --env U_ONLY >/dev/null 2>&1
CODE22D=$?
POST22="$(cat "$F22/.quetrex/verify.json")"
[ "$CODE22D" -ne 0 ] && pass "AC22: declare --env U_ONLY exits non-zero (not a provable candidate)" \
  || fail "AC22: expected declare --env U_ONLY to refuse, got exit 0"
[ "$PRE22" = "$POST22" ] && pass "AC22: .quetrex/verify.json byte-identical after the refused declare" \
  || fail "AC22: .quetrex/verify.json changed after a refused declare"

# --- EVIDENCE-BASE EQUIVALENCE: propose stdout byte-identical after every
# uncommitted/untracked file is deleted -------------------------------------
OUT22_BEFORE="$OUT22"
git -C "$F22" checkout -q -- .env.example
git -C "$F22" clean -q -fd
OUT22_AFTER="$("$TOOL" propose "$F22" 2>/dev/null)"
if diff <(printf '%s' "$OUT22_BEFORE") <(printf '%s' "$OUT22_AFTER") >/dev/null 2>&1; then
  pass "AC22: propose stdout is byte-identical before and after every uncommitted/untracked file is deleted"
else
  fail "AC22: propose stdout changed after deleting uncommitted/untracked files: before=[$OUT22_BEFORE] after=[$OUT22_AFTER]"
fi

HEADCOLON22="$(grep -c 'HEAD:' "$TOOL")"
if [ "$HEADCOLON22" -ge 2 ]; then
  pass "AC22: bin/quetrex-env-derive contains >= 2 occurrences of the literal 'HEAD:' ($HEADCOLON22)"
else
  fail "AC22: expected >= 2 occurrences of 'HEAD:' in the tool, got $HEADCOLON22"
fi

# --- HOOK PARITY -------------------------------------------------------------
HOOKPARITY22="$(git -C "$F22" show HEAD:.env.example | grep -cE '^A_URL=')"
[ "$HOOKPARITY22" = "1" ] && pass "AC22 HOOK PARITY: the accepted name A_URL is a key in the COMMITTED .env.example at HEAD (matches verify-gate.sh's own read)" \
  || fail "AC22 HOOK PARITY: expected exactly 1 match for ^A_URL= in the committed blob, got $HOOKPARITY22"

# --- NEGATIVE CONTROL --------------------------------------------------------
# A SEPARATE fixture isolates exactly what breaks when declaredNames() alone
# regresses to reading the working tree: U_ONLY needs a COMMITTED read (so
# fallbacklessReads, left untouched, already carries it) but an UNCOMMITTED
# declaration — the one axis the mutation controls.
F22neg="$TMPROOT/ac22neg"
git_init_repo "$F22neg"
mkdir -p "$F22neg/src" "$F22neg/.quetrex"
printf 'A_URL=x\n' > "$F22neg/.env.example"
cat > "$F22neg/src/db.js" <<'EOF'
const a = process.env.A_URL;
const u = process.env.U_ONLY;
EOF
jq -cn '{verify:["npm run build"]}' > "$F22neg/.quetrex/verify.json"
git -C "$F22neg" add .env.example src/db.js .quetrex/verify.json
git -C "$F22neg" commit -q -m "chore: AC22 negative-control fixture — U_ONLY has a COMMITTED read but no committed declaration"
printf 'U_ONLY=y\n' >> "$F22neg/.env.example"  # working-tree-only declaration

MUT22="$TMPROOT/quetrex-env-derive.declarednames-fs"
sed -E 's/^([[:space:]]*)var text = committedBlob\(repoRoot, candidates\[i\]\);$/\1var text = null; try { text = fs.readFileSync(path.join(repoRoot, candidates[i]), "utf8"); } catch (e) { text = null; }/' "$TOOL" > "$MUT22"
chmod +x "$MUT22"
MUT22_DIFF="$(diff "$TOOL" "$MUT22" | grep -c '^[<>]')"
[ "$MUT22_DIFF" = "2" ] && pass "AC22 NEGATIVE CONTROL: the declaredNames()-to-fs mutation changes exactly one line in the tool" \
  || fail "AC22 NEGATIVE CONTROL: expected the mutation to touch exactly 1 line (2 diff lines), got $MUT22_DIFF"

OUT22NEG="$("$MUT22" propose "$F22neg" 2>/dev/null)"
CANDLEN22NEG="$(printf '%s' "$OUT22NEG" | jq '.candidates | length' 2>/dev/null)"
UPRESENT22NEG="$(printf '%s' "$OUT22NEG" | jq -c '.candidates' 2>/dev/null | grep -c 'U_ONLY')"
if [ "$CANDLEN22NEG" = "2" ] && [ "$UPRESENT22NEG" = "1" ]; then
  pass "AC22 NEGATIVE CONTROL: reverting declaredNames() to a working-tree fs read wrongly surfaces U_ONLY as a candidate (candidates|length 1 -> 2, U_ONLY present) — proving both assertions are load-bearing, not vacuous"
else
  fail "AC22 NEGATIVE CONTROL: expected the mutated tool to wrongly surface U_ONLY (length 2, present), got length=$CANDLEN22NEG present=$UPRESENT22NEG (out: [$OUT22NEG])"
fi

# =============================================================================
# AC31 — `plan <plan.json> <repo-root>` stamps Contract A required_env[]
# entries by reading the SAME committed requiredEnv declaration verify-
# gate.sh reads — never re-derived, never inferred — and is root-contained
# (SEC-3): it can only ever write a plan artifact where a plan artifact
# belongs.
# =============================================================================
F31="$TMPROOT/ac31"
git_init_repo "$F31"
mkdir -p "$F31/src" "$F31/.quetrex/plan"
cat > "$F31/src/db.js" <<'EOF'
// db client
// A_URL: no fallback — line 3 is the provable read
const a = process.env.A_URL;
EOF
printf 'A_URL=ac31-value-should-never-leak\n' > "$F31/.env.example"
jq -cn '{verify:["npm run build"],requiredEnv:{"npm run build":["A_URL"]}}' > "$F31/.quetrex/verify.json"
git -C "$F31" add src/db.js .env.example .quetrex/verify.json
git -C "$F31" commit -q -m "chore: AC31 fixture — committed requiredEnv for npm run build"

mk_plan() {  # mk_plan <path> <extra-json-merge>
  jq -cn --argjson extra "$2" '{task:"AC31-TASK", base_sha:"deadbeef", verify:["npm run build"]} + $extra' > "$1"
}

PLAN31="$F31/.quetrex/plan/AC31-TASK.json"
mk_plan "$PLAN31" '{}'
PRE31_NOREQ="$(jq 'del(.required_env)' "$PLAN31")"

OUT31="$("$TOOL" plan "$PLAN31" "$F31" 2>&1)"; CODE31=$?
[ "$CODE31" -eq 0 ] && pass "AC31 STAMP: plan exits 0" || fail "AC31 STAMP: expected exit 0, got $CODE31 (out: [$OUT31])"

REQLEN31="$(jq '.required_env | length' "$PLAN31")"
[ "$REQLEN31" = "1" ] && pass "AC31 STAMP: .required_env|length == 1" || fail "AC31 STAMP: expected 1, got $REQLEN31"
KEYS31="$(jq -r '.required_env[0] | keys | sort | join(",")' "$PLAN31")"
[ "$KEYS31" = "name,placeholderable,read_at,why" ] && pass "AC31 STAMP: entry keys are exactly name,placeholderable,read_at,why" \
  || fail "AC31 STAMP: expected 'name,placeholderable,read_at,why', got '$KEYS31'"
NAME31="$(jq -r '.required_env[0].name' "$PLAN31")"
[ "$NAME31" = "A_URL" ] && pass "AC31 STAMP: [0].name == A_URL" || fail "AC31 STAMP: expected A_URL, got '$NAME31'"
READAT31="$(jq -r '.required_env[0].read_at' "$PLAN31")"
[ "$READAT31" = "src/db.js:3" ] && pass "AC31 STAMP: [0].read_at == src/db.js:3" || fail "AC31 STAMP: expected src/db.js:3, got '$READAT31'"

POST31_NOREQ="$(jq 'del(.required_env)' "$PLAN31")"
if diff <(printf '%s' "$PRE31_NOREQ") <(printf '%s' "$POST31_NOREQ") >/dev/null 2>&1; then
  pass "AC31 STAMP: del(.required_env) is byte-identical to the pre-stamp plan with required_env deleted"
else
  fail "AC31 STAMP: stamping mutated fields other than required_env"
fi

cp "$PLAN31" "$TMPROOT/ac31-after-stamp1.json"
"$TOOL" plan "$PLAN31" "$F31" >/dev/null
cmp -s "$TMPROOT/ac31-after-stamp1.json" "$PLAN31" && pass "AC31 STAMP: a second stamp leaves the file byte-identical" \
  || fail "AC31 STAMP: a second stamp changed the file"

STRAY31="$(find "$F31/.quetrex/plan" -maxdepth 1 -name '*.envderive.*' -o -maxdepth 1 -name '*.stamp.*' 2>/dev/null | grep -c .)"
[ "$STRAY31" = "0" ] && pass "AC31 STAMP: 0 stray .envderive.*/.stamp.* files remain in the plan directory" \
  || fail "AC31 STAMP: found $STRAY31 stray temp file(s) in the plan directory"

# --- UNION ---------------------------------------------------------------
PLAN31U="$F31/.quetrex/plan/AC31-UNION.json"
jq -cn '{task:"AC31-UNION", base_sha:"deadbeef", verify:["npm run build"], required_env:[{name:"ARCHITECT_VAR",read_at:"src/other.js:1",placeholderable:true,why:"architect-authored"}]}' > "$PLAN31U"
"$TOOL" plan "$PLAN31U" "$F31" >/dev/null
UNIONLEN31="$(jq '.required_env | length' "$PLAN31U")"
ARCH31="$(jq -r '.required_env[] | select(.name=="ARCHITECT_VAR") | .why' "$PLAN31U")"
[ "$UNIONLEN31" = "2" ] && [ "$ARCH31" = "architect-authored" ] \
  && pass "AC31 UNION: an existing architect entry yields length 2 with the architect's entry unchanged" \
  || fail "AC31 UNION: expected length 2 with architect entry preserved, got length=$UNIONLEN31 why='$ARCH31'"

# --- NO INFERENCE (load-bearing) -----------------------------------------
F31ni="$TMPROOT/ac31ni"
git_init_repo "$F31ni"
mkdir -p "$F31ni/src" "$F31ni/.quetrex/plan"
cp "$F31/src/db.js" "$F31ni/src/db.js"
cp "$F31/.env.example" "$F31ni/.env.example"
jq -cn '{verify:["npm run build"]}' > "$F31ni/.quetrex/verify.json"  # requiredEnv REMOVED
git -C "$F31ni" add src/db.js .env.example .quetrex/verify.json
git -C "$F31ni" commit -q -m "chore: AC31 no-inference fixture — A_URL is a committed candidate but NOT declared"

PLAN31NI="$F31ni/.quetrex/plan/AC31-NI.json"
mk_plan "$PLAN31NI" '{}'
"$TOOL" plan "$PLAN31NI" "$F31ni" >/dev/null
NILEN31="$(jq '.required_env // [] | length' "$PLAN31NI")"
[ "$NILEN31" = "0" ] && pass "AC31 NO INFERENCE: with requiredEnv absent, the stamp adds 0 entries even though A_URL is a committed candidate" \
  || fail "AC31 NO INFERENCE: expected 0 entries, got $NILEN31"

# --- CONTAINMENT, 4 probes ------------------------------------------------
# (a) outside .quetrex/plan entirely
OUTSIDE_DIR="$TMPROOT/ac31-outside"
mkdir -p "$OUTSIDE_DIR"
EVIL_PLAN="$OUTSIDE_DIR/evil-plan.json"
mk_plan "$EVIL_PLAN" '{}'
cp "$EVIL_PLAN" "$TMPROOT/ac31-evil-precopy.json"
"$TOOL" plan "$EVIL_PLAN" "$F31" >"$TMPROOT/ac31a.out" 2>&1; CODE31A=$?
[ "$CODE31A" -ne 0 ] && pass "AC31 CONTAINMENT (a): plan outside .quetrex/plan exits non-zero" \
  || fail "AC31 CONTAINMENT (a): expected non-zero exit, got 0"
cmp -s "$TMPROOT/ac31-evil-precopy.json" "$EVIL_PLAN" && pass "AC31 CONTAINMENT (a): the outside file is byte-identical afterward" \
  || fail "AC31 CONTAINMENT (a): the outside file was modified"
grep -qi 'plan' "$TMPROOT/ac31a.out" && pass "AC31 CONTAINMENT (a): stderr names the rule" \
  || fail "AC31 CONTAINMENT (a): stderr did not name a reason: [$(cat "$TMPROOT/ac31a.out")]"

# (b) resolved parent directory does not end in /.quetrex/plan
mkdir -p "$F31/.quetrex/plans"
WRONGDIR_PLAN="$F31/.quetrex/plans/wrong.json"
mk_plan "$WRONGDIR_PLAN" '{}'
cp "$WRONGDIR_PLAN" "$TMPROOT/ac31-wrongdir-precopy.json"
"$TOOL" plan "$WRONGDIR_PLAN" "$F31" >/dev/null 2>&1; CODE31B=$?
[ "$CODE31B" -ne 0 ] && pass "AC31 CONTAINMENT (b): a planPath whose parent dir is not /.quetrex/plan is refused" \
  || fail "AC31 CONTAINMENT (b): expected non-zero exit, got 0"
cmp -s "$TMPROOT/ac31-wrongdir-precopy.json" "$WRONGDIR_PLAN" && pass "AC31 CONTAINMENT (b): the target file is byte-identical afterward" \
  || fail "AC31 CONTAINMENT (b): the target file was modified"

# (c) planPath is itself a symlink
VICTIM31="$F31/.quetrex/plan/victim.json"
mk_plan "$VICTIM31" '{}'
cp "$VICTIM31" "$TMPROOT/ac31-victim-precopy.json"
SYMLINK31="$F31/.quetrex/plan/symlinked.json"
ln -sf "$VICTIM31" "$SYMLINK31"
"$TOOL" plan "$SYMLINK31" "$F31" >/dev/null 2>&1; CODE31C=$?
[ "$CODE31C" -ne 0 ] && pass "AC31 CONTAINMENT (c): a symlinked planPath is refused" \
  || fail "AC31 CONTAINMENT (c): expected non-zero exit, got 0"
cmp -s "$TMPROOT/ac31-victim-precopy.json" "$VICTIM31" && pass "AC31 CONTAINMENT (c): the symlink's victim file is byte-identical afterward" \
  || fail "AC31 CONTAINMENT (c): the victim file was modified"
rm -f "$SYMLINK31"

# (d) the REAL dispatcher shape: mktemp -d OUTSIDE the repo root holding
# .quetrex/plan/<TASK_ID>.json — must be ACCEPTED.
TMP_WT31="$(mktemp -d "${TMPDIR:-/tmp}/ac31-tmpwt.XXXXXX")"
mkdir -p "$TMP_WT31/.quetrex/plan"
DISPATCH_PLAN="$TMP_WT31/.quetrex/plan/AC31-DISPATCH.json"
mk_plan "$DISPATCH_PLAN" '{}'
"$TOOL" plan "$DISPATCH_PLAN" "$F31" >/dev/null 2>&1; CODE31D=$?
[ "$CODE31D" -eq 0 ] && pass "AC31 CONTAINMENT (d): the real dispatcher shape (mktemp -d outside repo root) is ACCEPTED" \
  || fail "AC31 CONTAINMENT (d): expected exit 0 for the real dispatcher shape, got $CODE31D"
rm -rf "$TMP_WT31"

# --- NEGATIVE CONTROL ------------------------------------------------------
MUT31="$TMPROOT/quetrex-env-derive.no-parent-check"
sed -E 's/^([[:space:]]*)if \(!endsWithSuffix\) \{$/\1if (false) {/' "$TOOL" > "$MUT31"
chmod +x "$MUT31"
MUT31_DIFF="$(diff "$TOOL" "$MUT31" | grep -c '^[<>]')"
[ "$MUT31_DIFF" = "2" ] && pass "AC31 NEGATIVE CONTROL: the parent-directory-check mutation changes exactly one line" \
  || fail "AC31 NEGATIVE CONTROL: expected the mutation to touch exactly 1 line (2 diff lines), got $MUT31_DIFF"

EVIL_PLAN2="$OUTSIDE_DIR/evil-plan2.json"
mk_plan "$EVIL_PLAN2" '{}'
cp "$EVIL_PLAN2" "$TMPROOT/ac31-evil2-precopy.json"
"$MUT31" plan "$EVIL_PLAN2" "$F31" >/dev/null 2>&1; CODE31NEG=$?
if [ "$CODE31NEG" -eq 0 ] && ! cmp -s "$TMPROOT/ac31-evil2-precopy.json" "$EVIL_PLAN2"; then
  pass "AC31 NEGATIVE CONTROL: removing the parent-directory check makes probe (a) exit 0 and write — proving the check is load-bearing"
else
  fail "AC31 NEGATIVE CONTROL: expected the mutated tool to (wrongly) accept and write outside .quetrex/plan, got exit=$CODE31NEG"
fi

# =============================================================================
# AC31 END-TO-END — the human's COMMITTED declare reaches hydrate, in the
# exact Contract A shape `quetrex-cloud-prep hydrate` consumes. This is the
# concrete answer to the QDM-1 regression: dropping the deleted attribution
# engine must not silently drop the field an unattended cloud build's
# `hydrate` step depends on to export a real placeholder for a genuinely
# required, unset variable. Undeclared must still mean EMPTY, never
# invented — the NEGATIVE CONTROL proves that half.
# =============================================================================
if [ ! -f "$CLOUD_PREP" ]; then
  fail "AC31 END-TO-END: quetrex-cloud-prep not found at $CLOUD_PREP"
else
  F31E="$TMPROOT/ac31e2e"
  git_init_repo "$F31E"
  mkdir -p "$F31E/src" "$F31E/.quetrex/plan"
  cat > "$F31E/src/db.js" <<'EOF'
// db client
// A_URL: no fallback — line 3 is the provable read
const a = process.env.A_URL;
EOF
  printf 'A_URL=ac31e2e-value-should-never-leak\n' > "$F31E/.env.example"
  jq -cn '{verify:["npm run build"]}' > "$F31E/.quetrex/verify.json"  # nothing declared yet
  git -C "$F31E" add src/db.js .env.example .quetrex/verify.json
  git -C "$F31E" commit -q -m "chore: AC31 end-to-end fixture — A_URL is a committed candidate, not yet declared"

  # --- NEGATIVE CONTROL FIRST (fail-first): before declare, the stamp adds
  # nothing and hydrate exports nothing — the undeclared-candidate case must
  # never invent a name. ------------------------------------------------
  PLAN31E="$F31E/.quetrex/plan/AC31E2E.json"
  mk_plan "$PLAN31E" '{}'
  "$TOOL" plan "$PLAN31E" "$F31E" >/dev/null
  PRELEN31E="$(jq '.required_env // [] | length' "$PLAN31E")"
  [ "$PRELEN31E" = "0" ] && pass "AC31 END-TO-END NEGATIVE CONTROL: before declare, the stamp adds 0 entries" \
    || fail "AC31 END-TO-END NEGATIVE CONTROL: expected 0 entries before declare, got $PRELEN31E"

  ENV_FILE31EPRE="$TMPROOT/ac31e2e-env-pre.sh"
  HYDRATE_OUT_PRE="$(env -u A_URL "$CLOUD_PREP" hydrate "$PLAN31E" --env-file "$ENV_FILE31EPRE" --repo "$F31E" 2>/dev/null)"
  PLACEHOLDERED_PRE="$(printf '%s\n' "$HYDRATE_OUT_PRE" | grep '^QX_ENV_PLACEHOLDERED=' | sed "s/^QX_ENV_PLACEHOLDERED='//; s/'\$//")"
  [ -z "$PLACEHOLDERED_PRE" ] && pass "AC31 END-TO-END NEGATIVE CONTROL: before declare, hydrate placeholders nothing (QX_ENV_PLACEHOLDERED is empty)" \
    || fail "AC31 END-TO-END NEGATIVE CONTROL: expected hydrate to placeholder nothing before declare, got '$PLACEHOLDERED_PRE'"

  # --- Now declare + commit, re-stamp, and hydrate for real. -------------
  "$TOOL" declare "$F31E" --cmd "npm run build" --env A_URL >/dev/null
  git -C "$F31E" add .quetrex/verify.json
  git -C "$F31E" commit -q -m "declare requiredEnv for npm run build"

  "$TOOL" plan "$PLAN31E" "$F31E" >/dev/null; CODE31E=$?
  [ "$CODE31E" -eq 0 ] && pass "AC31 END-TO-END: plan exits 0 after declare + commit" \
    || fail "AC31 END-TO-END: expected exit 0, got $CODE31E"
  REQLEN31E="$(jq '.required_env | length' "$PLAN31E")"
  [ "$REQLEN31E" = "1" ] && pass "AC31 END-TO-END: .required_env|length == 1 after declare + commit" \
    || fail "AC31 END-TO-END: expected 1, got $REQLEN31E"
  REQNAME31E="$(jq -r '.required_env[0].name' "$PLAN31E")"
  [ "$REQNAME31E" = "A_URL" ] && pass "AC31 END-TO-END: [0].name == A_URL" \
    || fail "AC31 END-TO-END: expected A_URL, got '$REQNAME31E'"

  ENV_FILE31E="$TMPROOT/ac31e2e-env.sh"
  HYDRATE_OUT="$(env -u A_URL "$CLOUD_PREP" hydrate "$PLAN31E" --env-file "$ENV_FILE31E" --repo "$F31E" 2>/dev/null)"
  PLACEHOLDERED31E="$(printf '%s\n' "$HYDRATE_OUT" | grep '^QX_ENV_PLACEHOLDERED=' | sed "s/^QX_ENV_PLACEHOLDERED='//; s/'\$//")"
  [ "$PLACEHOLDERED31E" = "A_URL" ] && pass "AC31 END-TO-END: hydrate exports a placeholder for A_URL (QX_ENV_PLACEHOLDERED='A_URL') — the committed declaration reaches the cloud build" \
    || fail "AC31 END-TO-END: expected QX_ENV_PLACEHOLDERED='A_URL', got '$PLACEHOLDERED31E' (hydrate out: [$HYDRATE_OUT])"
  EXPORTLEN31E="$(grep -cE '^export A_URL=' "$ENV_FILE31E")"
  [ "$EXPORTLEN31E" = "1" ] && pass "AC31 END-TO-END: the env file carries exactly 1 export line for A_URL" \
    || fail "AC31 END-TO-END: expected exactly 1 export line for A_URL, got $EXPORTLEN31E"
  LEAK31E="$(grep -c 'ac31e2e-value-should-never-leak' "$ENV_FILE31E")"
  [ "$LEAK31E" = "0" ] && pass "AC31 END-TO-END: the exported value is a placeholder — 0 occurrences of the real .env.example value" \
    || fail "AC31 END-TO-END: the real value leaked into the hydrated env file"
fi

# =============================================================================
# init.md extraction helper — pulls the fenced ```bash block out from under a
# given "### heading" line, verbatim, never retyped. Stops at the next line
# beginning with '#' (any heading), exactly like test/doctor-checks.test.sh's
# own extract_section convention for command-file fences.
# =============================================================================
extract_init_section() {  # extract_init_section <heading-prefix>
  local heading="$1"
  awk -v heading="$heading" '
    index($0, heading) == 1 { insec = 1; next }
    insec && !infence && /^#/ { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$INIT_MD"
}

SEED_BLOCK="$(extract_init_section "### 5a. Seed")"
GUARD_BLOCK="$(extract_init_section "### 5c. Confirm with the human")"

if [ -n "$SEED_BLOCK" ]; then
  pass "setup: extracted init.md's 5a seed block"
else
  fail "setup: could not extract init.md's 5a seed block"
fi
if [ -n "$GUARD_BLOCK" ]; then
  pass "setup: extracted init.md's 5c non-interactive-guard block"
else
  fail "setup: could not extract init.md's 5c non-interactive-guard block"
fi

# =============================================================================
# AC23 — init.md never invokes the seeder with an empty word (the permanent
# merge-deadlock defect), closed at TWO independent layers: the caller never
# passes an unguarded "${CONFIRMED_STEPS[@]:-}", and seed-chain itself
# refuses an empty/blank command.
# =============================================================================

# --- SHAPE: the extracted block never uses the bare "[@]:-" idiom, and DOES
# use an unset-safe guard form. ------------------------------------------
BAREIDIOM23="$(printf '%s\n' "$SEED_BLOCK" | grep -c '\[@\]:-')"
[ "$BAREIDIOM23" = "0" ] && pass "AC23 SHAPE: the extracted 5a block contains 0 occurrences of the literal '[@]:-'" \
  || fail "AC23 SHAPE: expected 0 occurrences of '[@]:-' in the extracted block, got $BAREIDIOM23"
GUARDFORM23="$(printf '%s\n' "$SEED_BLOCK" | grep -c '\${CONFIRMED_STEPS+set}')"
[ "$GUARDFORM23" -ge 1 ] && pass "AC23 SHAPE: the extracted 5a block uses the unset-safe \${CONFIRMED_STEPS+set} guard" \
  || fail "AC23 SHAPE: expected >= 1 occurrence of the unset-safe guard, got $GUARDFORM23"

# --- CALLER LAYER: run the extracted block verbatim, under set -u, in three
# states, with a counting PATH shim in front of the seeder. -----------------
SHIMDIR="$TMPROOT/ac23-shim"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/quetrex-env-derive" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "seed-chain" ]; then
  printf '%s\n' "\$*" >> "\$QX_SEED_SHIM_LOG"
fi
exec "$TOOL" "\$@"
EOF
chmod +x "$SHIMDIR/quetrex-env-derive"

run_seed_block() {  # run_seed_block <repo-root> <mode: unset|empty|four>
  local repo="$1" mode="$2" script="$TMPROOT/ac23-run.sh"
  {
    printf '#!/usr/bin/env bash\nset -u\nREPO_ROOT=%q\n' "$repo"
    case "$mode" in
      empty) printf 'CONFIRMED_STEPS=()\n' ;;
      four)  printf 'CONFIRMED_STEPS=("npm run a" "npm run b" "npm run c" "npm run d")\n' ;;
      unset) : ;;
    esac
    printf '%s\n' "$SEED_BLOCK"
  } > "$script"
  PATH="$SHIMDIR:$PATH" bash "$script"
}

# state (i): CONFIRMED_STEPS unset
F23i="$TMPROOT/ac23-i"; mkdir -p "$F23i"
export QX_SEED_SHIM_LOG="$TMPROOT/ac23-i.log"; : > "$QX_SEED_SHIM_LOG"
run_seed_block "$F23i" "unset" >/dev/null 2>&1
INVOKES23I="$(grep -c . "$QX_SEED_SHIM_LOG")"
[ "$INVOKES23I" = "0" ] && pass "AC23 CALLER (i unset): the shim records exactly 0 invocations" \
  || fail "AC23 CALLER (i unset): expected 0 invocations, got $INVOKES23I"
[ ! -f "$F23i/.quetrex/verify.json" ] && pass "AC23 CALLER (i unset): .quetrex/verify.json does not exist afterwards" \
  || fail "AC23 CALLER (i unset): .quetrex/verify.json was created"

# state (ii): CONFIRMED_STEPS declared empty
F23ii="$TMPROOT/ac23-ii"; mkdir -p "$F23ii"
export QX_SEED_SHIM_LOG="$TMPROOT/ac23-ii.log"; : > "$QX_SEED_SHIM_LOG"
run_seed_block "$F23ii" "empty" >/dev/null 2>&1
INVOKES23II="$(grep -c . "$QX_SEED_SHIM_LOG")"
[ "$INVOKES23II" = "0" ] && pass "AC23 CALLER (ii empty): the shim records exactly 0 invocations" \
  || fail "AC23 CALLER (ii empty): expected 0 invocations, got $INVOKES23II"
[ ! -f "$F23ii/.quetrex/verify.json" ] && pass "AC23 CALLER (ii empty): .quetrex/verify.json does not exist afterwards" \
  || fail "AC23 CALLER (ii empty): .quetrex/verify.json was created"

# state (iii): CONFIRMED_STEPS holding 4 real commands
F23iii="$TMPROOT/ac23-iii"; mkdir -p "$F23iii"
export QX_SEED_SHIM_LOG="$TMPROOT/ac23-iii.log"; : > "$QX_SEED_SHIM_LOG"
run_seed_block "$F23iii" "four" >/dev/null 2>&1
INVOKES23III="$(grep -c . "$QX_SEED_SHIM_LOG")"
[ "$INVOKES23III" = "1" ] && pass "AC23 CALLER (iii four): exactly 1 invocation" \
  || fail "AC23 CALLER (iii four): expected exactly 1 invocation, got $INVOKES23III"
[ -f "$F23iii/.quetrex/verify.json" ] && pass "AC23 CALLER (iii four): .quetrex/verify.json exists" \
  || fail "AC23 CALLER (iii four): .quetrex/verify.json was not created"
LEN23III="$(jq '.verify | length' "$F23iii/.quetrex/verify.json" 2>/dev/null)"
[ "$LEN23III" = "4" ] && pass "AC23 CALLER (iii four): .verify|length == 4" \
  || fail "AC23 CALLER (iii four): expected 4, got '$LEN23III'"
EMPTY23III="$(jq '[.verify[] | select(.=="")] | length' "$F23iii/.quetrex/verify.json" 2>/dev/null)"
[ "$EMPTY23III" = "0" ] && pass "AC23 CALLER (iii four): 0 empty entries in .verify[]" \
  || fail "AC23 CALLER (iii four): expected 0 empty entries, got $EMPTY23III"
unset QX_SEED_SHIM_LOG

# --- TOOL LAYER: seed-chain independently refuses an empty/blank command,
# even called directly (the second, structural backstop). -------------------
F23tool="$TMPROOT/ac23-tool"
git_init_repo "$F23tool"
OUT23TOOL1="$("$TOOL" seed-chain "$F23tool" "" 2>&1)"; CODE23TOOL1=$?
[ "$CODE23TOOL1" -ne 0 ] && pass "AC23 TOOL LAYER: seed-chain <root> \"\" exits non-zero" \
  || fail "AC23 TOOL LAYER: expected non-zero exit for a blank command, got 0"
[ ! -f "$F23tool/.quetrex/verify.json" ] && pass "AC23 TOOL LAYER: seed-chain <root> \"\" creates 0 files" \
  || fail "AC23 TOOL LAYER: a file was created for a blank command"
printf '%s\n' "$OUT23TOOL1" | grep -qi 'empty' && pass "AC23 TOOL LAYER: stderr names 'empty'" \
  || fail "AC23 TOOL LAYER: stderr does not mention 'empty': [$OUT23TOOL1]"

OUT23TOOL2="$("$TOOL" seed-chain "$F23tool" 2>&1)"; CODE23TOOL2=$?
[ "$CODE23TOOL2" -ne 0 ] && pass "AC23 TOOL LAYER: seed-chain <root> with 0 commands exits non-zero" \
  || fail "AC23 TOOL LAYER: expected non-zero exit for 0 commands, got 0"
[ ! -f "$F23tool/.quetrex/verify.json" ] && pass "AC23 TOOL LAYER: 0 commands creates 0 files" \
  || fail "AC23 TOOL LAYER: a file was created for 0 commands"

F23existing="$TMPROOT/ac23-existing"
git_init_repo "$F23existing"
mkdir -p "$F23existing/.quetrex"
jq -cn '{verify:["npm run build"]}' > "$F23existing/.quetrex/verify.json"
PRE23EX="$(cat "$F23existing/.quetrex/verify.json")"
"$TOOL" seed-chain "$F23existing" "npm run other" >/dev/null 2>&1
POST23EX="$(cat "$F23existing/.quetrex/verify.json")"
[ "$PRE23EX" = "$POST23EX" ] && pass "AC23 TOOL LAYER: seed-chain against an already-existing chain leaves it byte-identical" \
  || fail "AC23 TOOL LAYER: seed-chain modified an already-existing chain"

# --- DOWNSTREAM PROOF: merge-gate.sh GATE 3's own jq, evaluated against
# every verify.json this test produced, yields 0 RED entries with .cmd=="".
# -----------------------------------------------------------------------
gate3_empty_cmd_count() {  # gate3_empty_cmd_count <verify.json>
  jq '[.verify[]? | select(.=="")] | length' "$1" 2>/dev/null
}
DOWNSTREAM23_TOTAL=0
for f in "$F23iii/.quetrex/verify.json" "$F23existing/.quetrex/verify.json"; do
  [ -f "$f" ] || continue
  n="$(gate3_empty_cmd_count "$f")"
  DOWNSTREAM23_TOTAL=$((DOWNSTREAM23_TOTAL + n))
done
[ "$DOWNSTREAM23_TOTAL" = "0" ] && pass "AC23 DOWNSTREAM PROOF: 0 entries with .cmd == \"\" across every verify.json this test produced" \
  || fail "AC23 DOWNSTREAM PROOF: found $DOWNSTREAM23_TOTAL empty-cmd entr(ies)"

# --- NEGATIVE CONTROL: restoring the bare "${CONFIRMED_STEPS[@]:-}" form
# makes state (i) record exactly 1 invocation carrying 1 empty argument. ----
MUT_SEED_BLOCK="$(printf '%s\n' "$SEED_BLOCK" | sed -E 's/\[ "\$\{CONFIRMED_STEPS\+set\}" = "set" \] && \[ "\$\{#CONFIRMED_STEPS\[@\]\}" -gt 0 \]/true/; s/"\$\{CONFIRMED_STEPS\[@\]\}"/"\$\{CONFIRMED_STEPS[@]:-\}"/')"
F23neg="$TMPROOT/ac23-neg"; mkdir -p "$F23neg"
NEG_SCRIPT="$TMPROOT/ac23-neg-run.sh"
{
  printf '#!/usr/bin/env bash\nset -u\nREPO_ROOT=%q\n' "$F23neg"
  printf '%s\n' "$MUT_SEED_BLOCK"
} > "$NEG_SCRIPT"
export QX_SEED_SHIM_LOG="$TMPROOT/ac23-neg.log"; : > "$QX_SEED_SHIM_LOG"
PATH="$SHIMDIR:$PATH" bash "$NEG_SCRIPT" >/dev/null 2>&1
INVOKES23NEG="$(grep -c . "$QX_SEED_SHIM_LOG")"
EMPTYARG23NEG="$(grep -c "seed-chain $F23neg $" "$QX_SEED_SHIM_LOG")"
if [ "$INVOKES23NEG" = "1" ] && [ "$EMPTYARG23NEG" = "1" ]; then
  pass "AC23 NEGATIVE CONTROL: restoring the bare [@]:- form makes state (i) invoke the seeder once, with 1 empty argument"
else
  fail "AC23 NEGATIVE CONTROL: expected 1 invocation with 1 trailing empty arg, got $INVOKES23NEG invocation(s) (log: [$(cat "$QX_SEED_SHIM_LOG")])"
fi
unset QX_SEED_SHIM_LOG

# =============================================================================
# AC24 — init.md's step 5c is PROPOSE -> HUMAN CONFIRM -> WRITE. An init with
# nobody to ask proposes nothing and writes nothing; the structural backstop
# (declare with zero pairs writes nothing) holds even if the prose is skipped.
# =============================================================================
F24="$TMPROOT/ac24"
git_init_repo "$F24"
mkdir -p "$F24/src" "$F24/.quetrex"
printf 'AC24_URL=x\n' > "$F24/.env.example"
cat > "$F24/src/db.js" <<'EOF'
const a = process.env.AC24_URL;
EOF
jq -cn '{verify:["npm run build"]}' > "$F24/.quetrex/verify.json"
git -C "$F24" add .env.example src/db.js .quetrex/verify.json
git -C "$F24" commit -q -m "chore: AC24 fixture — exactly 1 candidate"

DECLARE_SHIM="$TMPROOT/ac24-shim"
mkdir -p "$DECLARE_SHIM"
cat > "$DECLARE_SHIM/quetrex-env-derive" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "declare" ]; then
  printf '%s\n' "\$*" >> "\$QX_DECLARE_SHIM_LOG"
fi
exec "$TOOL" "\$@"
EOF
chmod +x "$DECLARE_SHIM/quetrex-env-derive"

run_guard_block() {  # run_guard_block <repo-root> <noninteractive: 0|1>
  local repo="$1" noninteractive="$2" script="$TMPROOT/ac24-run.sh"
  {
    printf '#!/usr/bin/env bash\nset -u\nREPO_ROOT=%q\n' "$repo"
    if [ "$noninteractive" = "1" ]; then
      printf 'QUETREX_INIT_NONINTERACTIVE=1\n'
    else
      printf 'unset QUETREX_INIT_NONINTERACTIVE || true\n'
    fi
    # Simulate a human having already confirmed one pair via 5c's
    # AskUserQuestion — the guard must still prevent the call when
    # non-interactive, and the array stays empty (nothing to confirm) when
    # 5c's question step is simply omitted, proving the backstop holds
    # either way.
    if [ "$noninteractive" = "1" ]; then
      printf 'CONFIRM_CMD_ENV=("npm run build\\tAC24_URL")\n'
      printf 'CONFIRM_DECLINE=()\n'
    fi
    printf '%s\n' "$GUARD_BLOCK"
  } > "$script"
  PATH="$DECLARE_SHIM:$PATH" bash "$script" </dev/null
}

# --- NON-INTERACTIVE: propose nothing, write nothing, even with a
# pre-populated confirmation, and even under a real </dev/null (no TTY). ----
PRE24="$(cat "$F24/.quetrex/verify.json")"
export QX_DECLARE_SHIM_LOG="$TMPROOT/ac24-noninteractive.log"; : > "$QX_DECLARE_SHIM_LOG"
OUT24NI="$(run_guard_block "$F24" "1" 2>&1)"
POST24="$(cat "$F24/.quetrex/verify.json")"
[ "$PRE24" = "$POST24" ] && pass "AC24 NON-INTERACTIVE: .quetrex/verify.json is byte-identical" \
  || fail "AC24 NON-INTERACTIVE: .quetrex/verify.json changed"
INVOKES24NI="$(grep -c . "$QX_DECLARE_SHIM_LOG")"
[ "$INVOKES24NI" = "0" ] && pass "AC24 NON-INTERACTIVE: declare is invoked exactly 0 times" \
  || fail "AC24 NON-INTERACTIVE: expected 0 declare invocations, got $INVOKES24NI"
LINES24NI="$(printf '%s\n' "$OUT24NI" | grep -c 'non-interactive')"
[ "$LINES24NI" = "1" ] && pass "AC24 NON-INTERACTIVE: prints exactly 1 line containing 'non-interactive'" \
  || fail "AC24 NON-INTERACTIVE: expected exactly 1 line, got $LINES24NI (out: [$OUT24NI])"
unset QX_DECLARE_SHIM_LOG

# --- STRUCTURAL BACKSTOP: the same fixture, with 5c's AskUserQuestion step
# simply omitted (CONFIRM_CMD_ENV never populated) — declare still writes
# nothing, because declare with 0 pairs writes nothing (AC21). -------------
export QX_DECLARE_SHIM_LOG="$TMPROOT/ac24-backstop.log"; : > "$QX_DECLARE_SHIM_LOG"
PRE24B="$(cat "$F24/.quetrex/verify.json")"
run_guard_block "$F24" "0" >/dev/null 2>&1
POST24B="$(cat "$F24/.quetrex/verify.json")"
[ "$PRE24B" = "$POST24B" ] && pass "AC24 STRUCTURAL BACKSTOP: omitting the AskUserQuestion step still leaves .quetrex/verify.json byte-identical" \
  || fail "AC24 STRUCTURAL BACKSTOP: .quetrex/verify.json changed even with nothing confirmed"
unset QX_DECLARE_SHIM_LOG

# --- NEGATIVE CONTROL: reverting only the non-interactive guard makes the
# branch invoke declare >= 1 time. ------------------------------------------
# RE-ANCHORED: the guard used to also test [ ! -t 0 ] / [ ! -t 1 ], which are never
# true inside Claude Code's Bash tool and so made the sanctioned writer unreachable
# (init never authored a requiredEnv entry). The TTY clauses are gone; human
# confirmation is now the AskUserQuestion round trip, and QUETREX_INIT_NONINTERACTIVE
# remains the only suppressor. The control mutates that surviving clause, so it still
# proves the guard is load-bearing rather than decorative.
MUT_GUARD_BLOCK="$(printf '%s\n' "$GUARD_BLOCK" | sed -E 's/if \[ -n "\$\{QUETREX_INIT_NONINTERACTIVE:-\}" \]; then/if false; then/')"
# The mutation must actually apply — a sed that silently matches nothing would make
# this control vacuous, which is precisely how it went stale the first time.
if [ "$MUT_GUARD_BLOCK" = "$GUARD_BLOCK" ]; then
  fail "AC24 NEGATIVE CONTROL: the mutation matched nothing — the control is anchored to text that no longer exists in 5c"
fi
NEG24_SCRIPT="$TMPROOT/ac24-neg-run.sh"
{
  printf '#!/usr/bin/env bash\nset -u\nREPO_ROOT=%q\n' "$F24"
  printf 'QUETREX_INIT_NONINTERACTIVE=1\n'
  printf 'CONFIRM_CMD_ENV=("npm run build\\tAC24_URL")\n'
  printf 'CONFIRM_DECLINE=()\n'
  printf '%s\n' "$MUT_GUARD_BLOCK"
} > "$NEG24_SCRIPT"
export QX_DECLARE_SHIM_LOG="$TMPROOT/ac24-neg.log"; : > "$QX_DECLARE_SHIM_LOG"
PATH="$DECLARE_SHIM:$PATH" bash "$NEG24_SCRIPT" >/dev/null 2>&1 </dev/null
INVOKES24NEG="$(grep -c . "$QX_DECLARE_SHIM_LOG")"
if [ "$INVOKES24NEG" -ge 1 ]; then
  pass "AC24 NEGATIVE CONTROL: reverting the non-interactive guard makes the branch invoke declare >= 1 time — proving the guard is load-bearing"
else
  fail "AC24 NEGATIVE CONTROL: expected the mutated guard to invoke declare >= 1 time, got $INVOKES24NEG"
fi
unset QX_DECLARE_SHIM_LOG

# =============================================================================
# F2 (CONFIRMED, reviewer) — propose must never fabricate a pairing between a
# candidate NAME and a verify[] command, and read_at must never point at
# .quetrex/verify.json itself.
# =============================================================================

# --- F2 READ_AT: a chain command string that itself contains the literal
# text "process.env.NAME" must not corrupt the reported read site. ----------
F2RA="$TMPROOT/f2-readat"
git_init_repo "$F2RA"
mkdir -p "$F2RA/src" "$F2RA/.quetrex"
printf 'FOO_URL=f2-value-should-never-leak\n' > "$F2RA/.env.example"
cat > "$F2RA/src/db.js" <<'EOF'
const a = process.env.FOO_URL;
EOF
# The chain command string below is deliberately shaped so that a whole-tree
# grep for "process.env.NAME" ALSO matches inside .quetrex/verify.json —
# this is the exact reviewer repro, not a contrived edge case: any verify[]
# entry that inspects an env var via a one-liner reproduces it.
jq -cn '{verify:["node -e \"console.log(process.env.FOO_URL)\""]}' > "$F2RA/.quetrex/verify.json"
git -C "$F2RA" add .env.example src/db.js .quetrex/verify.json
git -C "$F2RA" commit -q -m "chore: F2 read_at fixture — verify.json's own text matches the read pattern"

SCAN_F2RA="$("$TOOL" scan "$F2RA" 2>/dev/null)"
READAT_F2RA="$(printf '%s' "$SCAN_F2RA" | cut -f2)"
[ "$READAT_F2RA" = "src/db.js:1" ] && pass "F2 READ_AT: scan reports the real source location src/db.js:1, not .quetrex/verify.json" \
  || fail "F2 READ_AT: expected src/db.js:1, got '$READAT_F2RA' (scan out: [$SCAN_F2RA])"

PROPOSE_F2RA="$("$TOOL" propose "$F2RA" 2>/dev/null)"
PREADAT_F2RA="$(printf '%s' "$PROPOSE_F2RA" | jq -r '.candidates[0].read_at' 2>/dev/null)"
[ "$PREADAT_F2RA" = "src/db.js:1" ] && pass "F2 READ_AT: propose's .candidates[0].read_at is src/db.js:1, not .quetrex/verify.json" \
  || fail "F2 READ_AT: expected src/db.js:1 from propose, got '$PREADAT_F2RA'"

# --- NEGATIVE CONTROL: reverting only the .quetrex exclusion in
# fallbacklessReads() regresses read_at back to the config file. -----------
MUT_F2RA="$TMPROOT/quetrex-env-derive.no-quetrex-exclusion"
sed -E 's/\["grep", "-n", "-I", "-E", combined, "HEAD", "--", "\.", ":!\.quetrex"\]/["grep", "-n", "-I", "-E", combined, "HEAD", "--"]/' "$TOOL" > "$MUT_F2RA"
chmod +x "$MUT_F2RA"
MUT_F2RA_DIFF="$(diff "$TOOL" "$MUT_F2RA" | grep -c '^[<>]')"
[ "$MUT_F2RA_DIFF" = "2" ] && pass "F2 NEGATIVE CONTROL: the .quetrex-exclusion mutation changes exactly one line" \
  || fail "F2 NEGATIVE CONTROL: expected the mutation to touch exactly 1 line (2 diff lines), got $MUT_F2RA_DIFF"

READAT_F2RANEG="$("$MUT_F2RA" scan "$F2RA" 2>/dev/null | cut -f2)"
[ "$READAT_F2RANEG" = ".quetrex/verify.json:1" ] && pass "F2 NEGATIVE CONTROL: reverting the exclusion reproduces the wrong read_at (.quetrex/verify.json:1) — proving the fix is load-bearing" \
  || fail "F2 NEGATIVE CONTROL: expected the mutated tool to (wrongly) report .quetrex/verify.json:1, got '$READAT_F2RANEG'"

# --- F2 HONESTY: propose's own JSON says, in the output itself, that no
# pairing is claimed — and never carries a cmd/command key on a candidate. --
NOTE_F2="$(printf '%s' "$PROPOSE_F2RA" | jq -r '.note')"
printf '%s' "$NOTE_F2" | grep -qF 'NOT paired to any verify' \
  && pass "F2 HONESTY: propose's .note states candidates are NOT paired to a verify[] command" \
  || fail "F2 HONESTY: expected .note to contain 'NOT paired to any verify', got '$NOTE_F2'"

CANDKEYS_F2="$(printf '%s' "$PROPOSE_F2RA" | jq -r '.candidates[0] | keys | sort | join(",")')"
[ "$CANDKEYS_F2" = "name,read_at" ] && pass "F2 HONESTY: a candidate carries exactly name,read_at — never a cmd/command key" \
  || fail "F2 HONESTY: expected exactly 'name,read_at', got '$CANDKEYS_F2'"

# --- F2 INIT.MD SHAPE: the fabricated 3-column table and its invented
# question text are gone; the real chain is rendered instead. ---------------
OLDCOL_F2="$(grep -c 'it could gate' "$INIT_MD")"
[ "$OLDCOL_F2" = "0" ] && pass "F2 INIT.MD: 0 occurrences of the fabricated 'it could gate' column" \
  || fail "F2 INIT.MD: the fabricated column phrase still appears $OLDCOL_F2 time(s)"

OLDQ_F2="$(grep -c 'looks required by' "$INIT_MD")"
[ "$OLDQ_F2" = "0" ] && pass "F2 INIT.MD: 0 occurrences of the old invented 'looks required by' question" \
  || fail "F2 INIT.MD: the old invented question phrase still appears $OLDQ_F2 time(s)"

NEWCHAIN_F2="$(grep -c 'The real verify chain' "$INIT_MD")"
[ "$NEWCHAIN_F2" -ge 1 ] && pass "F2 INIT.MD: the real verify chain is rendered as its own section" \
  || fail "F2 INIT.MD: expected the real-chain rendering section, got $NEWCHAIN_F2"

MULTISEL_F2="$(grep -c 'multi-select' "$INIT_MD")"
[ "$MULTISEL_F2" -ge 1 ] && pass "F2 INIT.MD: the question is documented as multi-select (a name may gate more than one real command)" \
  || fail "F2 INIT.MD: expected a multi-select mention, got $MULTISEL_F2"

# =============================================================================
# F3 (CONFIRMED, reviewer) — init.md's verify.json staging must surface a
# genuine git-add failure instead of swallowing it with 2>/dev/null || true.
#
# RE-ANCHORED (QDM-4 / DEFECT 4). Every PROPERTY F3 asserted is unchanged and
# still asserted below: the verify.json staging must not swallow, a real
# git-add failure must exit non-zero, git's own error text must be visible,
# and restoring the swallow must demonstrably re-hide it. What changed is the
# SHAPE of the shipped text F3 reads. init.md step 6 no longer stages each
# artifact with a bare one-liner; QDM-4 showed the same swallow on the
# NEIGHBORING lines silently dropped the step-4e permissions grant on
# quetrex-demo (its .claude/settings.json ended up with no `permissions` key
# at all), so the unattended cloud build ran the whole pipeline and then
# stalled at `gh pr create` waiting for a human. All required arming artifacts
# now go through one `stage_required()` helper in a single fenced block, so F3
# reads that block instead of a single grep-matched line.
#
# THE ONE ASSERTION THAT CHANGED, STATED PLAINLY: the old "F3 CONTROL" pinned
# the neighboring `.worktreeinclude` line to STILL carry `2>/dev/null || true`.
# Its intent was scope ("this was not a blanket rewrite"), but as written it
# encoded the swallow-on-a-required-artifact behavior that DEFECT 4 exists to
# remove — .worktreeinclude is an arming artifact (without it every pipeline
# worktree lands with no deps and no env). The control is therefore re-pointed
# at `.mcp.json`, which is deliberately NOT a required arming artifact and is
# deliberately still tolerant: it may legitimately not exist, and `add -A` on
# an absent, never-tracked path errors rather than no-oping. That keeps a real
# scope control — proving the change is a considered set, not a sweep — without
# codifying a defect. See test/init-staging.test.sh for the full behavioural
# coverage of the block.
# =============================================================================
F3_BLOCK="$(awk -v anchor='Stage the arming artifacts — fail loud, never silently' '
  !found && index($0, anchor) { found = 1; next }
  found && !infence && /^```bash/ { infence = 1; next }
  found && infence && /^```/ { exit }
  found && infence { print }
' "$INIT_MD")"
F3_LINE="$(printf '%s\n' "$F3_BLOCK" | grep -F 'stage_required .quetrex/verify.json')"
[ -n "$F3_LINE" ] && pass "F3: extracted the verify.json staging call verbatim from init.md's staging block" \
  || fail "F3: could not find the verify.json staging call in init.md's staging block"

SWALLOW_F3="$(printf '%s\n' "$F3_BLOCK" | grep -F 'stage_required' | grep -c '2>/dev/null')"
[ "$SWALLOW_F3" = "0" ] && pass "F3: no stage_required call swallows its exit code" \
  || fail "F3: expected 0 occurrences of '2>/dev/null' on the stage_required calls, got $SWALLOW_F3"

# --- CONTROL: a deliberately NON-required line is still tolerant (proves this
# is a considered set of required artifacts, not a blanket rewrite). --------
NEIGHBOR_F3="$(printf '%s\n' "$F3_BLOCK" | grep -F 'git -C "$REPO_ROOT" add -A .mcp.json')"
NEIGHBOR_SWALLOW_F3="$(printf '%s\n' "$NEIGHBOR_F3" | grep -c '2>/dev/null || true')"
[ "$NEIGHBOR_SWALLOW_F3" = "1" ] && pass "F3 CONTROL: the non-required .mcp.json line is deliberately still tolerant — the fail-loud change is a scoped set, not a sweep" \
  || fail "F3 CONTROL: expected the non-required .mcp.json line to stay tolerant, got $NEIGHBOR_SWALLOW_F3"

# --- BEHAVIORAL: run the extracted block for real against a fixture where
# .quetrex/verify.json is gitignored — git add genuinely fails, and that
# failure must now be visible (nonzero exit, real stderr), not swallowed.
# Only verify.json is ignored, so the block reaches it (project.json stages
# cleanly first) and the observed failure is unambiguously verify.json's. ---
F3FIX="$TMPROOT/f3-fixture"
git_init_repo "$F3FIX"
mkdir -p "$F3FIX/.quetrex"
printf '.quetrex/verify.json\n' > "$F3FIX/.gitignore"
jq -cn '{projectCode:"F3",branchPrefix:"claude/"}' > "$F3FIX/.quetrex/project.json"
jq -cn '{verify:["npm test"]}' > "$F3FIX/.quetrex/verify.json"
git -C "$F3FIX" add .gitignore
git -C "$F3FIX" commit -q -m "chore: F3 fixture — .quetrex/verify.json is gitignored"

run_f3_block() {  # run_f3_block <repo-root> <block>
  local repo="$1" block="$2"
  REPO_ROOT="$repo" BRANCH_PREFIX="claude/" bash -c "$block" 2>&1
}

OUT_F3="$(run_f3_block "$F3FIX" "$F3_BLOCK")"; CODE_F3=$?
[ "$CODE_F3" -ne 0 ] && pass "F3 BEHAVIORAL: a genuine git-add failure now exits non-zero" \
  || fail "F3 BEHAVIORAL: expected non-zero exit on a real git-add failure, got 0 (out: [$OUT_F3])"
printf '%s' "$OUT_F3" | grep -qi 'ignored' && pass "F3 BEHAVIORAL: git's real error text (mentions 'ignored') is visible, not swallowed" \
  || fail "F3 BEHAVIORAL: expected git's error text to be visible, got: [$OUT_F3]"

# --- NEGATIVE CONTROL: put the swallow back inside stage_required() and the
# exact same failure disappears — exit 0, no output — proving the assertions
# above are load-bearing and not passing for some incidental reason. A fresh
# fixture is used because the positive run above already created the adopt
# branch, and the checkout fallback would otherwise print on stderr. --------
F3FIXNEG="$TMPROOT/f3-fixture-neg"
git_init_repo "$F3FIXNEG"
mkdir -p "$F3FIXNEG/.quetrex"
printf '.quetrex/verify.json\n' > "$F3FIXNEG/.gitignore"
jq -cn '{projectCode:"F3",branchPrefix:"claude/"}' > "$F3FIXNEG/.quetrex/project.json"
jq -cn '{verify:["npm test"]}' > "$F3FIXNEG/.quetrex/verify.json"
git -C "$F3FIXNEG" add .gitignore
git -C "$F3FIXNEG" commit -q -m "chore: F3 negative-control fixture"

F3_BLOCK_NEG="$(printf '%s\n' "$F3_BLOCK" | sed 's|git -C "$REPO_ROOT" add -- "$1" && return 0|git -C "$REPO_ROOT" add -- "$1" 2>/dev/null; return 0|')"
if [ "$F3_BLOCK_NEG" = "$F3_BLOCK" ]; then
  fail "F3 NEGATIVE CONTROL: could not re-introduce the swallow into stage_required() — the mutation did not apply, so this control proves nothing"
fi
OUT_F3NEG="$(run_f3_block "$F3FIXNEG" "$F3_BLOCK_NEG")"; CODE_F3NEG=$?
if [ "$CODE_F3NEG" -eq 0 ] && [ -z "$OUT_F3NEG" ]; then
  pass "F3 NEGATIVE CONTROL: putting '2>/dev/null' back inside stage_required() makes the same real failure silently exit 0 with no output — proving the fix is load-bearing"
else
  fail "F3 NEGATIVE CONTROL: expected exit 0 and no output with the swallow restored, got exit=$CODE_F3NEG out=[$OUT_F3NEG]"
fi

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "env-derive.test.sh: all checks passed"
  exit 0
else
  echo
  echo "env-derive.test.sh: FAILURES ABOVE"
  exit 1
fi
