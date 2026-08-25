#!/usr/bin/env bash
# test/merge-child-ids.test.sh — behavioural test for the epic-child half of
# .claude/commands/merge.md.
#
# Run: bash test/merge-child-ids.test.sh
#
# WHY THIS EXISTS. `/quetrex:merge <child>` is the REAPER of an epic's DAG: it
# is the only thing in the engine that sets a child to `merged`, and `merged`
# is the only status that satisfies a dependency (task-build.md §B.3, and
# quetrex-api's is-unblocked). Two defects in merge.md meant that reaper could
# never run, so every epic stranded after its first wave:
#
#   1. THE ARGUMENT VALIDATOR REJECTED EVERY CHILD ID. §1 validated with
#      `^[A-Za-z][A-Za-z0-9]*-[0-9]+$`, which has no room for the `.child`
#      suffix. The server is authoritative on the shape — quetrex-kanban's
#      src/lib/task-ref.ts carries
#          IDENTIFIER_RE = /^([A-Za-z][A-Za-z0-9]*)-(\d+)(?:\.(\d+))?$/
#      and src/lib/dto.ts renders it with
#          childIdent(n, cn, code) => cn == null ? `${code}-${n}`
#                                                : `${code}-${n}.${cn}`
#      so a child is `CODE-N.C` (e.g. QDM-2.1), exactly one level deep. Every
#      `/quetrex:merge QDM-2.1` died on line 8 of the command with "Not a
#      Quetrex task id".
#
#   2. AND THEN THE PR MATCHER WOULD HAVE PICKED THE WRONG PR. §1 builds its
#      branch-matching regex by string-concatenating the id, on the written
#      assumption that "a validated id carries no metacharacter". A child id
#      carries a literal `.` — a regex WILDCARD — so `qdm-2.1` matched
#      `claude/qdm-231-manifest`. Merely widening the validator would have
#      turned a hard stop into a silent wrong-PR merge. The id has to be
#      escaped before it becomes a pattern.
#
#      The same section also has to stop a PARENT id from selecting one of its
#      CHILDREN's PRs: `.` is non-alphanumeric, so the old right-hand boundary
#      `[^a-z0-9]` let `qdm-2` match `claude/qdm-2.1-manifest`. With the epic's
#      own integration PR not yet open and one child PR still open, that is a
#      single unambiguous hit on the WRONG PR — the exact failure the
#      whole-segment rule was introduced to kill, reached through the child
#      form instead of the two-digit form.
#
#   3. THE WORKTREE TEARDOWN WAS AN UNBOUNDED SUBSTRING MATCH. §5c removed any
#      worktree whose path merely CONTAINED the task id:
#          case "$wt" in *"$TASK"*) git worktree remove "$wt" --force ;;
#      so `/quetrex:merge QDM-1` force-removed QDM-10's worktree, and every
#      uncommitted file in it, with no warning. `--force` means git's own
#      "contains modified or untracked files" refusal does not save you.
#
# Nothing below is asserted from the TEXT of merge.md. Every section EXTRACTS
# the real program out of the file and RUNS it — the validator is eval'd, the
# matcher is fed real `gh pr list` JSON through node, and the teardown is run
# against real `git worktree`s holding real uncommitted files. Each defect is
# reproduced RED first (against the old form, retyped here on purpose so it
# cannot drift silently) before the fixed form is asserted green.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MERGE_MD="$REPO_ROOT/.claude/commands/merge.md"

if [ ! -f "$MERGE_MD" ]; then
  echo "NOT OK - merge.md not found at $MERGE_MD"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — merge.md builds all its JSON with node"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git is not installed — the teardown section drives real worktrees"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-merge-child.XXXXXX")"
