#!/usr/bin/env bash
# reviewer.md must AGREE with merge-gate.sh GATE 2b, and must resolve its diff
# BASE instead of hardcoding `main`. Two mechanical defects made nearly every
# cloud build end in ESCALATE_HUMAN when nothing was wrong:
#   CAUSE 1 — rules keyed on `native_security_ok`, a variable the file never
#     defines. Step 3 defines `independence_ok` (the three-route GATE 2b test).
#     `/security-review` needs SlashCommand, absent in cloud, so route 1 alone
#     is structurally unreachable there and every clean review escalated.
#   CAUSE 2 — `BASE="${1:-main}"`; local main is stale/absent in cloud. On
#     QDM-14 that reported 15 files "owned by no workstream"; the true count
#     was 4.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
R="$ROOT/plugins/quetrex-factory/agents/reviewer.md"
BASE_SHA="c221ed99b5c22087e49878aa26309ada88efaab2"   # fixed, never `main`

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

[ -f "$R" ] || { echo "NOT OK - reviewer.md missing"; echo "reviewer-escalation-fix.test.sh: 0 passed, 1 failed"; exit 1; }

# --- fail-first: both defects were real at the fixed baseline ---------------
OLD="$(git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-factory/agents/reviewer.md" 2>/dev/null)"
if [ -z "$OLD" ]; then
  notok "baseline $BASE_SHA unreachable — cannot prove the defects were open pre-fix"
else
  printf '%s' "$OLD" | grep -qF 'native_security_ok == 0' \
    && ok "fail-first: baseline escalated on the undefined 'native_security_ok'" \
    || notok "fail-first: baseline no longer reproduces CAUSE 1"
  printf '%s' "$OLD" | grep -qF 'BASE="${1:-main}"' \
    && ok "fail-first: baseline hardcoded BASE=\"\${1:-main}\"" \
    || notok "fail-first: baseline no longer reproduces CAUSE 2"
fi

# --- CAUSE 1: the undefined variable is gone; both decision sites key on the
#     defined one instead ---------------------------------------------------
grep -qF 'native_security_ok' "$R" \
  && notok "reviewer.md still references the undefined 'native_security_ok'" \
  || ok "reviewer.md no longer references the undefined 'native_security_ok'"

S1="$(awk '/^## Step 1/{f=1} /^## Step 2/{f=0} f' "$R")"
S4="$(awk '/^## Step 4/{f=1} /^## Output contract/{f=0} f' "$R")"
check_site() {
  local blk="$1" label="$2"
  [ -n "$blk" ] || { notok "$label: section not found — file structure changed"; return; }
  printf '%s' "$blk" | grep -qF 'independence_ok' \
    && ok "$label keys its escalation on 'independence_ok'" \
    || notok "$label does not key on 'independence_ok'"
  printf '%s' "$blk" | grep -qF 'GATE 2b' \
    && ok "$label names GATE 2b as the mirrored test" \
    || notok "$label no longer names GATE 2b"
}
check_site "$S1" "hard rule (Step 1)"
check_site "$S4" "decision rule 4 (Step 4)"

# --- CAUSE 2: base resolution ----------------------------------------------
grep -qF 'BASE="${1:-main}"' "$R" \
  && notok "reviewer.md still hardcodes BASE=\"\${1:-main}\"" \
  || ok "reviewer.md no longer hardcodes BASE=\"\${1:-main}\""

S0="$(awk '/^## Step 0/{f=1} /^## Step 1/{f=0} f' "$R")"
for tok in baseRefOid 'origin/main' 'command -v gh' ESCALATE_HUMAN; do
  printf '%s' "$S0" | grep -qF "$tok" \
    && ok "Step 0 names '$tok'" \
    || notok "Step 0 never names '$tok'"
done

CODE="$(printf '%s\n' "$S0" | awk '/^```bash/{c=1;next} /^```/{c=0} c')"
if [ -z "$CODE" ]; then
  notok "could not extract Step 0's fenced bash block"
else
  T="$(mktemp)"; printf '%s\n' "$CODE" > "$T"
  if ERR="$(bash -n "$T" 2>&1)"; then ok "Step 0's bash block is syntactically valid"
  else notok "Step 0's bash block has a syntax error: $ERR"; fi
  rm -f "$T"
fi

echo
echo "reviewer-escalation-fix.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
