#!/usr/bin/env bash
# test/deny-guard-push-delete.test.sh — remote REF DELETION is a catastrophic
# command, and .claude/hooks/deny-guard.sh used to be blind to it.
#
# Run: bash test/deny-guard-push-delete.test.sh
#
# THE DEFECT THIS CLOSES (SEC-2). check_git's `push` case matched only
# --force/-f. There was no `delete` case and no refspec inspection at all, so
# every one of these was ALLOWED by the shipped hook while the strictly LESS
# destructive `git push -f` next to it was denied:
#
#     git push origin --delete main                     -> ALLOWED
#     git push --quiet origin --delete claude/QUE-1     -> ALLOWED
#     git push origin :main                             -> ALLOWED
#
# A force-push MOVES a ref (the old commits survive in the reflog / on any
# clone that has them); a delete REMOVES it. The gap mattered more, not less,
# after the spec/gates publication was rewritten from `push -f` to
# ls-remote -> `push --delete` -> `push`: the engine now TEACHES the delete
# idiom in three shipped files (task-build.md, cloud-build-routine.md,
# merge.md), so an injected or misinstructed session reads it as blessed
# practice and can destroy an unmerged unit branch with one allowed command.
#
# THE RULE THIS PINS. A ref delete is denied unless the ref is in a namespace
# this pipeline creates and replaces BY CONSTRUCTION:
#   - quetrex-spec/*  — one dispatch's plan JSON, republished every dispatch
#   - *-gates         — one run's gate evidence, republished every run
# Both halves ship here, per this repo's rule that a change to a hook's
# blocking behaviour ships with a test proving the new BLOCK and the new ALLOW.
#
# WHY THE SHIPPED COMMANDS SPELL THEIR NAMESPACE OUT (the class assertion at
# the end). A PreToolUse hook receives the command text BEFORE the shell
# expands it, so `--delete "$SPEC_BRANCH"` is opaque — the guard cannot tell it
# from `--delete "$BASE"`. Every shipped delete therefore names its disposable
# namespace literally at the call site (`quetrex-spec/$TASK_ID`,
# `$BRANCH_PREFIX$TASK-gates`), and this file feeds the REAL shipped lines to
# the REAL hook to prove they stay legal. Without that assertion, tightening
# the guard would silently break the pipeline's own publication step.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="$REPO_ROOT/.claude/hooks/deny-guard.sh"

if [ ! -f "$DENY_GUARD" ]; then
  echo "NOT OK - required file not found: $DENY_GUARD"
  echo "deny-guard-push-delete.test.sh: FAILURES above"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — the PreToolUse payloads are built with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

# The REAL hook, fed a REAL PreToolUse payload. No copy, no re-implementation.
hook_verdict() {  # hook_verdict <command-string> -> "deny" | "allow"
  local payload out
  payload="$(node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "Bash",
      tool_input: { command: process.argv[1] }
    }));
  ' "$1")"
  out="$(printf '%s' "$payload" | bash "$DENY_GUARD" 2>/dev/null)"
  case "$out" in
    *'"permissionDecision":"deny"'*) printf 'deny' ;;
    *) printf 'allow' ;;
  esac
}

expect_deny() {  # expect_deny <label> <command>
  local v; v="$(hook_verdict "$2")"
  if [ "$v" = "deny" ]; then
    pass "$1 — DENIED: [$2]"
  else
    fail "$1 — the hook ALLOWED [$2]. Remote ref deletion removes the branch outright; it must not be easier to run than the force-push the same guard already blocks."
  fi
}

expect_allow() {  # expect_allow <label> <command>
  local v; v="$(hook_verdict "$2")"
  if [ "$v" = "allow" ]; then
    pass "$1 — allowed: [$2]"
  else
    fail "$1 — the hook DENIED [$2]. A guard that blocks the pipeline's own legitimate commands gets switched off, and then it blocks nothing at all."
  fi
}

# =============================================================================
# 0 — negative controls: the hook is alive and still decides both ways
# =============================================================================
# Without these, every "denied" below could come from a hook that denies
# everything, and every "allowed" from a hook that has stopped parsing input.
expect_deny  "AC0-a: negative control, the pre-existing force-push rule still fires" \
             'git -C /tmp/wt push -f origin quetrex-spec/QUE-1'
expect_allow "AC0-b: negative control, an ordinary push is still allowed" \
             'git push --quiet origin claude/QUE-1'

# =============================================================================
# 1 — THE BLOCK: deleting a ref outside the disposable namespaces
# =============================================================================
expect_deny "AC1-a: --delete of the default branch" \
            'git push origin --delete main'
expect_deny "AC1-b: --delete of a unit branch, behind an unrelated flag" \
            'git push --quiet origin --delete claude/QUE-1'
expect_deny "AC1-c: the short form -d, on a unit branch" \
            'git push origin -d claude/QUE-1'
expect_deny "AC1-d: the empty-source refspec form, which names no delete flag at all" \
            'git push origin :main'
expect_deny "AC1-e: the empty-source refspec, fully qualified" \
            'git push origin :refs/heads/claude/QUE-1'
expect_deny "AC1-f: --delete survives git's own global options (-C)" \
            'git -C /tmp/wt push origin --delete main'
expect_deny "AC1-g: --delete before the remote, which is also valid git" \
            'git push --delete origin master'
expect_deny "AC1-h: a fully-qualified ref is not a way around the namespace rule" \
            'git push origin --delete refs/heads/main'
