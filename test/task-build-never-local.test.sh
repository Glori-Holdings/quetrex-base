#!/usr/bin/env bash
# test/task-build-never-local.test.sh — a task build is NEVER run locally as a
# substitute for a missing cloud environment binding.
#
# Run: bash test/task-build-never-local.test.sh
#
# WHY THIS FILE EXISTS. 2026-09-02/03, repo dealerq-2026: `/quetrex:task-build
# DEA-12` hit Step 1a's qx_cloud_env_id failure (no cloudEnvironmentId). The
# session then ran the WHOLE pipeline locally as a Workflow in a hydrated
# worktree, and saved a feedback memory telling future sessions to do the same.
# Next day `/quetrex:task-build DEA-13` read that memory, showed the operator
# the architect's plan ending in "Approve?", and on "yes" ran locally again.
# The operator asked "is this running on anthropics servers?" — no. The scope
# approval was about the plan, not the execution location, so "yes" was not
# consent to run locally.
#
# Doctrine: a task build runs ONLY on Anthropic's cloud via RemoteTrigger. If
# Step 1a fails, the command is over — one line, then stop. This file pins:
#   (a) task-build.md carries the exact one-line stop message,
#   (b) it says a plan approval is not consent to change where the build runs,
#   (c) the scope-gate approval text names the cloud environment the build
#       will run in (so the tap is informed),
#   (d) the qx_cloud_env_id exec block STILL exits non-zero with an empty
#       binding — under bash AND zsh (the operator's shell) — and still
#       returns the id when one is bound (not vacuously broken),
#   (e) the pipeline doctrine skill says local execution without the typed
#       argument is a violation, never a fallback,
#   (f) the frontmatter Usage carries `[cloud|local]`,
#   (g) the file states `cloud` is the default,
#   (h) the doctrine says local requires the literal argument `local` and is
#       never inferred — and the qx_parse_args exec block, driven under bash
#       AND zsh, defaults to cloud, honours the typed word, and rejects any
#       other location with one line,
#   (i) task-rework.md cross-references the same stop rule,
#   (j) the typed `local` path does not dead-end: Step 6L forks from the
#       pinned approved base and publishes the SAME gates branch the cloud
#       routine does (qx_publish_gates, executed against a bare remote under
#       bash AND zsh), and Step 7 has a local branch ending in /quetrex:merge,
#   (k) `local` + epic is refused at Step 1b in every mode (executed),
#   (l) the publication logic exists in ONE copy (cloud-build-routine.md).
# Fail-first: (a),(b),(c),(e),(f),(g),(h) are proven ABSENT from the pre-fix
# baseline 85ec69c, and (j),(k) from the pre-rework head 31d6489 (literal
# shas, never `main`) before the shipped text is checked.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMAND="$REPO_ROOT/.claude/commands/task-build.md"
REWORK="$REPO_ROOT/.claude/commands/task-rework.md"
SKILL="$REPO_ROOT/.claude/skills/quetrex-pipeline/SKILL.md"
export PATH="$REPO_ROOT/bin:$PATH"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

for f in "$COMMAND" "$REWORK" "$SKILL"; do
  if [ ! -f "$f" ]; then
    echo "NOT OK - task-build-never-local.test.sh: file not found: $f"
    echo
    echo "task-build-never-local.test.sh: FAILURES above"
    exit 1
  fi
done
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node is not installed — qx_cloud_env_id is node-backed (quetrex-api json-get)"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-never-local.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# The exact strings under test. Change them here and in the command together.
STOP_LINE="Build not dispatched: no cloud environment is bound to this repo. Run /quetrex-setup:doctor — it names the environment and the one-line fix."
NOT_CONSENT="a plan approval is not consent to change where the build runs"
RUNS_ON="Runs unattended on Anthropic's cloud in environment <QX_CLOUD_ENV_ID>"
OVER="If this fails, the command is over"
SKILL_LINE="without the literal \`local\` argument is a violation, never a fallback"
LOCAL_LINE="Runs LOCALLY on this machine in worktree <path> (session must stay alive)"
USAGE_OPT="[cloud|local]"
DEFAULT_LINE="\`cloud\` is the default"
NEVER_INFERRED="local requires the literal argument \`local\` on this invocation and is never
inferred"
NEVER_INFERRED_1L="local requires the literal argument \`local\` on this invocation and is never"

# --------------------------------------------------------------------------
# FAIL-FIRST — the pre-fix baseline (85ec69c) must LACK every phrase below.
# --------------------------------------------------------------------------
BASE_SHA="85ec69c"
BASE_FULL="85ec69c"
if git -C "$REPO_ROOT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  BASE_FULL="$(git -C "$REPO_ROOT" rev-parse "$BASE_SHA^{commit}")"
else
  git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$BASE_SHA" 2>/dev/null || true
fi
if ! git -C "$REPO_ROOT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  fail "FAIL-FIRST: baseline commit $BASE_SHA is not reachable in this checkout even after a depth-1 fetch — cannot prove the fix, refusing to report a pass having compared against nothing"
else
  BASE_TB="$WORK/base-task-build.md"; git -C "$REPO_ROOT" show "$BASE_SHA:.claude/commands/task-build.md" > "$BASE_TB"
  BASE_SK="$WORK/base-SKILL.md";       git -C "$REPO_ROOT" show "$BASE_SHA:.claude/skills/quetrex-pipeline/SKILL.md" > "$BASE_SK"
  if [ -s "$BASE_TB" ] && [ -s "$BASE_SK" ]; then
    pass "FAIL-FIRST: baseline $BASE_SHA (${BASE_FULL:0:12}) task-build.md + SKILL.md extracted"
  else
    fail "FAIL-FIRST: baseline files came back empty from git show $BASE_SHA"
  fi
  absent() {  # absent <label> <file> <fixed-string>
    if grep -qF -- "$3" "$2"; then
      fail "FAIL-FIRST $1: baseline $BASE_SHA ALREADY contains \"$3\" — this assertion would pass against the pre-fix text and proves nothing"
    else
      pass "FAIL-FIRST $1: baseline $BASE_SHA lacks \"$3\" (the incident text was reachable)"
    fi
  }
  absent "(a) stop line"         "$BASE_TB" "$STOP_LINE"
  absent "(b) not-consent"       "$BASE_TB" "$NOT_CONSENT"
  absent "(c) approval runs-on"  "$BASE_TB" "$RUNS_ON"
  absent "(e) skill doctrine"    "$BASE_SK" "$SKILL_LINE"
  absent "(c) approval local"    "$BASE_TB" "$LOCAL_LINE"
  absent "(f) usage [cloud|local]" "$BASE_TB" "$USAGE_OPT"
  absent "(g) cloud is the default" "$BASE_TB" "$DEFAULT_LINE"
  absent "(h) never inferred"    "$BASE_TB" "$NEVER_INFERRED_1L"
  if grep -qF 'quetrex:exec-block qx_parse_args' "$BASE_TB"; then
    fail "FAIL-FIRST (h): baseline $BASE_SHA already has a qx_parse_args block"
  else
    pass "FAIL-FIRST (h): baseline $BASE_SHA has no qx_parse_args block (mode was a substring match, no run location)"
  fi
