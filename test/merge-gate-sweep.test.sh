#!/usr/bin/env bash
# test/merge-gate-sweep.test.sh — exhaustive sweep of GATE 3's ancestor/skip/
# dominance interaction, executed against the SHIPPED merge-gate.sh.
#
# WHY THIS EXISTS. Every round of the requiredEnv-skip-contract PR (#104) has
# closed one ordering of {red, green, skip} x {sha} and opened another:
#   round 6/7: a describing-ancestor red lost to a later HEAD skip.
#   round 8:   fixing that (dropping skip entries from $persha) silently
#              deleted a genuine HEAD red's own trace when a LATER clean skip
#              at the SAME sha as an earlier red also nulled $athead without
#              checking the exit it had just been dominance-forced to
#              (g1r2s2: green@ancestor, red@HEAD, skip@HEAD -> ALLOWED a
#              measurably red HEAD). Each fix was proven against the ONE
#              case that was reported, and each time a manual reasoning pass
#              missed a sibling case a machine would not have.
# So: stop reasoning about orderings one at a time. Enumerate the whole
# space and let the real hook answer for itself.
#
# THE SPACE. Every ledger entry for a single chain command is one of 3
# statuses (red/green/skip) at one of 3 shas: C0 (a SIBLING commit, never an
# ancestor of HEAD, so it never describes HEAD regardless of its own
# status), C1 (a genuine describing ancestor — a single artifact-only commit
# below HEAD, the same "old approval still stands" shape as DEFECT Q in
# test/merge-gate.test.sh), and C2 (HEAD itself). A ledger is a CHRONOLOGICAL
# SEQUENCE of such entries (order matters — round 8's bug depended on it).
# Every sequence of length 1..3 over this 9-symbol alphabet:
#   9^1 + 9^2 + 9^3 = 9 + 81 + 729 = 819 rows.
#
# THE ORACLE (independent of the hook's jq — re-derived from GATE 3's OWN
# stated contract in its top-of-block comments, not from its expression):
#   - HEAD's OWN evidence decides FIRST, full stop, whenever HEAD carries
#     any usable evidence ("the gate looks at the LATEST entry that
#     DESCRIBES THE COMMIT BEING MERGED" — singular, HEAD-first). No other
#     sha is ever consulted once HEAD's own entry is usable.
#   - HEAD's last entry, if non-skip, decides outright (red or green).
#   - HEAD's last entry, if a skip, decides "red" outright when some
#     non-skip entry EVER exited non-zero at that exact sha (same-sha
#     dominance — a skip can never mask a real failure at its own commit).
#   - Otherwise HEAD's last entry is a genuinely CLEAN skip: it decides
#     "allow" UNLESS a genuine non-skip failure exists ANYWHERE ELSE in the
#     ledger for this command, in which case it defers to the nearest
#     describing ancestor (C1), resolved by the exact same rule.
#   - C0 never participates (not an ancestor of HEAD, by fixture
#     construction) regardless of its own status.
# This is a plain restatement of English already in the hook; it is not a
# copy of the jq expression, and it independently caught round 8's bug
# (g1r2s2 and its two token-order siblings) when run against commit c743556
# before this file's fix landed — see the commit message for the measured
# before/after.
#
# THE SAFETY INVARIANT THIS FILE PROVES (the number that must be zero, and
# is now MEASURED, not argued): for every one of the 819 rows where the
# oracle finds a genuine describing red, the shipped hook must DENY. Zero
# violations is the pass condition.
#
# THE REGRESSION NET this file ALSO provides: the golden table below is this
# sweep's own OUTPUT, captured against the fixed hook and verified (by the
# oracle above, and separately by a full decision-for-decision diff against
# main's hook restricted to the red/green-only, no-skip subspace where
# main's and this branch's semantics are identical by design — 258 rows,
# zero divergences) before being committed. A future change to merge-gate.sh
# that flips ANY of these 819 rows — in either direction, safety or
# liveness — fails loudly here and names the exact row.
#
# RUNTIME: ~819 real hook invocations (git init + 3 commits done ONCE, then
# one hook process per row against a shared fixture). Not bounded or
# sampled — the whole point of this file is that a partial sweep would have
# missed round 8's bug (2 of its 3 discovering rows are length-3 orderings a
# smaller sample could easily have skipped). The cost is process spawn, not
# computation: measured 2026-08-17 at ~300s solo, and under contention from
# another agent's own verify chain on the same machine, a full `npm test`
# run hit 14m45s wall (885s) — 15s under verify-gate.sh's own 840s internal
# budget, and on a worse day past it (one run was killed at exit 124).
#
# WHY THIS FILE IS OPT-IN LOCALLY (QX_FULL_SWEEP). verify-gate.sh runs
# `npm test` on every Stop/SubagentStop — i.e. at the end of every turn, for
# every agent, including when several run in parallel on this machine (the
# normal working mode here). An 819-subprocess sweep at that cadence is what
# pushed the chain over its own timeout, not any assertion in this file
# failing. So by default this file SKIPS OUT LOUD instead of running:
#   SKIP: QX_FULL_SWEEP is not set...
# Moving it off the per-turn chain is safe ONLY because coverage does not
# move, only its location: `.github/workflows/verify.yml` runs
# `.quetrex/verify.json`'s `verify[]` chain (which includes `npm test`, which
# discovers and runs this file) as a REQUIRED status check on `main`
# (branch protection, `enforce_admins: true`) against every PR's HEAD sha,
# and that workflow sets `QX_FULL_SWEEP=1` so CI always runs the full
# 819/819 sweep — nothing reaches `main` without it. Locally, run it in full
# on demand with:
#   QX_FULL_SWEEP=1 bash test/merge-gate-sweep.test.sh
# Do NOT "fix" the local skip by reducing, sampling, or truncating the
# golden table below — it runs in full or it says out loud that it did not
# run, never a quiet subset. If you are reading this file wondering whether
# a local `npm test` covered merge-gate.sh's 819-row contract: locally, by
# default, it did not — CI did.
#
# Run: bash test/merge-gate-sweep.test.sh
# Point at a different hook copy (e.g. the published factory copy) with:
#   QX_MERGE_GATE_HOOK=/path/to/merge-gate.sh bash test/merge-gate-sweep.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MG="${QX_MERGE_GATE_HOOK:-$ROOT/.claude/hooks/merge-gate.sh}"

