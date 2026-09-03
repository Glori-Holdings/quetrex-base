#!/usr/bin/env bash
# test/init-already-linked.test.sh — /quetrex-setup:init on an ALREADY-LINKED
# repo does not ask to confirm a verify chain that is already in place.
#
# Run: bash test/init-already-linked.test.sh
#
# OPERATOR EVIDENCE. Re-running init on a linked repo asked "Confirm the
# verification chain to write into .claude/CLAUDE.md's ## Verification
# section?" while .quetrex/verify.json already committed exactly that chain.
# Step 2a now compares the two line-for-line in node (this block runs in the
# operator's zsh as well as bash — never shell word-splitting) and, when they
# are equal, prints one line and step 4b never asks. Every other question is
# unchanged; the requiredEnv pairing question (F2) is explicitly not skipped
# on this basis.
#
#   AC1  init.md step 2a carries the `qx_verify_block_in_place` exec block and
#        the skip instruction; step 4b.1 keys on VERIF_CHAIN_IN_PLACE.
#   AC2  EXECUTED (bash + zsh): equal -> prints the "already in place" line;
#        drifted / no block / no verify.json -> prints nothing (4b runs as
#        before).
#   AC3  the F2 question is not weakened: 5c still asks per outstanding
#        candidate, with "No — leave undeclared" first, and nothing keys that
#        question on VERIF_CHAIN_IN_PLACE.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$ROOT/plugins/quetrex-setup/commands/init.md"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
[ -f "$INIT_MD" ] || { echo "NOT OK - init.md not found at $INIT_MD"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/init-already-linked.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- AC1: the block and the instruction exist where 2a lives -----------------
SECTION_2A="$(awk '/^### 2a\./{s=1} s && /^### 2b\./{exit} s' "$INIT_MD")"
if printf '%s' "$SECTION_2A" | grep -q 'quetrex:exec-block qx_verify_block_in_place' \
   && printf '%s' "$SECTION_2A" | grep -q 'do NOT ask the "Confirm the verification chain" question'; then
  ok "AC1: step 2a carries the qx_verify_block_in_place block and the do-not-ask instruction"
else
  notok "AC1: step 2a lacks the exec block or the skip instruction"
fi
if grep -q 'If step 2a set `VERIF_CHAIN_IN_PLACE=1`, this step is already' "$INIT_MD"; then
  ok "AC1: step 4b.1 keys its confirm question on VERIF_CHAIN_IN_PLACE"
else
  notok "AC1: step 4b.1 does not reference VERIF_CHAIN_IN_PLACE"
fi

awk -v name="qx_verify_block_in_place" '
  $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
' "$INIT_MD" > "$WORK/block.sh"
if [ -s "$WORK/block.sh" ] && bash -n "$WORK/block.sh" 2>/dev/null; then
  ok "AC1: the block extracts and parses"
else
  notok "AC1: could not extract a parseable qx_verify_block_in_place block"
  printf '\n%s\n' "init-already-linked.test.sh: $PASS passed, $FAIL failed"; exit 1
fi

# --- AC2: execute it ---------------------------------------------------------
write_json() { node -e 'require("fs").writeFileSync(process.argv[1], process.argv[2]+"\n")' "$1" "$2"; }
run_block() {  # run_block <shell> <repo-root>
  { printf 'REPO_ROOT=%q\n' "$2"; cat "$WORK/block.sh"; printf 'echo "FLAG=$VERIF_CHAIN_IN_PLACE"\n'; } > "$WORK/run.sh"
  "$1" "$WORK/run.sh" 2>&1
}
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

for SH in $SHELLS; do
  R="$WORK/eq-$SH"; mkdir -p "$R/.quetrex" "$R/.claude"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm run check:js","npm test"]}'
  printf '# X\n\n## Verification\nRun in this order:\n\n```bash\nnpm run check:js\nnpm test\n```\n\n## Quetrex\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_block "$SH" "$R")"
  if printf '%s' "$OUT" | grep -q 'verify chain already in place' && printf '%s' "$OUT" | grep -q '^FLAG=1$'; then
    ok "AC2/$SH: equal chain -> the one line is printed and VERIF_CHAIN_IN_PLACE=1 (no confirm question)"
  else
    notok "AC2/$SH: equal case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$WORK/drift-$SH"; mkdir -p "$R/.quetrex" "$R/.claude"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm run check:js","npm test"]}'
  printf '## Verification\n\n```bash\nnpm test\n```\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_block "$SH" "$R")"
  if ! printf '%s' "$OUT" | grep -q 'already in place' && printf '%s' "$OUT" | grep -q '^FLAG=0$'; then
    ok "AC2/$SH: drifted chain -> nothing printed, VERIF_CHAIN_IN_PLACE=0 (4b runs as before)"
  else
    notok "AC2/$SH: drift case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$WORK/noblock-$SH"; mkdir -p "$R/.quetrex" "$R/.claude"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm test"]}'
  printf '# X\n\nno verification section here\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_block "$SH" "$R")"
  if printf '%s' "$OUT" | grep -q '^FLAG=0$'; then
    ok "AC2/$SH: no ## Verification block -> VERIF_CHAIN_IN_PLACE=0"
  else
    notok "AC2/$SH: no-block case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$WORK/novj-$SH"; mkdir -p "$R/.claude"
  printf '## Verification\n\n```bash\nnpm test\n```\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_block "$SH" "$R")"
  if printf '%s' "$OUT" | grep -q '^FLAG=0$'; then
    ok "AC2/$SH: no verify.json -> VERIF_CHAIN_IN_PLACE=0"
  else
    notok "AC2/$SH: no-verify.json case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
done

# --- AC3: F2 is untouched ----------------------------------------------------
SECTION_5C="$(awk '/^### 5c\./{s=1} s && /^## 4c\./{exit} s' "$INIT_MD")"
if printf '%s' "$SECTION_5C" | grep -q 'one question per OUTSTANDING candidate' \
   && printf '%s' "$SECTION_5C" | grep -q '"No — leave undeclared"' \
   && ! printf '%s' "$SECTION_5C" | grep -q 'VERIF_CHAIN_IN_PLACE'; then
  ok "AC3: 5c still asks per outstanding candidate with 'No — leave undeclared' first, and is not keyed on VERIF_CHAIN_IN_PLACE"
else
  notok "AC3: the requiredEnv pairing question changed shape or was tied to the verify-block skip"
fi

printf '\n%s\n' "init-already-linked.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