fi

# --------------------------------------------------------------------------
# (a)–(c): task-build.md, shipped text
# --------------------------------------------------------------------------
present() {  # present <label> <file> <fixed-string> [min-count]
  local n; n="$(grep -cF -- "$3" "$2" || true)"
  if [ "$n" -ge "${4:-1}" ]; then
    pass "$1: $(basename "$2") carries \"$3\" (x$n)"
  else
    fail "$1: $(basename "$2") does not carry \"$3\" (found $n, need ${4:-1})"
  fi
}
present "(a) exact one-line stop message"                        "$COMMAND" "$STOP_LINE"
present "(a) Step 1a heading: the command is over"               "$COMMAND" "$OVER"
present "(b) a plan approval is not consent to relocate the build" "$COMMAND" "$NOT_CONSENT"
present "(b) no local substitute — not a Workflow"                "$COMMAND" "not as a \`Workflow\`"
present "(b) a memory saying run-locally is stale and wrong"     "$COMMAND" "stale and wrong"

# (f)(g)(h): the typed-argument doctrine
if head -5 "$COMMAND" | grep -F 'Usage: /quetrex:task-build SMA-1' | grep -qF "$USAGE_OPT"; then
  pass "(f) frontmatter Usage carries $USAGE_OPT"
else
  fail "(f) frontmatter Usage does not carry $USAGE_OPT: $(head -5 "$COMMAND" | grep -F 'Usage:' | sed 's/.*Usage:/Usage:/')"
fi
if head -5 "$COMMAND" | grep -F 'argument-hint:' | grep -qF "$USAGE_OPT"; then
  pass "(f) argument-hint carries $USAGE_OPT"
else
  fail "(f) argument-hint does not carry $USAGE_OPT"
fi
present "(g) the file states cloud is the default"               "$COMMAND" "$DEFAULT_LINE" 2
present "(h) local requires the literal argument and is never inferred" "$COMMAND" "$NEVER_INFERRED_1L"
present "(h) a failed env lookup never turns cloud into local"   "$COMMAND" "A failed environment lookup never turns \`cloud\`"

# The stop line must sit INSIDE Step 1a, i.e. after the qx_cloud_env_id
# resolution and before Step 1b — not buried in the closing bullets only.
L_RESOLVE="$(grep -nF 'QX_CLOUD_ENV_ID="$(qx_cloud_env_id "$REPO_ROOT")" || exit 1' "$COMMAND" | head -1 | cut -d: -f1)"
L_STOP="$(grep -nF -- "$STOP_LINE" "$COMMAND" | head -1 | cut -d: -f1)"
L_1B="$(grep -n '^### 1b\.' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$L_RESOLVE" ] && [ -n "$L_STOP" ] && [ -n "$L_1B" ] && [ "$L_RESOLVE" -lt "$L_STOP" ] && [ "$L_STOP" -lt "$L_1B" ]; then
  pass "(a) the stop line sits inside Step 1a (resolve@$L_RESOLVE < stop@$L_STOP < 1b@$L_1B)"
else
  fail "(a) the stop line is not inside Step 1a (resolve=${L_RESOLVE:-?} stop=${L_STOP:-?} 1b=${L_1B:-?})"
fi

# (c) the approval prompt (Step 4b) names the environment — for the single
# unit AND the epic — and asserts Step 1a already ran.
L_4B="$(grep -n '^### 4b\.' "$COMMAND" | head -1 | cut -d: -f1)"
L_4C="$(grep -n '^### 4c\.' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$L_4B" ] && [ -n "$L_4C" ] && [ "$L_4B" -lt "$L_4C" ]; then
  SEC4B="$WORK/4b.md"; sed -n "${L_4B},${L_4C}p" "$COMMAND" > "$SEC4B"
  present "(c) Step 4b names where the build runs, single unit + epic" "$SEC4B" "$RUNS_ON" 2
  present "(c) Step 4b names the LOCAL run location for the local argument" "$SEC4B" "$LOCAL_LINE"
  present "(c) Step 4b: the approval text must carry the runs-on line" "$SEC4B" "text **must** carry the"
  present "(c) Step 4b asserts Step 1a already ran"                   "$SEC4B" "Step 1a has already run"
  present "(c) Step 4b: yes is never consent to run elsewhere"        "$SEC4B" "is never consent to run it"
else
  fail "(c) could not locate Step 4b..4c in task-build.md (4b=${L_4B:-?} 4c=${L_4C:-?})"
fi

# The closing "Never hardcode" bullet cross-references the same rule.
L_NH="$(grep -nF 'Never hardcode the cloud `environment_id`' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$L_NH" ] && sed -n "${L_NH},$((L_NH+5))p" "$COMMAND" | tr '\n' ' ' | grep -qF "run the build locally instead"; then
  pass "(a) the closing Never-hardcode bullet cross-references never-run-locally"
else
  fail "(a) the closing Never-hardcode bullet (line ${L_NH:-?}) does not cross-reference the never-run-locally rule"
fi

# --------------------------------------------------------------------------
# (d): the qx_cloud_env_id block, EXECUTED — empty binding exits non-zero
# under bash and zsh; a bound id is still returned.
# --------------------------------------------------------------------------
extract_block() {   # extract_block <name> > file
  awk -v name="$1" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$COMMAND"
}
# qx_valid_ids defines qx_valid_task_id / qx_valid_branch_prefix. qx_parse_args and
# qx_publish_gates both depend on it, so every driver below sources it first — exactly
# as the shipped command includes both blocks.
VALIDS="$WORK/qx_valid_ids.sh"
extract_block qx_valid_ids > "$VALIDS"
if [ -s "$VALIDS" ] && grep -q '^qx_valid_task_id()' "$VALIDS" && grep -q '^qx_valid_branch_prefix()' "$VALIDS"; then
  pass "(o) extracted the qx_valid_ids exec block ($(wc -l < "$VALIDS" | tr -d ' ') lines)"
else
  fail "(o) task-build.md has no executable qx_valid_ids block — the task id and the branch prefix are unvalidated"
fi
BLOCK="$WORK/qx_cloud_env_id.sh"
extract_block qx_cloud_env_id > "$BLOCK"
if [ -s "$BLOCK" ] && grep -q '^qx_cloud_env_id()' "$BLOCK"; then
  pass "(d) extracted the qx_cloud_env_id exec block ($(wc -l < "$BLOCK" | tr -d ' ') lines)"
else
  fail "(d) task-build.md has no executable qx_cloud_env_id block — the guard is prose again"
fi

