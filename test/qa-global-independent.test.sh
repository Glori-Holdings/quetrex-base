#!/usr/bin/env bash
# test/qa-global-independent.test.sh — QA's own independent adversarial
# coverage for task GLOBAL (the quetrex-setup plugin split,
# .quetrex/plan/GLOBAL.json). Written by QA, in a fresh pass over the shipped
# artifacts, NOT by reusing or re-deriving the developer workstreams' own
# test files (test/quetrex-arm.test.sh, test/plugin-one-copy.test.sh,
# test/doctor-checks.test.sh, test/legacy-command-repoint.test.sh, ...) —
# this file re-implements each check from scratch against the real shipped
# scripts/markdown so a bug shared between "the code" and "the developer's
# test for the code" cannot hide from both.
#
# Sections (see the QA task brief this responds to):
#   (a) INSTALL SMOKE  — the installed-cache layout actually resolves.
#   (b) unarmed-offer  — exactly one line unarmed, silent armed/non-git.
#   (c) session-state  — the `quetrex` plugin's armed-only half stays silent
#                         in an unarmed repo and still restores in an armed one.
#   (d) quetrex-arm    — PROJECT-scope enabledPlugins across 5 stack
#                         fixtures + a plain repo, driven through the real
#                         stack-pack detection fence in init.md; never
#                         touches user-scope; never writes a version pin.
#   (e) doctor Check 10 — flags a stray quetrex/quetrex-factory pin at user
#                         scope, passes clean with only quetrex-setup.
#   (f) one-copy        — every command/hook/lib/bin/script basename tracked
#                         exactly once, PLUS a live, mechanical break-test:
#                         plant a duplicate in a synthetic repo and prove the
#                         walk catches it (the developer's own
#                         plugin-one-copy.test.sh only asserts this in prose).
#   (g) legacy-string sweep — an independent re-implementation of AC20's
#                         grep, with QA's own allow-list, so a shared bug in
#                         the developer's allow-list cannot mask a real hit.
#
# Run: bash test/qa-global-independent.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-global-independent.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

SETUP_ROOT="$ROOT/plugins/quetrex-setup"

# =============================================================================
# (a) INSTALL SMOKE — simulate ~/.claude/plugins/cache/quetrex/quetrex-setup/1.0.0/
# =============================================================================
echo "# (a) install smoke"
CACHE_ROOT="$WORK/cache/quetrex/quetrex-setup/1.0.0"
mkdir -p "$(dirname "$CACHE_ROOT")"
cp -R "$SETUP_ROOT" "$CACHE_ROOT"

for tool in quetrex-api quetrex-arm quetrex-version quetrex-env-derive quetrex-cleanup; do
  if [ -x "$CACHE_ROOT/bin/$tool" ]; then
    pass "install smoke: $tool ships executable in the installed cache's bin/"
  else
    fail "install smoke: $tool missing or not executable at $CACHE_ROOT/bin/$tool"
  fi
done

RESOLVE_OUT="$WORK/resolve.out"
: > "$RESOLVE_OUT"
(
  PATH="$CACHE_ROOT/bin:$PATH"; export PATH
  for tool in quetrex-api quetrex-arm quetrex-version quetrex-env-derive quetrex-cleanup; do
    RESOLVED="$(command -v "$tool" 2>/dev/null || true)"
    if [ "$RESOLVED" = "$CACHE_ROOT/bin/$tool" ]; then
      echo "ok - install smoke: $tool resolves BY NAME to the installed cache bin/ (PATH resolution, not a hardcoded path)"
    else
      echo "NOT OK - install smoke: $tool did not resolve to the installed cache bin/ via PATH (got: [$RESOLVED])"
    fi
  done
) >> "$RESOLVE_OUT" 2>&1
cat "$RESOLVE_OUT"
grep -q '^NOT OK' "$RESOLVE_OUT" && FAIL=1

# The two SessionStart hooks + unarmed-offer must run clean from the cache
# root with CLAUDE_PLUGIN_ROOT set to it (no "not found", no raw error), on a
# realistic unarmed-repo stdin payload.
UNARMED_FIXTURE="$WORK/unarmed-fixture"
mkdir -p "$UNARMED_FIXTURE" && git -C "$UNARMED_FIXTURE" init -q

