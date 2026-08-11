#!/usr/bin/env bash
# test/gate-transport.test.sh — the TRANSPORT contract of the merge gate.
#
# Run: bash test/gate-transport.test.sh
#
# A Quetrex build runs in an Anthropic cloud session and publishes its gate
# evidence onto a <prefix><TASK>-gates branch; /quetrex:merge fetches that
# evidence into the operator's LOCAL .quetrex/ and then merges. Everything the
# merge gate reads is therefore evidence about a commit the local checkout is
# NOT sitting on. Three defects all come from that one fact — the gate reading
# the operator's working tree where it should be reading the commit being
# merged, or reading local ledger noise as if it described that commit:
#
#   1. GATE 3 resolved the verify CHAIN from $QDIR/verify.json — the working
#      tree file, i.e. the BASE branch's version during a `gh pr merge`. A PR
#      that renames/replaces a verify command was permanently unmergeable: the
#      gate demanded a ledger entry for a command the merged code no longer
#      defines, and the only way to update the local verify.json was to land
#      the PR. (verify-gate.sh already reads the COMMITTED blob at a pinned sha
#      for requiredEnv, for exactly this class of reason — the two gates
#      disagreed about what the chain even is.)
#
#   2. GATE 3 took the LAST ledger entry per command, full stop. verify-gate.sh
#      is a Stop/SubagentStop hook with NO fast-skip: every turn end runs the
#      chain and appends entries pinned to the LOCAL checkout's HEAD. One Stop
#      firing between /quetrex:merge's fetch (step 2) and `gh pr merge` (step 4)
#      shadowed every transported green with a line pinned to local main — and
#      the merge was denied as STALE, blaming the cloud build for the operator's
#      own machine destroying the evidence it had just fetched.
#
#   3. The architect's plan never reached the operator's checkout at all, so
#      GATE 5 (file ownership) and the plan's security_review_required were
#      dead on the only supported execution route. The transport contract now
#      brings .quetrex/plan/<TASK>.json and .quetrex/state.json home alongside
#      the other five artifacts (cloud-build-routine.md pushes them,
#      /quetrex:merge fetches them). This file asserts the gate's HALF of that
#      contract: both gates become live when the plan lands, the "no plan ->
#      skip" branch is preserved for genuinely plan-less units, and a LEFTOVER
#      plan from another task cannot silently govern an unrelated merge.
#
# Everything here runs the real hook against throwaway fixture repos with a
# mocked `gh pr view`, the same approach test/merge-gate.test.sh uses.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Same override contract as test/merge-gate.test.sh: point the suite at the
# factory copy of the gate to prove the fix in the one armed repos execute.
HOOK="${QX_MERGE_GATE_HOOK:-$REPO_ROOT/.claude/hooks/merge-gate.sh}"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — merge-gate.sh is jq-mandatory, nothing to test"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-transport.XXXXXX")"
MOCKBIN="$(mktemp -d "${TMPDIR:-/tmp}/gate-transport-mockbin.XXXXXX")"
cleanup() { rm -rf "$TMPROOT" "$MOCKBIN"; }
trap cleanup EXIT

# --- mock `gh` — only `gh pr view [<id>] [--repo x] --json headRefOid,baseRefOid`
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

# The literal merge command, assembled at runtime so this test file does not
# itself contain the token sequence this repo's own PreToolUse gate matches on.
GH_MERGE="$(printf 'gh pr mer%s' 'ge') 123 --squash"

is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"\|MERGE GATE'; }

# run_gate <repo> <pr_head_sha> <pr_base_sha> — invoke the hook for a
# `gh pr merge` vector with the PR's head/base fully under the test's control.
# stderr is folded in because the no-jq fallback blocks via exit 2 + stderr.
run_gate() {
  local repo="$1" head="$2" base="$3" payload
  payload="$(jq -cn --arg cmd "$GH_MERGE" --arg cwd "$repo" \
    '{tool_input:{command:$cmd},cwd:$cwd}')"
  printf '%s' "$payload" | env PATH="$MOCKBIN:$PATH" \
    MOCK_GH_PR_VIEW_SHA="$head" MOCK_GH_PR_BASE_SHA="$base" GH_REPO="" \
    CLAUDE_PROJECT_DIR="$repo" "$HOOK" 2>&1
}

