#!/usr/bin/env bash
# test/merge-command.test.sh — behavioural test for .claude/commands/merge.md.
#
# Run: bash test/merge-command.test.sh
#
# WHY THIS EXISTS. merge.md is an INSTRUCTION file, so the temptation is to
# assert that it "says the right thing". That is exactly how four defects lived
# in it: every one was a path that was written down and never executed. So this
# file does not read merge.md for reassurance — it EXTRACTS the actual programs
# and command templates out of it and RUNS them, against throwaway git
# fixtures and against the REAL hooks in .claude/hooks/.
#
# The four defects it pins down, each proved by running the OLD form and
# watching it fail before the NEW form is asserted green:
#
#   A. THE MERGE COMMAND DENIED ITSELF. merge.md §4 used to say
#      `gh pr merge "$PR_NUM" --repo "$SLUG" --squash --delete-branch`. A
#      PreToolUse hook is handed the command string BEFORE the shell expands
#      it, and Claude Code keeps no shell state between Bash calls, so
#      merge-gate.sh received the literal 8 characters `$PR_NUM`, ran
#      `gh pr view $PR_NUM --json headRefOid,baseRefOid`, got nothing, and —
#      correctly fail-closed — DENIED, blaming gh authentication. The one
#      command the whole transport exists to enable could never reach its own
#      gates. Fixed by making §4 a literal-substitution template.
#
#   B. SUBSTRING PR MATCHING. §1 selected the PR with
#      `headRefName.toLowerCase().includes(task)`, and
#      `"claude/qdm-10-manifest".includes("qdm-1")` is true. From a project's
#      tenth task onward every single-digit id was ambiguous — or, once its own
#      PR had closed, resolved silently to the WRONG PR. Fixed with a
#      whole-segment (delimiter-bounded) match.
#
#   C. quetrex-spec/<TASK> WAS NEVER DELETED. task-build §6A pushes a spec
#      branch carrying the approved plan on every dispatch; nothing in the
#      engine ever removed it. And the gates-branch delete that DID exist was
#      itself dead: `git push origin --delete` runs after §5b switches the
#      checkout to main, and enforce-branch.sh denies every `git push` made on
#      main. Fixed by deleting both refs via `gh api --method DELETE` (a REST
#      ref delete, which both hooks allow) with the names spelled out.
#
#   D. THE EPIC TERMINUS. An epic's integration→main PR needs gate evidence at
#      <prefix><EPIC>-gates. merge.md never distinguished an epic, so the
#      operator got the generic "merge it yourself on GitHub" remedy. Fixed:
#      §1 detects the epic, §2 gives it its own remedy, and the transport path
#      itself is proved here to work unchanged for an epic gates branch.
#
#   E. (cross-agent contract) The plan never came home. §2 fetched five
#      artifacts; merge-gate.sh's GATE 5 (file ownership) and the plan's
#      security_review_required need .quetrex/plan/<TASK>.json, and the state
#      needs .quetrex/state.json. §2 now fetches seven.
#
# Fixture pattern (throwaway git repo + mock `gh` on PATH + the real hook
# script) follows test/merge-gate.test.sh and test/plan-stamp.test.sh.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE_MD="$REPO_ROOT/.claude/commands/merge.md"
MERGE_GATE="$REPO_ROOT/plugins/quetrex-factory/scripts/merge-gate.sh"
ENFORCE_BRANCH="$REPO_ROOT/plugins/quetrex-factory/scripts/enforce-branch.sh"
DENY_GUARD="$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh"

if [ ! -f "$MERGE_MD" ]; then
  echo "NOT OK - merge.md not found at $MERGE_MD"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — every hook in this system is jq-mandatory"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — merge.md builds all its JSON with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-merge-cmd.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Extractors. Everything asserted below is pulled OUT of merge.md and executed;
# nothing is retyped here. Assertion 0 of each section proves the extractor
# actually extracted something, so a renamed heading turns the section red
# instead of passing vacuously on an empty string.
# ---------------------------------------------------------------------------