cleanup() { chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# ===========================================================================
# SECTION A — §1's argument validator accepts an epic child id
# ===========================================================================
#
# Extract the real compound statement (the `grep -qE ... || { echo ...; exit 1; }`)
# and EVAL it with $TASK set. Its exit status is the verdict, so this is the
# command's own accept/reject decision, not a restatement of it.

VALIDATE_BLOCK="$(awk '
  !p && index($0, "$TASK\" | grep -qE") { p = 1 }
  p { print }
  p && index($0, "exit 1; }") { exit }
' "$MERGE_MD")"

if [ -n "$VALIDATE_BLOCK" ] && printf '%s' "$VALIDATE_BLOCK" | grep -q 'grep -qE'; then
  pass "A0: extracted §1's task-id validator from merge.md ($(printf '%s\n' "$VALIDATE_BLOCK" | grep -c .) line(s))"
else
  fail "A0: could not extract §1's validator — every assertion in section A would pass vacuously"
fi

# validate <id> -> exit 0 accepted, non-zero rejected. Runs merge.md's own code.
validate() { ( TASK="$1"; eval "$VALIDATE_BLOCK" ) >/dev/null 2>&1; }

# The OLD validator, retyped here on purpose: it is the thing being disproved,
# so it must not be sourced from the file it is disproving.
validate_old() { printf '%s' "$1" | grep -qE '^[A-Za-z][A-Za-z0-9]*-[0-9]+$'; }

# --- RED first: the old validator really did reject every child id.
if ! validate_old 'QDM-2.1'; then
  pass "A1: the OLD validator rejects QDM-2.1 — the defect, reproduced (an epic's reaper could never be invoked)"
else
  fail "A1: the OLD validator accepted QDM-2.1, so the reproduction is broken and A2 proves nothing"
fi
if validate_old 'QDM-2'; then
  pass "A1b: the OLD validator did accept the plain form QDM-2 — so the child suffix was the whole of the rejection"
else
  fail "A1b: the OLD validator rejected even QDM-2 — the reproduction is not measuring what it claims"
fi

# --- GREEN: merge.md's validator now takes both forms.
if validate 'QDM-2.1'; then
  pass "A2: merge.md accepts the epic-child id QDM-2.1"
else
  fail "A2: merge.md STILL rejects QDM-2.1 — /quetrex:merge cannot reap an epic child, so no DAG can drain"
fi
if validate 'QDM-2' && validate 'DEA-1' && validate 'A1B2-345'; then
  pass "A3: the plain form still validates (QDM-2, DEA-1, A1B2-345) — no assertion weakened"
else
  fail "A3: merge.md now rejects a plain <CODE>-<number> id — the fix broke the common case"
fi
if validate 'QDM-12.34'; then
  pass "A3b: multi-digit child ids validate (QDM-12.34)"
else
  fail "A3b: QDM-12.34 was rejected"
fi

# --- and it is still a validator, not a rubber stamp. The comment in §1 is a
#     load-bearing claim: the matcher below builds a regex from this string,
#     and §2/§5 build ref names and PATHS from it.
BAD_OK=""
for bad in \
  'QDM' 'QDM-' '-1' 'QDM-2.' 'QDM-.1' 'QDM-2.1.3' 'QDM-2.x' 'QDM_2' \
  '1QDM-2' 'QDM-2-3' '../QDM-1' 'QDM-2/../..' 'QDM-2*' 'QDM-2$x' ''
do
  if validate "$bad"; then BAD_OK="$BAD_OK '$bad'"; fi
done
if [ -z "$BAD_OK" ]; then
  pass "A4: the widened validator still rejects every malformed id (grandchildren, path traversal, globs, empty)"
else
  fail "A4: the validator now accepts malformed ids:$BAD_OK — a bad id reaches the branch matcher and the rm/ref paths"
fi

# --- A5: agree with the SERVER, which is authoritative on the identifier shape.
#     Conditional: quetrex-kanban is a sibling checkout, not a dependency.
KANBAN_REF="/Users/barnent1/Projects/quetrex-kanban/src/lib/task-ref.ts"
if [ -f "$KANBAN_REF" ]; then
  SERVER_RE="$(sed -n 's/^const IDENTIFIER_RE = \(.*\);$/\1/p' "$KANBAN_REF" | head -1)"
  if [ -n "$SERVER_RE" ]; then
    DISAGREE=""
    for id in 'QDM-2' 'QDM-2.1' 'QDM-12.34' 'DEA-1' 'QDM' 'QDM-' 'QDM-2.' 'QDM-2.1.3' 'QDM-2.x' '../QDM-1' ''; do
      if validate "$id"; then mine=1; else mine=0; fi
      theirs="$(node -e 'process.stdout.write(('"$SERVER_RE"').test(process.argv[1])?"1":"0")' "$id" 2>/dev/null || echo X)"
      [ "$mine" = "$theirs" ] || DISAGREE="$DISAGREE '$id'(cmd=$mine,server=$theirs)"
    done
    if [ -z "$DISAGREE" ]; then
      pass "A5: merge.md's validator agrees with the server's own IDENTIFIER_RE ($SERVER_RE) on every probe"
    else
      fail "A5: merge.md's validator disagrees with the server's IDENTIFIER_RE on:$DISAGREE"
    fi
  else
    echo "note: could not read IDENTIFIER_RE out of $KANBAN_REF — A5 not run"
  fi
else
  echo "note: quetrex-kanban checkout not present — A5 (agreement with the server's IDENTIFIER_RE) not run"
fi

# ===========================================================================
# SECTION B — §1's PR matcher treats the child id's `.` as a literal
# ===========================================================================

# Pull the `node -e '<program>'` matcher out of §1's bash fence: it starts on
# the line AFTER the one ending `PR_JSON" | node -e '` and ends on the first
# line whose first non-space characters are `})'`.
MATCHER="$(awk '
  !seen && index($0, "PR_JSON\" | node -e ") { seen = 1; next }
  !seen { next }
  /^[[:space:]]*\}\)'"'"'/ { print "  })"; exit }
  { print }
