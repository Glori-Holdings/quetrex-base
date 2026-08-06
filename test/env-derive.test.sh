#!/usr/bin/env bash
# test/env-derive.test.sh — contract test for bin/quetrex-env-derive, the
# single shared tool that discovers requiredEnv/required_env associations
# from a repo's own manifest (see .quetrex/plan/VERIFY-GATE-QUIET.json).
#
# Run: bash test/env-derive.test.sh
#
# THE DEFECT THIS CLOSES. verify-gate.sh's declarative env skip
# (should_skip_for_env) has been fully implemented for a while but is INERT:
# nothing anywhere ever writes `requiredEnv` into .quetrex/verify.json. The
# real-world consequence is the operator's original complaint — a fixture
# repo's `npm run build` needs a database URL that legitimately cannot exist
# in every checkout, the command exits non-zero, and the gate blocks the
# agent with a message that reads as "your healthy build failed". This suite
# proves the derivation that makes the skip fire is correct, conservative,
# and non-vacuous:
#   AC12 — `scan` discovers exactly the intersection of a committed
#          declaration and a fallback-less read; nothing hardcoded, nothing
#          executed.
#   AC13 — `verify-json` merges requiredEnv into a committed verify.json:
#          union-only, names only, idempotent, a reviewable one-line diff.
#   AC14 — attribution is SCOPE-FILTERED by the chain command's own leaf
#          script, not blindly the whole tree — over-attribution is the
#          dangerous direction (a wrongly-skipped command), so this is
#          negative-controlled to prove the filter is load-bearing.
#   AC15 — end to end: a derived, COMMITTED requiredEnv is what actually
#          stops the real-world case from blocking the agent, proven by
#          running the real verify-gate hook — also negative-controlled, so
#          this is proven to be the derivation's doing and not the hook's.
#   AC16 — /quetrex:doctor Check 5 tells an already-adopted repo (a
#          verify.json that predates this feature) how to acquire
#          requiredEnv, and never nags a repo with nothing to declare.
#
# SECURITY POSTURE THIS SUITE HOLDS THE LINE ON. Over-attribution is the
# dangerous direction: a variable wrongly attributed to a command means that
# command is silently SKIPPED whenever the var happens to be unset, which is
# strictly worse than never attributing it (a missing entry just means the
# chain runs normally). Every assertion below that checks an ABSENCE — no
# name for a command outside its scope, 0 leaked values, 0 spawned verify
# commands — is checking the conservative, safe-by-default direction; the
# negative controls exist specifically to prove those absences are not
# vacuous (an empty result is trivially true of a tool that does nothing).

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="$TOOLROOT/bin/quetrex-env-derive"
HOOK="${QX_VERIFY_GATE_HOOK:-$TOOLROOT/.claude/hooks/verify-gate.sh}"
DOCTOR_MD="$TOOLROOT/.claude/commands/doctor.md"

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

