#!/usr/bin/env bash
# test/init-arming.test.sh — proves the two arming paths that a repo is
# adopted through actually EXECUTE, rather than merely being written down.
#
# Run: bash test/init-arming.test.sh
#
# ---------------------------------------------------------------------------
# PART A — /quetrex-setup:init step 5c must be able to author a requiredEnv entry.
#
# The bash block in plugins/quetrex-setup/commands/init.md step 5c is the ONLY caller of
# `quetrex-env-derive declare`, the ONLY writer of `.quetrex/verify.json`'s
# `requiredEnv`. It used to guard that call with
#
#     if [ -n "${QUETREX_INIT_NONINTERACTIVE:-}" ] || [ ! -t 0 ] || [ ! -t 1 ]
#
# and put the `declare` call in the `else` branch. `/quetrex-setup:init` only ever
# runs through Claude Code's Bash tool, where NEITHER stdin NOR stdout is a
# TTY — so that condition was true 100% of the time and the writer was
# structurally unreachable. Consequence: every repo armed by /quetrex-setup:init
# shipped with no `requiredEnv`, verify-gate's declarative env skip never
# fired, and the first cloud build of any repo whose verify chain needs a
# credential died on an unset variable no sandbox could ever hold.
#
# The human-confirmation requirement is real and is PRESERVED: the confirming
# surface is `AskUserQuestion` (a tool call), not a terminal, and the explicit
# `QUETREX_INIT_NONINTERACTIVE` opt-out still suppresses everything. What this
# file proves is that with confirmations in hand and no explicit opt-out, the
# block RUNS `declare` under exactly the non-TTY conditions Claude Code
# provides — and that the real tool then lands the entry on disk.
#
# The block is EXTRACTED FROM init.md AND EXECUTED here, never eyeballed:
# init.md is the shipped artifact, so a test that reads a copy proves nothing.
#
# ---------------------------------------------------------------------------
# PART B — arming must install the status bar into the target repo.
#
# Nothing is version-pinned anywhere (a pinned enabledPlugins entry makes the
# plugin count as DISABLED and the whole /quetrex:* command layer stops
# loading), so config carries no version at all. `/quetrex-setup:update` and
# `/quetrex:doctor` both tell the operator the running engine version "lives
# in the status bar" — but nothing installed it, so in every armed repo the
# one place the product says to look was blank. A Claude Code plugin CANNOT
# register a `statusLine`, so arming has to write the registration into the
# target repo's own `.claude/settings.json` and put the script beside it.
#
# The registration must use the GUARDED form,
# `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/statusline-command.sh"`. The bare
# form exits 127 when the variable is unset; this file runs BOTH for real to
# prove the difference rather than asserting it.
#
# init's union-only, never-narrow contract holds throughout: a statusLine the
# operator already set is never clobbered, an existing statusline script in
# the repo is never overwritten, and re-arming is a byte-for-byte no-op.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$REPO_ROOT/plugins/quetrex-setup/commands/init.md"
ARM="$REPO_ROOT/plugins/quetrex-setup/bin/quetrex-arm"
ENV_DERIVE="$REPO_ROOT/plugins/quetrex-setup/bin/quetrex-env-derive"

for f in "$INIT_MD" "$ARM" "$ENV_DERIVE"; do
  if [ ! -f "$f" ]; then
    echo "NOT OK - required file missing: $f"
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — quetrex-arm and quetrex-env-derive both write JSON with node"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — the requiredEnv candidate proof reads committed blobs"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-init-arming.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

KANBAN_URL="https://kanban.example.test"