# --- fixture builders --------------------------------------------------------
# mk_repo <name> <chain_json_at_base> <chain_json_at_head> [track_verify_json]
#
# Builds a repo shaped like a real armed one at merge time:
#   commit A on `main`  — README.md, src/app.js, .quetrex/verify.json (TRACKED,
#                         because .gitignore un-ignores exactly that file), and
#                         the working tree LEFT on main. This is where the
#                         operator's checkout sits during `gh pr merge`.
#   commit B on `pr`    — modifies README.md, src/app.js and verify.json. This
#                         is the PR head: the commit actually being merged.
# Echoes "<repo> <shaA> <shaB>".
mk_repo() {
  local name="$1" chain_a="$2" chain_b="$3" track="${4:-1}"
  local d="$TMPROOT/$name"
  mkdir -p "$d/.quetrex" "$d/src"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Fixture"
  printf '.quetrex/*\n!.quetrex/verify.json\n' > "$d/.gitignore"
  printf 'base readme\n' > "$d/README.md"
  printf 'export const one = 1;\n' > "$d/src/app.js"
  printf '%s' "$chain_a" > "$d/.quetrex/verify.json"
  git -C "$d" add .gitignore README.md src/app.js >/dev/null 2>&1
  if [ "$track" = "1" ]; then
    git -C "$d" add -f .quetrex/verify.json >/dev/null 2>&1
  fi
  git -C "$d" commit -q -m "chore: base"
  local a; a="$(git -C "$d" rev-parse HEAD)"

  git -C "$d" checkout -q -b pr
  printf 'head readme\n' > "$d/README.md"
  printf 'export const one = 1;\nexport const two = 2;\n' > "$d/src/app.js"
  printf '%s' "$chain_b" > "$d/.quetrex/verify.json"
  git -C "$d" add README.md src/app.js >/dev/null 2>&1
  if [ "$track" = "1" ]; then
    git -C "$d" add -f .quetrex/verify.json >/dev/null 2>&1
  fi
  git -C "$d" commit -q -m "feat: head"
  local b; b="$(git -C "$d" rev-parse HEAD)"

  # Put the operator's checkout back on main — the whole point: the working
  # tree holds the BASE's verify.json, not the commit being merged.
  git -C "$d" checkout -q main
  printf '%s' "$chain_a" > "$d/.quetrex/verify.json"

  printf '%s %s %s' "$d" "$a" "$b"
}

# Transported evidence, exactly the shapes the cloud publishes.
write_verdict() {  # write_verdict <repo> <sha> [nativeSecurityReview]
  jq -cn --arg sha "$2" --arg nsr "${3:-not_available_in_env}" \
    '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:$nsr}}' \
    > "$1/.quetrex/review-verdict.json"
}
write_sec_clean() {  # write_sec_clean <repo> <head_sha>
  jq -cn --arg sha "$2" \
    '{task:"T-1",base:"main",head_sha:$sha,reviewed_files:3,verdict:"PASS",findings:[]}' \
    > "$1/.quetrex/security-findings.json"
}
ledger_reset() { : > "$1/.quetrex/verify-ledger.jsonl"; }
ledger_add() {  # ledger_add <repo> <cmd> <sha> <exit>
  jq -cn --arg cmd "$2" --arg sha "$3" --arg cwd "$1" --argjson ex "$4" \
    '{ts:"2026-01-01T00:00:00Z",cmd:$cmd,cwd:$cwd,sha:$sha,exit:$ex,tail:""}' \
    >> "$1/.quetrex/verify-ledger.jsonl"
}

OLD_CHAIN='{"verify":["npm test"]}'
NEW_CHAIN='{"verify":["npm run check"]}'
SAME_CHAIN='{"verify":["npm run check"]}'

# =============================================================================
# SECTION 1 — GATE 3 must resolve the verify CHAIN from the commit being
#             merged, not from the operator's working tree.
# =============================================================================
read -r R1 A1 B1 <<<"$(mk_repo r1 "$OLD_CHAIN" "$NEW_CHAIN")"
write_verdict "$R1" "$B1"
ledger_reset "$R1"
ledger_add "$R1" "npm run check" "$B1" 0