# fence_after <heading-substring> <fence-index> — print the Nth fenced block
# (1-based) that appears after the first line containing <heading-substring>.
fence_after() {
  awk -v h="$1" -v want="$2" '
    !seen && index($0, h) { seen = 1; next }
    !seen { next }
    /^```/ { if (inb) { inb = 0; n++; if (n == want) exit } else { inb = 1; if (n + 1 == want) next } ; next }
    inb && n + 1 == want { print }
  ' "$MERGE_MD"
}

# node_prog <first-line-marker> — pull a `node -e '<<program>>'` program out of
# a bash fence. The program starts on the line AFTER the one carrying the
# marker (every such line in merge.md ends with `node -e '`) and ends on the
# first following line whose first non-space characters are `})'`.
node_prog() {
  awk -v m="$1" '
    !seen && index($0, m) { seen = 1; next }
    !seen { next }
    /^[[:space:]]*\}\)'"'"'/ { print "  })"; exit }
    { print }
  ' "$MERGE_MD"
}

# ===========================================================================
# SECTION A — §4's merge command reaches its own gate
# ===========================================================================
#
# The template lives in a ```text fence because it is NOT a script to paste:
# the operator substitutes <PR_NUM> and <OWNER/REPO> as literal text. Pull it
# out, substitute fixture values, and hand the result to the REAL
# merge-gate.sh as a PreToolUse payload.

MERGE_TEMPLATE="$(fence_after '## 4. Merge' 1 | grep -m1 'pr merge' || true)"

if [ -n "$MERGE_TEMPLATE" ]; then
  pass "A0: extracted §4's merge command template: $MERGE_TEMPLATE"
else
  fail "A0: could not extract a merge command template from §4 of merge.md — every assertion in section A would pass vacuously"
fi

# The whole point: no shell expansion left in the text a hook has to parse.
if [ -n "$MERGE_TEMPLATE" ] && ! printf '%s' "$MERGE_TEMPLATE" | grep -q '[$`]'; then
  pass "A1: §4's template carries no \$variable or backtick — the hook sees literal text"
else
  fail "A1: §4's template still contains a shell expression ($MERGE_TEMPLATE) — merge-gate.sh reads this BEFORE expansion and will deny"
fi

# --- fixture: an armed repo + a faithful mock gh ---------------------------
GATE_FIX="$WORK/gate-repo"
MOCKBIN="$WORK/mockbin"
mkdir -p "$GATE_FIX" "$MOCKBIN"

# A faithful `gh pr view`: the REAL one exits non-zero when the positional
# argument is not a PR number/URL/branch it can resolve. That is precisely what
# turned the unexpanded `$PR_NUM` into a denial, so the mock must reproduce it
# rather than answering every argument alike. Also logs its argv so the
# resolved identifier is assertable directly, not merely inferred from the
# allow/deny outcome. `gh pr merge` is never actually executed by a PreToolUse
# hook, so it needs no implementation.
cat > "$MOCKBIN/gh" <<'MOCKGH'
#!/bin/sh
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
  shift 2
  if [ -n "${MOCK_GH_ARGV_LOG:-}" ]; then
    : > "$MOCK_GH_ARGV_LOG"
    for a in "$@"; do printf '%s\n' "$a" >> "$MOCK_GH_ARGV_LOG"; done
  fi
  seen_id=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --json|--repo|-R) shift 2; continue ;;
      --*) shift; continue ;;
      *)
        seen_id=1
        case "$1" in
          ''|*[!0-9]*)
            echo "could not resolve to a PullRequest with the number of $1" >&2
            exit 1 ;;
        esac
        shift ;;
    esac
  done
  # No positional id and no current branch to infer one from: real gh fails.
  if [ "$seen_id" -eq 0 ]; then
    echo "no pull requests found for branch" >&2
    exit 1
  fi
  printf '{"headRefOid":"%s","baseRefOid":"%s"}' "${MOCK_GH_HEAD:-}" "${MOCK_GH_BASE:-}"
  exit 0
fi
echo "mock gh: unhandled: $*" >&2
exit 1
MOCKGH
chmod +x "$MOCKBIN/gh"

git -C "$GATE_FIX" init -q -b main
git -C "$GATE_FIX" config user.email "test@example.com"
git -C "$GATE_FIX" config user.name "Fixture"
git -C "$GATE_FIX" remote add origin "https://github.com/glori-holdings/quetrex-base.git"
echo "fixture" > "$GATE_FIX/README.md"
mkdir -p "$GATE_FIX/.quetrex/plan"
printf '{"branchPrefix":"claude/"}' > "$GATE_FIX/.quetrex/project.json" 2>/dev/null
git -C "$GATE_FIX" add README.md
git -C "$GATE_FIX" commit -q -m "chore: fixture commit"
GATE_SHA="$(git -C "$GATE_FIX" rev-parse HEAD)"