' "$MERGE_MD")"

if [ -n "$MATCHER" ] && printf '%s' "$MATCHER" | grep -q 'headRefName'; then
  pass "B0: extracted §1's PR matcher ($(printf '%s\n' "$MATCHER" | grep -c .) lines)"
else
  fail "B0: could not extract §1's PR matcher — section B would pass vacuously"
fi

# match <prs-json> <task> -> the selected PR number, or ERR<exit> when the
# matcher refuses (its own contract: exit 2 when the hit count is not exactly 1).
match() {
  local out
  out="$(printf '%s' "$1" | node -e "$MATCHER" "$2" 2>/dev/null)" || { printf 'ERR%s' "$?"; return; }
  printf '%s' "$out" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).number)))'
}

# The OLD matcher, retyped: whole-segment boundaries, but the id concatenated
# straight into the pattern and `.` allowed as a right-hand boundary — i.e.
# merge.md exactly as it stood once the validator was widened.
match_old() {
  local out
  out="$(printf '%s' "$1" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let a; try{a=JSON.parse(s)}catch{process.exit(1)}
      const task=process.argv[1].toLowerCase();
      const re=new RegExp("(^|[^a-z0-9])"+task+"([^a-z0-9]|$)");
      const hit=a.filter(p=>re.test(String(p.headRefName).toLowerCase()));
      if(hit.length!==1){ process.exit(2) }
      process.stdout.write(String(hit[0].number));
    })' "$2" 2>/dev/null)" || { printf 'ERR%s' "$?"; return; }
  printf '%s' "$out"
}