# DELIBERATE BEHAVIOR CHANGE, recorded rather than quietly re-anchored.
# This assertion used to require that REPLACING the chain (drop "npm test", add
# "npm run check") merges. It no longer does, and that is the point: SEC-1 proved a
# branch could de-gate ITSELF by shrinking its own verify[] — the removed command
# stopped being required while every survivor was green, so a measurably red suite
# reached the base branch with the gate satisfied. The effective chain is now the
# UNION of base and head, so a dropped command must still be proven green for this
# commit.
#
# A rename is a drop plus an add, so it is denied until the old command is proven at
# this commit — the expand -> migrate -> contract shape this repo already requires of
# database migrations. The half of the original fix that mattered is preserved and
# asserted at 1a-add below: a chain change is no longer read from the operator's
# WORKING TREE, so a task that legitimately edits verify.json is not unmergeable.
OUT="$(run_gate "$R1" "$B1" "$A1")"
if is_deny "$OUT"; then
  pass "1a: dropping a command from the chain is DENIED while it is unproven — a branch cannot de-gate itself (SEC-1)"
else
  fail "1a: a branch dropped 'npm test' from its own chain and merged anyway — SEC-1 de-gating is open [got: $(printf '%s' "$OUT" | head -c 260)]"
fi

# 1a-add — the half of the original fix that must survive: a task that legitimately
# EDITS its verify chain is not permanently unmergeable. Adding a command tightens
# the gate immediately; it does not lock the PR out. Without this, the SEC-1 union
# could have been "over-corrected" into refusing every verify.json change, which was
# the original defect (GATE 3 read the chain from the operator's working tree).
read -r RADD AADD BADD <<<"$(mk_repo radd '{"verify":["npm test"]}' '{"verify":["npm test","npm run check"]}')"
write_verdict "$RADD" "$BADD"
ledger_reset "$RADD"
ledger_add "$RADD" "npm test" "$BADD" 0
ledger_add "$RADD" "npm run check" "$BADD" 0
OUT="$(run_gate "$RADD" "$BADD" "$AADD")"
if is_deny "$OUT"; then
  fail "1a-add: ADDING a command to the chain blocked the merge — the lower bound over-corrected into refusing every verify.json edit [got: $(printf '%s' "$OUT" | head -c 200)]"
else
  pass "1a-add: adding a command to the chain still merges when both are proven — editing verify.json is not a lockout"
fi

# The complement, and the proof this is not simply 'trust whatever the ledger
# says': the ledger proves the OLD command green at the PR head, but the PR
# head's own verify.json no longer defines it. The NEW command never ran.
ledger_reset "$R1"
ledger_add "$R1" "npm test" "$B1" 0
OUT="$(run_gate "$R1" "$B1" "$A1")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'npm run check'; then
  pass "1b: the chain enforced is the merged commit's own — a ledger proving only the base's old command is denied"
else
  fail "1b: expected a denial naming the merged commit's chain command [got: $(printf '%s' "$OUT" | head -c 260)]"
fi

# Backwards compatibility: a repo whose .quetrex/verify.json is UNTRACKED has
# no committed blob to read at any sha. The working tree stays the source of
# truth there — this must not become a silent 'no chain resolvable' fallback.
read -r R1U A1U B1U <<<"$(mk_repo r1u "$OLD_CHAIN" "$OLD_CHAIN" 0)"
write_verdict "$R1U" "$B1U"
ledger_reset "$R1U"
ledger_add "$R1U" "npm run check" "$B1U" 0   # green for a command the chain does NOT list
OUT="$(run_gate "$R1U" "$B1U" "$A1U")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'npm test'; then
  pass "1c: untracked verify.json still resolves the chain from the working tree (no committed blob to read)"
else
  fail "1c: expected the working-tree chain to still govern when verify.json is untracked [got: $(printf '%s' "$OUT" | head -c 260)]"
fi

