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
#   (i) task-rework.md cross-references the same stop rule.
# Fail-first: (a),(b),(c),(e),(f),(g),(h) are proven ABSENT from the pre-fix
# baseline 85ec69c (a literal sha, never `main`) before the shipped text is
# checked.

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
parse() { local sh="$1"; shift; "$sh" -c '. "$1"; shift; qx_parse_args "$*"' _ "$PARSE" "$@"; }
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

echo
if [ "$FAIL" -eq 0 ]; then
  echo "task-build-never-local.test.sh: all checks passed"
else
  echo "task-build-never-local.test.sh: FAILURES above"
fi
exit "$FAIL"