# One epic (QDM-2) with children, alongside an unrelated three-digit sibling.
PRS_WILDCARD='[{"number":31,"headRefName":"claude/QDM-231-manifest"}]'
PRS_CHILD='[{"number":41,"headRefName":"claude/QDM-2.1-manifest"},{"number":42,"headRefName":"claude/QDM-2.11-manifest"}]'
PRS_PARENT_VS_CHILD='[{"number":41,"headRefName":"claude/QDM-2.1-manifest"}]'
PRS_EPIC='[{"number":41,"headRefName":"claude/QDM-2.1-manifest"},{"number":50,"headRefName":"claude/QDM-2"}]'
PRS_TEN='[{"number":11,"headRefName":"claude/QDM-1-manifest"},{"number":12,"headRefName":"claude/QDM-10-manifest"}]'

# --- RED first: the unescaped `.` really is a wildcard.
if [ "$(match_old "$PRS_WILDCARD" QDM-2.1)" = "31" ]; then
  pass "B1: the OLD matcher resolves QDM-2.1 to PR #31 (claude/QDM-231-manifest) — the '.' wildcard, reproduced: a single, confident, WRONG hit"
else
  fail "B1: could not reproduce the '.'-as-wildcard collision — B3 then proves nothing (got '$(match_old "$PRS_WILDCARD" QDM-2.1)')"
fi
if [ "$(match_old "$PRS_PARENT_VS_CHILD" QDM-2)" = "41" ]; then
  pass "B2: the OLD matcher resolves the PARENT id QDM-2 to its CHILD's PR #41 (claude/QDM-2.1-manifest) — '.' passed as a segment boundary"
else
  fail "B2: could not reproduce the parent→child mis-resolution (got '$(match_old "$PRS_PARENT_VS_CHILD" QDM-2)')"
fi

# --- GREEN: merge.md's matcher.
if [ "$(match "$PRS_WILDCARD" QDM-2.1)" = "ERR2" ]; then
  pass "B3: QDM-2.1 does NOT match claude/QDM-231-manifest — the '.' is escaped into a literal"
else
  fail "B3: QDM-2.1 still matched claude/QDM-231-manifest (got '$(match "$PRS_WILDCARD" QDM-2.1)')"
fi
if [ "$(match "$PRS_CHILD" QDM-2.1)" = "41" ]; then
  pass "B4: QDM-2.1 resolves to its own PR #41 (claude/QDM-2.1-manifest) and not to the QDM-2.11 sibling"
else
  fail "B4: QDM-2.1 did not resolve to #41 (got '$(match "$PRS_CHILD" QDM-2.1)') — the reaper cannot find a child's PR"
fi
if [ "$(match "$PRS_CHILD" QDM-2.11)" = "42" ]; then
  pass "B5: QDM-2.11 resolves to #42 — the longer child id is not swallowed by its prefix"
else
  fail "B5: QDM-2.11 did not resolve to #42 (got '$(match "$PRS_CHILD" QDM-2.11)')"
fi
if [ "$(match "$PRS_PARENT_VS_CHILD" QDM-2)" = "ERR2" ]; then
  pass "B6: the parent id QDM-2 does NOT resolve to its child's PR — an epic terminus can never merge a child by mistake"
else
  fail "B6: QDM-2 still resolved to a child's PR (got '$(match "$PRS_PARENT_VS_CHILD" QDM-2)')"
fi
if [ "$(match "$PRS_EPIC" QDM-2)" = "50" ]; then
  pass "B7: with a child PR open alongside it, the epic's integration PR (claude/QDM-2) still resolves unambiguously to #50"
else
  fail "B7: the epic's own integration PR did not resolve while a child PR was open (got '$(match "$PRS_EPIC" QDM-2)')"
fi
# The pre-existing whole-segment guarantee must survive the escaping change.
if [ "$(match "$PRS_TEN" QDM-1)" = "11" ] && [ "$(match "$PRS_TEN" QDM-10)" = "12" ]; then
  pass "B8: the two-digit whole-segment rule is intact — QDM-1→#11, QDM-10→#12"
