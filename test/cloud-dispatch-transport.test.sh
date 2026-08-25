#!/usr/bin/env bash
# test/cloud-dispatch-transport.test.sh — the three DISPATCH-SIDE defects the
# live QDM-4 cloud build (trigger trig_01TdwkWbT6PradXbyFYDxovX) exposed in
# .claude/commands/task-build.md Step 6A and .claude/lib/cloud-build-routine.md.
#
# Run: bash test/cloud-dispatch-transport.test.sh
#
# Every assertion below reads the REAL shipped files (never a copy) and, where
# the artifact is executable text, EXECUTES it against a fixture — because the
# three defects are all cases where the file read correctly and behaved wrongly.
#
# DEFECT 1 — the cloud session is unidentifiable on a phone.
#   The routine's `name` field is fine, but the SESSION/transport name derives
#   from the FIRST LINE of the prompt body, and that first line was the same
#   35-word boilerplate ("You are a fresh Claude Code cloud session. You have
#   just cloned {{REPO_URL}} with zero") for every build ever dispatched. Two
#   concurrent builds are indistinguishable on the phone, which is the only
#   surface the operator has. The prompt must LEAD with the task id.
#     AC1-a: the first non-empty line of the prompt fence starts with the
#            literal `{{TASK}}` — the id is the first token, always.
#     AC1-b: that same first line also carries `{{TITLE}}`, so the name is
#            scannable and not just an opaque id.
#     AC1-c: the old boilerplate is still there, on a LATER line — the fix is a
#            prepend, not a rewrite that drops the zero-context briefing.
#     AC1-d: `{{TITLE}}` is a first-class placeholder (declared in the table and
#            substituted). The set-contract itself is enforced by
#            test/placeholder-substitution.test.sh; this asserts the specific
#            name so a silent removal is caught here too.
#
# DEFECT 2 — the spec-branch push is denied by this repo's own force-push hook.
#   Step 6A published the spec branch with `git push -f`. .claude/hooks/
#   deny-guard.sh DENIES unconditional force-push. QDM-4 only survived because
#   the branch was brand new and the operator's session hand-retried without
#   `-f`; ANY re-dispatch of an existing task hits the deny and the dispatch
#   dies with the plan unpublished. The publication must be idempotent AND
#   hook-legal.
#     AC2-a (hook-legal): every `git ... push ...` line in the shipped Step 6A
#            publication block is fed to the REAL deny-guard.sh and must not be
#            denied.
#     AC2-b (negative control): a literal `git push -f origin x` fed to the same
#            hook MUST be denied — otherwise AC2-a passes vacuously because the
#            detector stopped detecting.
#     AC2-c (first dispatch): the shipped block, executed verbatim against a
#            real bare remote where the spec branch does NOT exist, exits 0 and
#            publishes it.
#     AC2-d (re-dispatch): the SAME block, executed again against the SAME
#            remote where the spec branch now DOES exist, exits 0 and the remote
#            branch advances to the new commit. This is the case that was broken.
#     AC2-e (whole class): no shipped engine file under .claude/ instructs an
#            unconditional force-push at all.
#
# DEFECT 3 — dispatch arms a SECOND concurrent build.
#   `RemoteTrigger action:"create"` (with `run_once_at`) followed by
#   `action:"run"` fires the run immediately but leaves `next_run_at` still armed
#   at `run_once_at` — measured on QDM-4: fired 20:59:16Z, next_run_at 21:00:09Z,
#   i.e. a second concurrent build on the same branch 53 seconds later. The
#   operator's session had to notice and disable the trigger by hand. The
#   documented dispatch sequence must disarm the schedule as PART of dispatch.
#     AC3-a: Step 6A names all three actions — create, run, update — and in that
#            order.
#     AC3-b: the update carries `enabled: false` (the disarm), and Step 6A says
#            in so many words that exactly one run may be left armed.
#     AC3-c: Step 6A requires the dispatcher to CONFIRM `next_run_at` is clear
#            afterwards, so a silent re-arm is caught rather than assumed away.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$REPO_ROOT/.claude/lib/cloud-build-routine.md"
COMMAND="$REPO_ROOT/.claude/commands/task-build.md"
DENY_GUARD="$REPO_ROOT/.claude/hooks/deny-guard.sh"