# A fully green evidence set, so the ONLY thing that can deny the fixed command
# is the PR-resolution failure this section is about. Same shapes
# test/merge-gate.test.sh writes.
printf '{"verify":["true"]}' > "$GATE_FIX/.quetrex/verify.json"
jq -cn --arg sha "$GATE_SHA" --arg cwd "$GATE_FIX" \
  '{ts:"2026-01-01T00:00:00Z",cmd:"true",cwd:$cwd,sha:$sha,exit:0,tail:""}' \
  > "$GATE_FIX/.quetrex/verify-ledger.jsonl"
jq -cn --arg sha "$GATE_SHA" \
  '{verdict:"AUTO_MERGE",sha:$sha,confirmed:[],inputs:{nativeSecurityReview:"clean"}}' \
  > "$GATE_FIX/.quetrex/review-verdict.json"
jq -cn --arg sha "$GATE_SHA" \
  '{task:"DEA-1",base:"main",head_sha:$sha,reviewed_files:1,verdict:"PASS",findings:[]}' \
  > "$GATE_FIX/.quetrex/security-findings.json"
jq -cn '{task:"DEA-1"}' > "$GATE_FIX/.quetrex/state.json"
jq -cn '{task:"DEA-1",security_review_required:false,ownership:{"README.md":"dev-a"},workstreams:[{name:"dev-a",owns:["README.md"]}]}' \
  > "$GATE_FIX/.quetrex/plan/DEA-1.json"

# run_gate <command> [argv_log] — hand COMMAND to the real merge-gate.sh.
run_gate() {
  local cmd="$1" argv_log="${2:-}"
  jq -cn --arg cmd "$cmd" --arg cwd "$GATE_FIX" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}' \
    | env PATH="$MOCKBIN:$PATH" \
          MOCK_GH_HEAD="$GATE_SHA" MOCK_GH_BASE="$GATE_SHA" \
          MOCK_GH_ARGV_LOG="$argv_log" GH_REPO="" \
          CLAUDE_PROJECT_DIR="$GATE_FIX" bash "$MERGE_GATE" 2>&1
}

# --- A2: the OLD form. RED: this is the defect, reproduced against the real
#     hook. If this ever stops denying, the mechanism changed and the rest of
#     this section is measuring nothing.
OLD_CMD='gh pr merge "$PR_NUM" --repo "$SLUG" --squash --delete-branch'
OLD_OUT="$(run_gate "$OLD_CMD" "$WORK/argv-old.log")"
if printf '%s' "$OLD_OUT" | grep -q "could not resolve the PR's head commit"; then
  pass "A2: the OLD \"\$PR_NUM\" phrasing is denied by the real merge-gate.sh (could not resolve the PR's head commit) — the defect, reproduced"
else
  fail "A2: the OLD \"\$PR_NUM\" phrasing was NOT denied for PR resolution — the reproduction is broken, so A3/A4 prove nothing. Got: $OLD_OUT"
fi
if [ -f "$WORK/argv-old.log" ] && grep -qxF '$PR_NUM' "$WORK/argv-old.log"; then
  pass "A2b: merge-gate.sh really passed the literal text \$PR_NUM to gh pr view"
else
  fail "A2b: expected the hook to hand gh pr view the literal \$PR_NUM; argv was: $(tr '\n' ' ' < "$WORK/argv-old.log" 2>/dev/null)"
fi

# --- A3/A4: the NEW form, built from merge.md's own template.
NEW_CMD="$(printf '%s' "$MERGE_TEMPLATE" \
  | sed -e 's#<PR_NUM>#97#' -e 's#<OWNER/REPO>#glori-holdings/quetrex-base#')"
NEW_OUT="$(run_gate "$NEW_CMD" "$WORK/argv-new.log")"

if printf '%s' "$NEW_OUT" | grep -q "could not resolve the PR's head commit"; then
  fail "A3: merge.md's own §4 template STILL cannot resolve its PR through merge-gate.sh: $NEW_OUT"