UNBOUND="$WORK/unbound"; mkdir -p "$UNBOUND/.quetrex"
printf '%s\n' '{"projectCode":"QUE","branchPrefix":"claude/"}' > "$UNBOUND/.quetrex/project.json"
BOUND="$WORK/bound"; mkdir -p "$BOUND/.quetrex"
printf '%s\n' '{"projectCode":"QUE","branchPrefix":"claude/","cloudEnvironmentId":"env_NeverLocal1"}' > "$BOUND/.quetrex/project.json"

# drive <shell> <repo-root> — runs the SAME bytes the model is told to run,
# with the env-var fallback explicitly empty, and mirrors the command's own
# `QX_CLOUD_ENV_ID="$(qx_cloud_env_id "$REPO_ROOT")" || exit 1` line.
drive() {
  "$1" -c '. "$1"; QUETREX_CLOUD_ENVIRONMENT_ID= ; export QUETREX_CLOUD_ENVIRONMENT_ID
           QX_CLOUD_ENV_ID="$(qx_cloud_env_id "$2")" || exit 1
           printf "%s\n" "$QX_CLOUD_ENV_ID"' _ "$BLOCK" "$2"
}
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then
    pass "(d) $sh not present, skipped"
    continue
  fi
  OUT="$(PATH="$REPO_ROOT/bin:$PATH" drive "$sh" "$UNBOUND" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ]; then
    pass "(d) $sh: empty binding → qx_cloud_env_id exits non-zero (rc=$RC), the command is over"
  else
    fail "(d) $sh: with NO environment bound the resolve line exited 0 and printed [$OUT] — nothing stops the command, and the incident path (run it locally) is open again"
  fi
  case "$OUT" in
    *"No cloud environment is bound"*) pass "(d) $sh: the block's own stderr names the missing binding" ;;
    *) fail "(d) $sh: the block's stderr does not name the missing binding: $OUT" ;;
  esac
  OUT="$(PATH="$REPO_ROOT/bin:$PATH" drive "$sh" "$BOUND" 2>&1)"; RC=$?
  if [ "$RC" -eq 0 ] && [ "$OUT" = "env_NeverLocal1" ]; then
    pass "(d) $sh: a bound cloudEnvironmentId is returned (rc=0) — the guard is not vacuously broken"
  else
    fail "(d) $sh: bound id not returned: rc=$RC out=[$OUT]"
  fi
done

# --------------------------------------------------------------------------
# (h) EXECUTED: qx_parse_args under bash and zsh — cloud by default, `local`
# only when typed, anything else rejected with one line.
# --------------------------------------------------------------------------
PARSE="$WORK/qx_parse_args.sh"
awk -v name="qx_parse_args" '
  $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
' "$COMMAND" > "$PARSE"
if [ -s "$PARSE" ] && grep -q '^qx_parse_args()' "$PARSE"; then
  pass "(h) extracted the qx_parse_args exec block ($(wc -l < "$PARSE" | tr -d ' ') lines)"
else
  fail "(h) task-build.md has no executable qx_parse_args block — the run location is prose only"