jqget() {  # jqget <file> <node-expression-on-o>
  node -e '
    const fs = require("fs");
    let o = {};
    try { o = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
    const v = (function (o) { return eval(process.argv[2]); })(o);
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  ' "$1" "$2" 2>/dev/null
}

# ===========================================================================
# PART A — step 5c's declare call must be reachable in a non-TTY session
# ===========================================================================

# Extract the ONE fenced bash block in init.md that contains the DECLARE_ARGS
# assembly — i.e. the shipped step-5c block, byte for byte.
BLOCK="$WORK/step5c.sh"
awk '
  /^```bash$/ { inb = 1; buf = ""; hit = 0; next }
  /^```$/ && inb { if (hit) { printf "%s", buf; exit } inb = 0; next }
  inb { buf = buf $0 "\n"; if ($0 ~ /DECLARE_ARGS=\(\)/) hit = 1 }
' "$INIT_MD" > "$BLOCK"

if [ -s "$BLOCK" ]; then
  pass "A0: extracted step 5c's DECLARE_ARGS block from init.md ($(wc -l < "$BLOCK" | tr -d ' ') lines)"
else
  fail "A0: could not extract step 5c's DECLARE_ARGS block from init.md — nothing below can run"
  echo
  echo "init-arming.test.sh: FAILURES above"
  exit 1
fi

# --- A1: the block must carry no TTY test in EXECUTABLE code -------------
# `[ -t 0 ]`/`[ -t 1 ]` are false in every Claude Code Bash tool invocation,
# which is the ONLY way /quetrex-setup:init ever executes. A TTY test here is not a
# conservative guard; it is an unconditional off switch. Whole-line comments
# are stripped first — the block is expected to WARN about this in prose, and
# a warning is not a guard.
BLOCK_CODE="$WORK/step5c.code"
grep -vE '^[[:space:]]*#' "$BLOCK" > "$BLOCK_CODE" || true
if grep -qE '\-t[[:space:]]+[012]' "$BLOCK_CODE"; then
  fail "A1: step 5c's executable block still tests for a TTY — that test is never true inside Claude Code, so declare can never run"
else
  pass "A1: step 5c's executable block contains no TTY test"
fi

# --- A2: init.md's prose must not direct a skip on a no-TTY basis --------
if grep -q 'a no-TTY test' "$INIT_MD"; then
  fail "A2: init.md prose still names a no-TTY test as a reason to skip 5c's question"
else
  pass "A2: init.md prose no longer names a no-TTY test as a reason to skip 5c"
fi
INIT_FLAT="$WORK/init.flat"
tr '\n' ' ' < "$INIT_MD" | tr -s ' ' > "$INIT_FLAT"
if grep -q 'a tool call, not a terminal' "$INIT_FLAT"; then
  pass "A2: init.md names AskUserQuestion (a tool call, not a terminal) as the confirming surface"
else
  fail "A2: init.md no longer states that the human-confirmation surface is a tool call, not a terminal"
fi

# A stub declare that records exactly what it was called with.
STUBBIN="$WORK/stubbin"
mkdir -p "$STUBBIN"
cat > "$STUBBIN/quetrex-env-derive" <<'STUB'
#!/bin/sh
: > "$QX_STUB_RECORD"
for a in "$@"; do printf '%s\n' "$a" >> "$QX_STUB_RECORD"; done
echo "stub: declare invoked"
STUB
chmod +x "$STUBBIN/quetrex-env-derive"

# run_5c <record-file> <noninteractive-value> <with-confirmations:yes|no>
# Executes the extracted block with BOTH stdin and stdout non-TTY — exactly
# the conditions Claude Code's Bash tool provides.
run_5c() {
  local record="$1" nonint="$2" conf="$3"
  local driver="$WORK/driver.sh"
  rm -f "$record"
  {
    echo 'REPO_ROOT="$QX_TEST_REPO_ROOT"'
    if [ "$conf" = "yes" ]; then
      printf 'CONFIRM_CMD_ENV=($%s)\n' "'npm run build\tDEMO_DATABASE_URL'"
      echo 'CONFIRM_DECLINE=(DECLINED_NAME)'
    else
      echo 'CONFIRM_CMD_ENV=()'
      echo 'CONFIRM_DECLINE=()'
    fi
    cat "$BLOCK"
  } > "$driver"
  (
    if [ -n "$nonint" ]; then
      export QUETREX_INIT_NONINTERACTIVE="$nonint"
    else
      unset QUETREX_INIT_NONINTERACTIVE
    fi
    export QX_STUB_RECORD="$record"
    export PATH="$STUBBIN:$PATH"
    bash "$driver" < /dev/null > "$WORK/run.out" 2>&1
  )
}

FIXA="$WORK/repo-a"
mkdir -p "$FIXA"
export QX_TEST_REPO_ROOT="$FIXA"

# --- A3: confirmations in hand, no explicit opt-out -> declare RUNS ------
REC_A3="$WORK/rec-a3"
run_5c "$REC_A3" "" yes
if [ -f "$REC_A3" ]; then
  pass "A3: with human confirmations and no explicit opt-out, step 5c invokes quetrex-env-derive in a non-TTY session"
  A3ARGS="$(tr '\n' '|' < "$REC_A3")"
  if [ "$A3ARGS" = "declare|$FIXA|--cmd|npm run build|--env|DEMO_DATABASE_URL|--decline|DECLINED_NAME|" ]; then
    pass "A3: declare received exactly the confirmed pairs and declines, repo-root pinned (\`$A3ARGS\`)"
  else
    fail "A3: declare received the wrong argv: \`$A3ARGS\`"
  fi
else
  fail "A3: step 5c never invoked quetrex-env-derive in a non-TTY session — the sanctioned requiredEnv writer is unreachable ($(cat "$WORK/run.out" 2>/dev/null))"
fi

# --- A4: the explicit opt-out still suppresses everything ----------------
REC_A4="$WORK/rec-a4"
run_5c "$REC_A4" "1" yes
if [ -f "$REC_A4" ]; then
  fail "A4: QUETREX_INIT_NONINTERACTIVE=1 must write nothing, but declare was invoked ($(tr '\n' '|' < "$REC_A4"))"
else
  pass "A4: QUETREX_INIT_NONINTERACTIVE=1 still suppresses the declare call entirely"
fi

# --- A5: no confirmations -> nothing is ever manufactured ----------------
REC_A5="$WORK/rec-a5"
run_5c "$REC_A5" "" no
if [ -f "$REC_A5" ]; then
  fail "A5: with zero confirmed pairs and zero declines, declare must never be invoked (got $(tr '\n' '|' < "$REC_A5"))"
else
  pass "A5: with zero confirmed pairs and zero declines, declare is never invoked"
fi

# --- A6: END TO END against the REAL tool -------------------------------
# The block, the shipped quetrex-env-derive, and a repo whose committed
# evidence actually proves the candidate. Nothing stubbed.
FIXE="$WORK/repo-e2e"
mkdir -p "$FIXE/src" "$FIXE/.quetrex"
printf 'DEMO_DATABASE_URL=e2e-value-must-never-leak\n' > "$FIXE/.env.example"
printf 'const url = process.env.DEMO_DATABASE_URL;\nmodule.exports = { url };\n' > "$FIXE/src/db.js"
printf '{\n  "verify": ["npm run build"]\n}\n' > "$FIXE/.quetrex/verify.json"
git -C "$FIXE" init -q -b main >/dev/null 2>&1
git -C "$FIXE" config user.email t@e.test
git -C "$FIXE" config user.name T
git -C "$FIXE" add .env.example src/db.js .quetrex/verify.json >/dev/null 2>&1
git -C "$FIXE" commit -q -m "fixture" >/dev/null 2>&1

REALBIN="$WORK/realbin"
mkdir -p "$REALBIN"
ln -s "$ENV_DERIVE" "$REALBIN/quetrex-env-derive" 2>/dev/null || cp "$ENV_DERIVE" "$REALBIN/quetrex-env-derive"
chmod +x "$REALBIN/quetrex-env-derive" 2>/dev/null || true

E2E_DRIVER="$WORK/e2e-driver.sh"
{
  echo "REPO_ROOT=\"$FIXE\""
  printf 'CONFIRM_CMD_ENV=($%s)\n' "'npm run build\tDEMO_DATABASE_URL'"
  echo 'CONFIRM_DECLINE=(DECLINED_NAME)'
  cat "$BLOCK"
} > "$E2E_DRIVER"
(
  unset QUETREX_INIT_NONINTERACTIVE
  export PATH="$REALBIN:$PATH"
  bash "$E2E_DRIVER" < /dev/null > "$WORK/e2e.out" 2>&1
)

E2E_REQ="$(jqget "$FIXE/.quetrex/verify.json" 'o.requiredEnv && o.requiredEnv["npm run build"] && o.requiredEnv["npm run build"].join(",")')"
if [ "$E2E_REQ" = "DEMO_DATABASE_URL" ]; then
  pass "A6 END TO END: step 5c + the real quetrex-env-derive landed requiredEnv[\"npm run build\"]=[DEMO_DATABASE_URL] on disk"
else
  fail "A6 END TO END: requiredEnv was never written (got '$E2E_REQ'; output: $(cat "$WORK/e2e.out" 2>/dev/null))"
fi

E2E_DEC="$(jqget "$FIXE/.quetrex/verify.json" 'Array.isArray(o.requiredEnvDeclined) && o.requiredEnvDeclined.join(",")')"
if [ "$E2E_DEC" = "DECLINED_NAME" ]; then
  pass "A6 END TO END: the declined name landed in requiredEnvDeclined"
else
  fail "A6 END TO END: requiredEnvDeclined was never written (got '$E2E_DEC')"
fi

E2E_LEAK="$(grep -c 'e2e-value-must-never-leak' "$FIXE/.quetrex/verify.json" 2>/dev/null || true)"
if [ "${E2E_LEAK:-0}" = "0" ]; then
  pass "A6 INVARIANT: 0 occurrences of the .env.example VALUE in the written file — names only"
else
  fail "A6 INVARIANT: the .env.example value leaked into .quetrex/verify.json"
fi

# ===========================================================================
# PART B — arming installs the status bar into the target repo
# ===========================================================================

STATUSLINE_CMD='bash "${CLAUDE_PROJECT_DIR:-.}/.claude/statusline-command.sh"'

FIXB="$WORK/repo-b"
mkdir -p "$FIXB"
B_OUT="$(bash "$ARM" "$FIXB" "$KANBAN_URL" 2>&1)"; B_RC=$?
B_SETTINGS="$FIXB/.claude/settings.json"

if [ "$B_RC" -eq 0 ]; then
  pass "B0: arming a fresh repo exits 0"
else
  fail "B0: arming a fresh repo exited $B_RC ($B_OUT)"
fi

B_TYPE="$(jqget "$B_SETTINGS" 'o.statusLine && o.statusLine.type')"
B_CMD="$(jqget "$B_SETTINGS" 'o.statusLine && o.statusLine.command')"
if [ "$B_TYPE" = "command" ]; then
  pass "B1: arming registers statusLine.type=command in the target repo's .claude/settings.json"
else
  fail "B1: no statusLine registered by arming — the sole sanctioned home of the engine version is never installed (got type='$B_TYPE')"
fi
if [ "$B_CMD" = "$STATUSLINE_CMD" ]; then
  pass "B2: statusLine.command is the GUARDED form — $STATUSLINE_CMD"
else
  fail "B2: statusLine.command is not the guarded form (got '$B_CMD', want '$STATUSLINE_CMD')"
fi

B_SCRIPT="$FIXB/.claude/statusline-command.sh"
if [ -f "$B_SCRIPT" ]; then
  pass "B3: arming placed .claude/statusline-command.sh in the target repo"
  if [ -x "$B_SCRIPT" ]; then
    pass "B3: the placed statusline script is executable"
  else
    fail "B3: the placed statusline script is not executable"
  fi
else
  fail "B3: arming did not place .claude/statusline-command.sh in the target repo — the registration would point at nothing"
fi

# --- B4: RUN the registered command for real, both forms ----------------
# `${CLAUDE_PROJECT_DIR:-.}` is the whole point: with the variable unset the
# bare form resolves to /.claude/statusline-command.sh and bash exits 127.
if command -v jq >/dev/null 2>&1 && [ -f "$B_SCRIPT" ] && [ -n "$B_CMD" ]; then
  SL_JSON='{"workspace":{"current_dir":"'"$FIXB"'","project_dir":"'"$FIXB"'"},"model":{"display_name":"Test"},"version":"9.9.9","context_window":{"used_percentage":10}}'
  GUARD_OUT="$(cd "$FIXB" && printf '%s' "$SL_JSON" | env -u CLAUDE_PROJECT_DIR bash -c "$B_CMD" 2>&1)"; GUARD_RC=$?
  if [ "$GUARD_RC" -eq 0 ] && [ -n "$GUARD_OUT" ]; then
    pass "B4: the registered statusLine command RUNS (exit 0, non-empty render) with CLAUDE_PROJECT_DIR unset"
  else
    fail "B4: the registered statusLine command failed with CLAUDE_PROJECT_DIR unset (exit $GUARD_RC): $GUARD_OUT"
  fi

  BARE_CMD='bash "${CLAUDE_PROJECT_DIR}/.claude/statusline-command.sh"'
  BARE_OUT="$(cd "$FIXB" && printf '%s' "$SL_JSON" | env -u CLAUDE_PROJECT_DIR bash -c "$BARE_CMD" 2>&1)"; BARE_RC=$?
  if [ "$BARE_RC" -ne 0 ]; then
    pass "B4 NEGATIVE CONTROL: the BARE form fails (exit $BARE_RC) with CLAUDE_PROJECT_DIR unset — the guard is load-bearing"
  else
    fail "B4 NEGATIVE CONTROL: the bare form unexpectedly succeeded, so this test cannot prove the guard matters"
  fi
elif ! command -v jq >/dev/null 2>&1; then
  echo "note: jq not installed — skipping the live statusLine render (B4) only"
else
  fail "B4: cannot run the registered statusLine command — nothing was installed or registered to run"
fi

# --- B9: a previously-written BARE registration is repaired --------------
# The bare form exits 127 when CLAUDE_PROJECT_DIR is unset. It is OUR string,
# not the operator's, so re-arming repairs it — the same "re-running
# /quetrex-setup:init is the remediation path" contract as the dead-MCP purge.
FIXG="$WORK/repo-g"
mkdir -p "$FIXG/.claude"
cat > "$FIXG/.claude/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "bash \"${CLAUDE_PROJECT_DIR}/.claude/statusline-command.sh\""
  }
}
JSON
G_OUT="$(bash "$ARM" "$FIXG" "$KANBAN_URL" 2>&1)"; G_RC=$?
G_CMD="$(jqget "$FIXG/.claude/settings.json" 'o.statusLine && o.statusLine.command')"
if [ "$G_RC" -eq 0 ] && [ "$G_CMD" = "$STATUSLINE_CMD" ]; then
  pass "B9: a bare (unguarded) Quetrex statusLine registration is repaired to the guarded form on re-arming"