else
  pass "A3: merge.md's §4 template ('$NEW_CMD') is no longer denied for PR resolution"
fi

if [ -f "$WORK/argv-new.log" ] && grep -qxF '97' "$WORK/argv-new.log" \
   && grep -qxF 'glori-holdings/quetrex-base' "$WORK/argv-new.log"; then
  pass "A3b: the hook resolved a NUMERIC pr id (97) and the literal repo slug from merge.md's template"
else
  fail "A3b: hook did not see a literal pr id + repo; argv was: $(tr '\n' ' ' < "$WORK/argv-new.log" 2>/dev/null)"
fi

# The whole evidence set is green, so the fixed command must be ALLOWED
# outright — the hook emits nothing at all.
if [ -z "$NEW_OUT" ]; then
  pass "A4: with green evidence, merge.md's §4 command is ALLOWED by merge-gate.sh (no output at all)"
else
  fail "A4: green evidence but merge.md's §4 command was still denied: $NEW_OUT"
fi

# --- A5: contract E — GATE 5 is only live because §2 brings the plan home.
#     Remove the plan and the ownership gate goes silent; that is the branch
#     that used to be the ONLY reachable outcome on the cloud route.
mv "$GATE_FIX/.quetrex/plan/DEA-1.json" "$WORK/plan-DEA-1.json"
if [ -z "$(run_gate "$NEW_CMD")" ]; then
  pass "A5: with no plan/<TASK>.json the gate still allows — i.e. GATE 5 is a no-op without the transported plan (why §2 must fetch it)"
else
  fail "A5: expected the no-plan case to be a silent skip, not a denial"
fi
mv "$WORK/plan-DEA-1.json" "$GATE_FIX/.quetrex/plan/DEA-1.json"

# ===========================================================================
# SECTION B — §1 resolves the PR by whole segment, not by substring
# ===========================================================================

MATCHER="$(node_prog 'PR_JSON" | node -e ')"
if [ -n "$MATCHER" ] && printf '%s' "$MATCHER" | grep -q 'headRefName'; then
  pass "B0: extracted §1's PR matcher from merge.md ($(printf '%s' "$MATCHER" | wc -l | tr -d ' ') lines)"
else
  fail "B0: could not extract §1's PR matcher — section B would pass vacuously"
fi

# The fixture the audit reproduced against: task 1 and task 10 of one project.
PRS_BOTH='[{"number":11,"headRefName":"claude/QDM-1-manifest"},{"number":12,"headRefName":"claude/QDM-10-manifest"}]'
PRS_TEN_ONLY='[{"number":12,"headRefName":"claude/QDM-10-manifest"}]'
PRS_EXACT='[{"number":13,"headRefName":"claude/QDM-1"}]'
PRS_EPIC='[{"number":20,"headRefName":"claude/QDM-5"}]'

# match <json> <task> -> prints the selected PR number, or "ERR<exit>"
match() {
  local out
  out="$(printf '%s' "$1" | node -e "$MATCHER" "$2" 2>/dev/null)" || { printf 'ERR%s' "$?"; return; }
  printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).number)))'
}

# The OLD matcher, retyped here on purpose — it is the thing being disproved,
# so it must not come from merge.md.
match_old() {
  local out
  out="$(printf '%s' "$1" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let a; try{a=JSON.parse(s)}catch{process.exit(1)}
      const task=process.argv[1].toLowerCase();
      const hit=a.filter(p=>p.headRefName.toLowerCase().includes(task));
      if(hit.length!==1){ process.exit(2) }
      process.stdout.write(String(hit[0].number));
    })' "$2" 2>/dev/null)" || { printf 'ERR%s' "$?"; return; }
  printf '%s' "$out"
}

# --- RED first: the old matcher really does pick the wrong PR.
if [ "$(match_old "$PRS_TEN_ONLY" QDM-1)" = "12" ]; then
  pass "B1: the OLD .includes() matcher resolves QDM-1 to PR #12 (claude/QDM-10-manifest) — the wrong PR, reproduced"
else
  fail "B1: could not reproduce the substring collision with the old matcher — B2/B3 then prove nothing"
fi
if [ "$(match_old "$PRS_BOTH" QDM-1)" = "ERR2" ]; then
  pass "B1b: the OLD matcher sees 2 candidates for QDM-1 and blocks — the ambiguity half of the defect"