fi
# parse <shell> <arguments...> — mirrors the command's own read line
parse() { local sh="$1"; shift; "$sh" -c '. "$1"; . "$2"; shift 2; qx_parse_args "$*"' _ "$VALIDS" "$PARSE" "$@"; }
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then pass "(h) $sh not present, skipped"; continue; fi
  OUT="$(parse "$sh" SMA-1 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && [ "$OUT" = "SMA-1 full cloud" ] && pass "(h) $sh: no location → cloud is the default (got: $OUT)" || fail "(h) $sh: 'SMA-1' → rc=$RC out=[$OUT], want 'SMA-1 full cloud'"
  OUT="$(parse "$sh" SMA-1 local 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && [ "$OUT" = "SMA-1 full local" ] && pass "(h) $sh: typed 'local' → local" || fail "(h) $sh: 'SMA-1 local' → rc=$RC out=[$OUT]"
  OUT="$(parse "$sh" SMA-1 local --build-only 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && [ "$OUT" = "SMA-1 build local" ] && pass "(h) $sh: 'local --build-only' → build local" || fail "(h) $sh: 'SMA-1 local --build-only' → rc=$RC out=[$OUT]"
  OUT="$(parse "$sh" SMA-1 --tick cloud 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && [ "$OUT" = "SMA-1 tick cloud" ] && pass "(h) $sh: '--tick cloud' → tick cloud (order-independent)" || fail "(h) $sh: 'SMA-1 --tick cloud' → rc=$RC out=[$OUT]"
  OUT="$(parse "$sh" SMA-1 --build-only 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] && [ "$OUT" = "SMA-1 build cloud" ] && pass "(h) $sh: '--build-only' alone → build cloud (existing routine entry point unchanged)" || fail "(h) $sh: 'SMA-1 --build-only' → rc=$RC out=[$OUT]"
  OUT="$(parse "$sh" SMA-1 laptop 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" = "1" ] && printf '%s' "$OUT" | grep -qF "cloud|local"; then
    pass "(h) $sh: 'laptop' is rejected with one line naming cloud|local"
  else
    fail "(h) $sh: 'SMA-1 laptop' → rc=$RC out=[$OUT] — must be rejected with exactly one line naming cloud|local"
  fi
  OUT="$(parse "$sh" SMA-1 LOCAL 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] && pass "(h) $sh: 'LOCAL' (not the literal word) is rejected" || fail "(h) $sh: 'SMA-1 LOCAL' was accepted as [$OUT] — only the literal lowercase word selects local"
  OUT="$(parse "$sh" "" 2>&1)"; RC=$?
  [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "$USAGE_OPT" && pass "(h) $sh: empty arguments → usage line carries $USAGE_OPT" || fail "(h) $sh: empty arguments → rc=$RC out=[$OUT]"
done

# --------------------------------------------------------------------------
# (e): the doctrine skill; (i): task-rework.md cross-reference
# --------------------------------------------------------------------------
present "(e) SKILL.md: local execution is a violation, never a fallback" "$SKILL"  "$SKILL_LINE"
present "(e) SKILL.md: the binding is the fix"                           "$SKILL"  "the environment binding is the fix"
present "(e) SKILL.md command map names the run location"                "$SKILL"  "[cloud\\|local]"
present "(i) task-rework.md carries the same stop line"                  "$REWORK" "Build not dispatched: no cloud environment is bound to this repo"
present "(i) task-rework.md: if this fails, the command is over"         "$REWORK" "$OVER"

# --------------------------------------------------------------------------
# (j)–(l): REWORK of PR #145 — the local path must not dead-end at the merge.
#   (j) Step 6L forks from the payload's pinned approved base (same pin and
#       the same `quetrex-cloud-prep sync` as the cloud routine's step 2b) and
#       publishes the SAME gates branch the routine publishes at its step 5b,
#       via the qx_publish_gates exec block — EXECUTED here under bash and zsh
#       against a real bare remote; and Step 7 has a local branch that names
#       /quetrex:merge, no monitor URL, and no "needs no session" contradiction.
#   (k) qx_reject_local_epic refuses `local` for an epic at Step 1b — in every
#       mode, before the plan half — EXECUTED under bash and zsh.
#   (l) ONE COPY: the publication block exists exactly once, between the
#       sentinels in cloud-build-routine.md; task-build.md calls it by name and
#       carries no second GATES_BRANCH= assignment.
# Fail-first: every phrase is proven ABSENT from 31d6489, the pre-rework head
# of PR #145 (a literal sha, never `main`).
# --------------------------------------------------------------------------
LOCAL_S7="**Single unit, \`local\` (Step 6L).**"
NO_CONTRADICTION="neither cloud dispatch needs this session"
RW_SHA="31d6489"
if git -C "$REPO_ROOT" cat-file -e "$RW_SHA^{commit}" 2>/dev/null || { git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$RW_SHA" 2>/dev/null && git -C "$REPO_ROOT" cat-file -e "$RW_SHA^{commit}" 2>/dev/null; }; then
  RW_TB="$WORK/rework-base-task-build.md"; git -C "$REPO_ROOT" show "$RW_SHA:.claude/commands/task-build.md" > "$RW_TB"
  if [ -s "$RW_TB" ]; then
    pass "FAIL-FIRST (j-l): rework baseline $RW_SHA task-build.md extracted"
    absent "(j) 6L publishes the gates"     "$RW_TB" "quetrex:exec-block qx_publish_gates"
    absent "(j) 6L runs the routine's block" "$RW_TB" "QUETREX GATE PUBLICATION"
    absent "(j) Step 7 local branch"        "$RW_TB" "$LOCAL_S7"
    absent "(j) Step 7 contradiction fixed" "$RW_TB" "$NO_CONTRADICTION"
    absent "(k) parse-time epic guard"      "$RW_TB" "quetrex:exec-block qx_reject_local_epic"
  else
    fail "FAIL-FIRST (j-l): baseline task-build.md came back empty from git show $RW_SHA"
  fi
else
  fail "FAIL-FIRST (j-l): rework baseline $RW_SHA is not reachable even after a depth-1 fetch — refusing to report a pass having compared against nothing"
fi

# (j) Step 6L text — scoped to the 6L section, not the whole file.
L_6L="$(grep -n '^### L) Single unit' "$COMMAND" | head -1 | cut -d: -f1)"
L_6A="$(grep -n '^### A) Single unit' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$L_6L" ] && [ -n "$L_6A" ] && [ "$L_6L" -lt "$L_6A" ]; then
  SEC6L="$WORK/6L.md"; sed -n "${L_6L},${L_6A}p" "$COMMAND" > "$SEC6L"
  present "(j) 6L pins the approved base with the 6A function"        "$SEC6L" 'APPROVED_BASE_SHA="$(qx_approved_base_sha "$PAYLOAD"'
  present "(j) 6L creates a re-made worktree AT the approved sha"      "$SEC6L" 'worktree add --detach --quiet "$WT" "$APPROVED_BASE_SHA"'
  present "(j) 6L syncs like the routine's step 2b"                    "$SEC6L" 'quetrex-cloud-prep sync "$BASE_BRANCH" "$APPROVED_BASE_SHA" "$UNIT_BRANCH" --repo "$WT"'
  present "(j) 6L stops before the engine's teardown"                  "$SEC6L" "stop before step 10's teardown"
  present "(j) 6L names the routine's sentinel block"                  "$SEC6L" "# >>> QUETREX GATE PUBLICATION >>>"
  present "(j) 6L calls qx_publish_gates from the unit worktree"       "$SEC6L" 'qx_publish_gates "$WT" "$TASK_ID" "$BRANCH_PREFIX" || exit 1'
  present "(j) 6L still hands off to Step 7"                           "$SEC6L" "Then go to **Step 7**"
else
  fail "(j) could not locate Step 6L..6A in task-build.md (6L=${L_6L:-?} 6A=${L_6A:-?})"
fi

# (j) Step 7 — a local branch, and the cloud-only claims no longer unconditional.
L_S7="$(grep -n '^## Step 7' "$COMMAND" | head -1 | cut -d: -f1)"
L_S8="$(awk -v s="${L_S7:-0}" 'NR>s && /^## /{print NR; exit}' "$COMMAND")"
if [ -n "$L_S7" ] && [ -n "$L_S8" ] && [ "$L_S7" -lt "$L_S8" ]; then
  SEC7="$WORK/step7.md"; sed -n "${L_S7},${L_S8}p" "$COMMAND" > "$SEC7"
  present "(j) Step 7 has a local branch"                              "$SEC7" "$LOCAL_S7"
  present "(j) Step 7: only the CLOUD dispatches need no live session"  "$SEC7" "$NO_CONTRADICTION"
  if grep -qF "neither one needs this session to stay alive" "$SEC7"; then
    fail "(j) Step 7 still asserts unconditionally that no run needs this session — contradicts 6L"
  else
    pass "(j) Step 7 no longer contradicts 6L's session-must-stay-alive"
  fi
  L_LOC="$(grep -nF "$LOCAL_S7" "$SEC7" | head -1 | cut -d: -f1)"
  L_CLD="$(grep -nF '**Single unit, cloud.**' "$SEC7" | head -1 | cut -d: -f1)"
  if [ -n "$L_LOC" ] && [ -n "$L_CLD" ] && [ "$L_LOC" -lt "$L_CLD" ]; then
    LOCPARA="$WORK/step7-local.md"; sed -n "${L_LOC},$((L_CLD-1))p" "$SEC7" > "$LOCPARA"
    present "(j) Step 7 local branch names /quetrex:merge <TASK-ID>"    "$LOCPARA" '/quetrex:merge <TASK-ID>'
    present "(j) Step 7 local branch names the gates branch shape"       "$LOCPARA" '<prefix><TASK>-gates-<sha7>'
    present "(j) Step 7 local branch reports the worktree path"          "$LOCPARA" 'worktree path'
    present "(j) Step 7 local branch reports the PR URL"                 "$LOCPARA" 'PR URL'
    present "(j) Step 7 local branch says the session had to stay alive" "$LOCPARA" 'session had to stay alive'
    if grep -qF 'claude.ai/code/routines' "$LOCPARA"; then
      fail "(j) Step 7's local branch still points at a routine monitor URL a local run never has"
    else
      pass "(j) Step 7's local branch reports no monitor URL"
    fi
  else
    fail "(j) Step 7: local branch (${L_LOC:-?}) must come before the cloud branch (${L_CLD:-?})"
  fi
else
  fail "(j) could not locate Step 7 in task-build.md (7=${L_S7:-?} next=${L_S8:-?})"
fi

# (j) EXECUTED: qx_publish_gates against a real bare remote, under bash and zsh.
PUB="$WORK/qx_publish_gates.sh"
extract_block qx_publish_gates > "$PUB"
if [ -s "$PUB" ] && grep -q '^qx_publish_gates()' "$PUB"; then
  pass "(j) extracted the qx_publish_gates exec block ($(wc -l < "$PUB" | tr -d ' ') lines)"
else
  fail "(j) task-build.md has no executable qx_publish_gates block — the local merge path is prose only"
fi
gates_fixture() {   # gates_fixture <name> <task> [no-plan] -> echoes the clone path
  local bare="$WORK/$1.git" work="$WORK/$1"
  git init -q --bare "$bare"
  git init -q -b main "$work"
  git -C "$work" config user.email t@example.com
  git -C "$work" config user.name  Tester
  printf '.quetrex/\n' > "$work/.gitignore"
  printf 'console.log(1);\n' > "$work/build.js"
  git -C "$work" add -A && git -C "$work" commit -q -m "seed"
  git -C "$work" remote add origin "$bare" && git -C "$work" push -q origin main
  git -C "$work" checkout -q -b "claude/$2-unit"
  mkdir -p "$work/.quetrex/plan"
  printf '{"verdict":"AUTO_MERGE"}\n'    > "$work/.quetrex/review-verdict.json"
  printf '{"cmd":"npm test","exit":0}\n' > "$work/.quetrex/verify-ledger.jsonl"
  printf '{"task":"%s","review_iter":0}\n' "$2" > "$work/.quetrex/state.json"
  [ "${3:-}" = "no-plan" ] || printf '{"task":"%s","ownership":{"build.js":"ws1"}}\n' "$2" > "$work/.quetrex/plan/$2.json"
  echo "$work"
}
# drive_publish <shell> <wt> <task> — the SAME bytes the model is told to run,
# with the routine located the way the shipped block locates it (bin/ on PATH).
drive_publish() {   # drive_publish <shell> <wt> <task> [prefix] [routine.md]
  PATH="$REPO_ROOT/bin:$PATH" "$1" -c '. "$1"; . "$2"; qx_publish_gates "$3" "$4" "${5:-claude/}" ${6:+"$6"}' \
    _ "$VALIDS" "$PUB" "$2" "$3" "${4:-claude/}" "${5:-}"
}
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then pass "(j) $sh not present, skipped"; continue; fi
  # A REAL task-id shape. qx_valid_task_id (Step 1) now refuses anything else, so a
  # fixture id that is not a real identifier would prove only that the guard fires.
  T="QXL${$}${sh}-1"; rm -f "/tmp/plan-$T.json"
  WTX="$(gates_fixture "pub-$sh" "$T")"
  HEADX="$(git -C "$WTX" rev-parse HEAD)"
  OUT="$(drive_publish "$sh" "$WTX" "$T" 2>&1)"; RC=$?
  REF="$(git -C "$WORK/pub-$sh.git" for-each-ref --format='%(refname:short)' "refs/heads/claude/$T-gates-*" | head -1)"
  if [ "$RC" -eq 0 ] && [ -n "$REF" ]; then
    pass "(j) $sh: qx_publish_gates exits 0 and origin now has $REF"
  else
    fail "(j) $sh: qx_publish_gates rc=$RC gates-ref='${REF:-none}' out=[$OUT]"
  fi
  GH="$(git -C "$WORK/pub-$sh.git" show "$REF:.quetrex/gates-head" 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$REF" ] && [ "$GH" = "$HEADX" ]; then
    pass "(j) $sh: the published gates-head IS the unit head (${HEADX:0:12}) — /quetrex:merge selects it by content"
  else
    fail "(j) $sh: gates-head on $REF is '${GH:-missing}', unit head is $HEADX"
  fi
  for f in review-verdict.json verify-ledger.jsonl state.json "plan/$T.json"; do
    if [ -n "$REF" ] && git -C "$WORK/pub-$sh.git" show "$REF:.quetrex/$f" >/dev/null 2>&1; then
      pass "(j) $sh: .quetrex/$f rode the gates branch home"
    else
      fail "(j) $sh: .quetrex/$f is NOT on the gates branch — the merge gate would read it as missing"
    fi
  done
  # Negative: a required artifact missing must FAIL the wrapper and push nothing.
  T2="${T}0"; rm -f "/tmp/plan-$T2.json"
  WTN="$(gates_fixture "nopub-$sh" "$T2" no-plan)"
  OUT="$(drive_publish "$sh" "$WTN" "$T2" 2>&1)"; RC=$?
  REFN="$(git -C "$WORK/nopub-$sh.git" for-each-ref --format='%(refname:short)' "refs/heads/claude/$T2-gates-*" | head -1)"
  if [ "$RC" -ne 0 ] && [ -z "$REFN" ] && printf '%s' "$OUT" | grep -q 'transport_failure'; then
    pass "(j) $sh: with the plan missing the wrapper fails (rc=$RC), names transport_failure, and pushes nothing"
  else
    fail "(j) $sh: missing plan → rc=$RC ref='${REFN:-none}' out=[$OUT] — a swallowed failure would publish incomplete evidence"
  fi