for script in unarmed-offer.sh quetrex-update-check.sh quetrex-bound-version-guard.sh; do
  OUT_FILE="$WORK/${script}.out"
  ERR_FILE="$WORK/${script}.err"
  (
    CLAUDE_PLUGIN_ROOT="$CACHE_ROOT"; export CLAUDE_PLUGIN_ROOT
    env -u CLAUDE_PROJECT_DIR bash "$CACHE_ROOT/scripts/$script" \
      <<< "{\"source\":\"startup\",\"cwd\":\"$UNARMED_FIXTURE\"}" \
      > "$OUT_FILE" 2> "$ERR_FILE"
  )
  RC=$?
  if [ "$RC" -eq 0 ] && ! grep -qiE 'not found|no such file|command not found' "$ERR_FILE"; then
    pass "install smoke: scripts/$script runs clean from the installed cache root (exit 0, no raw error on stderr)"
  else
    fail "install smoke: scripts/$script failed from the installed cache root (exit=$RC stderr=[$(cat "$ERR_FILE")])"
  fi
done

# Every bare quetrex-* tool name referenced in the shipped commands must
# exist in THIS PLUGIN's own bin/ — never assume a sibling checkout's bin/.
for cmdfile in "$CACHE_ROOT"/commands/*.md; do
  base="$(basename "$cmdfile")"
  for tool in $(grep -oE '\bquetrex-(api|arm|cleanup|env-derive|version)\b' "$cmdfile" | sort -u); do
    if [ -x "$CACHE_ROOT/bin/$tool" ]; then
      pass "install smoke: $base references $tool, which ships in this plugin's own bin/"
    else
      fail "install smoke: $base references $tool, which is MISSING from this plugin's own bin/"
    fi
  done
done

# =============================================================================
# (b) unarmed-offer.sh — exactly one line unarmed, 0 bytes armed/non-git,
# never on stderr, across all three SessionStart sources.
# =============================================================================
echo "# (b) unarmed-offer.sh"
EXPECT_LINE="Quetrex: this repo is not armed (no .quetrex/project.json). Offer the user /quetrex-setup:init; if they say yes, run it."

B_UNARMED="$WORK/b-unarmed"; mkdir -p "$B_UNARMED"; git -C "$B_UNARMED" init -q
B_ARMED="$WORK/b-armed"; mkdir -p "$B_ARMED/.quetrex"; git -C "$B_ARMED" init -q
echo '{"code":"QUE"}' > "$B_ARMED/.quetrex/project.json"
B_NOTGIT="$WORK/b-notgit"; mkdir -p "$B_NOTGIT"

for src in startup resume compact; do
  OUT_FILE="$WORK/b-unarmed-$src.out"; ERR_FILE="$WORK/b-unarmed-$src.err"
  env -u CLAUDE_PROJECT_DIR bash "$SETUP_ROOT/scripts/unarmed-offer.sh" \
    <<< "{\"source\":\"$src\",\"cwd\":\"$B_UNARMED\"}" > "$OUT_FILE" 2> "$ERR_FILE"
  RC=$?
  LINES="$(wc -l < "$OUT_FILE" | tr -d ' ')"
  if [ "$RC" -eq 0 ] && [ "$LINES" -eq 1 ] && diff -q <(printf '%s\n' "$EXPECT_LINE") "$OUT_FILE" >/dev/null 2>&1 && [ ! -s "$ERR_FILE" ]; then
    pass "unarmed-offer/$src: unarmed repo prints byte-identical single line on stdout, nothing on stderr, exit 0"
  else
    fail "unarmed-offer/$src: unarmed repo did not print exactly the expected single line (rc=$RC lines=$LINES stdout=[$(cat "$OUT_FILE")] stderr=[$(cat "$ERR_FILE")])"
  fi

  OUT_FILE2="$WORK/b-armed-$src.out"; ERR_FILE2="$WORK/b-armed-$src.err"
  env -u CLAUDE_PROJECT_DIR bash "$SETUP_ROOT/scripts/unarmed-offer.sh" \
    <<< "{\"source\":\"$src\",\"cwd\":\"$B_ARMED\"}" > "$OUT_FILE2" 2> "$ERR_FILE2"
  RC2=$?
  BYTES2="$(wc -c < "$OUT_FILE2" | tr -d ' ')"
  if [ "$RC2" -eq 0 ] && [ "$BYTES2" -eq 0 ] && [ ! -s "$ERR_FILE2" ]; then
    pass "unarmed-offer/$src: armed repo produces 0 bytes on stdout, nothing on stderr, exit 0"
  else
    fail "unarmed-offer/$src: armed repo was not silent (rc=$RC2 bytes=$BYTES2 stderr=[$(cat "$ERR_FILE2")])"
  fi

  OUT_FILE3="$WORK/b-notgit-$src.out"; ERR_FILE3="$WORK/b-notgit-$src.err"
  env -u CLAUDE_PROJECT_DIR bash "$SETUP_ROOT/scripts/unarmed-offer.sh" \
    <<< "{\"source\":\"$src\",\"cwd\":\"$B_NOTGIT\"}" > "$OUT_FILE3" 2> "$ERR_FILE3"
  RC3=$?
  BYTES3="$(wc -c < "$OUT_FILE3" | tr -d ' ')"
  if [ "$RC3" -eq 0 ] && [ "$BYTES3" -eq 0 ] && [ ! -s "$ERR_FILE3" ]; then
    pass "unarmed-offer/$src: non-git directory produces 0 bytes on stdout, nothing on stderr, exit 0"
  else
    fail "unarmed-offer/$src: non-git directory was not silent (rc=$RC3 bytes=$BYTES3 stderr=[$(cat "$ERR_FILE3")])"
  fi
done

# =============================================================================
# (c) .claude/hooks/session-state.sh (the `quetrex` plugin's ARMED-only half)
# =============================================================================
echo "# (c) session-state.sh (quetrex plugin, armed-only half)"
SS_SCRIPT="$ROOT/.claude/hooks/session-state.sh"

C_UNARMED="$WORK/c-unarmed"; mkdir -p "$C_UNARMED"; git -C "$C_UNARMED" init -q
OUT_FILE="$WORK/c-unarmed.out"
env -u CLAUDE_PROJECT_DIR bash "$SS_SCRIPT" <<< "{\"source\":\"startup\",\"cwd\":\"$C_UNARMED\"}" > "$OUT_FILE" 2>/dev/null
RC=$?
BYTES="$(wc -c < "$OUT_FILE" | tr -d ' ')"
if [ "$RC" -eq 0 ] && [ "$BYTES" -eq 0 ]; then
  pass "session-state.sh: unarmed repo -> 0 bytes, exit 0 (the armed half stays silent — unarmed-offer.sh owns that repo now)"
else
  fail "session-state.sh: unarmed repo was not silent (rc=$RC bytes=$BYTES out=[$(cat "$OUT_FILE")])"
fi

C_ARMED="$WORK/c-armed"; mkdir -p "$C_ARMED/.quetrex"; git -C "$C_ARMED" init -q
echo '{"code":"QUE"}' > "$C_ARMED/.quetrex/project.json"
OUT_FILE2="$WORK/c-armed.out"
env -u CLAUDE_PROJECT_DIR bash "$SS_SCRIPT" <<< "{\"source\":\"startup\",\"cwd\":\"$C_ARMED\"}" > "$OUT_FILE2" 2>/dev/null
if grep -qF '[quetrex-state]' "$OUT_FILE2"; then
  pass "session-state.sh: armed repo still restores state (stdout contains '[quetrex-state]')"
else
  fail "session-state.sh: armed repo did not restore state (out=[$(cat "$OUT_FILE2")])"
fi

# armed + ESCALATION marker -> the escalation line must PRECEDE any
# task/plan restoration line.
mkdir -p "$C_ARMED/.quetrex/plan"
cat > "$C_ARMED/.quetrex/plan/QUE-1.json" <<'JSON'
{"task": "QUE-1", "route": "STANDARD"}
JSON
cat > "$C_ARMED/.quetrex/state.json" <<'JSON'
{"task": "QUE-1", "stage": "developer"}
JSON
touch "$C_ARMED/.quetrex/ESCALATION"
OUT_FILE3="$WORK/c-armed-escalation.out"
env -u CLAUDE_PROJECT_DIR bash "$SS_SCRIPT" <<< "{\"source\":\"startup\",\"cwd\":\"$C_ARMED\"}" > "$OUT_FILE3" 2>/dev/null
ESC_LINE="$(grep -n 'ESCALATION IS ACTIVE' "$OUT_FILE3" | head -1 | cut -d: -f1)"
TASK_LINE="$(grep -n 'QUE-1' "$OUT_FILE3" | head -1 | cut -d: -f1)"
if grep -qF 'ESCALATION IS ACTIVE' "$OUT_FILE3" && [ -n "$ESC_LINE" ] && [ -n "$TASK_LINE" ] && [ "$ESC_LINE" -lt "$TASK_LINE" ]; then
  pass "session-state.sh: ESCALATION IS ACTIVE line (line $ESC_LINE) precedes the task/plan line (line $TASK_LINE)"
else
  fail "session-state.sh: ESCALATION ordering not proven (esc_line=$ESC_LINE task_line=$TASK_LINE out=[$(cat "$OUT_FILE3")])"
fi

# =============================================================================
# (d) quetrex-arm — PROJECT-scope enabledPlugins across 5 stack fixtures +
# a plain repo, driven through the REAL detection fence in init.md.
# =============================================================================
echo "# (d) quetrex-arm across stack fixtures"
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — quetrex-arm and the stack-pack detector both need node"
else
  INIT_MD="$SETUP_ROOT/commands/init.md"
  extract_section() {  # extract_section <heading-regex-literal>
    local heading="$1"
    awk -v heading="$heading" '
      index($0, heading) == 1 { insec = 1; next }
      insec && /^## / { exit }
      insec && /^```bash/ { infence = 1; next }
      insec && /^```/ { infence = 0; next }
      insec && infence { print }
    ' "$INIT_MD"
  }
  STACK_SCRIPT="$(extract_section '## 4h. Detect a stack pack')"
  if [ -z "$STACK_SCRIPT" ]; then
    fail "quetrex-arm: could not extract the stack-pack detection bash fence from init.md step 4h — detection logic has moved or been removed"
  else
    pass "quetrex-arm: extracted the stack-pack detection bash fence from init.md step 4h"
  fi

  detect_stack() {  # detect_stack <repo-root> -> prints STACK_PACK (may be empty)
    ( REPO_ROOT="$1"; export REPO_ROOT; eval "$STACK_SCRIPT" >/dev/null 2>&1; printf '%s' "$STACK_PACK" )
  }

  MARKET="$WORK/marketplace.json"
  cat > "$MARKET" <<'JSON'
{ "name": "quetrex", "plugins": [ { "name": "quetrex", "version": "2.6.0" }, { "name": "quetrex-factory", "version": "1.0.0" } ] }
JSON

  mk_fixture() {  # mk_fixture <name>
    local d="$WORK/d-$1"
    mkdir -p "$d"
    printf '%s' "$d"
  }

  # 1. Next.js: package.json with a `next` dependency.
  NEXT_DIR="$(mk_fixture nextjs)"
  cat > "$NEXT_DIR/package.json" <<'JSON'
{ "name": "app", "dependencies": { "next": "15.0.0", "react": "19.0.0" } }
JSON

  # 2. Python via pyproject.toml
  PY1_DIR="$(mk_fixture python-pyproject)"
  echo '[project]' > "$PY1_DIR/pyproject.toml"

  # 3. Python via requirements.txt
  PY2_DIR="$(mk_fixture python-requirements)"
  echo 'flask==3.0.0' > "$PY2_DIR/requirements.txt"

  # 4. Rust
  RUST_DIR="$(mk_fixture rust)"
  echo '[package]' > "$RUST_DIR/Cargo.toml"

  # 5. Swift
  SWIFT_DIR="$(mk_fixture swift)"
  echo '// swift-tools-version:5.9' > "$SWIFT_DIR/Package.swift"

  # 6. Plain repo — no stack evidence at all.
  PLAIN_DIR="$(mk_fixture plain)"
  echo 'just a readme' > "$PLAIN_DIR/README.md"

  declare -a FIXTURES=(
    "$NEXT_DIR|quetrex-nextjs"
    "$PY1_DIR|quetrex-python"
    "$PY2_DIR|quetrex-python"
    "$RUST_DIR|quetrex-rust"
    "$SWIFT_DIR|quetrex-swift"
    "$PLAIN_DIR|"
  )

  FAKE_HOME="$WORK/d-fake-home"
  mkdir -p "$FAKE_HOME/.claude"
  cat > "$FAKE_HOME/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "some-unrelated-plugin@marketplace": true } }
JSON
  HOME_BEFORE_SHA="$(shasum "$FAKE_HOME/.claude/settings.json" | cut -d' ' -f1)"

  for pair in "${FIXTURES[@]}"; do
    dir="${pair%%|*}"
    expect_pack="${pair##*|}"
    label="$(basename "$dir")"

    got_pack="$(detect_stack "$dir")"
    if [ "$got_pack" = "$expect_pack" ]; then
      pass "quetrex-arm/$label: init.md step 4h detects stack pack '$expect_pack' (empty means none)"
    else
      fail "quetrex-arm/$label: expected detected pack '$expect_pack', got '$got_pack'"
    fi

    ARM_OUT="$WORK/d-$label.arm.out"
    (
      HOME="$FAKE_HOME"; export HOME
      QX_ARM_MARKET_URL="file://$MARKET"; export QX_ARM_MARKET_URL
      QX_ARM_STATUSLINE_SRC="$SETUP_ROOT/statusline-command.sh"; export QX_ARM_STATUSLINE_SRC
      if [ -n "$got_pack" ]; then
        "$SETUP_ROOT/bin/quetrex-arm" "$dir" "https://kanban.example.test" "$got_pack" > "$ARM_OUT" 2>&1
      else
        "$SETUP_ROOT/bin/quetrex-arm" "$dir" "https://kanban.example.test" > "$ARM_OUT" 2>&1
      fi
    )
    ARM_RC=$?
    SETTINGS="$dir/.claude/settings.json"
    if [ "$ARM_RC" -ne 0 ] || [ ! -f "$SETTINGS" ]; then
      fail "quetrex-arm/$label: quetrex-arm failed or wrote no settings.json (rc=$ARM_RC out=[$(cat "$ARM_OUT")])"
      continue
    fi

    node -e '
      const fs = require("fs");
      const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const ep = s.enabledPlugins || {};
      const need = ["quetrex@quetrex", "quetrex-factory@quetrex", "quetrex-setup@quetrex"];
      const pack = process.argv[2];
      if (pack) need.push(pack + "@quetrex");
      let bad = [];
      for (const k of need) {
        if (ep[k] !== true) bad.push(k + "=" + JSON.stringify(ep[k]));
      }
      // no key matching the quetrex family may be a non-boolean (array/string) pin
      for (const [k, v] of Object.entries(ep)) {
        if (/^quetrex(-[a-z]+)?@quetrex$/.test(k) && typeof v !== "boolean") {
          bad.push("PIN:" + k + "=" + JSON.stringify(v));
        }
      }
      if (bad.length) { console.error(bad.join(",")); process.exit(1); }
      process.exit(0);
    ' "$SETTINGS" "$expect_pack" 2>"$WORK/d-$label.node.err"
    if [ $? -eq 0 ]; then
      pass "quetrex-arm/$label: PROJECT settings.json carries quetrex+quetrex-factory+quetrex-setup${expect_pack:+ + $expect_pack}, all boolean true, no version pin"
    else
      fail "quetrex-arm/$label: PROJECT settings.json is wrong ($(cat "$WORK/d-$label.node.err"))"
    fi
  done

  HOME_AFTER_SHA="$(shasum "$FAKE_HOME/.claude/settings.json" | cut -d' ' -f1)"
  if [ "$HOME_BEFORE_SHA" = "$HOME_AFTER_SHA" ]; then
    pass "quetrex-arm: user-scope \$HOME/.claude/settings.json is byte-identical after arming 6 different project fixtures (never touched)"
  else
    fail "quetrex-arm: user-scope \$HOME/.claude/settings.json CHANGED after arming a project (before=$HOME_BEFORE_SHA after=$HOME_AFTER_SHA)"
  fi
fi

# =============================================================================
# (e) doctor Check 10 — user-scope plugin hygiene.
# =============================================================================
echo "# (e) doctor Check 10"
DOCTOR_MD="$ROOT/.claude/commands/doctor.md"
extract_doctor_section() {
  local heading="$1"
  awk -v heading="$heading" '
    index($0, heading) == 1 { insec = 1; next }
    insec && /^## / { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$DOCTOR_MD"
}
CHECK10_SCRIPT="$(extract_doctor_section '## Check 10')"
if [ -z "$CHECK10_SCRIPT" ]; then
  fail "doctor Check 10: could not extract a bash fence for '## Check 10' from doctor.md — no user-scope plugin hygiene check shipped"
elif ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq not installed — doctor Check 10 needs jq to inspect settings.json"
else
  E_STRAY="$WORK/e-stray-home"
  mkdir -p "$E_STRAY/.claude"
  cat > "$E_STRAY/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "quetrex@quetrex": true, "quetrex-setup@quetrex": true } }
JSON
  OUT_STRAY="$( (HOME="$E_STRAY"; HOME_SETTINGS="$E_STRAY/.claude/settings.json"; export HOME HOME_SETTINGS; bash -c "$CHECK10_SCRIPT") 2>&1 )"
  if printf '%s' "$OUT_STRAY" | grep -q '✗' && printf '%s' "$OUT_STRAY" | grep -qF 'quetrex@quetrex'; then
    pass "doctor Check 10: a stray quetrex@quetrex pin at user scope is flagged ✗ and named"
  else
    fail "doctor Check 10: a stray user-scope quetrex@quetrex pin was not flagged (out=[$OUT_STRAY])"
  fi

  E_CLEAN="$WORK/e-clean-home"
  mkdir -p "$E_CLEAN/.claude"
  cat > "$E_CLEAN/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "quetrex-setup@quetrex": true } }
JSON
  OUT_CLEAN="$( (HOME="$E_CLEAN"; HOME_SETTINGS="$E_CLEAN/.claude/settings.json"; export HOME HOME_SETTINGS; bash -c "$CHECK10_SCRIPT") 2>&1 )"
  if printf '%s' "$OUT_CLEAN" | grep -q '✓' && ! printf '%s' "$OUT_CLEAN" | grep -q '✗'; then
    pass "doctor Check 10: only quetrex-setup enabled at user scope reports a clean ✓"
  else
    fail "doctor Check 10: the clean-only-quetrex-setup fixture did not report a clean ✓ (out=[$OUT_CLEAN])"
  fi
fi

# =============================================================================
# (f) one-copy — every basename tracked exactly once, PLUS a live break-test.
# =============================================================================
echo "# (f) one-copy (fresh recomputation + a live break-test)"
ALLOWED_MULTIPLE="plugin.json hooks.json SKILL.md reference.md CLAUDE.md README.md"
WALK_DIRS=".claude plugins/quetrex-factory plugins/quetrex-setup bin hooks"

TRACKED="$(git ls-files -- $WALK_DIRS)"
if [ -z "$TRACKED" ]; then
  fail "one-copy: git ls-files over ($WALK_DIRS) returned 0 files"
else
  pass "one-copy: git ls-files over ($WALK_DIRS) returned $(printf '%s\n' "$TRACKED" | grep -c .) tracked file(s)"
fi

DUP_BASENAMES="$(printf '%s\n' "$TRACKED" | xargs -n1 basename 2>/dev/null | sort | uniq -d)"
UNEXPECTED=0
if [ -n "$DUP_BASENAMES" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    allowed=0
    for a in $ALLOWED_MULTIPLE; do [ "$b" = "$a" ] && allowed=1 && break; done
    [ "$allowed" -eq 1 ] && continue
    UNEXPECTED=$((UNEXPECTED + 1))
    fail "one-copy: basename '$b' is tracked more than once and is not on the allow-list"
  done <<EOF
$DUP_BASENAMES
EOF
fi
[ "$UNEXPECTED" -eq 0 ] && pass "one-copy: 0 unexpected duplicate basenames across ($WALK_DIRS) (independent recomputation)"

# --- live break-test: build a synthetic git repo, plant a real duplicate,
# prove the SAME walk-and-group logic catches it. Never touches this repo.
BREAK_REPO="$WORK/f-break-repo"
mkdir -p "$BREAK_REPO/dirA" "$BREAK_REPO/dirB"
git -C "$BREAK_REPO" init -q
echo 'echo one' > "$BREAK_REPO/dirA/unique-tool.sh"
git -C "$BREAK_REPO" add -A >/dev/null
git -C "$BREAK_REPO" -c user.email=qa@test -c user.name=qa commit -q -m init

one_copy_check() {  # one_copy_check <repo> <walk-dirs...> -> prints dup basenames not allowed
  local repo="$1"; shift
  ( cd "$repo" && git ls-files -- "$@" | xargs -n1 basename 2>/dev/null | sort | uniq -d )
}

BEFORE_DUPS="$(one_copy_check "$BREAK_REPO" dirA dirB)"
if [ -z "$BEFORE_DUPS" ]; then
  pass "one-copy break-test: synthetic repo starts with 0 duplicate basenames"
else
  fail "one-copy break-test: synthetic repo fixture is already wrong before planting anything (dups=[$BEFORE_DUPS])"
fi

# Plant a real duplicate: same basename, different path (a leftover copy).
cp "$BREAK_REPO/dirA/unique-tool.sh" "$BREAK_REPO/dirB/unique-tool.sh"
git -C "$BREAK_REPO" add -A >/dev/null
git -C "$BREAK_REPO" -c user.email=qa@test -c user.name=qa commit -q -m "plant a duplicate"

AFTER_DUPS="$(one_copy_check "$BREAK_REPO" dirA dirB)"
if printf '%s\n' "$AFTER_DUPS" | grep -qx 'unique-tool.sh'; then
  pass "one-copy break-test: planting dirB/unique-tool.sh alongside dirA/unique-tool.sh IS caught by the walk-and-group logic (mechanical proof, not prose)"
else
  fail "one-copy break-test: the walk-and-group logic did NOT catch a planted duplicate basename (dups=[$AFTER_DUPS]) — the one-copy check cannot be trusted to catch a real regression"
fi

# =============================================================================
# (g) legacy-string sweep — independent re-implementation of AC20's grep.
# =============================================================================
echo "# (g) legacy /quetrex:(login|init|update) sweep (QA's own allow-list)"
# QA's own allow-list, decided independently of test/legacy-command-repoint.test.sh's
# (which ships with an EMPTY allow-list per its own header comment — "every
# one of the 197 references was either... repointed... or already excluded").
# If this sweep finds hits, they must appear here, each with QA's own stated
# reason; otherwise this is a real, undocumented regression/omission.
QA_ALLOWLIST=()

RAW_HITS="$(git grep -nE '/quetrex:(login|init|update)' -- . 2>/dev/null | grep -v '^\.quetrex-backups/\|^\.quetrex/plan/' || true)"
HITS=()
if [ -n "$RAW_HITS" ]; then
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    HITS+=("$(printf '%s' "$line" | cut -d: -f1,2)")
  done <<< "$RAW_HITS"
fi

echo "# QA sweep: ${#HITS[@]} hit(s) for /quetrex:(login|init|update) outside .quetrex-backups/ and .quetrex/plan/"
if [ "${#HITS[@]}" -gt 0 ]; then
  printf '#   %s\n' "${HITS[@]}"
fi

SWEEP_BAD=0
for h in "${HITS[@]}"; do
  found=0
  for a in "${QA_ALLOWLIST[@]:-}"; do
    [ "$h" = "$a" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    SWEEP_BAD=$((SWEEP_BAD + 1))
    fail "legacy-string sweep: $h still reads /quetrex:(login|init|update) and is not on QA's documented allow-list — this is the SAME defect test/legacy-command-repoint.test.sh's own (empty) ALLOWLIST array misses, found independently"
  fi
done
[ "$SWEEP_BAD" -eq 0 ] && pass "legacy-string sweep: every surviving hit (${#HITS[@]}) is accounted for on QA's own allow-list"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "qa-global-independent.test.sh: all checks passed"
  exit 0
else
  echo "qa-global-independent.test.sh: FAILURES above"
  exit 1
fi