for f in "$TEMPLATE" "$COMMAND" "$DENY_GUARD"; do
  if [ ! -f "$f" ]; then
    echo "NOT OK - required file not found: $f"
    echo "cloud-dispatch-transport.test.sh: FAILURES above"
    exit 1
  fi
done
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — the publication block cannot be executed"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — the hook payloads are built with node"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-dispatch-transport.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --- extractors, anchored on TEXT so an inserted line above never breaks them --

# The routine prompt itself: the plain ``` fence under "## The prompt".
extract_prompt() {
  awk '
    /^## The prompt/ { insec = 1; next }
    insec && !infence && /^```/ { infence = 1; next }
    insec && infence && /^```/ { exit }
    insec && infence { print }
  ' "$TEMPLATE"
}

# The ```bash fence that follows a given anchor line in a given file.
extract_fence_after() {  # <file> <anchor-substring>
  awk -v anchor="$2" '
    !found && index($0, anchor) { found = 1; next }
    found && !infence && /^```bash/ { infence = 1; next }
    found && infence && /^```/ { exit }
    found && infence { print }
  ' "$1"
}

# =============================================================================
# DEFECT 1 — the prompt must lead with the task id
# =============================================================================
PROMPT="$(extract_prompt)"
if [ -z "$PROMPT" ]; then
  fail "setup: could not extract the prompt fence from $TEMPLATE (anchor: '## The prompt') — every DEFECT 1 assertion below would be vacuous"
  FIRST_LINE=""
else
  pass "setup: extracted the routine prompt fence from cloud-build-routine.md ($(printf '%s\n' "$PROMPT" | wc -l | tr -d ' ') lines)"
  FIRST_LINE="$(printf '%s\n' "$PROMPT" | grep -m1 -v '^[[:space:]]*$')"
fi

case "$FIRST_LINE" in
  '{{TASK}}'*)
    pass "AC1-a: the prompt's first line begins with the literal {{TASK}} — the transport/session name leads with the task id (first line: [$FIRST_LINE])" ;;
  *)
    fail "AC1-a: the prompt's first line does NOT begin with {{TASK}} — it is [$FIRST_LINE]. The cloud SESSION name derives from this line, so every running build shows the operator the same string on his phone and concurrent builds are indistinguishable." ;;
esac

case "$FIRST_LINE" in
  *'{{TITLE}}'*)
    pass "AC1-b: the prompt's first line also carries {{TITLE}}, so the session name is scannable, not just an opaque id" ;;
  *)
    fail "AC1-b: the prompt's first line carries no {{TITLE}} — it is [$FIRST_LINE]. An id with no title is not scannable on a phone-width list." ;;
esac

if printf '%s\n' "$PROMPT" | grep -q 'You are a fresh Claude Code cloud session'; then
  BOILER_LINE="$(printf '%s\n' "$PROMPT" | grep -n 'You are a fresh Claude Code cloud session' | head -n1 | cut -d: -f1)"
  FIRST_NONEMPTY_LINE="$(printf '%s\n' "$PROMPT" | grep -n -m1 -v '^[[:space:]]*$' | cut -d: -f1)"
  if [ "${BOILER_LINE:-0}" -gt "${FIRST_NONEMPTY_LINE:-0}" ]; then
    pass "AC1-c: the zero-context briefing survives, on a later line (prompt line $BOILER_LINE, after the identity line $FIRST_NONEMPTY_LINE) — the fix is a prepend, not a rewrite"
  else
    fail "AC1-c: the 'You are a fresh Claude Code cloud session' briefing is still the FIRST line of the prompt (line $BOILER_LINE) — nothing was prepended, so the transport name is unchanged"
  fi
else
  fail "AC1-c: the zero-context briefing ('You are a fresh Claude Code cloud session') is GONE from the prompt — the identity line must be prepended to it, never replace it; the cloud session needs that briefing to know it has no context"
fi