# =============================================================================
# SECTION 2 — GATE 3 must judge the commit being merged, not the last thing a
#             local Stop cycle happened to append.
# =============================================================================
read -r R2 A2 B2 <<<"$(mk_repo r2 "$SAME_CHAIN" "$SAME_CHAIN")"
write_verdict "$R2" "$B2"

# 2a — baseline: exactly the transported cloud ledger, nothing local.
ledger_reset "$R2"; ledger_add "$R2" "npm run check" "$B2" 0
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT"; then
  fail "2a: transported green pinned to the PR head should ALLOW [got: $(printf '%s' "$OUT" | head -c 260)]"
else
  pass "2a: transported green pinned to the PR head allows the merge"
fi

# 2b — THE DEFECT: one local Stop cycle appends a green pinned to local main
#      after the fetch. The transported evidence is still there and still
#      describes the commit being merged.
ledger_add "$R2" "npm run check" "$A2" 0
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT"; then
  fail "2b: a local Stop cycle's green (pinned to local main) must not shadow the transported green [got: $(printf '%s' "$OUT" | head -c 260)]"
else
  pass "2b: a local Stop cycle's ledger line pinned to local main does not shadow the transported evidence"
fi

# 2c — the same, but the operator's own checkout is RED (main broken, missing
#      env, whatever). That is a fact about main, not about the PR head.
ledger_reset "$R2"; ledger_add "$R2" "npm run check" "$B2" 0; ledger_add "$R2" "npm run check" "$A2" 1
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT"; then
  fail "2c: a RED local Stop cycle on another commit must not deny a PR head proven green [got: $(printf '%s' "$OUT" | head -c 260)]"
else
  pass "2c: a red local cycle pinned to another commit does not deny a PR head proven green"
fi

# 2d — NOT WEAKENED: a later red for the SAME commit being merged still denies.
ledger_reset "$R2"; ledger_add "$R2" "npm run check" "$B2" 0; ledger_add "$R2" "npm run check" "$B2" 1
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'exit 1'; then
  pass "2d: a later RED for the merged commit itself still denies (latest evidence for that commit governs)"
else
  fail "2d: expected a denial for a red pinned to the merged commit [got: $(printf '%s' "$OUT" | head -c 260)]"
fi

# 2e — NOT WEAKENED: a red for the merged commit is not rescued by a LATER
#      green pinned to some other commit.
ledger_reset "$R2"; ledger_add "$R2" "npm run check" "$B2" 1; ledger_add "$R2" "npm run check" "$A2" 0
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT"; then
  pass "2e: a red for the merged commit is not laundered by a later green for a different commit"
else
  fail "2e: expected a denial — the merged commit's own latest evidence is red"
fi

# 2f — NOT WEAKENED: no evidence for the merged commit at all is still STALE.
ledger_reset "$R2"; ledger_add "$R2" "npm run check" "$A2" 0
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'STALE'; then
  pass "2f: a ledger with no entry for the merged commit is still denied as STALE"
else
  fail "2f: expected a STALE denial [got: $(printf '%s' "$OUT" | head -c 260)]"
fi

# 2g — NOT WEAKENED: a chain command with no ledger entry at all still denies.
ledger_reset "$R2"; ledger_add "$R2" "some other command" "$B2" 0
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'never ran'; then
  pass "2g: a chain command absent from the ledger is still denied as never ran"
else
  fail "2g: expected a never-ran denial [got: $(printf '%s' "$OUT" | head -c 260)]"
fi

# 2i — NOT WEAKENED: an unreadable ledger still fails CLOSED. The old
#      implementation keyed a jq object by `.cmd` and therefore ABORTED on an
#      entry that had none, which is what produced the denial. The rescoped
#      evaluation matches on `.cmd` instead and would have ignored such a line,
#      so the check is now explicit — this asserts it did not get lost.
ledger_reset "$R2"; ledger_add "$R2" "npm run check" "$B2" 0
jq -cn '{ts:"2026-01-01T00:00:02Z",cwd:"x",sha:"y",exit:0,tail:""}' >> "$R2/.quetrex/verify-ledger.jsonl"
OUT="$(run_gate "$R2" "$B2" "$A2")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'malformed'; then
  pass "2i: a ledger entry with no 'cmd' still fails closed instead of being silently ignored"