done

# (k) EXECUTED: qx_reject_local_epic under bash and zsh, and it sits in Step 1
# (before Step 2), where every mode passes through.
EPIC_LINE="local builds a single unit; an epic's children are always cloud routines — re-run without local."
REJ="$WORK/qx_reject_local_epic.sh"
extract_block qx_reject_local_epic > "$REJ"
if [ -s "$REJ" ] && grep -q '^qx_reject_local_epic()' "$REJ"; then
  pass "(k) extracted the qx_reject_local_epic exec block ($(wc -l < "$REJ" | tr -d ' ') lines)"
else
  fail "(k) task-build.md has no executable qx_reject_local_epic block — the epic guard is prose only"
fi
L_REJ="$(grep -nF 'qx_reject_local_epic "$KIND" "$RUN_WHERE" || exit 1' "$COMMAND" | head -1 | cut -d: -f1)"
L_S2="$(grep -n '^## Step 2' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$L_REJ" ] && [ -n "$L_S2" ] && [ "$L_REJ" -lt "$L_S2" ]; then
  pass "(k) the guard call sits in Step 1 (line $L_REJ < Step 2 @ $L_S2) — every mode passes through it"
else
  fail "(k) the guard call is not in Step 1 (call=${L_REJ:-?} step2=${L_S2:-?})"
fi
reject() { "$1" -c '. "$1"; qx_reject_local_epic "$2" "$3"' _ "$REJ" "$2" "$3"; }
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then pass "(k) $sh not present, skipped"; continue; fi
  OUT="$(reject "$sh" epic local 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && [ "$OUT" = "$EPIC_LINE" ]; then
    pass "(k) $sh: epic + local → rejected with exactly the one line"
  else
    fail "(k) $sh: epic + local → rc=$RC out=[$OUT]"
  fi
  for pair in "single local" "epic cloud" "single cloud"; do
    # shellcheck disable=SC2086
    OUT="$(reject "$sh" $pair 2>&1)"; RC=$?
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] && pass "(k) $sh: $pair → allowed, silent" || fail "(k) $sh: $pair → rc=$RC out=[$OUT]"
  done
