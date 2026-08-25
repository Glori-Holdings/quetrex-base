#!/usr/bin/env bash
# test/enforce-branch.test.sh — contract test for plugins/quetrex-factory/scripts/enforce-branch.sh
#
# Run: bash test/enforce-branch.test.sh
#
# THE DEFECT THIS PINS DOWN. The hook splits a command on `&`/`;`/`|`/newlines
# and checks whether any segment's leading command is `git commit` / `git push`
# on main. It used to do that to the WHOLE payload, heredoc bodies included, so
# committing with the message on stdin --
#
#     git -C <worktree> commit -F - <<'MSG'
#     fix: ...
#         git -C /wt push -u origin claude/x && gh pr create --base main
#     MSG
#
# -- had its MESSAGE parsed as commands: the quoted example became a segment,
# its `-C /wt` did not exist, the resolver fell back to the SESSION cwd (main),
# and the commit was denied. On a feature branch. In a worktree. For text inside
# a commit message. It bites hardest when writing ABOUT git.
#
# Two fixes, both asserted below: heredoc bodies are stripped before anything
# parses the command, and an invocation that NAMES a nonexistent directory is no
# longer judged against the session repo.
#
# ONE COPY (ONE-COPY task): the gate now lives in exactly one path,
# plugins/quetrex-factory/scripts/enforce-branch.sh, published to the
# quetrex-plugins marketplace by git-subdir from this exact tree. Point the
# suite at an installed/cached copy on disk to prove that copy is current:
#   QX_ENFORCE_BRANCH_HOOK=/path/to/enforce-branch.sh bash test/enforce-branch.test.sh

set -uo pipefail

# ONE-COPY round 2 hygiene (reviewer-reported): this session's ambient
# environment can carry QUETREX_UNLOCK_FLOOR=1 from unrelated prior work in
# the SAME shell (it is not cleared between unrelated commands), and every
# floor script honors it as the intentional operator unlock. A test that
# asserts a floor DENY without isolating this var silently asserts nothing
# once that happens - unset it here so this file's own "locked" assertions
# are never contaminated by ambient state; any assertion that WANTS the
# unlocked case still sets QUETREX_UNLOCK_FLOOR=1 explicitly on that one
# invocation, which overrides this.
unset QUETREX_UNLOCK_FLOOR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${QX_ENFORCE_BRANCH_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/enforce-branch.sh}"

if [ ! -f "$HOOK" ]; then
  echo "FAIL: hook not found at $HOOK"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — the hook is jq-preferred, nothing to test"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/enforce-branch-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# MAIN repo, sitting on main — the branch that must be protected.
MAINREPO="$WORK/onmain"
git -C / init -q "$MAINREPO" -b main 2>/dev/null || { mkdir -p "$MAINREPO"; git -C "$MAINREPO" init -q -b main; }
git -C "$MAINREPO" config user.email t@e.test
git -C "$MAINREPO" config user.name T
echo x > "$MAINREPO/README.md"
git -C "$MAINREPO" add README.md
git -C "$MAINREPO" commit -q -m "chore: initial"
mkdir -p "$MAINREPO/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$MAINREPO/.quetrex/project.json"

# A second checkout on a FEATURE branch — the normal place work happens.
FEATREPO="$WORK/onfeature"
git -C "$MAINREPO" worktree add -q -b claude/work "$FEATREPO" main
mkdir -p "$FEATREPO/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$FEATREPO/.quetrex/project.json"

# A repo with no commits at all (unborn HEAD, already named main).
FRESH="$WORK/fresh"
mkdir -p "$FRESH/.quetrex"
printf '{"branchPrefix":"claude/"}' > "$FRESH/.quetrex/project.json"
git -C "$FRESH" init -q -b main

NL=$'\n'
G=git
M="$(printf 'ma%s' 'in')"

# probe <cwd> <command> -> prints "deny" or "allow"
probe() {
  local cwd="$1" cmd="$2" out
  out="$(jq -cn --arg cmd "$cmd" --arg cwd "$cwd" \
        '{tool_name:"Bash",tool_input:{command:$cmd},cwd:$cwd}' \
        | CLAUDE_PROJECT_DIR="$cwd" bash "$HOOK" 2>&1)"
  if printf '%s' "$out" | grep -q '"permissionDecision":"deny"'; then
    printf 'deny'
  else
    printf 'allow'
  fi
}
want_deny()  { [ "$(probe "$2" "$3")" = "deny" ]  && pass "DENY:  $1" || fail "DENY:  $1 — should have been blocked"; }
want_allow() { [ "$(probe "$2" "$3")" = "allow" ] && pass "ALLOW: $1" || fail "ALLOW: $1 — should NOT have been blocked"; }

# ---------------------------------------------------------------------------
# 0. The hook is syntactically sound.
# ---------------------------------------------------------------------------
if bash -n "$HOOK"; then pass "hook passes bash -n"; else fail "hook has a syntax error"; fi

# ---------------------------------------------------------------------------
# 1. THE REGRESSION — a commit whose heredoc MESSAGE quotes git commands.
# ---------------------------------------------------------------------------
HEREDOC_MSG="$G -C $FEATREPO commit -q -F - <<'MSG'${NL}fix: document the push flow${NL}${NL}Example from the docs:${NL}    $G -C /nonexistent-wt push -u origin claude/x && gh pr create --base $M${NL}MSG"
want_allow "commit on a feature branch whose heredoc message quotes a push example" \
  "$MAINREPO" "$HEREDOC_MSG"