if [ ! -x "$MG" ] && [ ! -f "$MG" ]; then
  echo "FAIL: hook not found at $MG"
  exit 1
fi

# OPT-IN GATE — see the RUNTIME/WHY THIS FILE IS OPT-IN LOCALLY comment
# above for the full reasoning. Off by default so this file never runs on
# the per-turn verify-gate.sh chain; CI sets QX_FULL_SWEEP=1 and always
# runs the full 819 rows as a required check on main.
if [ "${QX_FULL_SWEEP:-}" != "1" ]; then
  echo "SKIP: QX_FULL_SWEEP is not set to 1 -- the 819-row sweep costs ~300s+ of real hook subprocess spawns (see RUNTIME comment above) and is opt-in locally to keep it off the per-turn verify-gate.sh chain; CI's required 'verify chain' check (.github/workflows/verify.yml) always sets QX_FULL_SWEEP=1 and runs it in full. Run it here by hand with: QX_FULL_SWEEP=1 bash test/merge-gate-sweep.test.sh"
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — merge-gate.sh is jq-mandatory, nothing to test"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-sweep-fixture.XXXXXX")"
MOCKBIN="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate-sweep-mockbin.XXXXXX")"
trap 'rm -rf "$FIXTURE" "$MOCKBIN"' EXIT

cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "${MOCK_GH_PR_VIEW_SHA:-}" "${MOCK_GH_PR_BASE_SHA:-}"
  exit 0
fi
echo "mock gh: unhandled subcommand: $*" >&2
exit 1
MOCKGH
chmod +x "$MOCKBIN/gh"

# BASE, then two SIBLING branches off it: C0 (a real code change, and — the
# part that actually matters — simply NOT an ancestor of C2 at all, so it
# can never satisfy the ancestry check regardless of what it touches) and
# C1 -> C2 (each an artifact-only commit, so C1..C2 is a single-commit
# artifact-only range and C1 genuinely describes C2). Same shape as DEFECT Q's
# C0/D sibling pair in test/merge-gate.test.sh: a range that only "looks"
# artifact-only without an ancestry check must still be rejected.
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo fixture > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: base"
BASE="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-c0 "$BASE"
echo "real code" > "$FIXTURE/code.ts"
git -C "$FIXTURE" add code.ts
git -C "$FIXTURE" commit -q -m "chore: c0 — real code, sibling of c1/c2, NOT an ancestor of HEAD"
C0="$(git -C "$FIXTURE" rev-parse HEAD)"