if grep -q '{{TITLE}}' "$TEMPLATE" && grep -q '{{TITLE}}' "$COMMAND"; then
  pass "AC1-d: {{TITLE}} is present in BOTH the template and task-build.md (its set-contract is enforced by placeholder-substitution.test.sh)"
else
  fail "AC1-d: {{TITLE}} is missing from $( grep -q '{{TITLE}}' "$TEMPLATE" || echo "the template" ) $( grep -q '{{TITLE}}' "$COMMAND" || echo "task-build.md" ) — it must be a declared, substituted placeholder or it ships to the cloud as literal text"
fi

# =============================================================================
# DEFECT 2 — the spec-branch publication must be hook-legal and idempotent
# =============================================================================
PUBLISH_ANCHOR='Publish it. This is a plain create-and-push'
PUBLISH_BLOCK="$(extract_fence_after "$COMMAND" "$PUBLISH_ANCHOR")"

if [ -z "$PUBLISH_BLOCK" ]; then
  fail "setup: could not extract the spec-branch publication block from $COMMAND (anchor: '$PUBLISH_ANCHOR') — Step 6A has no separately-runnable, hook-legal publication step, so AC2-a/c/d cannot be proven against shipped text"
else
  pass "setup: extracted the spec-branch publication block from task-build.md ($(printf '%s\n' "$PUBLISH_BLOCK" | wc -l | tr -d ' ') lines)"
fi

# --- AC2-a / AC2-b: the REAL deny-guard verdict on real command text ---------
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

# Negative control FIRST: if the hook has stopped denying, AC2-a means nothing.
CONTROL="$(hook_verdict 'git -C /tmp/wt push -f origin quetrex-spec/QDM-4')"
if [ "$CONTROL" = "deny" ]; then
  pass "AC2-b: negative control — deny-guard.sh still DENIES a literal 'git push -f', so AC2-a is a real verdict and not a broken detector"
else
  fail "AC2-b: negative control FAILED — deny-guard.sh returned '$CONTROL' for 'git push -f origin quetrex-spec/QDM-4'. Every AC2-a verdict below is meaningless while this is true."
fi

DENIED_LINES=""
PUSH_LINES=0
while IFS= read -r line; do
  case "$line" in
    *' push '*)
      case "$line" in
        \#*) continue ;;
      esac
      PUSH_LINES=$((PUSH_LINES + 1))
      if [ "$(hook_verdict "$line")" = "deny" ]; then
        DENIED_LINES="$DENIED_LINES
    $line"
      fi
      ;;
  esac
done <<PUBEOF
$PUBLISH_BLOCK
PUBEOF

if [ "$PUSH_LINES" -eq 0 ]; then
  fail "AC2-a: the publication block contains NO push command at all — either the block was not found or it no longer publishes the spec branch; AC2-a would pass vacuously"
elif [ -z "$DENIED_LINES" ]; then
  pass "AC2-a: all $PUSH_LINES push command(s) in the shipped publication block are permitted by the real deny-guard.sh"
else
  fail "AC2-a: deny-guard.sh DENIES $(printf '%s' "$DENIED_LINES" | grep -c .) push command(s) that Step 6A tells the dispatcher to run:$DENIED_LINES
    Dispatch dies here on every re-dispatch of a task whose spec branch already exists."
fi

# --- AC2-e: the whole class, across every shipped engine file ----------------
FORCE_PUSH_HITS="$(grep -rn -- 'push -f \|push --force ' "$REPO_ROOT/.claude/commands" "$REPO_ROOT/.claude/lib" 2>/dev/null | grep -v -- '--force-with-lease' | grep -v -- '--force-if-includes' || true)"
if [ -z "$FORCE_PUSH_HITS" ]; then
  pass "AC2-e: no shipped file under .claude/commands or .claude/lib instructs an unconditional force-push"
else
  fail "AC2-e: shipped engine text still instructs an unconditional force-push, which deny-guard.sh denies:
$FORCE_PUSH_HITS"
fi