else
  fail "B9: the bare registration was not repaired (got '$G_CMD', exit $G_RC: $G_OUT)"
fi

# --- B5: idempotent -----------------------------------------------------
B_BEFORE="$(cat "$B_SETTINGS")"
B_SCRIPT_BEFORE="$(cat "$B_SCRIPT" 2>/dev/null || true)"
B_OUT2="$(bash "$ARM" "$FIXB" "$KANBAN_URL" 2>&1)"; B_RC2=$?
B_AFTER="$(cat "$B_SETTINGS")"
if [ "$B_RC2" -eq 0 ] && [ "$B_BEFORE" = "$B_AFTER" ]; then
  pass "B5: re-arming makes NO change to settings.json and exits 0"
else
  fail "B5: re-arming changed settings.json or exited $B_RC2 ($B_OUT2)"
fi
if [ "$B_SCRIPT_BEFORE" = "$(cat "$B_SCRIPT" 2>/dev/null || true)" ]; then
  pass "B5: re-arming leaves the statusline script byte-identical"
else
  fail "B5: re-arming rewrote the statusline script"
fi

# --- B6: union-only — an operator's own statusLine is never clobbered ----
FIXC="$WORK/repo-c"
mkdir -p "$FIXC/.claude"
cat > "$FIXC/.claude/settings.json" <<'JSON'
{
  "statusLine": {
    "type": "command",
    "command": "my-own-statusline --fancy"
  },
  "permissions": {
    "allow": [
      "Bash(npm run:*)"
    ]
  }
}
JSON
C_OUT="$(bash "$ARM" "$FIXC" "$KANBAN_URL" 2>&1)"; C_RC=$?
C_CMD="$(jqget "$FIXC/.claude/settings.json" 'o.statusLine && o.statusLine.command')"
C_PERM="$(jqget "$FIXC/.claude/settings.json" 'o.permissions && o.permissions.allow && o.permissions.allow.join(",")')"
C_QPIN="$(jqget "$FIXC/.claude/settings.json" 'o.enabledPlugins && o.enabledPlugins["quetrex@quetrex"]')"
if [ "$C_RC" -eq 0 ] && [ "$C_CMD" = "my-own-statusline --fancy" ]; then
  pass "B6: an operator's pre-existing statusLine survives arming byte-for-byte"
