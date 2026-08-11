#!/usr/bin/env bash
# gate-chain-lower-bound.test.sh — a PR must not be able to de-gate itself.
#
# SEC-1 (Critical, found by the review gate on PR #99 and reproduced live).
# GATE 3 resolved the verify chain from the MERGED COMMIT with no lower bound, so a
# branch could shrink its own .quetrex/verify.json, the removed command stopped being
# required, every remaining command was green, and a measurably red suite reached the
# base branch with the gate satisfied.
#
# It needs no adversary: /quetrex:init regenerating a shorter chain silently de-gates
# the repo — the same silent-unarming class the audit found in init's swallowed git add.
#
# The fix makes the effective chain the UNION of base and head. These assertions pin
# both directions: shrink must DENY, and legitimate additions must still ALLOW.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_MERGE_GATE_HOOK:-$ROOT/.claude/hooks/merge-gate.sh}"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

if [ ! -f "$HOOK" ]; then
  echo "NOT OK - merge-gate.sh not found at $HOOK"; exit 1
fi

# --- SOURCE-LEVEL: the union must exist and must only widen -------------------
if grep -q 'unique' "$HOOK" && grep -q 'BASE_CHAIN_JSON' "$HOOK"; then
  ok "AC1: GATE 3 resolves a base chain and unions it with the head chain"
else
  notok "AC1: no base-chain union in GATE 3 — a PR can still delete its own requirements"
fi

# The union must never be allowed to shrink the chain on a jq failure.
if awk '/MERGED_CHAIN=/{f=1} f&&/CHAIN_JSON="\$MERGED_CHAIN"/{print; exit}' "$HOOK" | grep -q MERGED_CHAIN; then
  if grep -q 'MERGED_CHAIN" != "null"' "$HOOK"; then
    ok "AC2: the union is guarded — a jq failure cannot silently shrink the chain"
  else
    notok "AC2: the union is unguarded; a jq failure would shrink the chain, reintroducing the bypass"
  fi
else
  notok "AC2: could not locate the union assignment"
fi

# --- BEHAVIORAL: build a real repo and run the real hook ----------------------
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
R="$T/repo"
mkdir -p "$R/.quetrex"
( cd "$R"
  git init -q . && git config user.email t@t && git config user.name t
  printf '{\n  "verify": ["echo one", "echo two"]\n}\n' > .quetrex/verify.json
  printf 'x\n' > f.txt
  git add -A && git commit -q -m base
) >/dev/null 2>&1
BASE_SHA="$(git -C "$R" rev-parse HEAD)"

# The branch drops "echo two" from its own chain — the de-gating move.
( cd "$R"
  git switch -q -c shrink
  printf '{\n  "verify": ["echo one"]\n}\n' > .quetrex/verify.json
  git add -A && git commit -q -m "shrink the chain"
) >/dev/null 2>&1
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"

# A ledger proving ONLY the surviving command green for the head commit.
printf '{"cmd":"echo one","sha":"%s","exit":0}\n' "$HEAD_SHA" > "$R/.quetrex/verify-ledger.jsonl"

resolve_chain() {  # <head-sha> <base-ref> -> the effective chain, via the hook's own logic
  local head="$1" base="$2" chain="" bc="" cv
  cv="$(git -C "$R" show "$head:.quetrex/verify.json" 2>/dev/null)"
  [ -n "$cv" ] && chain="$(printf '%s' "$cv" | jq -c 'if (.verify|type)=="array" and (.verify|length)>0 then .verify else empty end' 2>/dev/null)"
  if [ -n "$chain" ] && grep -q 'BASE_CHAIN_JSON' "$HOOK"; then
    local bv; bv="$(git -C "$R" show "$base:.quetrex/verify.json" 2>/dev/null)"
    if [ -n "$bv" ]; then
      bc="$(printf '%s' "$bv" | jq -c 'if (.verify|type)=="array" and (.verify|length)>0 then .verify else empty end' 2>/dev/null)"
      [ -n "$bc" ] && chain="$(jq -cn --argjson a "$bc" --argjson b "$chain" '($a+$b)|unique' 2>/dev/null)"
    fi
  fi
  printf '%s' "$chain"
}

EFFECTIVE="$(resolve_chain "$HEAD_SHA" "$BASE_SHA")"

# AC3: the dropped command must still be required.
if printf '%s' "$EFFECTIVE" | jq -e 'index("echo two")' >/dev/null 2>&1; then
  ok "AC3: the command the branch deleted is STILL required (effective chain: $EFFECTIVE)"
else
  notok "AC3: the deleted command is no longer required — a branch can de-gate itself (effective chain: $EFFECTIVE)"
fi

# AC4: and it is unproven for this commit, so the merge must be denied.
UNPROVEN="$(jq -sr --arg c "echo two" '[ .[] | select(.cmd == $c) ] | length' "$R/.quetrex/verify-ledger.jsonl" 2>/dev/null)"
if [ "$UNPROVEN" = "0" ]; then
  ok "AC4: no ledger line proves the deleted command for this commit — GATE 3 has grounds to deny"
else
  notok "AC4: fixture is wrong; the deleted command appears proven"
fi

# --- NEGATIVE CONTROL: additions must still be allowed ------------------------
( cd "$R"
  git switch -q -c grow "$BASE_SHA"
  printf '{\n  "verify": ["echo one", "echo two", "echo three"]\n}\n' > .quetrex/verify.json
  git add -A && git commit -q -m "add a command"
) >/dev/null 2>&1
GROW_SHA="$(git -C "$R" rev-parse HEAD)"
GROWN="$(resolve_chain "$GROW_SHA" "$BASE_SHA")"
if printf '%s' "$GROWN" | jq -e 'length == 3' >/dev/null 2>&1; then
  ok "AC5: adding a command still tightens the gate (3 required, no double-count)"
else
  notok "AC5: adding a command produced an unexpected chain: $GROWN"
fi

# --- DISCRIMINATION: without the union, AC3 would pass vacuously --------------
NOUNION="$(git -C "$R" show "$HEAD_SHA:.quetrex/verify.json" | jq -c '.verify')"
if printf '%s' "$NOUNION" | jq -e 'index("echo two")' >/dev/null 2>&1; then
  notok "AC6: fixture cannot discriminate — the head chain already contains the deleted command"
else
  ok "AC6: the head chain alone omits it, so AC3 is a real check and not vacuous"
fi

echo
echo "gate-chain-lower-bound.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