else
  fail "B8: the escaping change broke the existing whole-segment match (QDM-1→'$(match "$PRS_TEN" QDM-1)', QDM-10→'$(match "$PRS_TEN" QDM-10)')"
fi

# ===========================================================================
# SECTION C — §1 derives a child's gates/spec refs
# ===========================================================================
#
# The reaper needs `<prefix><CHILD>-gates` and `quetrex-spec/<CHILD>` to exist
# as names before §2 can fetch anything. Execute the two derivation lines.

# The refs are no longer NAMED by string, they are DISCOVERED: each carries the sha of what
# it holds, so a rebuild publishes new refs beside the old ones instead of replacing them.
# What still has to be right for a child id like QDM-2.1 is the SEARCH PATTERN — a pattern
# that mangles the dot finds nothing, and §2 then fetches no evidence at all. So extract the
# ls-remote patterns and expand them for a child.
PATTERNS="$(grep -oE "['\"][^'\"]*\\$\{TASK\}[^'\"]*-\*['\"]|['\"]quetrex-spec/\\$\{TASK\}-\*['\"]" "$MERGE_MD" | tr -d "'\"" | sort -u)"
if [ "$(printf '%s\n' "$PATTERNS" | grep -c .)" -ge 2 ]; then
  pass "C0: extracted §1's gates/spec ref DISCOVERY patterns"
else
  fail "C0: expected at least 2 ref-discovery patterns in merge.md, found $(printf '%s\n' "$PATTERNS" | grep -c .): $PATTERNS"
fi
EXPANDED="$( TASK="QDM-2.1" BRANCH_PREFIX="claude/" bash -c 'while IFS= read -r pat; do [ -n "$pat" ] || continue; eval "printf \"%s \" \"$pat\""; done' <<< "$PATTERNS" )"
case "$EXPANDED" in
  *"claude/QDM-2.1-gates-*"*)
    case "$EXPANDED" in
      *"quetrex-spec/QDM-2.1-*"*)
        pass "C1: a child id expands to claude/QDM-2.1-gates-* and quetrex-spec/QDM-2.1-* — the ref namespaces its cloud routine actually publishes into" ;;
      *) fail "C1: the spec-branch discovery pattern does not cover child QDM-2.1 — got '$EXPANDED'" ;;
    esac ;;
  *)
    fail "C1: child ref discovery patterns produced '$EXPANDED'" ;;
esac

# ===========================================================================
# SECTION D — §5c's worktree teardown is bounded, and runs on real worktrees
# ===========================================================================

WT_FN="$(awk '
  index($0, "end quetrex:exec-block qx_remove_task_worktrees") { exit }
  p { print }
  index($0, "quetrex:exec-block qx_remove_task_worktrees") { p = 1 }
' "$MERGE_MD")"

if [ -n "$WT_FN" ] && printf '%s' "$WT_FN" | grep -q 'qx_remove_task_worktrees()'; then
  pass "D0: extracted §5c's qx_remove_task_worktrees from merge.md ($(printf '%s\n' "$WT_FN" | grep -c .) lines)"
else
  fail "D0: could not extract a qx_remove_task_worktrees function from merge.md — section D would pass vacuously"
fi
if [ -n "$WT_FN" ] && printf '%s\n' "$WT_FN" | bash -n /dev/stdin 2>/dev/null; then
  pass "D0b: the extracted function is syntactically valid bash"
else
  fail "D0b: the extracted teardown function does not parse: $(printf '%s\n' "$WT_FN" | bash -n /dev/stdin 2>&1 | head -3)"
fi
# It must actually be CALLED — a function nobody invokes tears down nothing.
if grep -qE '^[[:space:]]*qx_remove_task_worktrees "\$REPO_ROOT" "\$TASK"' "$MERGE_MD"; then
  pass "D0c: §5 invokes qx_remove_task_worktrees \"\$REPO_ROOT\" \"\$TASK\" — it is not dead code"