done

# --------------------------------------------------------------------------
# (o) SEC-4 / SEC-5 — the task id and the branch prefix are DATA, not code.
#
# THE DEFECT (SEC-4, HIGH, demonstrated by execution against 80b7895).
# qx_publish_gates substituted $task and $prefix into the extracted publication
# block with an unescaped `sed s|{{TASK}}|$task|g` and then ran the result with
# `bash "$script"`. Both placeholders sat inside double-quoted shell strings, so
#   * a branchPrefix carrying a double quote closed the string and ran what
#     followed — and branchPrefix is COMMITTED data, read from
#     .quetrex/project.json at Step 1, so a branch that edits its own binding
#     executes shell on the operator's machine the next time it is built local;
#   * a task id that was a bare `$(...)` or backtick needed no quote at all —
#     sed wrote it verbatim and bash expanded it at run time. The task id comes
#     straight from $ARGUMENTS through a parser that split on whitespace and
#     validated nothing.
#
# THE FIX IS NOT MORE ESCAPING. Both values are validated at their source
# (qx_valid_ids, Step 1), and the script no longer carries them at all — they
# travel in the ENVIRONMENT and the routine's block reads them as shell
# variables. SEC-5: the extractor now takes exactly the FIRST sentinel pair and
# refuses a routine carrying more than one.
#
# The FAIL-FIRST block at the end runs the SAME payloads against the pre-fix
# bytes (git show 80b7895) and REQUIRES the canary to appear there. Without it
# every refusal below could be green against a payload that never executed.
# --------------------------------------------------------------------------
ROUTINE="$REPO_ROOT/.claude/lib/cloud-build-routine.md"
CANDIR="$WORK/canary"; mkdir -p "$CANDIR"
canary_absent() {   # canary_absent <label> <name>
  if [ -e "$CANDIR/$2" ]; then
    fail "$1: the injected command RAN — $CANDIR/$2 exists"
    rm -f "$CANDIR/$2"
  else
    pass "$1: nothing executed (no $2 canary)"
  fi
}

# (o) the wiring, in the shipped text.
present "(o) qx_parse_args validates the task id"        "$COMMAND" 'qx_valid_task_id "$task" || return 1'
present "(o) the binding read validates the prefix"      "$COMMAND" 'qx_valid_branch_prefix "$BRANCH_PREFIX" || exit 1'
present "(o) qx_publish_gates re-asserts both shapes"    "$COMMAND" 'qx_valid_task_id       "$task"   || return 1'
present "(o) the values reach the script by environment" "$COMMAND" 'QX_TASK="$task" QX_BRANCH_PREFIX="$prefix" bash "$script"'
present "(o) the routine block reads QX_TASK"            "$ROUTINE" '[ -n "${QX_TASK:-}" ]'
present "(o) the routine block reads QX_BRANCH_PREFIX"   "$ROUTINE" '[ -n "${QX_BRANCH_PREFIX:-}" ]'
if grep -qF 's|{{TASK}}|' "$COMMAND" || grep -qF 's|{{BRANCH_PREFIX}}|' "$COMMAND"; then
  fail "(o) task-build.md still substitutes a caller value into the publication script's TEXT — that is the SEC-4 vector"
else
  pass "(o) task-build.md substitutes nothing into the publication script's text"
fi

# (o) EXECUTED: the two validators, under bash and zsh.
vid()  { "$1" -c '. "$1"; qx_valid_task_id "$2"'       _ "$VALIDS" "$2"; }
vpfx() { "$1" -c '. "$1"; qx_valid_branch_prefix "$2"' _ "$VALIDS" "$2"; }
one_line() { [ "$(printf '%s\n' "$1" | wc -l | tr -d ' ')" = "1" ]; }
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then pass "(o) $sh not present, skipped"; continue; fi
  for good in SMA-1 QDM-5.1 A-1 QUE-142; do
    if vid "$sh" "$good" 2>/dev/null; then
      pass "(o) $sh: qx_valid_task_id accepts the real identifier $good"
    else
      fail "(o) $sh: qx_valid_task_id REFUSED the legitimate id $good — the guard is over-tight and no task can be built"
    fi
  done
  for bad in "" "SMA" "SMA-" "-1" "SMA-1x" "SMA-1.2.3" "SMA-1 local" \
             'SMA-1"; touch '"$CANDIR"'/vid-q; :"' \
             '$(touch '"$CANDIR"'/vid-cs)' \
             '`touch '"$CANDIR"'/vid-bt`' \
             "$(printf 'SMA-1\n; touch %s/vid-nl' "$CANDIR")"; do
    OUT="$(vid "$sh" "$bad" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ] && one_line "$OUT" && printf '%s' "$OUT" | grep -qF 'Not a task id'; then
      pass "(o) $sh: qx_valid_task_id refuses [$(printf '%s' "$bad" | tr '\n' '~')] with one line"
    else
      fail "(o) $sh: qx_valid_task_id accepted or misreported [$(printf '%s' "$bad" | tr '\n' '~')] — rc=$RC out=[$OUT]"
    fi
  done
  for good in claude/ que/ feature/ team.a/sub-1/; do
    if vpfx "$sh" "$good" 2>/dev/null; then
      pass "(o) $sh: qx_valid_branch_prefix accepts $good"
    else
      fail "(o) $sh: qx_valid_branch_prefix REFUSED the legitimate prefix $good"
    fi
  done
  for bad in "" "claude" "/claude/" "-claude/" "claude/../" \
             'claude/"; touch '"$CANDIR"'/vpfx-q; :"' \
             'claude/$(touch '"$CANDIR"'/vpfx-cs)/' \
             'claude/`touch '"$CANDIR"'/vpfx-bt`/' \
             "$(printf 'claude/\n; touch %s/vpfx-nl' "$CANDIR")"; do
    OUT="$(vpfx "$sh" "$bad" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ] && one_line "$OUT" && printf '%s' "$OUT" | grep -qF 'Not a branch prefix'; then
      pass "(o) $sh: qx_valid_branch_prefix refuses [$(printf '%s' "$bad" | tr '\n' '~')] with one line"
    else
      fail "(o) $sh: qx_valid_branch_prefix accepted or misreported [$(printf '%s' "$bad" | tr '\n' '~')] — rc=$RC out=[$OUT]"
    fi
  done
done
canary_absent "(o) validator payloads: quoted task id"   vid-q
canary_absent "(o) validator payloads: \$() task id"     vid-cs
canary_absent "(o) validator payloads: backtick task id" vid-bt
canary_absent "(o) validator payloads: newline task id"  vid-nl
canary_absent "(o) validator payloads: quoted prefix"    vpfx-q
canary_absent "(o) validator payloads: \$() prefix"      vpfx-cs
canary_absent "(o) validator payloads: backtick prefix"  vpfx-bt
canary_absent "(o) validator payloads: newline prefix"   vpfx-nl

