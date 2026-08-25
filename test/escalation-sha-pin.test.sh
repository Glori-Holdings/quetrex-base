#!/usr/bin/env bash
# test/escalation-sha-pin.test.sh — ESCALATION-SHA-PIN (ONE-COPY, AC6/AC7).
#
# Run: bash test/escalation-sha-pin.test.sh
#
# THE DEFECT THIS CLOSES. .quetrex/ESCALATION used to be an unstructured
# marker (`touch`/`printf` — no sha). merge-gate.sh's GATE 1 denied on its
# mere PRESENCE, forever — including a marker recorded on a commit this
# branch has since left behind (a stale escalation from a prior, abandoned
# attempt, or a since-rebased-off commit). Once such a marker existed, every
# future merge on the branch was permanently blocked with no way to tell a
# genuinely-current escalation from a historical one, short of a human
# deleting the file by hand.
#
# THE FIX. Both producers (verify-gate.sh's self-heal cap, reviewer.md's
# rework cap) now write `{"sha":"<head-sha-at-cap>","reason":"..."}`. GATE 1
# denies UNLESS the recorded sha is PROVEN not an ancestor of the branch's
# current HEAD — every other shape (legacy/empty/malformed, or a sha this
# repo cannot even resolve) fails CLOSED and still denies.
#
# PART A (AC6) proves the PRODUCER: verify-gate.sh's self-heal cap.
# PART B (AC7) proves the CONSUMER: merge-gate.sh's GATE 1, all 5 cases.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_GATE="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"
MERGE_GATE="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh}"