else
  fail "B1b: expected the old matcher to find 2 candidates for QDM-1 in the both-open fixture"
fi

# --- GREEN: merge.md's matcher.
if [ "$(match "$PRS_TEN_ONLY" QDM-1)" = "ERR2" ]; then
  pass "B2: QDM-1 does NOT match claude/QDM-10-manifest — no wrong-PR merge"
else
  fail "B2: QDM-1 still matched claude/QDM-10-manifest (got '$(match "$PRS_TEN_ONLY" QDM-1)')"
fi
if [ "$(match "$PRS_BOTH" QDM-1)" = "11" ]; then
  pass "B3: with both PRs open, QDM-1 resolves to #11 (claude/QDM-1-manifest)"
else
  fail "B3: QDM-1 did not resolve to #11 with both open (got '$(match "$PRS_BOTH" QDM-1)')"
fi
if [ "$(match "$PRS_BOTH" QDM-10)" = "12" ]; then
  pass "B4: QDM-10 resolves to #12 — the longer id is not broken by the boundary rule"
else
  fail "B4: QDM-10 did not resolve to #12 (got '$(match "$PRS_BOTH" QDM-10)')"
fi
if [ "$(match "$PRS_EXACT" QDM-1)" = "13" ]; then
  pass "B5: a branch that is exactly <prefix><TASK> still matches (end-of-string boundary)"
else
  fail "B5: claude/QDM-1 no longer matches QDM-1 (got '$(match "$PRS_EXACT" QDM-1)')"
fi
if [ "$(match "$PRS_EPIC" QDM-5)" = "20" ]; then
  pass "B6: an epic's integration branch (claude/QDM-5) resolves like any other head"
else
  fail "B6: the epic integration branch did not resolve (got '$(match "$PRS_EPIC" QDM-5)')"
fi
if [ "$(match "$PRS_BOTH" QDM-2)" = "ERR2" ]; then
  pass "B7: a task with no open PR resolves to nothing rather than to a neighbour"
else
  fail "B7: QDM-2 matched something in a fixture that has no QDM-2 branch"
fi

# ===========================================================================
# SECTION C — §5d actually deletes the spec and gates refs
# ===========================================================================

# §5d now opens with a DISCOVERY fence (ls-remote for every sha-suffixed evidence ref,
# including superseded ones from earlier dispatches) and the literal delete commands follow
# in the second fence. Assert the discovery step exists — without it the operator cannot
# know which refs to name — then take the deletes from fence 2.
DISCOVER_BLOCK="$(fence_after '### 5d.' 1)"
if printf '%s' "$DISCOVER_BLOCK" | grep -q 'ls-remote'; then
  pass "C0-a: §5d lists the sha-suffixed evidence refs before deleting, so superseded ones are found too"
else
  fail "C0-a: §5d has no ls-remote discovery step — with sha-suffixed names the operator cannot know which refs to delete"
fi
CLEANUP_BLOCK="$(fence_after '### 5d.' 2)"
if [ -n "$CLEANUP_BLOCK" ]; then
  pass "C0: extracted §5d's literal delete commands"
else
  fail "C0: could not extract §5d's delete commands — section C would pass vacuously"
fi

if printf '%s' "$CLEANUP_BLOCK" | grep -q 'quetrex-spec/'; then
  pass "C1: §5d deletes the quetrex-spec/<TASK> branch (it was never deleted by anything in the engine)"
else
  fail "C1: §5d still never removes quetrex-spec/<TASK>"
fi
if printf '%s' "$CLEANUP_BLOCK" | grep -q -- '-gates'; then
  pass "C1b: §5d deletes the gates branch too"
else
  fail "C1b: §5d no longer removes the gates branch"
fi