# (o) EXECUTED end to end: qx_publish_gates itself, against a real bare remote.
# A routine copy carrying a SECOND sentinel pair — the SEC-5 shape: the branch under
# review supplies the bytes, and the old extractor appended every pair it found.
DUP="$WORK/dup-routine.md"
cp "$ROUTINE" "$DUP"
{
  printf '\n    # >>> QUETREX GATE PUBLICATION >>>\n'
  printf '    touch %s/pub-second-pair\n' "$CANDIR"
  printf '    # <<< QUETREX GATE PUBLICATION <<<\n'
} >> "$DUP"
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then pass "(o) $sh not present (publish), skipped"; continue; fi
  SAFE="QXS${$}${sh}-1"
  WTS="$(gates_fixture "sec4-$sh" "$SAFE")"
  # 1. hostile TASK ID, legitimate prefix
  for pay in 'SMA-1"; touch '"$CANDIR"'/pub-task-q; :"' \
             '$(touch '"$CANDIR"'/pub-task-cs)' \
             '`touch '"$CANDIR"'/pub-task-bt`'; do
    OUT="$(drive_publish "$sh" "$WTS" "$pay" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'Not a task id'; then
      pass "(o) $sh: qx_publish_gates refuses the injected task id before anything runs"
    else
      fail "(o) $sh: injected task id reached the publication — rc=$RC out=[$OUT]"
    fi
  done
  # 2. hostile BRANCH PREFIX, legitimate task id
  for pay in 'claude/"; touch '"$CANDIR"'/pub-pfx-q; :"' \
             'claude/$(touch '"$CANDIR"'/pub-pfx-cs)/' \
             'claude/`touch '"$CANDIR"'/pub-pfx-bt`/'; do
    OUT="$(drive_publish "$sh" "$WTS" "$SAFE" "$pay" 2>&1)"; RC=$?
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'Not a branch prefix'; then
      pass "(o) $sh: qx_publish_gates refuses the injected branchPrefix before anything runs"
    else
      fail "(o) $sh: injected branchPrefix reached the publication — rc=$RC out=[$OUT]"
    fi
  done
  NREF="$(git -C "$WORK/sec4-$sh.git" for-each-ref --format='%(refname:short)' refs/heads/ | grep -c -- '-gates-' || true)"
  if [ "$NREF" = "0" ]; then
    pass "(o) $sh: no refused run pushed anything to origin"
  else
    fail "(o) $sh: a refused run still published $NREF gates ref(s)"
  fi
  # 3. SEC-5 — a routine carrying TWO sentinel pairs must fail loudly, not concatenate.
  OUT="$(drive_publish "$sh" "$WTS" "$SAFE" "claude/" "$DUP" 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF 'exactly one pair is required'; then
    pass "(o) $sh: a routine with two GATE PUBLICATION pairs is refused by name"
  else
    fail "(o) $sh: two sentinel pairs → rc=$RC out=[$OUT] — the extractor concatenated them again"
  fi
done
canary_absent "(o) publish: quoted task id"   pub-task-q
canary_absent "(o) publish: \$() task id"     pub-task-cs
canary_absent "(o) publish: backtick task id" pub-task-bt
canary_absent "(o) publish: quoted prefix"    pub-pfx-q
canary_absent "(o) publish: \$() prefix"      pub-pfx-cs
canary_absent "(o) publish: backtick prefix"  pub-pfx-bt
canary_absent "(o) publish: second sentinel pair" pub-second-pair

# (o) FAIL-FIRST — the SAME payloads against the pre-fix bytes (80b7895).
# They must EXECUTE there. A refusal above that cannot be shown to have been an
# execution before is a test of nothing.
SEC_SHA="80b7895"
if ! git -C "$REPO_ROOT" cat-file -e "$SEC_SHA^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$SEC_SHA" 2>/dev/null || true
fi
if ! git -C "$REPO_ROOT" cat-file -e "$SEC_SHA^{commit}" 2>/dev/null; then
  fail "(o) FAIL-FIRST: baseline $SEC_SHA unreachable — refusing to report a pass having compared against nothing"
else
  OLD_TB="$WORK/sec4-task-build.md"; git -C "$REPO_ROOT" show "$SEC_SHA:.claude/commands/task-build.md"      > "$OLD_TB"
  OLD_RT="$WORK/sec4-routine.md";    git -C "$REPO_ROOT" show "$SEC_SHA:.claude/lib/cloud-build-routine.md"  > "$OLD_RT"
  OLD_PUB="$WORK/sec4-qx_publish_gates.sh"
  awk -v name="qx_publish_gates" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$OLD_TB" > "$OLD_PUB"
  if grep -qF 's|{{TASK}}|' "$OLD_PUB" && ! grep -q 'qx_valid_task_id' "$OLD_PUB"; then
    pass "(o) FAIL-FIRST: $SEC_SHA's qx_publish_gates seds the values into the script text and validates nothing"
  else
    fail "(o) FAIL-FIRST: $SEC_SHA's qx_publish_gates does not look like the pre-fix version — the control is not testing the reported defect"
  fi
  drive_old() {   # drive_old <shell> <wt> <task> <prefix> <routine>
    PATH="$REPO_ROOT/bin:$PATH" "$1" -c '. "$1"; qx_publish_gates "$2" "$3" "$4" "$5"' \
      _ "$OLD_PUB" "$2" "$3" "$4" "$5"
  }
  for sh in bash zsh; do
    if ! command -v "$sh" >/dev/null 2>&1; then pass "(o) FAIL-FIRST $sh not present, skipped"; continue; fi
    OLDT="QXO${$}${sh}-1"; rm -f "/tmp/plan-$OLDT.json"
    WTO="$(gates_fixture "sec4old-$sh" "$OLDT")"
    drive_old "$sh" "$WTO" '$(touch '"$CANDIR"'/old-task-cs)' "claude/" "$OLD_RT" >/dev/null 2>&1
    drive_old "$sh" "$WTO" '`touch '"$CANDIR"'/old-task-bt`' "claude/" "$OLD_RT" >/dev/null 2>&1
    drive_old "$sh" "$WTO" "$OLDT" 'claude/"; touch '"$CANDIR"'/old-pfx-q; :"' "$OLD_RT" >/dev/null 2>&1
    WTOD="$(gates_fixture "sec4olddup-$sh" "$OLDT")"
    drive_old "$sh" "$WTOD" "$OLDT" "claude/" "$DUP" >/dev/null 2>&1
    for c in old-task-cs old-task-bt old-pfx-q; do
      if [ -e "$CANDIR/$c" ]; then
        pass "(o) FAIL-FIRST $sh: $SEC_SHA EXECUTED the payload ($c canary created) — the vector was live"
        rm -f "$CANDIR/$c"
      else
        fail "(o) FAIL-FIRST $sh: $SEC_SHA did NOT execute $c — the payload proves nothing, so the refusal above proves nothing"
      fi
    done
    if [ -e "$CANDIR/pub-second-pair" ]; then
      pass "(o) FAIL-FIRST $sh: $SEC_SHA's extractor concatenated the SECOND sentinel pair and ran it (SEC-5 was live)"
      rm -f "$CANDIR/pub-second-pair"
    else
      fail "(o) FAIL-FIRST $sh: $SEC_SHA did not run the second sentinel pair — the SEC-5 assertion above proves nothing"
    fi
  done