else
  fail "2i: expected a malformed-ledger denial [got: $(printf '%s' "$OUT" | head -c 300)]"
fi

# 2h — the artifact-only rescue survives the rescope. Repo where the ONLY thing
#      between the proven commit and the merged commit is a .quetrex/ change
#      (the documented self-invalidation escape hatch), PLUS a local Stop line
#      pinned to an unrelated commit appended after it — which under the old
#      'last entry per command' rule would have buried the rescuable green.
R2H="$TMPROOT/r2h"
mkdir -p "$R2H/.quetrex"
git -C "$R2H" init -q -b main
git -C "$R2H" config user.email "test@example.com"
git -C "$R2H" config user.name "Fixture"
printf '.quetrex/*\n!.quetrex/verify.json\n' > "$R2H/.gitignore"
printf 'x\n' > "$R2H/code.txt"
printf '%s' "$SAME_CHAIN" > "$R2H/.quetrex/verify.json"
git -C "$R2H" add .gitignore code.txt >/dev/null 2>&1
git -C "$R2H" add -f .quetrex/verify.json >/dev/null 2>&1
git -C "$R2H" commit -q -m "chore: base"
A2H="$(git -C "$R2H" rev-parse HEAD)"
git -C "$R2H" checkout -q -b pr
printf '{"note":"artifact only"}' > "$R2H/.quetrex/qa-report.json"
git -C "$R2H" add -f .quetrex/qa-report.json >/dev/null 2>&1
git -C "$R2H" commit -q -m "chore: commit a control-plane artifact"
B2H="$(git -C "$R2H" rev-parse HEAD)"
git -C "$R2H" checkout -q main
# An unrelated third commit, so the local Stop line points at a real object
# that is NOT in the A2H..B2H range.
printf 'y\n' > "$R2H/code.txt"
git -C "$R2H" commit -q -am "chore: unrelated main commit"
C2H="$(git -C "$R2H" rev-parse HEAD)"
write_verdict "$R2H" "$A2H"
write_sec_clean "$R2H" "$A2H"
ledger_reset "$R2H"; ledger_add "$R2H" "npm run check" "$A2H" 0; ledger_add "$R2H" "npm run check" "$C2H" 0
OUT="$(run_gate "$R2H" "$B2H" "$A2H")"
if is_deny "$OUT"; then
  fail "2h: the artifact-only-range rescue must survive a later local ledger line at an unrelated commit [got: $(printf '%s' "$OUT" | head -c 300)]"
else
  pass "2h: an artifact-only-range green is still honoured even when a local Stop line for an unrelated commit was appended after it"
fi

# =============================================================================
# SECTION 3 — the transported plan makes GATE 5 and PLAN_SEC live.
# =============================================================================
read -r R3 A3 B3 <<<"$(mk_repo r3 "$SAME_CHAIN" "$SAME_CHAIN")"
write_verdict "$R3" "$B3"     # nativeSecurityReview = not_available_in_env (the cloud reality)
ledger_reset "$R3"; ledger_add "$R3" "npm run check" "$B3" 0

write_plan() {  # write_plan <repo> <task> <base_sha_json> <sec_required> <owns_json>
  mkdir -p "$1/.quetrex/plan"
  jq -n --arg task "$2" --argjson base "$3" --argjson sec "$4" --argjson owns "$5" \
    '{task:$task,route:"COMPLEX",base_sha:$base,summary:"t",
      workstreams:[{id:"ws-a",agent:"developer",owns:$owns,depends_on:[]}],
      ownership:{"src/app.js":"ws-a"},
      security_review_required:$sec}' > "$1/.quetrex/plan/$2.json"
}
write_state() { jq -cn --arg t "$2" '{task:$t}' > "$1/.quetrex/state.json"; }

# 3a — no plan on disk (the pre-contract reality, and a genuinely plan-less
#      TRIVIAL/SIMPLE unit): neutral diff, no security artifact -> ALLOW.
rm -rf "$R3/.quetrex/plan" "$R3/.quetrex/state.json"
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT"; then
  fail "3a: a plan-less unit must still merge (no plan -> skip) [got: $(printf '%s' "$OUT" | head -c 260)]"