# --- fixture: an armed repo sitting on main with a real bare origin ---------
DEL_ORIGIN="$WORK/origin.git"
DEL_FIX="$WORK/del-repo"
git init -q --bare -b main "$DEL_ORIGIN"
git -C "$WORK" clone -q "$DEL_ORIGIN" del-repo 2>/dev/null
git -C "$DEL_FIX" config user.email "test@example.com"
git -C "$DEL_FIX" config user.name "Fixture"
mkdir -p "$DEL_FIX/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$DEL_FIX/.quetrex/project.json" 2>/dev/null
echo "fixture" > "$DEL_FIX/README.md"
git -C "$DEL_FIX" add README.md
git -C "$DEL_FIX" commit -q -m "chore: fixture"
git -C "$DEL_FIX" push -q origin main
# Seed the refs under the names §5d's worked example actually uses: sha-suffixed, because
# each dispatch publishes its own refs rather than replacing the previous ones.
git -C "$DEL_FIX" push -q origin "HEAD:refs/heads/quetrex-spec/DEA-1-4b71e08"
git -C "$DEL_FIX" push -q origin "HEAD:refs/heads/claude/DEA-1-gates-9f3a12c"
git -C "$DEL_FIX" branch -q "claude/DEA-1-gates-9f3a12c" 2>/dev/null
git -C "$DEL_FIX" branch -q "claude/DEA-1-manifest" 2>/dev/null
git -C "$DEL_FIX" switch -q main

# The commands, taken from merge.md, with <REPO_ROOT> substituted.
mapfile_cmds() { printf '%s\n' "$CLEANUP_BLOCK" | grep -E '^(git|gh) ' | sed "s#<REPO_ROOT>#$DEL_FIX#g"; }
CMDS="$(mapfile_cmds)"
CMD_COUNT="$(printf '%s\n' "$CMDS" | grep -c .)"
if [ "$CMD_COUNT" -ge 4 ]; then
  pass "C2: §5d spells out $CMD_COUNT delete commands"
else
  fail "C2: expected at least 4 delete commands in §5d, extracted $CMD_COUNT"
fi

# hook_verdict <hook> <command> -> "" when allowed, the deny reason otherwise.
hook_verdict() {
  jq -cn --arg cmd "$2" --arg cwd "$DEL_FIX" \
    '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}' \
    | env CLAUDE_PROJECT_DIR="$DEL_FIX" bash "$1" 2>&1
}

# --- RED: the OLD `git push --delete` spelling, on main, is denied outright.
#     §5b switches to main immediately before §5d, so this is not a corner
#     case — it is the only state §5d ever runs in.
OLD_DEL="git -C $DEL_FIX push -q origin --delete claude/DEA-1-gates"
if hook_verdict "$ENFORCE_BRANCH" "$OLD_DEL" | grep -q 'Never commit or push on main'; then
  pass "C3: the OLD 'git push origin --delete' is denied by enforce-branch.sh on main — the gates-branch delete never ran either"
else
  fail "C3: could not reproduce the push-on-main denial; C4 then proves nothing"
fi

# --- GREEN: every command merge.md now names passes both PreToolUse hooks.
DENIED=""
while IFS= read -r c; do
  [ -n "$c" ] || continue
  for h in "$ENFORCE_BRANCH" "$DENY_GUARD"; do
    v="$(hook_verdict "$h" "$c")"
    if printf '%s' "$v" | grep -q 'permissionDecision'; then
      DENIED="$DENIED\n  $(basename "$h") denied: $c"
    fi
  done
done <<EOF
$CMDS
EOF
if [ "$CMD_COUNT" -lt 4 ]; then
  # Zero commands would make the loop above pass by asserting nothing — the
  # exact vacuity this file exists to avoid.
  fail "C4: only $CMD_COUNT command(s) extracted, so the hook check ran against (almost) nothing"
elif [ -z "$DENIED" ]; then
  pass "C4: every §5d delete command is allowed by enforce-branch.sh AND deny-guard.sh, standing on main"
else
  fail "C4: §5d commands still denied by a PreToolUse hook:$(printf '%b' "$DENIED")"
fi

# --- and they actually delete. `gh api --method DELETE repos/<slug>/git/refs/
#     heads/<branch>` is mapped onto the fixture's bare origin so the REST form
#     is executed for real rather than assumed to work.
cat > "$MOCKBIN/gh-api-runner" <<MOCKAPI
#!/bin/sh
# usage: gh-api-runner <ref-path>   (e.g. repos/o/r/git/refs/heads/claude/x)
ref="\${1#*/git/refs/}"
git -C "$DEL_ORIGIN" update-ref -d "refs/\$ref"
MOCKAPI
chmod +x "$MOCKBIN/gh-api-runner"