for h in "$VERIFY_GATE" "$MERGE_GATE"; do
  [ -f "$h" ] || { echo "FAIL: hook not found at $h"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed — both gates are jq-preferred and this contract is most reliably proven with it available"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

# =============================================================================
# PART A (AC6) — verify-gate.sh's self-heal cap writes a sha-pinned marker
# =============================================================================
FA="$(mktemp -d "${TMPDIR:-/tmp}/qx-escsha-a.XXXXXX")"
mkdir -p "$FA/.quetrex"
git -C "$FA" init -q -b main >/dev/null 2>&1 || git init -q "$FA" >/dev/null 2>&1
git -C "$FA" config user.email t@e.com; git -C "$FA" config user.name t
git -C "$FA" commit -q --allow-empty -m init
printf '{"branchPrefix":"claude/"}' > "$FA/.quetrex/project.json"
jq -cn '{verify:["false"]}' > "$FA/.quetrex/verify.json"   # always red
FA_HEAD="$(git -C "$FA" rev-parse HEAD)"

run_vg() {
  local root="$1" payload
  payload="$(jq -cn --arg cwd "$root" '{cwd:$cwd,hook_event_name:"Stop"}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$root" QUETREX_VERIFY_MAX=3 "$VERIFY_GATE" >/dev/null 2>&1
}

run_vg "$FA" >/dev/null; run_vg "$FA" >/dev/null; run_vg "$FA" >/dev/null  # hit the cap

if [ -f "$FA/.quetrex/ESCALATION" ]; then
  ESC_SHA="$(jq -r '.sha // empty' "$FA/.quetrex/ESCALATION" 2>/dev/null)"
  if [ "$ESC_SHA" = "$FA_HEAD" ] && [[ "$ESC_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    ok "AC6: ESCALATION.sha ($ESC_SHA) is a 40-hex string equal to HEAD after the self-heal cap"
  else
    notok "AC6: ESCALATION.sha ('$ESC_SHA') does not equal HEAD ($FA_HEAD) or is not 40-hex"
  fi
else
  notok "AC6: no .quetrex/ESCALATION written after 3 self-heal attempts on an always-red chain"
fi
rm -rf "$FA"

# --- AC6, HEAD unresolvable (0-commit repo): legacy shape, fail-closed -----
FB="$(mktemp -d "${TMPDIR:-/tmp}/qx-escsha-b.XXXXXX")"
mkdir -p "$FB/.quetrex"
git -C "$FB" init -q -b main >/dev/null 2>&1 || git init -q "$FB" >/dev/null 2>&1
git -C "$FB" config user.email t@e.com; git -C "$FB" config user.name t
printf '{"branchPrefix":"claude/"}' > "$FB/.quetrex/project.json"
jq -cn '{verify:["false"]}' > "$FB/.quetrex/verify.json"

run_vg "$FB" >/dev/null; run_vg "$FB" >/dev/null; run_vg "$FB" >/dev/null

if [ -f "$FB/.quetrex/ESCALATION" ]; then
  if jq -e '.sha' "$FB/.quetrex/ESCALATION" >/dev/null 2>&1; then
    notok "AC6: ESCALATION written with 0 commits still carries a usable .sha ('jq -e .sha' should fail — legacy fail-closed shape expected)"
  else
    ok "AC6: with HEAD unresolvable (0 commits), ESCALATION is the legacy shape — 'jq -e .sha' fails (fail-closed)"
  fi
else
  notok "AC6: no .quetrex/ESCALATION written after 3 self-heal attempts even with 0 commits"
fi
rm -rf "$FB"

# =============================================================================
# PART B (AC7) — merge-gate.sh GATE 1, all 5 marker shapes
# =============================================================================
FC="$(mktemp -d "${TMPDIR:-/tmp}/qx-escsha-c.XXXXXX")"
git -C "$FC" init -q -b main
git -C "$FC" config user.email t@e.com; git -C "$FC" config user.name t
echo one > "$FC/f.txt"; git -C "$FC" add f.txt; git -C "$FC" commit -q -m c1
C1_SHA="$(git -C "$FC" rev-parse HEAD)"
echo two > "$FC/f.txt"; git -C "$FC" add f.txt; git -C "$FC" commit -q -m c2   # HEAD
HEAD_SHA="$(git -C "$FC" rev-parse HEAD)"
mkdir -p "$FC/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$FC/.quetrex/project.json"

# An unrelated commit that is NOT an ancestor of main's HEAD (a disjoint
# history, built with --orphan so it shares nothing with main).
git -C "$FC" checkout -q --orphan qx-unrelated
echo three > "$FC/g.txt"; git -C "$FC" add g.txt; git -C "$FC" commit -q -m unrelated
UNRELATED_SHA="$(git -C "$FC" rev-parse HEAD)"
git -C "$FC" checkout -q main
git -C "$FC" branch -q -D qx-unrelated

run_mg() {  # run_mg <label>
  local payload
  payload="$(jq -cn --arg cwd "$FC" '{tool_input:{command:"git push origin main"},cwd:$cwd}')"
  printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$FC" bash "$MERGE_GATE" 2>&1
}
escalation_cited() { printf '%s' "$1" | grep -q '\.quetrex/ESCALATION is present'; }

# (a) marker sha == HEAD -> deny, ESCALATE_HUMAN
jq -cn --arg sha "$HEAD_SHA" '{sha:$sha,reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(a): marker sha == HEAD -> GATE 1 denies, reason contains ESCALATE_HUMAN"
else
  notok "AC7(a): marker sha == HEAD did not deny with ESCALATE_HUMAN: [$OUT]"
fi

# (b) marker sha is an ancestor of HEAD (not equal) -> deny, ESCALATE_HUMAN
jq -cn --arg sha "$C1_SHA" '{sha:$sha,reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(b): marker sha is an ancestor of HEAD -> GATE 1 denies, reason contains ESCALATE_HUMAN"
else
  notok "AC7(b): ancestor marker sha did not deny with ESCALATE_HUMAN: [$OUT]"
fi

# (c) marker sha on an unrelated branch (is-ancestor exits 1) -> GATE 1
#     emits 0 deny decisions (falls through to GATE 2, which may still deny
#     for ITS OWN reason — e.g. missing review-verdict.json — but GATE 1's
#     ESCALATION-specific text must not appear).
jq -cn --arg sha "$UNRELATED_SHA" '{sha:$sha,reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT"; then
  notok "AC7(c): marker sha is NOT an ancestor of HEAD, but GATE 1 still cited ESCALATION: [$OUT]"
else
  ok "AC7(c): marker sha is not an ancestor of HEAD -> GATE 1 emitted 0 deny decisions (ignored the stale marker, fell through to GATE 2)"
fi

# (d) legacy 0-byte marker -> deny, ESCALATE_HUMAN
: > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(d): legacy 0-byte marker -> GATE 1 denies, reason contains ESCALATE_HUMAN"
else
  notok "AC7(d): legacy 0-byte marker did not deny with ESCALATE_HUMAN: [$OUT]"
fi

# (e) marker sha not resolvable in this repo -> deny (fail-closed)
jq -cn '{sha:"abbaabbaabbaabbaabbaabbaabbaabbaabbaabba",reason:"test"}' > "$FC/.quetrex/ESCALATION"
OUT="$(run_mg)"
if escalation_cited "$OUT" && printf '%s' "$OUT" | grep -q 'ESCALATE_HUMAN'; then
  ok "AC7(e): unresolvable marker sha -> GATE 1 denies (fail-closed), reason contains ESCALATE_HUMAN"
else
  notok "AC7(e): unresolvable marker sha did not deny (should fail closed): [$OUT]"
fi

rm -rf "$FC"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "escalation-sha-pin.test.sh: all checks passed"
else
  echo "escalation-sha-pin.test.sh: FAILURES above"
fi
exit "$FAIL"