else
  fail "D0c: qx_remove_task_worktrees is defined but never invoked in merge.md"
fi

# --- fixture: one repo whose OWN directory name carries a task id (so the
#     main-worktree guard is exercised), plus five linked worktrees.
WT_NAMES="QDM-1-manifest QDM-10-manifest QDM-2-integration QDM-2.1-manifest QDM-231-manifest"

make_wt_fixture() {   # make_wt_fixture <dir-name> -> echoes the repo root
  local root="$WORK/$1/QDM-7-root" n i=0
  rm -rf "$WORK/$1"
  mkdir -p "$root"
  git -C "$root" init -q -b main
  git -C "$root" config user.email "test@example.com"
  git -C "$root" config user.name "Fixture"
  echo fixture > "$root/README.md"
  git -C "$root" add README.md
  git -C "$root" commit -q -m "chore: fixture"
  for n in $WT_NAMES; do
    i=$((i + 1))
    git -C "$root" worktree add -q -b "wt$i" "$WORK/$1/wt/$n" >/dev/null 2>&1
    # Uncommitted work, which --force destroys without asking.
    echo "PRECIOUS UNCOMMITTED WORK" > "$WORK/$1/wt/$n/scratch.txt"
  done
  printf '%s' "$root"
}

wt_alive() {  # wt_alive <fixture-dir> <name>
  [ -d "$WORK/$1/wt/$2" ] && [ -f "$WORK/$1/wt/$2/scratch.txt" ]
}

# --- RED first: the OLD unbounded `*"$TASK"*` teardown, retyped.
OLD_ROOT="$(make_wt_fixture old)"
(
  TASK="QDM-1"; REPO_ROOT="$OLD_ROOT"
  for wt in $(git -C "$REPO_ROOT" worktree list --porcelain | awk '/^worktree /{print $2}'); do
    case "$wt" in
      *"$TASK"*) git -C "$REPO_ROOT" worktree remove "$wt" --force 2>/dev/null ;;
    esac
  done
) >/dev/null 2>&1

if ! wt_alive old QDM-10-manifest; then
  pass "D1: the OLD teardown destroyed QDM-10's worktree (and its uncommitted scratch.txt) while merging QDM-1 — the defect, reproduced"
else
  fail "D1: could not reproduce the substring worktree destruction — D3 then proves nothing"
fi
if ! wt_alive old QDM-1-manifest; then
  pass "D1b: the OLD teardown did remove its own worktree too — so D1 is over-reach, not total failure"
else
  fail "D1b: the OLD teardown removed nothing at all; the reproduction is not measuring what it claims"
fi

# --- GREEN: merge.md's own function, run against a fresh identical fixture.
run_teardown() {  # run_teardown <fixture-dir> <root> <task>
  ( eval "$WT_FN"; qx_remove_task_worktrees "$2" "$3" ) >/dev/null 2>&1
}

NEW_ROOT="$(make_wt_fixture new1)"
run_teardown new1 "$NEW_ROOT" "QDM-1"
if wt_alive new1 QDM-10-manifest; then
  pass "D2: merging QDM-1 leaves QDM-10's worktree — and its uncommitted scratch.txt — untouched"
else
  fail "D2: merging QDM-1 STILL destroys QDM-10's worktree"
fi
if ! wt_alive new1 QDM-1-manifest; then
  pass "D3: merging QDM-1 does remove QDM-1's own worktree — bounded, not disabled"
else
  fail "D3: the bounded match no longer removes the task's OWN worktree, so nothing is torn down at all"
fi
SURVIVORS="$(ls "$WORK/new1/wt" 2>/dev/null | tr '\n' ' ')"
if [ "$SURVIVORS" = "QDM-10-manifest QDM-2-integration QDM-2.1-manifest QDM-231-manifest " ]; then
  pass "D3b: exactly one worktree was removed; the other four survive ($SURVIVORS)"