else
  pass "3a: 'no plan -> skip' is preserved for genuinely plan-less units"
fi

# 3b — THE DEFECT: the SAME state, with the plan transported home. The plan set
#      security_review_required:true, so a merge with no security artifact must
#      now be refused. Before the plan came home this was structurally
#      unreachable on the cloud route.
write_state "$R3" "T-1"
write_plan "$R3" "T-1" 'null' 'true' '["src/**","README.md"]'
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'security_review_required'; then
  pass "3b: a transported plan's security_review_required:true is live at the merge boundary"
else
  fail "3b: expected a denial citing the plan's forced security review [got: $(printf '%s' "$OUT" | head -c 300)]"
fi

# 3c — with the security artifact supplied, the ownership map is what governs.
#      This plan's lanes do NOT cover README.md, which the PR changed.
write_sec_clean "$R3" "$B3"
write_plan "$R3" "T-1" 'null' 'true' '["src/**"]'
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'NO workstream owns'; then
  pass "3c: GATE 5 enforces the transported ownership map against the PR diff"
else
  fail "3c: expected an unowned-file denial from GATE 5 [got: $(printf '%s' "$OUT" | head -c 300)]"
fi

# 3d — the clean cloud build: every changed file owned, security artifact clean
#      and pinned to the PR head. .quetrex/** is exempt, so the transported
#      verify.json change does not need a lane.
write_plan "$R3" "T-1" 'null' 'true' '["src/**","README.md"]'
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT"; then
  fail "3d: a fully covered cloud build should ALLOW [got: $(printf '%s' "$OUT" | head -c 300)]"
else
  pass "3d: a transported plan whose lanes cover the whole PR diff allows the merge"
fi

# 3e — the plan is bound to the work it describes. A LEFTOVER plan from another
#      task (its approved base is not an ancestor of the commit being merged)
#      must never silently govern this diff — before the contract, plans never
#      landed locally at all, so this failure mode is new and fails closed.
git -C "$R3" checkout -q -b other "$A3"
printf 'unrelated\n' > "$R3/other.txt"
git -C "$R3" add other.txt >/dev/null 2>&1
git -C "$R3" commit -q -m "chore: unrelated line of work"
X3="$(git -C "$R3" rev-parse HEAD)"
git -C "$R3" checkout -q main
write_plan "$R3" "T-1" "\"$X3\"" 'true' '["src/**","README.md"]'
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT" && printf '%s' "$OUT" | grep -q 'base_sha'; then
  pass "3e: a leftover plan whose approved base is not an ancestor of the merged commit is refused, not applied"
else
  fail "3e: expected an ESCALATE denial for a foreign plan [got: $(printf '%s' "$OUT" | head -c 300)]"
fi

# 3f — the real cloud case: base_sha IS the approved base the PR was cut from.
write_plan "$R3" "T-1" "\"$A3\"" 'true' '["src/**","README.md"]'
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT"; then
  fail "3f: a plan stamped with the approved base must govern normally [got: $(printf '%s' "$OUT" | head -c 300)]"
else
  pass "3f: a plan whose base_sha is an ancestor of the merged commit governs normally"
fi

# 3g — state.json comes home too, and is what picks the governing plan when
#      more than one is on disk.
write_plan "$R3" "T-9" 'null' 'false' '["nothing/**"]'
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT"; then
  fail "3g: state.json must select T-1's plan out of two on disk [got: $(printf '%s' "$OUT" | head -c 300)]"
else
  pass "3g: the transported state.json names the task, so the right plan governs when several are on disk"
fi

# 3h — and without state.json, two plans still escalate rather than guess.
rm -f "$R3/.quetrex/state.json"
OUT="$(run_gate "$R3" "$B3" "$A3")"
if is_deny "$OUT"; then
  pass "3h: two plans and no state.json still refuses to guess which map governs"
else
  fail "3h: expected an escalation when several plans exist and nothing names the task"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "gate-transport.test.sh: all checks passed"
else
  echo "gate-transport.test.sh: FAILURES above"
fi
exit "$FAIL"