# --- AC2-c / AC2-d: execute the shipped block against a REAL remote ----------
run_publication() {  # run_publication <n>  -> echoes exit code; leaves state on the remote
  local n="$1" wt="$WORK/wt-$1"
  rm -rf "$wt"
  git clone --quiet "$WORK/remote.git" "$wt" 2>/dev/null
  git -C "$wt" -c user.name=t -c user.email=t@e \
    commit --quiet --allow-empty -m "spec payload run $n"
  # Derive the spec branch the way Step 6A does: from the sha of the commit being
  # published, so the ref is unique per dispatch and nothing is ever replaced. The
  # fixture must mirror the shipped derivation, or it measures a naming scheme the
  # engine no longer uses.
  SPEC_SHA="$(git -C "$wt" rev-parse HEAD)"
  SPEC_BRANCH_RUN="${SPEC_BRANCH_FIXTURE}-$(printf '%.7s' "$SPEC_SHA")"
  git -C "$wt" branch -q "$SPEC_BRANCH_RUN"
  printf '%s' "$SPEC_BRANCH_RUN" > "$WORK/last-spec-branch"
  (
    TMP_WT="$wt"
    SPEC_BRANCH="$SPEC_BRANCH_RUN"
    TASK_ID="${SPEC_BRANCH_FIXTURE#quetrex-spec/}"
    export TMP_WT SPEC_BRANCH TASK_ID
    bash -c "$PUBLISH_BLOCK" >/dev/null 2>&1
  )
  printf '%s' "$?"
}

if [ -n "$PUBLISH_BLOCK" ]; then
  SPEC_BRANCH_FIXTURE="quetrex-spec/QDM-4"
  git init --quiet --bare "$WORK/remote.git"
  # seed the remote with a default branch so `git clone` yields a working tree
  git init --quiet "$WORK/seed"
  git -C "$WORK/seed" -c user.name=t -c user.email=t@e commit --quiet --allow-empty -m init
  git -C "$WORK/seed" push --quiet "$WORK/remote.git" HEAD:refs/heads/main 2>/dev/null

  RC1="$(run_publication 1)"
  BR1="$(cat "$WORK/last-spec-branch")"
  REMOTE1="$(git -C "$WORK/remote.git" rev-parse "refs/heads/$BR1" 2>/dev/null || true)"
  LOCAL1="$(git -C "$WORK/wt-1" rev-parse HEAD 2>/dev/null || true)"
  if [ "$RC1" = "0" ] && [ -n "$REMOTE1" ] && [ "$REMOTE1" = "$LOCAL1" ]; then
    pass "AC2-c: FIRST dispatch (spec branch absent on the remote) — the shipped block exits 0 and publishes $BR1 at the right commit"
  else
    fail "AC2-c: FIRST dispatch failed — exit=$RC1, remote ref=[${REMOTE1:-<none>}], expected=[${LOCAL1:-<none>}]"
  fi

  # AC2-d, RESHAPED. The defect was "a task built twice can never republish its spec",
  # and it was caused by BOTH dispatches targeting one fixed ref — which forced first a
  # force-push (denied by deny-guard.sh) and then a remote ref delete. The fix removes the
  # collision instead of managing it: the ref is named after the commit it carries, so a
  # re-dispatch publishes a SECOND ref and the first is left intact. So the property to
  # assert is no longer "the ref advanced" but "the re-dispatch succeeded, published a
  # DIFFERENT ref at the new commit, and destroyed nothing".
  RC2="$(run_publication 2)"
  BR2="$(cat "$WORK/last-spec-branch")"
  REMOTE2="$(git -C "$WORK/remote.git" rev-parse "refs/heads/$BR2" 2>/dev/null || true)"
  LOCAL2="$(git -C "$WORK/wt-2" rev-parse HEAD 2>/dev/null || true)"
  STILL1="$(git -C "$WORK/remote.git" rev-parse "refs/heads/$BR1" 2>/dev/null || true)"
  if [ "$RC2" = "0" ] && [ -n "$REMOTE2" ] && [ "$REMOTE2" = "$LOCAL2" ] && [ "$BR2" != "$BR1" ] && [ "$STILL1" = "$REMOTE1" ]; then
    pass "AC2-d: RE-DISPATCH — the shipped block exits 0, publishes a NEW ref ($BR2) at the new commit, and leaves the first ($BR1) untouched: no force, no delete, no collision"
  else
    fail "AC2-d: RE-DISPATCH failed — exit=$RC2, new ref=[$BR2 -> ${REMOTE2:-<none>}], expected=[${LOCAL2:-<none>}], first ref=[$BR1 -> ${STILL1:-<GONE>}] (was ${REMOTE1:-<none>}). A re-dispatch must add a ref, never replace or remove one."
  fi