else
  fail "B6: arming clobbered the operator's own statusLine (got '$C_CMD', exit $C_RC: $C_OUT)"
fi
if [ "$C_PERM" = "Bash(npm run:*)" ] && [ "$C_QPIN" = "true" ]; then
  pass "B6: unrelated settings keys survive and the engine is still armed alongside the operator's statusLine"
else
  fail "B6: arming damaged unrelated keys (permissions='$C_PERM', quetrex pin='$C_QPIN')"
fi

# --- B7: an existing statusline script in the repo is never overwritten --
FIXD="$WORK/repo-d"
mkdir -p "$FIXD/.claude"
printf '#!/bin/bash\necho operator-custom-statusline\n' > "$FIXD/.claude/statusline-command.sh"
chmod +x "$FIXD/.claude/statusline-command.sh"
D_BEFORE="$(cat "$FIXD/.claude/statusline-command.sh")"
D_OUT="$(bash "$ARM" "$FIXD" "$KANBAN_URL" 2>&1)"; D_RC=$?
if [ "$D_RC" -eq 0 ] && [ "$D_BEFORE" = "$(cat "$FIXD/.claude/statusline-command.sh")" ]; then
  pass "B7: an existing .claude/statusline-command.sh in the target repo is never overwritten"
else
  fail "B7: arming overwrote the repo's existing statusline script (exit $D_RC: $D_OUT)"