line_count() {  # line_count <file> -> 0 if absent
  [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0
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

run_hook() {  # run_hook <cwd> <event>
  local cwd="$1" event="$2" payload
  payload="$(jq -cn --arg cwd "$cwd" --arg event "$event" '{cwd:$cwd,hook_event_name:$event}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$cwd" QUETREX_VERIFY_MAX=3 "$HOOK"
}

# A common package.json + build.sh pair, reused by AC13/AC14/AC15: lint has
# an explicit path arg ("src") so its scope narrows; build has a single-
# token leaf script (no path args at all) so its scope is the whole tracked
# tree. build.sh is a REAL, deterministic script (checks A_URL, no external
# binaries) so AC15 can actually execute the chain, not just resolve it
# statically.
mk_manifest() {  # mk_manifest <dir>
  local d="$1"
  cat > "$d/package.json" <<'EOF'
{
  "scripts": {
    "lint": "true src",
    "build": "./build.sh"
  }
}
EOF
  cat > "$d/build.sh" <<'EOF'
#!/usr/bin/env bash
if [ -z "${A_URL:-}" ]; then exit 1; else exit 0; fi
EOF
  chmod +x "$d/build.sh"
}

# =============================================================================
# AC12 — `scan` discovers exactly the intersection of a committed declaration
# and a fallback-less read; nothing hardcoded, nothing executed.
# =============================================================================
F12="$TMPROOT/ac12"
git_init_repo "$F12"
mkdir -p "$F12/src" "$F12/.quetrex"
cat > "$F12/.env.example" <<'EOF'
A_URL=
B_URL=
C_URL=
EOF
cat > "$F12/src/db.js" <<'EOF'
// db client module
// A_URL has no fallback — line 3 is the read the scan must find
const url = process.env.A_URL;
const other = process.env.B_URL ?? "default-b";
module.exports = { url, other };
EOF
cat > "$F12/src/other.js" <<'EOF'
// other module
// padding line 2
// padding line 3
// padding line 4
// padding line 5
// padding line 6
const dUrl = process.env.D_URL;
module.exports = { dUrl };
EOF
SENTINEL12="$F12/.quetrex/sentinel"
jq -cn --arg cmd "touch \"$SENTINEL12\"" '{verify: [$cmd]}' > "$F12/.quetrex/verify.json"
git -C "$F12" add .env.example src/db.js src/other.js .quetrex/verify.json
git -C "$F12" commit -q -m "chore: AC12 fixture"

OUT12="$("$TOOL" scan "$F12")"; CODE12=$?

if [ "$CODE12" -eq 0 ]; then
  pass "AC12: exit code 0"
else
  fail "AC12: expected exit 0, got $CODE12"
fi

LINES12="$(printf '%s\n' "$OUT12" | grep -c .)"
if [ "$LINES12" = "1" ]; then
  pass "AC12: stdout is exactly 1 line"
else
  fail "AC12: expected exactly 1 stdout line, got $LINES12 (out: [$OUT12])"
fi

F1_NAME="$(printf '%s' "$OUT12" | cut -f1)"
F1_READAT="$(printf '%s' "$OUT12" | cut -f2)"
if [ "$F1_NAME" = "A_URL" ]; then
  pass "AC12: field 1 is A_URL"
else
  fail "AC12: expected field 1 == A_URL, got '$F1_NAME'"
fi
if printf '%s' "$F1_READAT" | grep -qE '^src/db\.js:3$'; then
  pass "AC12: field 2 matches ^src/db\\.js:3\$"
else
  fail "AC12: expected field 2 == src/db.js:3, got '$F1_READAT'"
fi

for excluded in B_URL C_URL D_URL; do
  n="$(printf '%s\n' "$OUT12" | grep -c "$excluded")"
  if [ "$n" = "0" ]; then
    pass "AC12: $excluded does not appear in stdout"
  else
    fail "AC12: $excluded unexpectedly appears in stdout ($n times)"
  fi
done

for fixture_name in A_URL B_URL C_URL D_URL; do
  n="$(grep -c "$fixture_name" "$TOOL")"
  if [ "$n" = "0" ]; then
    pass "AC12: fixture name $fixture_name is not hardcoded in bin/quetrex-env-derive"
  else
    fail "AC12: fixture name $fixture_name appears $n time(s) in bin/quetrex-env-derive — a name must never be baked into the tool"
  fi
done

if [ -f "$SENTINEL12" ]; then
  fail "AC12: scan executed the verify command (sentinel file was created)"
else
  pass "AC12: scan spawned 0 child processes that execute a verify command (sentinel absent)"
fi

# =============================================================================
# AC13 — `verify-json` merges requiredEnv into a committed verify.json:
# union-only, names only, idempotent, a reviewable one-line diff.
# =============================================================================
F13="$TMPROOT/ac13"
git_init_repo "$F13"
mkdir -p "$F13/src" "$F13/.quetrex"
cat > "$F13/.env.example" <<'EOF'
A_URL=postgres://ac13-value-should-never-leak
B_URL=ac13-other-value
EOF
cat > "$F13/src/db.js" <<'EOF'
// db client
// no fallback on this required connection string
const url = process.env.A_URL;
EOF
mk_manifest "$F13"
jq -cn '{verify:["npm run lint -- src","npm run build"],requiredEnv:{"npm run lint -- src":["B_URL"]}}' \
  > "$F13/.quetrex/verify.json"
git -C "$F13" add .env.example src/db.js package.json build.sh .quetrex/verify.json
git -C "$F13" commit -q -m "chore: AC13 fixture"

PRE13="$(cat "$F13/.quetrex/verify.json")"

OUT13="$("$TOOL" verify-json "$F13")"; CODE13=$?
if [ "$CODE13" -eq 0 ]; then
  pass "AC13: verify-json exits 0"
else
  fail "AC13: expected exit 0, got $CODE13 (out: [$OUT13])"
fi

if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$F13/.quetrex/verify.json" 2>/dev/null; then
  pass "AC13: resulting .quetrex/verify.json parses"
else
  fail "AC13: resulting .quetrex/verify.json does not parse as JSON"
fi

printf '%s' "$PRE13" | jq -S '.verify' > "$TMPROOT/ac13-verify-pre.json"
jq -S '.verify' "$F13/.quetrex/verify.json" > "$TMPROOT/ac13-verify-post.json"
if diff -q "$TMPROOT/ac13-verify-pre.json" "$TMPROOT/ac13-verify-post.json" >/dev/null; then
  pass "AC13: .verify is byte-identical (jq -S) before and after"
else
  fail "AC13: .verify changed — verify-json must never touch .verify[]"
fi

BUILD_REQ="$(jq -c '.requiredEnv["npm run build"] // empty' "$F13/.quetrex/verify.json")"
if [ "$BUILD_REQ" = '["A_URL"]' ]; then
  pass 'AC13: requiredEnv["npm run build"] == ["A_URL"]'
else
  fail "AC13: expected requiredEnv[\"npm run build\"] == [\"A_URL\"], got '$BUILD_REQ'"
fi

LINT_REQ="$(jq -c '.requiredEnv["npm run lint -- src"] // empty' "$F13/.quetrex/verify.json")"
if [ "$LINT_REQ" = '["B_URL"]' ]; then
  pass "AC13: pre-existing hand-written entry is present with its original array unchanged"
else
  fail "AC13: hand-written entry changed — expected [\"B_URL\"], got '$LINT_REQ'"
fi

FOREIGN_KEYS="$(jq '(.requiredEnv | keys) - .verify | length' "$F13/.quetrex/verify.json")"
if [ "$FOREIGN_KEYS" = "0" ]; then
  pass "AC13: every requiredEnv key is a byte-for-byte member of .verify[]"
else
  fail "AC13: $FOREIGN_KEYS requiredEnv key(s) are not members of .verify[]"
fi

LEAK="$(grep -c "ac13-value-should-never-leak" "$F13/.quetrex/verify.json")"
if [ "$LEAK" = "0" ]; then
  pass "AC13: the fixture's placeholder VALUE never appears in verify.json"
else
  fail "AC13: the fixture's placeholder value leaked into verify.json ($LEAK occurrence(s))"
fi

git -C "$F13" status --porcelain -- .quetrex/verify.json > "$TMPROOT/ac13-status.txt"
STATUS_LINES="$(grep -c . "$TMPROOT/ac13-status.txt")"
if [ "$STATUS_LINES" = "1" ]; then
  pass "AC13: git status --porcelain reports exactly 1 modified path"
else
  fail "AC13: expected exactly 1 modified path, got $STATUS_LINES ($(cat "$TMPROOT/ac13-status.txt"))"
fi

cp "$F13/.quetrex/verify.json" "$TMPROOT/ac13-after-run1.json"
"$TOOL" verify-json "$F13" >/dev/null
if cmp -s "$TMPROOT/ac13-after-run1.json" "$F13/.quetrex/verify.json"; then
  pass "AC13: a second run produces a byte-identical file"
else
  fail "AC13: a second run changed the file — verify-json must be idempotent"
fi

# =============================================================================
# AC14 — attribution is SCOPE-FILTERED by the chain command's own leaf
# script. Negative control: disabling the scope filter must turn fixture
# (i)'s first assertion red while every other assertion stays green.
# =============================================================================
mk_ac14_fixture() {  # mk_ac14_fixture <dir> <read-relpath> <pad-lines-before-read>
  local d="$1" readfile="$2" pad="$3" i
  git_init_repo "$d"
  mkdir -p "$d/src" "$d/tests" "$d/.quetrex"
  printf 'A_URL=ac14-value\n' > "$d/.env.example"
  mk_manifest "$d"
  {
    i=1
    while [ "$i" -le "$pad" ]; do
      echo "// pad line $i"
      i=$((i + 1))
    done
    echo 'const url = process.env.A_URL;'
  } > "$d/$readfile"
  printf '{"verify":["npm run lint -- src","npm run build"]}\n' > "$d/.quetrex/verify.json"
  git -C "$d" add -A
  git -C "$d" commit -q -m "chore: AC14 fixture ($readfile)"
}

# (i) the only read is OUTSIDE lint's declared scope ("src")
F14i="$TMPROOT/ac14i"
mk_ac14_fixture "$F14i" "tests/only_here.js" 1
"$TOOL" verify-json "$F14i" >/dev/null

LINT14i="$(jq -e '.requiredEnv["npm run lint -- src"] // empty' "$F14i/.quetrex/verify.json" 2>/dev/null)"
if [ -z "$LINT14i" ]; then
  pass "AC14(i): requiredEnv has no entry for the lint command (read is outside its scope)"
else
  fail "AC14(i): expected no lint entry, got '$LINT14i'"
fi
BUILD14i_LEN="$(jq '.requiredEnv["npm run build"] | length' "$F14i/.quetrex/verify.json" 2>/dev/null)"
if [ "$BUILD14i_LEN" = "1" ]; then
  pass "AC14(i): requiredEnv[\"npm run build\"] has length 1 (whole-tree scope)"
else
  fail "AC14(i): expected build entry length 1, got '$BUILD14i_LEN'"
fi

# (ii) the SAME repo shape but the read is INSIDE lint's declared scope
F14ii="$TMPROOT/ac14ii"
mk_ac14_fixture "$F14ii" "src/db.js" 2
"$TOOL" verify-json "$F14ii" >/dev/null
KEYS14ii="$(jq '.requiredEnv | keys | length' "$F14ii/.quetrex/verify.json" 2>/dev/null)"
if [ "$KEYS14ii" = "2" ]; then
  pass "AC14(ii): both commands are attributed when the read is inside lint's scope"
else
  fail "AC14(ii): expected 2 attributed commands, got '$KEYS14ii'"
fi

# NEGATIVE CONTROL — a mutated copy with ONLY the scope filter disabled
# (inScope always returns true) must turn fixture (i)'s first assertion red.
MUT_SCOPE="$TMPROOT/quetrex-env-derive.no-scope-filter"
sed -E 's/^var QX_SCOPE_FILTER_ENABLED = true;$/var QX_SCOPE_FILTER_ENABLED = false;/' "$TOOL" > "$MUT_SCOPE"
chmod +x "$MUT_SCOPE"
MUT_SCOPE_DIFF_LINES="$(diff "$TOOL" "$MUT_SCOPE" | grep -c '^[<>]')"
if [ "$MUT_SCOPE_DIFF_LINES" = "2" ]; then
  pass "AC14: the scope-filter mutation changes exactly one line in the tool"
else
  fail "AC14: expected the scope-filter mutation to touch exactly 1 line (2 diff lines), got $MUT_SCOPE_DIFF_LINES"
fi

F14neg="$TMPROOT/ac14neg"
mk_ac14_fixture "$F14neg" "tests/only_here.js" 1
"$MUT_SCOPE" verify-json "$F14neg" >/dev/null
LINT14neg="$(jq -e '.requiredEnv["npm run lint -- src"] // empty' "$F14neg/.quetrex/verify.json" 2>/dev/null)"
if [ -n "$LINT14neg" ]; then
  pass "AC14 NEGATIVE CONTROL: disabling the scope filter wrongly attributes the out-of-scope read to lint ($LINT14neg) — proves the filter is load-bearing"
else
  fail "AC14 NEGATIVE CONTROL: expected the mutated tool to (wrongly) attribute the read to lint, but it did not — the mutation did not disable the filter"
fi

# =============================================================================
# AC15 — end to end: a derived, COMMITTED requiredEnv is what actually stops
# the real-world case from blocking the agent. Proven against the REAL
# verify-gate hook, in a MAIN checkout with zero linked worktrees. Negative
# control: disabling the requiredEnv WRITE must turn this into a block.
# =============================================================================
mk_ac15_base() {  # mk_ac15_base <dir> -> commits everything except the derived requiredEnv
  local d="$1"
  git_init_repo "$d"
  mkdir -p "$d/src" "$d/.quetrex"
  cat > "$d/.env.example" <<'EOF'
A_URL=postgres://ac15-value-should-never-leak
B_URL=ac15-other-value
EOF
  cat > "$d/src/db.js" <<'EOF'
// db client
// no fallback on this required connection string
const url = process.env.A_URL;
EOF
  mk_manifest "$d"
  jq -cn '{verify:["npm run lint -- src","npm run build"],requiredEnv:{"npm run lint -- src":["B_URL"]}}' \
    > "$d/.quetrex/verify.json"
  # B_URL is genuinely present via .env.local (untracked, dotenv-loaded at
  # runtime) so lint's own PRE-EXISTING requiredEnv entry never fires — this
  # test is about the DERIVED entry for build, not the hand-written one.
  printf 'B_URL=locally-present\n' > "$d/.env.local"
  git -C "$d" add .env.example src/db.js package.json build.sh .quetrex/verify.json
  git -C "$d" commit -q -m "chore: AC15 base fixture"
}

if ! command -v npm >/dev/null 2>&1; then
  echo "SKIP: AC15 requires npm on PATH (the chain commands are npm scripts) — skipping AC15 only"
else
  # --- positive: the REAL tool derives and commits requiredEnv -------------
  F15="$TMPROOT/ac15"
  mk_ac15_base "$F15"
  "$TOOL" verify-json "$F15" >/dev/null
  git -C "$F15" add .quetrex/verify.json
  git -C "$F15" commit -q -m "chore: derive requiredEnv"
  mkdir -p "$F15/.quetrex"
  touch "$F15/.quetrex/ESCALATION"

  unset A_URL
  OUT15="$(run_hook "$F15" "Stop" 2>&1)"; CODE15=$?

  if [ "$CODE15" -eq 0 ]; then
    pass "AC15: hook exit code == 0"
  else
    fail "AC15: expected exit 0, got $CODE15 (out: [$OUT15])"
  fi

  BLOCKS15="$(count_block_decisions "$OUT15")"
  if [ "$BLOCKS15" = "0" ]; then
    pass "AC15: 0 stdout lines parse as a block decision"
  else
    fail "AC15: expected 0 block decisions, got $BLOCKS15 (out: [$OUT15])"
  fi

  SKIPS15="$(count_skip_lines "$OUT15")"
  SKIP_LINE15="$(printf '%s\n' "$OUT15" | grep '^VERIFY SKIPPED' | head -n1)"
  if [ "$SKIPS15" = "1" ] && printf '%s' "$SKIP_LINE15" | grep -q 'A_URL'; then
    pass "AC15: exactly 1 VERIFY SKIPPED line naming A_URL"
  else
    fail "AC15: expected exactly 1 VERIFY SKIPPED line naming A_URL, got $SKIPS15 (out: [$OUT15])"
  fi

  if printf '%s' "$SKIP_LINE15" | grep -q "ac15-value-should-never-leak"; then
    fail "AC15: the skip line leaked A_URL's value"
  else
    pass "AC15: the skip line contains 0 occurrences of A_URL's value"
  fi

  LEDGER15="$F15/.quetrex/verify-ledger.jsonl"
  BUILD_LINES15=0
  LINT_OK15=0
  if [ -f "$LEDGER15" ]; then
    while IFS= read -r l; do
      [ -z "$l" ] && continue
      cm="$(printf '%s' "$l" | jq -r '.cmd')"
      ex="$(printf '%s' "$l" | jq -r '.exit')"
      if [ "$cm" = "npm run build" ]; then BUILD_LINES15=$((BUILD_LINES15 + 1)); fi
      if [ "$cm" = "npm run lint -- src" ] && [ "$ex" = "0" ]; then LINT_OK15=1; fi
    done < "$LEDGER15"
  fi
  if [ "$BUILD_LINES15" = "0" ]; then
    pass "AC15: the ledger has 0 lines for the skipped build command"
  else
    fail "AC15: expected 0 ledger lines for npm run build, got $BUILD_LINES15"
  fi
  if [ "$LINT_OK15" = "1" ]; then
    pass "AC15: the ledger has exactly 1 line for the lint command with exit 0 (it genuinely ran)"
  else
    fail "AC15: expected a green ledger line for the lint command"
  fi

  if [ -f "$F15/.quetrex/ESCALATION" ]; then
    pass "AC15: a pre-seeded .quetrex/ESCALATION still exists after the run"
  else
    fail "AC15: .quetrex/ESCALATION was incorrectly cleared by a run that skipped a command"
  fi

  # --- NEGATIVE CONTROL: only the requiredEnv WRITE disabled ---------------
  MUT_WRITE="$TMPROOT/quetrex-env-derive.no-required-env-write"
  sed -E 's/^var QX_REQUIRED_ENV_WRITE_ENABLED = true;$/var QX_REQUIRED_ENV_WRITE_ENABLED = false;/' "$TOOL" > "$MUT_WRITE"
  chmod +x "$MUT_WRITE"
  MUT_WRITE_DIFF_LINES="$(diff "$TOOL" "$MUT_WRITE" | grep -c '^[<>]')"
  if [ "$MUT_WRITE_DIFF_LINES" = "2" ]; then
    pass "AC15: the requiredEnv-write mutation changes exactly one line in the tool"
  else
    fail "AC15: expected the requiredEnv-write mutation to touch exactly 1 line (2 diff lines), got $MUT_WRITE_DIFF_LINES"
  fi

  F15neg="$TMPROOT/ac15neg"
  mk_ac15_base "$F15neg"
  "$MUT_WRITE" verify-json "$F15neg" >/dev/null
  git -C "$F15neg" add .quetrex/verify.json
  git -C "$F15neg" commit -q -m "chore: derive requiredEnv (mutated writer — should add nothing new)"
  BUILD_REQ_NEG="$(jq -c '.requiredEnv["npm run build"] // empty' "$F15neg/.quetrex/verify.json")"
  if [ -z "$BUILD_REQ_NEG" ]; then
    pass "AC15 NEGATIVE CONTROL setup: the mutated writer emitted no requiredEnv entry for build"
  else
    fail "AC15 NEGATIVE CONTROL setup: expected no build entry from the mutated writer, got '$BUILD_REQ_NEG'"
  fi

  unset A_URL
  OUT15N="$(run_hook "$F15neg" "Stop" 2>&1)"; CODE15N=$?
  BLOCKS15N="$(count_block_decisions "$OUT15N")"
  SKIPS15N="$(count_skip_lines "$OUT15N")"
  if [ "$CODE15N" -eq 0 ] && [ "$BLOCKS15N" = "1" ]; then
    pass "AC15 NEGATIVE CONTROL: without the derived requiredEnv, build genuinely runs and blocks (1 block decision)"
  else
    fail "AC15 NEGATIVE CONTROL: expected exit 0 + 1 block decision, got exit $CODE15N blocks $BLOCKS15N (out: [$OUT15N])"
  fi
  if [ "$SKIPS15N" = "0" ]; then
    pass "AC15 NEGATIVE CONTROL: 0 VERIFY SKIPPED lines — the derivation, not the hook, is what made the positive case skip"
  else
    fail "AC15 NEGATIVE CONTROL: expected 0 skip lines, got $SKIPS15N (out: [$OUT15N])"
  fi
fi

# =============================================================================
# AC16 — /quetrex:doctor Check 5 tells an already-adopted repo (a verify.json
# that predates this feature) how to acquire requiredEnv, and never nags a
# repo with nothing to declare.
# =============================================================================
extract_check5() {
  awk '
    /^## Check 5/ { insec = 1; next }
    insec && /^## / { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$DOCTOR_MD"
}
CHECK5_SCRIPT="$(extract_check5)"

if [ -z "$CHECK5_SCRIPT" ]; then
  fail "AC16: could not extract a Check 5 bash fence from $DOCTOR_MD"
else
  pass "AC16: extracted the Check 5 bash fence from doctor.md"

  run_check5() {  # run_check5 <fixture-repo-root>
    ( export REPO_ROOT="$1"; export PATH="$TOOLROOT/bin:$PATH"; bash -c "$CHECK5_SCRIPT" )
  }

  # --- (a) a repo whose verify.json predates requiredEnv, but has something
  # to derive (a committed .env.example naming a var in a chain command's
  # scope) -----------------------------------------------------------------
  F16="$TMPROOT/ac16"
  git_init_repo "$F16"
  mkdir -p "$F16/src" "$F16/.quetrex"
  printf 'E_URL=ac16-value\n' > "$F16/.env.example"
  cat > "$F16/package.json" <<'EOF'
{ "scripts": { "build": "tsc" } }
EOF
  cat > "$F16/src/app.js" <<'EOF'
const url = process.env.E_URL;
EOF
  printf '{"verify":["npm run build"]}\n' > "$F16/.quetrex/verify.json"
  git -C "$F16" add -A
  git -C "$F16" commit -q -m "chore: AC16 fixture (predates requiredEnv)"

  BEFORE16="$(run_check5 "$F16" 2>&1)"; BEFORE16_CODE=$?
  BEFORE16_MATCH="$(printf '%s\n' "$BEFORE16" | grep -c -e 'requiredEnv' | grep -c .)"
  BEFORE16_BOTH="$(printf '%s\n' "$BEFORE16" | grep -c 'requiredEnv.*quetrex:init\|quetrex:init.*requiredEnv')"
  if [ "$BEFORE16_CODE" -eq 0 ]; then
    pass "AC16(before): doctor's exit code is unchanged (0) — this is a report, never a blocker"
  else
    fail "AC16(before): expected exit 0, got $BEFORE16_CODE"
  fi
  if [ "$BEFORE16_BOTH" = "1" ]; then
    pass "AC16(before): exactly 1 line contains both 'requiredEnv' and '/quetrex:init'"
  else
    fail "AC16(before): expected exactly 1 such line, got $BEFORE16_BOTH (out: [$BEFORE16])"
  fi
  GREEN16_BEFORE="$(printf '%s\n' "$BEFORE16" | grep -c '✓ Verify chain configured')"
  if [ "$GREEN16_BEFORE" = "1" ]; then
    pass "AC16(before): the '✓ Verify chain configured' line still prints exactly once"
  else
    fail "AC16(before): expected the green line exactly once, got $GREEN16_BEFORE"
  fi

  "$TOOL" verify-json "$F16" >/dev/null

  AFTER16="$(run_check5 "$F16" 2>&1)"
  AFTER16_BOTH="$(printf '%s\n' "$AFTER16" | grep -c 'requiredEnv.*quetrex:init\|quetrex:init.*requiredEnv')"
  if [ "$AFTER16_BOTH" = "0" ]; then
    pass "AC16(after): the requiredEnv-missing line is absent once verify-json has run"
  else
    fail "AC16(after): expected 0 such lines, got $AFTER16_BOTH (out: [$AFTER16])"
  fi
  GREEN16_AFTER="$(printf '%s\n' "$AFTER16" | grep -c '✓ Verify chain configured')"
  if [ "$GREEN16_AFTER" = "1" ]; then
    pass "AC16(after): the '✓ Verify chain configured' line still prints exactly once"
  else
    fail "AC16(after): expected the green line exactly once, got $GREEN16_AFTER"
  fi

  # --- (b) a repo with NO committed .env.example — never nagged, in either
  # state ---------------------------------------------------------------
  F16b="$TMPROOT/ac16b"
  git_init_repo "$F16b"
  mkdir -p "$F16b/.quetrex"
  printf '{"verify":["true"]}\n' > "$F16b/.quetrex/verify.json"
  git -C "$F16b" add .quetrex/verify.json
  git -C "$F16b" commit -q -m "chore: AC16b fixture (no .env.example)"

  NOENV_BEFORE="$(run_check5 "$F16b" 2>&1)"
  NOENV_BEFORE_BOTH="$(printf '%s\n' "$NOENV_BEFORE" | grep -c 'requiredEnv.*quetrex:init\|quetrex:init.*requiredEnv')"
  "$TOOL" verify-json "$F16b" >/dev/null
  NOENV_AFTER="$(run_check5 "$F16b" 2>&1)"
  NOENV_AFTER_BOTH="$(printf '%s\n' "$NOENV_AFTER" | grep -c 'requiredEnv.*quetrex:init\|quetrex:init.*requiredEnv')"
  if [ "$NOENV_BEFORE_BOTH" = "0" ] && [ "$NOENV_AFTER_BOTH" = "0" ]; then
    pass "AC16(no .env.example): the line is absent in both states (2 of 2)"
  else
    fail "AC16(no .env.example): expected 0/0, got before=$NOENV_BEFORE_BOTH after=$NOENV_AFTER_BOTH"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "env-derive.test.sh: all checks passed"
  exit 0
else
  echo "env-derive.test.sh: FAILURES above"
  exit 1
fi