fi

# =============================================================================
# DEFECT 3 — dispatch must leave exactly ONE run armed
# =============================================================================
# The authority is the ORDERED LIST under the "Dispatch call order" heading —
# not the first mention anywhere in the file. The paragraph above that list
# legitimately names `action:"run"` while explaining why create+run alone is
# wrong, and a naive whole-file "first occurrence" scan reads that prose as the
# sequence and reports a false failure. Read the numbered list, which is what a
# dispatching session actually follows.
ORDER_ANCHOR='Dispatch call order'
ORDER_LIST="$(awk -v anchor="$ORDER_ANCHOR" '
  !found && index($0, anchor) { found = 1; next }
  found && /^[0-9]+\. / { inlist = 1; print; next }
  found && inlist && /^[[:space:]]+[^[:space:]]/ { print; next }
  found && inlist && /^[[:space:]]*$/ { next }
  found && inlist { exit }
' "$COMMAND")"

if [ -z "$ORDER_LIST" ]; then
  fail "setup: no ordered call list under a '$ORDER_ANCHOR' heading in $COMMAND — AC3-a has no authoritative sequence to check"
else
  pass "setup: extracted the numbered dispatch call list from task-build.md ($(printf '%s\n' "$ORDER_LIST" | wc -l | tr -d ' ') lines)"
fi

line_of() {  # line_of <pattern> -> first matching line number in the ordered list, or ""
  printf '%s\n' "$ORDER_LIST" | grep -n -- "$1" | head -n1 | cut -d: -f1
}

L_CREATE="$(line_of 'action:"create"')"
L_RUN="$(line_of 'action:"run"')"
L_UPDATE="$(line_of 'action:"update"')"

if [ -n "$L_CREATE" ] && [ -n "$L_RUN" ] && [ -n "$L_UPDATE" ] \
   && [ "$L_CREATE" -le "$L_RUN" ] && [ "$L_RUN" -le "$L_UPDATE" ]; then
  pass "AC3-a: the dispatch call list names all three RemoteTrigger actions in order — create (item line $L_CREATE) → run ($L_RUN) → update ($L_UPDATE)"
else
  fail "AC3-a: the dispatch call list does not name create→run→update in order (create=[${L_CREATE:-absent}] run=[${L_RUN:-absent}] update=[${L_UPDATE:-absent}]). Without the third call the scheduled run_once_at stays armed and fires a SECOND concurrent build on the same branch — measured on QDM-4."
fi

if grep -q 'enabled.*false' "$COMMAND" && grep -qi 'exactly one run' "$COMMAND"; then
  pass "AC3-b: Step 6A disarms the schedule (enabled: false) and states the exactly-one-run rule"
else
  fail "AC3-b: Step 6A is missing $( grep -q 'enabled.*false' "$COMMAND" || printf 'the enabled:false disarm ' )$( grep -qi 'exactly one run' "$COMMAND" || printf 'the explicit "exactly ONE run armed" rule ' )— disabling the trigger must be part of dispatch, not a manual afterthought the operator has to notice."
fi

if grep -q 'next_run_at' "$COMMAND"; then
  pass "AC3-c: Step 6A names next_run_at, so the dispatcher is told what to confirm is clear"
else
  fail "AC3-c: Step 6A never mentions next_run_at — the dispatcher has no stated post-condition to verify, so a silently re-armed schedule ships again"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "cloud-dispatch-transport.test.sh: all checks passed"
  exit 0
else
  echo "cloud-dispatch-transport.test.sh: FAILURES above"
  exit 1
fi
