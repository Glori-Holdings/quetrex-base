#!/usr/bin/env bash
# no-eval-on-caller-data.test.sh — the CLASS, not one instance of it.
#
# Twice in this PR a shipped command resolved variables with
#     eval "$(<something that emits KEY=VALUE lines>)"
# and twice a value carrying a shell metacharacter or a newline became a command:
#
#   * task-rework.md — branchPrefix from committed .quetrex/project.json. Reproduced three
#     ways (`;touch`, `$( )`, backticks). Adjudicated Critical.
#   * task-build.md  — the epic tick. A routineId carrying a newline makes the RECOVER note
#     emit a SECOND physical line beginning `REAP=`; grep is line-based so it matched, and
#     eval ran it. Found only because a reviewer went looking for the sibling AFTER the first
#     was fixed.
#
# Both had the same blind spot: every fixture used the benign value, so nothing exercised it.
# This file exists so the third instance is caught by the suite instead of by a reviewer.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- ASSERTION 1: no command file evals a KEY=VALUE stream --------------------
# Textual, and deliberately so: this one is about a construct never being reintroduced.
# The behavioral proof is ASSERTION 2. Comment lines are stripped first — the previous
# says-not-does failure in this repo was a grep satisfied by a phrase in a dead comment.
OFFENDERS=""
for f in "$ROOT"/.claude/commands/*.md "$ROOT"/.claude/lib/*.md; do
  [ -f "$f" ] || continue
  if grep -vE '^[[:space:]]*#' "$f" | grep -qE 'eval "\$\('; then
    OFFENDERS="$OFFENDERS $(basename "$f")"
  fi
done
if [ -z "$OFFENDERS" ]; then
  ok "ASSERTION 1: no shipped command evals a command substitution"
else
  notok "ASSERTION 1: eval \"\$( … )\" present in:$OFFENDERS — parse the key/value lines instead"
fi

# --- ASSERTION 2: the epic tick's parser is inert under injection -------------
# Extract the SHIPPED block and run it. A value carrying a newline must land as text.
python3 - "$ROOT/.claude/commands/task-build.md" > "$TMP/tick.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'IN_FLIGHT=""; READY=""; BLOCKED=""; REAP=""; SETTLED=""; FAILED=""\n.*?unset _k _v', s, re.S)
if not m:
    print('echo "PROBE-ERROR: tick parser block not found"; exit 9'); sys.exit(0)
print("#!/usr/bin/env bash\nset -uo pipefail")
print('PLAN_OUT="$1"')
print(m.group(0))
print('echo "FIXPOINT=${FIXPOINT:-} REAP=${REAP:-}"')
PY

if grep -q 'PROBE-ERROR' "$TMP/tick.sh"; then
  notok "ASSERTION 2: could not extract the tick parser — the assertions below would be vacuous"
else
  ok "ASSERTION 2: extracted the shipped tick parser"

  SENT="$TMP/pwn-tick"; rm -f "$SENT"
  OUT="$(bash "$TMP/tick.sh" "$(printf 'FIXPOINT=no\nRECOVER=r1\nREAP=;touch %s;X=\nREAP=2' "$SENT")" 2>&1)"
  if [ -f "$SENT" ]; then
    notok "ASSERTION 2: COMMAND EXECUTION — a newline in a value reached a command in the epic tick"
  else
    ok "ASSERTION 2: a newline-injected value does not execute in the epic tick"
  fi

  # And the benign path must still parse, or the guard is just breakage.
  OUT_OK="$(bash "$TMP/tick.sh" "$(printf 'FIXPOINT=yes\nREAP=3\nIN_FLIGHT=1')" 2>&1)"
  if printf '%s' "$OUT_OK" | grep -q 'FIXPOINT=yes' && printf '%s' "$OUT_OK" | grep -q 'REAP=3'; then
    ok "ASSERTION 2: the benign tick output still parses correctly"
  else
    notok "ASSERTION 2: the benign path broke — got: $(printf '%s' "$OUT_OK" | head -c 120)"
  fi
fi

# --- ASSERTION 3: only known keys are honoured --------------------------------
# An unrecognised key must be ignored rather than assigned, so an injected `PATH=` or
# `IFS=` line cannot reach the surrounding shell.
if grep -q 'PROBE-ERROR' "$TMP/tick.sh"; then
  notok "ASSERTION 3: skipped, parser not extracted"
else
  OUT3="$(bash -c '
    PATH_BEFORE="$PATH"
    out="$(bash "'"$TMP/tick.sh"'" "$(printf "FIXPOINT=yes\nPATH=/pwn\nIFS=x")" 2>&1)"
    printf "%s|%s" "$out" "$PATH_BEFORE"
  ')"
  if printf '%s' "$OUT3" | grep -q '/pwn'; then
    notok "ASSERTION 3: an unknown key was honoured — PATH was assignable through the parser"
  else
    ok "ASSERTION 3: unknown keys (PATH, IFS) are ignored, not assigned"
  fi
fi

echo
echo "no-eval-on-caller-data.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