expect_deny "AC1-i: an opaque variable is NOT assumed disposable — the hook cannot expand it" \
            'git push origin --delete "$BASE_BRANCH"'
expect_deny "AC1-j: deleting several refs at once, one of them protected" \
            'git push origin --delete quetrex-spec/QUE-1 main'

# =============================================================================
# 2 — THE ALLOW: the namespaces this pipeline republishes by construction
# =============================================================================
expect_allow "AC2-a: the spec branch is disposable — one dispatch's plan JSON" \
             'git push origin --delete quetrex-spec/QUE-1'
expect_allow "AC2-b: the spec branch as the shipped step actually writes it (unexpanded \$TASK_ID)" \
             'git -C /tmp/wt push --quiet origin --delete "quetrex-spec/$TASK_ID"'
expect_allow "AC2-c: a gates branch is disposable — one run's gate evidence" \
             'git push --quiet origin --delete claude/QUE-1-gates'
expect_allow "AC2-d: the gates branch as the shipped step actually writes it (unexpanded prefix)" \
             'git -C /tmp/wt push -q origin --delete "$BRANCH_PREFIX$TASK-gates"'
expect_allow "AC2-e: a fully-qualified disposable ref" \
             'git push origin --delete refs/heads/quetrex-spec/QUE-1'
expect_allow "AC2-f: the empty-source refspec form, in a disposable namespace" \
             'git push origin :quetrex-spec/QUE-1'

# =============================================================================
# 3 — NOT a remote ref deletion: the rule must not spread
# =============================================================================
# Over-blocking is how a guard gets deleted by the next person who touches it.
expect_allow "AC3-a: a LOCAL branch delete is not a remote ref deletion" \
             'git branch -d claude/QUE-1'
expect_allow "AC3-b: a LOCAL force branch delete is still not this guard's business" \
             'git -C /tmp/wt branch -D main'
expect_allow "AC3-c: --delete on a different command entirely" \
             'gh pr merge 42 --squash --delete-branch'
expect_allow "AC3-d: text that MENTIONS the command is not the command" \
             'grep -rn "git push origin --delete main" .claude/'
expect_allow "AC3-e: an ordinary refspec push with a non-empty source" \
             'git push origin HEAD:refs/heads/claude/QUE-1'
expect_allow "AC3-f: --force-with-lease remains the sanctioned remedy" \
             'git push --force-with-lease origin claude/QUE-1'

# =============================================================================
# 4 — the evasion the existing backstop already covers for force-push
# =============================================================================
# check_tokens sets PIPE_TO_SHELL when a segment pipes into a bare shell, and
# the whole-string backstop then re-scans the literal text. Ref deletion has to
# be in that backstop too, or `echo '...' | bash` is a one-line bypass of
# everything above.
expect_deny  "AC4-a: a protected-ref delete piped into a shell is caught by the backstop" \
             "echo 'git push origin --delete main' | bash"
expect_allow "AC4-b: the backstop does not fire on a disposable-namespace delete" \
             "echo 'git push origin --delete quetrex-spec/QUE-1' | bash"

# =============================================================================
# 5 — THE CLASS: every ref delete this engine SHIPS must stay legal
# =============================================================================
# The guard and the shipped commands are one contract. Feed the real lines from
# the real files to the real hook. Template placeholders are substituted first,
# because a routine prompt is filled before any of it is ever executed — the
# hook never sees `{{TASK}}`.
SHIPPED_DELETES="$(grep -rhn -- 'push .*--delete\|push .*[^A-Za-z0-9]-d ' \
                     "$REPO_ROOT/.claude/commands" "$REPO_ROOT/.claude/lib" 2>/dev/null \
                   | sed 's/^[0-9]*://' \
                   | sed 's/^[[:space:]]*//' \
                   | grep -v '^#' \
                   | grep '^git ' || true)"

SHIPPED_N=0
SHIPPED_DENIED=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  filled="$(printf '%s' "$line" \
            | sed -e 's#{{BRANCH_PREFIX}}#claude/#g' -e 's#{{TASK}}#QUE-1#g' \
                  -e 's#{{TASK_ID}}#QUE-1#g')"
  SHIPPED_N=$((SHIPPED_N + 1))
  if [ "$(hook_verdict "$filled")" = "deny" ]; then
    SHIPPED_DENIED="$SHIPPED_DENIED
    $filled"
  fi
done <<SHIPEOF
$SHIPPED_DELETES
SHIPEOF

if [ "$SHIPPED_N" -eq 0 ]; then
  fail "AC5: found ZERO shipped 'git push --delete' lines under .claude/commands or .claude/lib — either the extractor broke or the publication steps changed shape; this assertion would pass vacuously"
elif [ -z "$SHIPPED_DENIED" ]; then
  pass "AC5: all $SHIPPED_N shipped ref-delete command(s) under .claude/ are still permitted by the real deny-guard.sh"
else
  fail "AC5: deny-guard.sh now DENIES shipped engine command(s):$SHIPPED_DENIED
    Every shipped delete must name its disposable namespace LITERALLY at the call site (quetrex-spec/... or ...-gates) — a PreToolUse hook sees the command before the shell expands \$VARS, so \"\$SPEC_BRANCH\" is indistinguishable from \"\$BASE\"."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "deny-guard-push-delete.test.sh: all checks passed"
  exit 0
else
  echo "deny-guard-push-delete.test.sh: FAILURES above"
  exit 1
fi