fi
D_CMD="$(jqget "$FIXD/.claude/settings.json" 'o.statusLine && o.statusLine.command')"
if [ "$D_CMD" = "$STATUSLINE_CMD" ]; then
  pass "B7: the registration is still written, pointing at the script the repo already had"
else
  fail "B7: no statusLine registered when the script already existed (got '$D_CMD')"
fi

# --- B8: never register a status bar that points at nothing -------------
# If the shipped script cannot be located, arming must still succeed for
# every other concern and register NO statusLine — a status bar that can only
# print "command not found" reads to the operator as a failed build.
FIXF="$WORK/repo-f"
mkdir -p "$FIXF"
F_OUT="$(QX_ARM_STATUSLINE_SRC="$WORK/definitely-not-here.sh" bash "$ARM" "$FIXF" "$KANBAN_URL" 2>&1)"; F_RC=$?
F_SL="$(jqget "$FIXF/.claude/settings.json" 'o.statusLine && o.statusLine.command')"
F_QPIN="$(jqget "$FIXF/.claude/settings.json" 'o.enabledPlugins && o.enabledPlugins["quetrex@quetrex"]')"
if [ "$F_RC" -eq 0 ] && [ "$F_QPIN" = "true" ]; then
  pass "B8: with the statusline source missing, arming still exits 0 and still enables the engine"
else
  fail "B8: a missing statusline source broke arming (exit $F_RC, pin='$F_QPIN': $F_OUT)"
fi
if [ -z "$F_SL" ]; then
  pass "B8: with the statusline source missing, NO statusLine is registered — never a registration pointing at nothing"
else
  fail "B8: arming registered a statusLine ('$F_SL') with no script to back it"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "init-arming.test.sh: all checks passed"
  exit 0
else
  echo "init-arming.test.sh: FAILURES above"
  exit 1
fi