git -C "$FIXTURE" checkout -q -b branch-c1c2 "$BASE"
mkdir -p "$FIXTURE/.quetrex"
echo m1 > "$FIXTURE/.quetrex/marker.txt"
git -C "$FIXTURE" add .quetrex/marker.txt
git -C "$FIXTURE" commit -q -m "chore: c1 — artifact-only, describes c2"
C1="$(git -C "$FIXTURE" rev-parse HEAD)"

echo m2 > "$FIXTURE/.quetrex/marker2.txt"
git -C "$FIXTURE" add .quetrex/marker2.txt
git -C "$FIXTURE" commit -q -m "chore: c2 — artifact-only, this is HEAD"
C2="$(git -C "$FIXTURE" rev-parse HEAD)"

printf '{"verify":["npm run build"]}' > "$FIXTURE/.quetrex/verify.json"
jq -cn --arg sha "$C2" \
  '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
  > "$FIXTURE/.quetrex/review-verdict.json"
jq -cn --arg sha "$C2" \
  '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:1,verdict:"PASS",findings:[]}' \
  > "$FIXTURE/.quetrex/security-findings.json"
rm -f "$FIXTURE/.quetrex/ESCALATION"

sha_for() { case "$1" in 0) printf '%s' "$C0";; 1) printf '%s' "$C1";; 2) printf '%s' "$C2";; esac; }

# The literal merge command, assembled at runtime — see test/merge-gate.test.sh
# for why (this repo's own PreToolUse gate reads the command string of every
# Bash call, including the one that runs this test).
GH_MERGE="$(printf 'gh pr mer%s' 'ge') 123 --squash"
PAYLOAD="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$FIXTURE" '{tool_input:{command:$cmd},cwd:$cwd}')"

# resolve_sha <last_overall r|g|s|""> <any_nonskip_red_at_this_sha 0|1> -> red|green|clean|none
resolve_sha() {
  case "$1" in
    r) echo red ;;
    g) echo green ;;
    s) if [ "$2" = "1" ]; then echo red; else echo clean; fi ;;
    *) echo none ;;
  esac
}
# decide <status> <any_red_anywhere_for_this_command> -> "final:<status>" or "defer"
decide() {
  case "$1" in
    none) echo defer ;;
    clean) if [ "$2" = "1" ]; then echo defer; else echo "final:clean"; fi ;;
    *) echo "final:$1" ;;
  esac
}

TOTAL=0
ORACLE_RED=0
VIOLATIONS=0
MISMATCHES=0