fi

# (l) ONE COPY of the publication logic.
N_SENT="$(git -C "$REPO_ROOT" grep -l -E '^[[:space:]]*# >>> QUETREX GATE PUBLICATION >>>[[:space:]]*$' -- . 2>/dev/null | wc -l | tr -d ' ')"
if [ "$N_SENT" = "1" ] && git -C "$REPO_ROOT" grep -q -E '^[[:space:]]*# >>> QUETREX GATE PUBLICATION >>>[[:space:]]*$' -- .claude/lib/cloud-build-routine.md; then
  pass "(l) exactly one tracked file carries the publication block, and it is cloud-build-routine.md"
else
  fail "(l) the publication block's start sentinel is in $N_SENT tracked file(s) — must be exactly one (cloud-build-routine.md)"
fi
if grep -qE '^[[:space:]]*GATES_BRANCH=' "$COMMAND"; then
  fail "(l) task-build.md assigns GATES_BRANCH= itself — a second copy of the publication logic"
else
  pass "(l) task-build.md carries no GATES_BRANCH= assignment — it runs the routine's block, it does not restate it"
fi
present "(l) task-build.md names the routine's block by its sentinel"       "$COMMAND" "QUETREX GATE PUBLICATION" 3
present "(l) task-build.md says the extracted bytes are routine-transport-tested" "$COMMAND" "test/routine-transport.test.sh"
present "(l) the doctrine skill says a local build publishes the same gates branch" "$SKILL" '<prefix><TASK>-gates-<sha7>'

# (m) Security runs BEFORE the reviewer. Measured 2026-09-03 on a local run:
# the reviewer ran first, found no security-findings.json, and wrote
# ESCALATE_HUMAN mechanically. Both the engine and 6L must state the order.
ORDER_LINE="qa → security-reviewer (when required) → reviewer → git-workflow"
NOT_UNTIL="must not run until"
present "(m) dev-pipeline.md states the stage order"                    "$REPO_ROOT/.claude/lib/dev-pipeline.md" "$ORDER_LINE"
present "(m) dev-pipeline.md: reviewer waits for the security artifact" "$REPO_ROOT/.claude/lib/dev-pipeline.md" "$NOT_UNTIL"
if [ -n "${SEC6L:-}" ] && [ -f "$SEC6L" ]; then
  present "(m) Step 6L states the same stage order"                     "$SEC6L" "$ORDER_LINE"
  present "(m) Step 6L: reviewer waits for security-findings.json"      "$SEC6L" "$NOT_UNTIL"
fi

# (n) A merge is NEVER automated (operator ruling 2026-09-03). Step 7 — both
# the cloud and the local branch — and the closing bullets end on the single
# next step; no AskUserQuestion about merging, no `gh pr merge`.
NEXT_STEP='run /quetrex:merge <TASK-ID> when you are ready'
NEVER_AUTO="The merge is never automated"
if [ -n "${SEC7:-}" ] && [ -f "$SEC7" ]; then
  present "(n) Step 7: the merge is never automated"                     "$SEC7" "$NEVER_AUTO"
  present "(n) Step 7: the single next step, local + cloud + the rule"   "$SEC7" "$NEXT_STEP" 3
  present "(n) Step 7 names /quetrex:merge <TASK-ID>"                     "$SEC7" '/quetrex:merge <TASK-ID>' 3
  present "(n) Step 7: an earlier yes is not merge authorization"        "$SEC7" "merge authorization"
fi
L_RULES="$(grep -n '^## Error-handling rules' "$COMMAND" | head -1 | cut -d: -f1)"
if [ -n "$L_RULES" ]; then
  RULES="$WORK/rules.md"; sed -n "${L_RULES},\$p" "$COMMAND" > "$RULES"
  present "(n) closing bullets: a merge is never automated"              "$RULES" "A merge is never automated"
  present "(n) closing bullets carry the single next step"               "$RULES" "$NEXT_STEP"
else
  fail "(n) could not locate the Error-handling rules section"
fi
# Every AskUserQuestion mention in task-build.md must be a PROHIBITION about
# merging (a `never` on the same line), never an instruction — and none may
# sit inside a fenced block, where it would be an invocation.
N_ASK="$(grep -c 'AskUserQuestion' "$COMMAND" || true)"
BAD_ASK="$(grep -n 'AskUserQuestion' "$COMMAND" | grep -v -i 'never' || true)"
if [ "$N_ASK" -gt 0 ] && [ -z "$BAD_ASK" ]; then
  pass "(n) all $N_ASK AskUserQuestion mention(s) are prohibitions (each line says never)"
else
  fail "(n) an AskUserQuestion mention is not a prohibition: ${BAD_ASK:-none found at all (need the rule, x$N_ASK)}"
fi
FENCED_ASK="$(awk '/^```/{inf=!inf; next} inf && /AskUserQuestion/{print NR": "$0}' "$COMMAND")"
if [ -z "$FENCED_ASK" ]; then
  pass "(n) no fenced block in task-build.md invokes AskUserQuestion"
else
  fail "(n) AskUserQuestion inside a fenced block (an invocation, not a rule): $FENCED_ASK"
fi
for L in $(grep -n 'AskUserQuestion' "$COMMAND" | cut -d: -f1); do
  CTX="$(sed -n "$((L>3?L-3:1)),$((L+3))p" "$COMMAND" | tr '\n' ' ')"
  case "$CTX" in
    *merge*) printf '%s' "$CTX" | grep -q -i 'never' && pass "(n) AskUserQuestion@$L: merge context is a never-rule" || fail "(n) AskUserQuestion@$L asks about merging: $CTX" ;;
    *) pass "(n) AskUserQuestion@$L: not about merging" ;;
  esac
done
BAD_GH="$(grep -n 'gh pr merge' "$COMMAND" | grep -v -i 'never' || true)"
if [ -z "$BAD_GH" ]; then
  pass "(n) task-build.md never runs gh pr merge (every mention is a prohibition)"
else
  fail "(n) task-build.md runs or instructs gh pr merge: $BAD_GH"
fi
if grep -q -i 'merge it?' "$COMMAND" && [ -n "$(grep -n -i 'merge it?' "$COMMAND" | grep -v -i 'never')" ]; then
  fail "(n) task-build.md asks \"merge it?\" outside a prohibition"
else
  pass "(n) task-build.md never asks \"merge it?\""
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "task-build-never-local.test.sh: all checks passed"
else
  echo "task-build-never-local.test.sh: FAILURES above"
fi
exit "$FAIL"