while IFS= read -r c; do
  case "$c" in
    "git "*) sh -c "$c" >/dev/null 2>&1 ;;
    "gh api --method DELETE "*)
      ref_path="${c##* }"
      "$MOCKBIN/gh-api-runner" "$ref_path" >/dev/null 2>&1 ;;
  esac
done <<EOF
$CMDS
EOF

REMAINING="$(git -C "$DEL_ORIGIN" for-each-ref --format='%(refname)' | grep -v '^refs/heads/main$' || true)"
if [ -z "$REMAINING" ]; then
  pass "C5: after running §5d verbatim, origin carries only refs/heads/main — the spec and gates branches are really gone"
else
  fail "C5: refs survived §5d on origin: $(printf '%s' "$REMAINING" | tr '\n' ' ')"
fi
if ! git -C "$DEL_FIX" show-ref --verify --quiet refs/heads/claude/DEA-1-gates; then
  pass "C5b: the local gates branch is gone too"
else
  fail "C5b: the local gates branch survived §5d"
fi

# ===========================================================================
# SECTION D — the epic terminus, and SECTION E — the plan comes home
# ===========================================================================

EPIC_PROG="$(node_prog 'IS_EPIC="$(printf ')"
if [ -n "$EPIC_PROG" ] && printf '%s' "$EPIC_PROG" | grep -q 'children'; then
  pass "D0: extracted §1's epic detector"
else
  fail "D0: could not extract §1's epic detector — section D would pass vacuously"
fi

is_epic() { printf '%s' "$1" | node -e "$EPIC_PROG" 2>/dev/null; }

if [ "$(is_epic '{"type":"project","status":"in_progress"}')" = "1" ]; then
  pass "D1: a type=project task is detected as an epic"
else
  fail "D1: type=project was not detected as an epic (got '$(is_epic '{"type":"project"}')')"
fi
if [ "$(is_epic '{"type":"feature","children":[{"id":"QDM-5.1"}]}')" = "1" ]; then
  pass "D2: a task carrying children is detected as an epic even if type says otherwise"
else
  fail "D2: children[] did not trigger epic detection"
fi
if [ "$(is_epic '{"type":"feature","status":"pr_ready"}')" = "0" ]; then
  pass "D3: an ordinary unit is not mistaken for an epic"
else
  fail "D3: a plain feature was misdetected as an epic"
fi
if [ "$(is_epic '{}')" = "0" ] && [ "$(is_epic 'not json at all')" = "0" ]; then
  pass "D4: an unreachable board (empty/garbage payload) degrades to 'not an epic' rather than crashing the block"
else
  fail "D4: the epic detector does not survive an empty or unparseable task payload"
fi

# The epic must get its OWN remedy, not the generic "merge it yourself on
# GitHub" — that message is the one thing the workflow forbids.
if awk '/^## 2\. Bring the gate evidence home/,/^## 3\./' "$MERGE_MD" | grep -q 'IS_EPIC=1'; then
  pass "D5: §2 gives an epic with no gates branch its own remedy"
else
  fail "D5: §2 still sends an epic to the generic no-evidence message"
fi
if awk '/^### 5d\./,/^### 5e\./' "$MERGE_MD" | grep -qi 'epic'; then
  pass "D6: §5d tears down an epic's children refs as well as its own"
else
  fail "D6: §5d does not mention the epic's leftover child refs"
fi

# --- SECTION E / D7: run §2's transport for real, for an EPIC gates branch.
FETCH_BLOCK="$(fence_after '## 2. Bring the gate evidence home' 1)"
if printf '%s' "$FETCH_BLOCK" | grep -q 'gates-head'; then
  pass "E0: extracted §2's fetch block"
else
  fail "E0: could not extract §2's fetch block — section E would pass vacuously"
fi

T_ORIGIN="$WORK/t-origin.git"
T_FIX="$WORK/t-repo"
git init -q --bare -b main "$T_ORIGIN"
git -C "$WORK" clone -q "$T_ORIGIN" t-repo 2>/dev/null
git -C "$T_FIX" config user.email "test@example.com"
git -C "$T_FIX" config user.name "Fixture"
echo "fixture" > "$T_FIX/README.md"
git -C "$T_FIX" add README.md
git -C "$T_FIX" commit -q -m "chore: fixture"
git -C "$T_FIX" push -q origin main
INTEGRATION_SHA="$(git -C "$T_FIX" rev-parse HEAD)"

# Build the gates branch the cloud routine publishes — seven artifacts, per the
# cross-agent contract (five, plus state.json and plan/<TASK>.json).
GB="$WORK/gates-build"
git -C "$WORK" clone -q "$T_ORIGIN" gates-build 2>/dev/null
git -C "$GB" config user.email "test@example.com"
git -C "$GB" config user.name "Fixture"
git -C "$GB" switch -q --orphan "claude/QDM-5-gates"
git -C "$GB" rm -rq --cached . 2>/dev/null
rm -f "$GB/README.md"
mkdir -p "$GB/.quetrex/plan"
printf '%s\n' "$INTEGRATION_SHA" > "$GB/.quetrex/gates-head"
jq -cn '{verdict:"AUTO_MERGE"}'                > "$GB/.quetrex/review-verdict.json"
jq -cn '{units:1}'                             > "$GB/.quetrex/qa-report.json"
jq -cn '{verdict:"PASS",findings:[]}'          > "$GB/.quetrex/security-findings.json"
jq -cn '{ts:"2026-01-01T00:00:00Z",cmd:"true",exit:0}' > "$GB/.quetrex/verify-ledger.jsonl"
jq -cn '{task:"QDM-5",phase:"pr_ready"}'       > "$GB/.quetrex/state.json"
jq -cn '{task:"QDM-5",ownership:{"README.md":"dev-a"}}' > "$GB/.quetrex/plan/QDM-5.json"
git -C "$GB" add -f .quetrex/gates-head .quetrex/review-verdict.json .quetrex/qa-report.json \
  .quetrex/security-findings.json .quetrex/verify-ledger.jsonl .quetrex/state.json \
  ".quetrex/plan/QDM-5.json"
git -C "$GB" commit -q -m "gates: QDM-5"
git -C "$GB" push -q origin "claude/QDM-5-gates"

# The facts file §1 writes, for the epic.
mkdir -p "$T_FIX/.quetrex"
{
  printf 'TASK=%q\n' "QDM-5"
  printf 'REPO_ROOT=%q\n' "$T_FIX"
  printf 'IS_EPIC=%q\n' "1"
  printf 'PR_SHA=%q\n' "$INTEGRATION_SHA"
  printf 'GATES_BRANCH=%q\n' "claude/QDM-5-gates"
} > "$T_FIX/.quetrex/merge-facts.env"

FETCH_OUT="$(cd "$T_FIX" && bash -c "$FETCH_BLOCK" 2>&1)"

MISSING=""
for f in verify-ledger.jsonl review-verdict.json qa-report.json security-findings.json gates-head state.json plan/QDM-5.json; do
  [ -s "$T_FIX/.quetrex/$f" ] || MISSING="$MISSING $f"
done
if [ -z "$MISSING" ]; then
  pass "E1: §2 brought all SEVEN artifacts home — including state.json and plan/QDM-5.json (the cross-agent contract)"
else
  fail "E1: §2 did not fetch:$MISSING  (output: $FETCH_OUT)"
fi
if [ "$(tr -d '[:space:]' < "$T_FIX/.quetrex/gates-head")" = "$INTEGRATION_SHA" ]; then
  pass "D7: an EPIC's gates branch (claude/QDM-5-gates) transports exactly like a unit's, pinned to the integration head"
else
  fail "D7: the epic gates branch did not transport its pin"
fi

# The facts file must not be left behind: it names a PR that no longer exists.
if awk '/^### 5e\./,0' "$MERGE_MD" | grep -q 'merge-facts.env'; then
  pass "E2: §5e removes .quetrex/merge-facts.env along with the transported artifacts"
else
  fail "E2: merge-facts.env is never cleaned up — a stale PR number survives into the next merge"
fi
if awk '/^### 5e\./,0' "$MERGE_MD" | grep -q 'plan/\$TASK.json'; then
  pass "E3: §5e removes the transported plan too"
else
  fail "E3: the transported plan is left behind after the merge"
fi

b="$(basename "${BASH_SOURCE[0]}")"
if [ "$FAIL" -eq 0 ]; then
  echo "$b: all checks passed"
  exit 0
fi
echo "$b: FAILURES above"
exit 1