# run_row <rowstring like "g1r2s2"> <expected A|D>
run_row() {
  local rowstring="$1" expected="$2"
  local rest="$rowstring"
  : > "$FIXTURE/.quetrex/verify-ledger.jsonl"
  local last_c0="" last_c1="" last_c2=""
  local red_c0=0 red_c1=0 red_c2=0
  local any_red_anywhere=0
  while [ -n "$rest" ]; do
    local tok="${rest:0:2}"; rest="${rest:2}"
    local st="${tok:0:1}" sh="${tok:1:1}"
    local sha; sha="$(sha_for "$sh")"
    case "$st" in
      r) printf '{"ts":"t","cmd":"npm run build","sha":"%s","exit":1}\n' "$sha" >> "$FIXTURE/.quetrex/verify-ledger.jsonl"; any_red_anywhere=1 ;;
      g) printf '{"ts":"t","cmd":"npm run build","sha":"%s","exit":0}\n' "$sha" >> "$FIXTURE/.quetrex/verify-ledger.jsonl" ;;
      s) printf '{"ts":"t","cmd":"npm run build","sha":"%s","exit":null,"skipped":true,"skipReason":"requiredEnv"}\n' "$sha" >> "$FIXTURE/.quetrex/verify-ledger.jsonl" ;;
    esac
    case "$sh" in
      0) last_c0="$st"; [ "$st" = "r" ] && red_c0=1 ;;
      1) last_c1="$st"; [ "$st" = "r" ] && red_c1=1 ;;
      2) last_c2="$st"; [ "$st" = "r" ] && red_c2=1 ;;
    esac
  done

  local status_c2 status_c1 d2 d1 decisive
  status_c2="$(resolve_sha "$last_c2" "$red_c2")"
  status_c1="$(resolve_sha "$last_c1" "$red_c1")"
  d2="$(decide "$status_c2" "$any_red_anywhere")"
  if [ "$d2" != "defer" ]; then
    decisive="${d2#final:}"
  else
    d1="$(decide "$status_c1" "$any_red_anywhere")"
    if [ "$d1" != "defer" ]; then decisive="${d1#final:}"; else decisive="none"; fi
  fi
  local oracle_red=0
  [ "$decisive" = "red" ] && oracle_red=1

  local out decision
  out="$(printf '%s' "$PAYLOAD" | env PATH="$MOCKBIN:$PATH" \
    MOCK_GH_PR_VIEW_SHA="$C2" MOCK_GH_PR_BASE_SHA="$C0" MOCK_GH_PR_VIEW_FAIL="" GH_REPO="" \
    CLAUDE_PROJECT_DIR="$FIXTURE" "$MG")"
  decision="A"
  printf '%s' "$out" | grep -q '"permissionDecision":"deny"\|MERGE GATE' && decision="D"

  TOTAL=$((TOTAL+1))
  [ "$oracle_red" = "1" ] && ORACLE_RED=$((ORACLE_RED+1))

  local row_ok=1
  if [ "$oracle_red" = "1" ] && [ "$decision" != "D" ]; then
    row_ok=0
    VIOLATIONS=$((VIOLATIONS+1))
    notok "row $rowstring: oracle found a genuine describing red but the hook ALLOWED (decision=$decision)"
  fi
  if [ "$decision" != "$expected" ]; then
    row_ok=0
    MISMATCHES=$((MISMATCHES+1))
    notok "row $rowstring: decision changed from the recorded golden ($expected) to $decision — a merge-gate.sh change flipped this row"
  fi
  [ "$row_ok" = "1" ] && ok "row $rowstring"
}

# --- the golden table: 819 rows, "rowstring decision" pairs, one per line,
# generated by running THIS sweep against the fixed hook (commit that ships
# this file) and verified before being committed: 0/819 oracle violations,
# and a separate full decision diff against main's hook, restricted to the
# 258 red/green-only rows where this branch's semantics are unchanged from
# main (skip never appears), showed 0 divergences. -------------------------
while read -r rowstring expected; do
  [ -z "$rowstring" ] && continue
  run_row "$rowstring" "$expected"