else
  fail "D3b: unexpected survivor set after merging QDM-1: '$SURVIVORS'"
fi

# --- a CHILD id tears down only its own worktree.
CHILD_ROOT="$(make_wt_fixture new2)"
run_teardown new2 "$CHILD_ROOT" "QDM-2.1"
if ! wt_alive new2 QDM-2.1-manifest && wt_alive new2 QDM-231-manifest; then
  pass "D4: merging the child QDM-2.1 removes its worktree and leaves QDM-231's standing (the '.' is a literal here too)"
else
  fail "D4: child teardown wrong — QDM-2.1 alive=$(wt_alive new2 QDM-2.1-manifest && echo yes || echo no), QDM-231 alive=$(wt_alive new2 QDM-231-manifest && echo yes || echo no)"
fi
if wt_alive new2 QDM-2-integration; then
  pass "D4b: the epic's own integration worktree survives a child's merge"
else
  fail "D4b: merging child QDM-2.1 destroyed the epic's integration worktree"
fi

# --- and a PARENT id does not reach into its children.
PAR_ROOT="$(make_wt_fixture new3)"
run_teardown new3 "$PAR_ROOT" "QDM-2"
if wt_alive new3 QDM-2.1-manifest; then
  pass "D5: merging the epic QDM-2 leaves child QDM-2.1's worktree alone — each child is torn down by its own reap"
else
  fail "D5: merging QDM-2 destroyed child QDM-2.1's worktree"
fi
if ! wt_alive new3 QDM-2-integration; then
  pass "D5b: merging QDM-2 does remove QDM-2-integration, its own worktree"
else
  fail "D5b: QDM-2's own worktree was not removed"
fi

# --- a task with no worktree removes nothing.
NONE_ROOT="$(make_wt_fixture new4)"
run_teardown new4 "$NONE_ROOT" "QDM-9"
NONE_LEFT="$(ls "$WORK/new4/wt" 2>/dev/null | tr '\n' ' ')"
if [ "$NONE_LEFT" = "QDM-1-manifest QDM-10-manifest QDM-2-integration QDM-2.1-manifest QDM-231-manifest " ]; then
  pass "D6: a task with no worktree of its own removes none of the others"
else
  fail "D6: merging QDM-9 disturbed the worktree set: '$NONE_LEFT'"
fi

# --- the operator's MAIN checkout is never a candidate, even when its own path
#     carries the id (the fixture root is literally .../QDM-7-root).
MAIN_ROOT="$(make_wt_fixture new5)"
run_teardown new5 "$MAIN_ROOT" "QDM-7"
if [ -d "$MAIN_ROOT" ] && [ -f "$MAIN_ROOT/README.md" ] && git -C "$MAIN_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  pass "D7: the main checkout survives a task id that matches its own path (QDM-7 vs .../QDM-7-root)"
else
  fail "D7: the teardown attacked the operator's main checkout at $MAIN_ROOT"
fi

# --- it must still be a --force removal of a DIRTY worktree; a plain
#     `worktree remove` refuses those, which is why teardown never happened by
#     hand. (Every worktree above carries an uncommitted scratch.txt, so D3
#     already proves --force is in play; assert the flag is really what did it.)
DIRTY_ROOT="$(make_wt_fixture new6)"
if ! git -C "$DIRTY_ROOT" worktree remove "$WORK/new6/wt/QDM-1-manifest" >/dev/null 2>&1; then
  pass "D8: git refuses to remove a dirty worktree without --force — so the teardown's --force is load-bearing, not decorative"
else
  fail "D8: git removed a dirty worktree without --force; the fixture is not dirty and D2/D3 prove less than claimed"
fi

b="$(basename "${BASH_SOURCE[0]}")"
if [ "$FAIL" -eq 0 ]; then
  echo "$b: all checks passed"
  exit 0
fi
echo "$b: FAILURES above"
exit 1