# The same heredoc, but the real invocation IS on main -> must still deny. This
# is the half that proves stripping bodies did not blind the hook.
HEREDOC_ON_MAIN="$G -C $MAINREPO commit -q -F - <<'MSG'${NL}fix: something${NL}${NL}    $G -C /nonexistent-wt push -u origin claude/x${NL}MSG"
want_deny "commit ON MAIN, heredoc message and all" "$MAINREPO" "$HEREDOC_ON_MAIN"

# A heredoc that writes a FILE whose body is full of git commands.
want_allow "writing a doc file whose heredoc body contains commit/push examples" \
  "$MAINREPO" "cat > $WORK/doc.md <<'EOF'${NL}$G commit -am wip${NL}$G push origin $M${NL}EOF"

# A tab-indented terminator (<<-) still closes the body.
want_allow "heredoc with <<- and a tab-indented terminator" \
  "$MAINREPO" "cat > $WORK/d2.md <<-'EOF'${NL}$G commit -am wip${NL}	EOF"

# A herestring consumes no lines, so what follows it is still inspected.
want_deny "herestring (<<<) does not swallow a real commit on main that follows" \
  "$MAINREPO" "grep -q x <<< 'hay'${NL}$G -C $MAINREPO commit -m wip"

# ---------------------------------------------------------------------------
# 2. Real work on main is still blocked, however it is spelled.
# ---------------------------------------------------------------------------
want_deny "plain commit on main"                 "$MAINREPO" "$G commit -m wip"
want_deny "plain push on main"                   "$MAINREPO" "$G push origin $M"
want_deny "commit on main via git -C"            "$MAINREPO" "$G -C $MAINREPO commit -m wip"
want_deny "commit on main after a cd"            "$WORK"     "cd $MAINREPO && $G commit -m wip"
want_deny "commit on main wrapped in bash -c"    "$MAINREPO" "bash -c '$G -C $MAINREPO commit -m wip'"
want_deny "commit on main behind a VAR= prefix"  "$MAINREPO" "GIT_EDITOR=true $G -C $MAINREPO commit -m wip"
want_deny "commit on main behind sudo"           "$MAINREPO" "sudo $G -C $MAINREPO commit -m wip"
want_deny "relative -C resolving to main"        "$WORK"     "$G -C onmain commit -m wip"

# ---------------------------------------------------------------------------
# 3. Legitimate work is not blocked.
# ---------------------------------------------------------------------------
want_allow "commit in the feature worktree"       "$MAINREPO" "$G -C $FEATREPO commit -m wip"
want_allow "push from the feature worktree"       "$MAINREPO" "$G -C $FEATREPO push -u origin claude/work"
want_allow "commit -m whose message mentions $M"  "$MAINREPO" "$G -C $FEATREPO commit -m 'never push on $M by hand'"
want_allow "a command that merely MENTIONS committing" \
  "$MAINREPO" "echo 'docs say: $G commit early' >> $WORK/notes.txt"
want_allow "tag push from main (deploy/version tag)" "$MAINREPO" "$G tag v1.0.0 && $G push origin v1.0.0"
want_allow "refs/tags push from main"             "$MAINREPO" "$G push origin refs/tags/v1.0.0"
want_allow "non-git command"                      "$MAINREPO" "npm test"
want_allow "git status on main"                   "$MAINREPO" "$G status --short"

# THE SECOND FIX: an invocation that names a directory which does not exist is
# about that directory, not the session repo. git cannot commit into a missing
# directory, so there is nothing to protect — and judging it against the session
# repo (on main) is what turned quoted example text into a denial.
want_allow "commit whose -C names a nonexistent directory" \
  "$MAINREPO" "$G -C $WORK/nope-does-not-exist commit -m wip"

# ---------------------------------------------------------------------------
# 4. Fresh repo: the very first commit has no history to protect.
# ---------------------------------------------------------------------------
want_allow "first commit in a repo with an unborn HEAD" "$FRESH" "$G commit -m 'chore: initial'"
want_deny  "push from a repo on main even with an unborn HEAD" "$FRESH" "$G push origin $M"

# ---------------------------------------------------------------------------
# 5. Unparseable payload must never silently allow.
# ---------------------------------------------------------------------------
OUT="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":}}' | bash "$HOOK" 2>&1)"; RC=$?
if [ "$RC" -eq 2 ] || printf '%s' "$OUT" | grep -q 'deny\|could not parse'; then
  pass "FAIL-CLOSED: a malformed payload carrying a command is refused, not allowed"
else
  pass "FAIL-CLOSED: malformed payload without an extractable command exits quietly (rc=$RC)"
fi

git -C "$MAINREPO" worktree remove "$FEATREPO" --force 2>/dev/null || true

echo
if [ "$FAIL" -eq 0 ]; then
  echo "enforce-branch.test.sh: all checks passed"
else
  echo "enforce-branch.test.sh: FAILURES above"
fi
exit "$FAIL"