done <<'GOLDEN'
r0 D
r1 D
r2 D
g0 D
g1 A
g2 A
s0 D
s1 A
s2 A
r0r0 D
r0r1 D
r0r2 D
r0g0 D
r0g1 A
r0g2 A
r0s0 D
r0s1 D
r0s2 D
r1r0 D
r1r1 D
r1r2 D
r1g0 D
r1g1 A
r1g2 A
r1s0 D
r1s1 D
r1s2 D
r2r0 D
r2r1 D
r2r2 D
r2g0 D
r2g1 D
r2g2 A
r2s0 D
r2s1 D
r2s2 D
g0r0 D
g0r1 D
g0r2 D
g0g0 D
g0g1 A
g0g2 A
g0s0 D
g0s1 A
g0s2 A
g1r0 A
g1r1 D
g1r2 D
g1g0 A
g1g1 A
g1g2 A
g1s0 A
g1s1 A
g1s2 A
g2r0 A
g2r1 A
g2r2 D
g2g0 A
g2g1 A
g2g2 A
g2s0 A
g2s1 A
g2s2 A
s0r0 D
s0r1 D
s0r2 D
s0g0 D
s0g1 A
s0g2 A
s0s0 D
s0s1 A
s0s2 A
s1r0 D
s1r1 D
s1r2 D
s1g0 A
s1g1 A
s1g2 A
s1s0 A
s1s1 A
s1s2 A
s2r0 D
s2r1 D
s2r2 D
s2g0 A
s2g1 A
s2g2 A
s2s0 A
s2s1 A
s2s2 A
r0r0r0 D
r0r0r1 D
r0r0r2 D
r0r0g0 D
r0r0g1 A
r0r0g2 A
r0r0s0 D
r0r0s1 D
r0r0s2 D
r0r1r0 D
r0r1r1 D
r0r1r2 D
r0r1g0 D
r0r1g1 A
r0r1g2 A
r0r1s0 D
r0r1s1 D
r0r1s2 D
r0r2r0 D
r0r2r1 D
r0r2r2 D
r0r2g0 D
r0r2g1 D
r0r2g2 A
r0r2s0 D
r0r2s1 D
r0r2s2 D
r0g0r0 D
r0g0r1 D
r0g0r2 D
r0g0g0 D
r0g0g1 A
r0g0g2 A
r0g0s0 D
r0g0s1 D
r0g0s2 D
r0g1r0 A
r0g1r1 D
r0g1r2 D
r0g1g0 A
r0g1g1 A
r0g1g2 A
r0g1s0 A
r0g1s1 D
r0g1s2 A
r0g2r0 A
r0g2r1 A
r0g2r2 D
r0g2g0 A
r0g2g1 A
r0g2g2 A
r0g2s0 A
r0g2s1 A
r0g2s2 D
r0s0r0 D
r0s0r1 D
r0s0r2 D
r0s0g0 D
r0s0g1 A
r0s0g2 A
r0s0s0 D
r0s0s1 D
r0s0s2 D
r0s1r0 D
r0s1r1 D
r0s1r2 D
r0s1g0 D
r0s1g1 A
r0s1g2 A
r0s1s0 D
r0s1s1 D
r0s1s2 D
r0s2r0 D
r0s2r1 D
r0s2r2 D
r0s2g0 D
r0s2g1 A
r0s2g2 A
r0s2s0 D
r0s2s1 D
r0s2s2 D
r1r0r0 D
r1r0r1 D
r1r0r2 D
r1r0g0 D
r1r0g1 A
r1r0g2 A
r1r0s0 D
r1r0s1 D
r1r0s2 D
r1r1r0 D
r1r1r1 D
r1r1r2 D
r1r1g0 D
r1r1g1 A
r1r1g2 A
r1r1s0 D
r1r1s1 D
r1r1s2 D
r1r2r0 D
r1r2r1 D
r1r2r2 D
r1r2g0 D
r1r2g1 D
r1r2g2 A
r1r2s0 D
r1r2s1 D
r1r2s2 D
r1g0r0 D
r1g0r1 D
r1g0r2 D
r1g0g0 D
r1g0g1 A
r1g0g2 A
r1g0s0 D
r1g0s1 D
r1g0s2 D
r1g1r0 A
r1g1r1 D
r1g1r2 D
r1g1g0 A
r1g1g1 A
r1g1g2 A
r1g1s0 A
r1g1s1 D
r1g1s2 A
r1g2r0 A
r1g2r1 A
r1g2r2 D
r1g2g0 A
r1g2g1 A
r1g2g2 A
r1g2s0 A
r1g2s1 A
r1g2s2 D
r1s0r0 D
r1s0r1 D
r1s0r2 D
r1s0g0 D
r1s0g1 A
r1s0g2 A
r1s0s0 D
r1s0s1 D
r1s0s2 D
r1s1r0 D
r1s1r1 D
r1s1r2 D
r1s1g0 D
r1s1g1 A
r1s1g2 A
r1s1s0 D
r1s1s1 D
r1s1s2 D
r1s2r0 D
r1s2r1 D
r1s2r2 D
r1s2g0 D
r1s2g1 A
r1s2g2 A
r1s2s0 D
r1s2s1 D
r1s2s2 D
r2r0r0 D
r2r0r1 D
r2r0r2 D
r2r0g0 D
r2r0g1 D
r2r0g2 A
r2r0s0 D
r2r0s1 D
r2r0s2 D
r2r1r0 D
r2r1r1 D
r2r1r2 D
r2r1g0 D
r2r1g1 D
r2r1g2 A
r2r1s0 D
r2r1s1 D
r2r1s2 D
r2r2r0 D
r2r2r1 D
r2r2r2 D
r2r2g0 D
r2r2g1 D
r2r2g2 A
r2r2s0 D
r2r2s1 D
r2r2s2 D
r2g0r0 D
r2g0r1 D
r2g0r2 D
r2g0g0 D
r2g0g1 D
r2g0g2 A
r2g0s0 D
r2g0s1 D
r2g0s2 D
r2g1r0 D
r2g1r1 D
r2g1r2 D
r2g1g0 D
r2g1g1 D
r2g1g2 A
r2g1s0 D
r2g1s1 D
r2g1s2 D
r2g2r0 A
r2g2r1 A
r2g2r2 D
r2g2g0 A
r2g2g1 A
r2g2g2 A
r2g2s0 A
r2g2s1 A
r2g2s2 D
r2s0r0 D
r2s0r1 D
r2s0r2 D
r2s0g0 D
r2s0g1 D
r2s0g2 A
r2s0s0 D
r2s0s1 D
r2s0s2 D
r2s1r0 D
r2s1r1 D
r2s1r2 D
r2s1g0 D
r2s1g1 D
r2s1g2 A
r2s1s0 D
r2s1s1 D
r2s1s2 D
r2s2r0 D
r2s2r1 D
r2s2r2 D
r2s2g0 D
r2s2g1 D
r2s2g2 A
r2s2s0 D
r2s2s1 D
r2s2s2 D
g0r0r0 D
g0r0r1 D
g0r0r2 D
g0r0g0 D
g0r0g1 A
g0r0g2 A
g0r0s0 D
g0r0s1 D
g0r0s2 D
g0r1r0 D
g0r1r1 D
g0r1r2 D
g0r1g0 D
g0r1g1 A
g0r1g2 A
g0r1s0 D
g0r1s1 D
g0r1s2 D
g0r2r0 D
g0r2r1 D
g0r2r2 D
g0r2g0 D
g0r2g1 D
g0r2g2 A
g0r2s0 D
g0r2s1 D
g0r2s2 D
g0g0r0 D
g0g0r1 D
g0g0r2 D
g0g0g0 D
g0g0g1 A
g0g0g2 A
g0g0s0 D
g0g0s1 A
g0g0s2 A
g0g1r0 A
g0g1r1 D
g0g1r2 D
g0g1g0 A
g0g1g1 A
g0g1g2 A
g0g1s0 A
g0g1s1 A
g0g1s2 A
g0g2r0 A
g0g2r1 A
g0g2r2 D
g0g2g0 A
g0g2g1 A
g0g2g2 A
g0g2s0 A
g0g2s1 A
g0g2s2 A
g0s0r0 D
g0s0r1 D
g0s0r2 D
g0s0g0 D
g0s0g1 A
g0s0g2 A
g0s0s0 D
g0s0s1 A
g0s0s2 A
g0s1r0 D
g0s1r1 D
g0s1r2 D
g0s1g0 A
g0s1g1 A
g0s1g2 A
g0s1s0 A
g0s1s1 A
g0s1s2 A
g0s2r0 D
g0s2r1 D
g0s2r2 D
g0s2g0 A
g0s2g1 A
g0s2g2 A
g0s2s0 A
g0s2s1 A
g0s2s2 A
g1r0r0 A
g1r0r1 D
g1r0r2 D
g1r0g0 A
g1r0g1 A
g1r0g2 A
g1r0s0 A
g1r0s1 D
g1r0s2 A
g1r1r0 D
g1r1r1 D
g1r1r2 D
g1r1g0 D
g1r1g1 A
g1r1g2 A
g1r1s0 D
g1r1s1 D
g1r1s2 D
g1r2r0 D
g1r2r1 D
g1r2r2 D
g1r2g0 D
g1r2g1 D
g1r2g2 A
g1r2s0 D
g1r2s1 D
g1r2s2 D
g1g0r0 A
g1g0r1 D
g1g0r2 D
g1g0g0 A
g1g0g1 A
g1g0g2 A
g1g0s0 A
g1g0s1 A
g1g0s2 A
g1g1r0 A
g1g1r1 D
g1g1r2 D
g1g1g0 A
g1g1g1 A
g1g1g2 A
g1g1s0 A
g1g1s1 A
g1g1s2 A
g1g2r0 A
g1g2r1 A
g1g2r2 D
g1g2g0 A
g1g2g1 A
g1g2g2 A
g1g2s0 A
g1g2s1 A
g1g2s2 A
g1s0r0 A
g1s0r1 D
g1s0r2 D
g1s0g0 A
g1s0g1 A
g1s0g2 A
g1s0s0 A
g1s0s1 A
g1s0s2 A
g1s1r0 D
g1s1r1 D
g1s1r2 D
g1s1g0 A
g1s1g1 A
g1s1g2 A
g1s1s0 A
g1s1s1 A
g1s1s2 A
g1s2r0 A
g1s2r1 D
g1s2r2 D
g1s2g0 A
g1s2g1 A
g1s2g2 A
g1s2s0 A
g1s2s1 A
g1s2s2 A
g2r0r0 A
g2r0r1 A
g2r0r2 D
g2r0g0 A
g2r0g1 A
g2r0g2 A
g2r0s0 A
g2r0s1 A
g2r0s2 D
g2r1r0 A
g2r1r1 A
g2r1r2 D
g2r1g0 A
g2r1g1 A
g2r1g2 A
g2r1s0 A
g2r1s1 A
g2r1s2 D
g2r2r0 D
g2r2r1 D
g2r2r2 D
g2r2g0 D
g2r2g1 D
g2r2g2 A
g2r2s0 D
g2r2s1 D
g2r2s2 D
g2g0r0 A
g2g0r1 A
g2g0r2 D
g2g0g0 A
g2g0g1 A
g2g0g2 A
g2g0s0 A
g2g0s1 A
g2g0s2 A
g2g1r0 A
g2g1r1 A
g2g1r2 D
g2g1g0 A
g2g1g1 A
g2g1g2 A
g2g1s0 A
g2g1s1 A
g2g1s2 A
g2g2r0 A
g2g2r1 A
g2g2r2 D
g2g2g0 A
g2g2g1 A
g2g2g2 A
g2g2s0 A
g2g2s1 A
g2g2s2 A
g2s0r0 A
g2s0r1 A
g2s0r2 D
g2s0g0 A
g2s0g1 A
g2s0g2 A
g2s0s0 A
g2s0s1 A
g2s0s2 A
g2s1r0 A
g2s1r1 A
g2s1r2 D
g2s1g0 A
g2s1g1 A
g2s1g2 A
g2s1s0 A
g2s1s1 A
g2s1s2 A
g2s2r0 D
g2s2r1 D
g2s2r2 D
g2s2g0 A
g2s2g1 A
g2s2g2 A
g2s2s0 A
g2s2s1 A
g2s2s2 A
s0r0r0 D
s0r0r1 D
s0r0r2 D
s0r0g0 D
s0r0g1 A
s0r0g2 A
s0r0s0 D
s0r0s1 D
s0r0s2 D
s0r1r0 D
s0r1r1 D
s0r1r2 D
s0r1g0 D
s0r1g1 A
s0r1g2 A
s0r1s0 D
s0r1s1 D
s0r1s2 D
s0r2r0 D
s0r2r1 D
s0r2r2 D
s0r2g0 D
s0r2g1 D
s0r2g2 A
s0r2s0 D
s0r2s1 D
s0r2s2 D
s0g0r0 D
s0g0r1 D
s0g0r2 D
s0g0g0 D
s0g0g1 A
s0g0g2 A
s0g0s0 D
s0g0s1 A
s0g0s2 A
s0g1r0 A
s0g1r1 D
s0g1r2 D
s0g1g0 A
s0g1g1 A
s0g1g2 A
s0g1s0 A
s0g1s1 A
s0g1s2 A
s0g2r0 A
s0g2r1 A
s0g2r2 D
s0g2g0 A
s0g2g1 A
s0g2g2 A
s0g2s0 A
s0g2s1 A
s0g2s2 A
s0s0r0 D
s0s0r1 D
s0s0r2 D
s0s0g0 D
s0s0g1 A
s0s0g2 A
s0s0s0 D
s0s0s1 A
s0s0s2 A
s0s1r0 D
s0s1r1 D
s0s1r2 D
s0s1g0 A
s0s1g1 A
s0s1g2 A
s0s1s0 A
s0s1s1 A
s0s1s2 A
s0s2r0 D
s0s2r1 D
s0s2r2 D
s0s2g0 A
s0s2g1 A
s0s2g2 A
s0s2s0 A
s0s2s1 A
s0s2s2 A
s1r0r0 D
s1r0r1 D
s1r0r2 D
s1r0g0 D
s1r0g1 A
s1r0g2 A
s1r0s0 D
s1r0s1 D
s1r0s2 D
s1r1r0 D
s1r1r1 D
s1r1r2 D
s1r1g0 D
s1r1g1 A
s1r1g2 A
s1r1s0 D
s1r1s1 D
s1r1s2 D
s1r2r0 D
s1r2r1 D
s1r2r2 D
s1r2g0 D
s1r2g1 D
s1r2g2 A
s1r2s0 D
s1r2s1 D
s1r2s2 D
s1g0r0 D
s1g0r1 D
s1g0r2 D
s1g0g0 A
s1g0g1 A
s1g0g2 A
s1g0s0 A
s1g0s1 A
s1g0s2 A
s1g1r0 A
s1g1r1 D
s1g1r2 D
s1g1g0 A
s1g1g1 A
s1g1g2 A
s1g1s0 A
s1g1s1 A
s1g1s2 A
s1g2r0 A
s1g2r1 A
s1g2r2 D
s1g2g0 A
s1g2g1 A
s1g2g2 A
s1g2s0 A
s1g2s1 A
s1g2s2 A
s1s0r0 D
s1s0r1 D
s1s0r2 D
s1s0g0 A
s1s0g1 A
s1s0g2 A
s1s0s0 A
s1s0s1 A
s1s0s2 A
s1s1r0 D
s1s1r1 D
s1s1r2 D
s1s1g0 A
s1s1g1 A
s1s1g2 A
s1s1s0 A
s1s1s1 A
s1s1s2 A
s1s2r0 D
s1s2r1 D
s1s2r2 D
s1s2g0 A
s1s2g1 A
s1s2g2 A
s1s2s0 A
s1s2s1 A
s1s2s2 A
s2r0r0 D
s2r0r1 D
s2r0r2 D
s2r0g0 D
s2r0g1 A
s2r0g2 A
s2r0s0 D
s2r0s1 D
s2r0s2 D
s2r1r0 D
s2r1r1 D
s2r1r2 D
s2r1g0 D
s2r1g1 A
s2r1g2 A
s2r1s0 D
s2r1s1 D
s2r1s2 D
s2r2r0 D
s2r2r1 D
s2r2r2 D
s2r2g0 D
s2r2g1 D
s2r2g2 A
s2r2s0 D
s2r2s1 D
s2r2s2 D
s2g0r0 D
s2g0r1 D
s2g0r2 D
s2g0g0 A
s2g0g1 A
s2g0g2 A
s2g0s0 A
s2g0s1 A
s2g0s2 A
s2g1r0 A
s2g1r1 D
s2g1r2 D
s2g1g0 A
s2g1g1 A
s2g1g2 A
s2g1s0 A
s2g1s1 A
s2g1s2 A
s2g2r0 A
s2g2r1 A
s2g2r2 D
s2g2g0 A
s2g2g1 A
s2g2g2 A
s2g2s0 A
s2g2s1 A
s2g2s2 A
s2s0r0 D
s2s0r1 D
s2s0r2 D
s2s0g0 A
s2s0g1 A
s2s0g2 A
s2s0s0 A
s2s0s1 A
s2s0s2 A
s2s1r0 D
s2s1r1 D
s2s1r2 D
s2s1g0 A
s2s1g1 A
s2s1g2 A
s2s1s0 A
s2s1s1 A
s2s1s2 A
s2s2r0 D
s2s2r1 D
s2s2r2 D
s2s2g0 A
s2s2g1 A
s2s2g2 A
s2s2s0 A
s2s2s1 A
s2s2s2 A
GOLDEN

echo
echo "merge-gate-sweep.test.sh: $TOTAL row(s) swept, $ORACLE_RED with a genuine describing red, $VIOLATIONS safety violation(s), $MISMATCHES golden mismatch(es)"
echo "merge-gate-sweep.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
