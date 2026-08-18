#!/usr/bin/env bash
# session-state.sh — SessionStart hook (sources: startup, resume, compact).
# Registered as `session-state.sh <source>`; the argument is optional and the
# hook payload's .source is used when it is absent.
#
# WHY THIS EVENT. A Quetrex pipeline runs for hours, so compaction is a
# certainty, not a risk. Compaction summarizes the conversation and DROPS the
# old messages — an agent can wake up mid-pipeline having forgotten which task
# it is on, which files its workstream owns, and how many self-heal attempts it
# has already burned. SessionStart with the `compact` source is the ONLY hook
# whose output is placed back into the conversation after a compaction; the
# PostCompact event is not (its output does not reach the model). Do not
# "fix" this by moving it to PostCompact.
#
# WHY IT IS SAFE. This hook re-reads GROUND TRUTH from .quetrex/ on disk — it
# never summarizes the transcript and never invents state. That is the same
# chain-of-custody the gates use ("you trust exactly one thing: the on-disk
# artifacts"), so re-injection cannot drift from what the gates will enforce.
#
# CONTRACT. On SessionStart, plain text on stdout is ADDED TO CONTEXT (no JSON
# required). SessionStart also ignores blocking entirely, so this hook always
# exits 0 and is never able to wedge a session. A repo with no ./.quetrex/ is
# not a Quetrex-managed repo: stay silent.
#
# THE ARTIFACT THAT MATTERS MOST is .quetrex/ESCALATION. It means a bounded
# loop hit its cap and the agent was told to STOP self-healing and surface to a
# human. An agent that forgets it exists will resume self-healing — and
# verify-gate.sh DELETES the marker on its next green, so a post-compaction
# retry that happens to pass can erase the escalation entirely. Re-stating it
# first, every time, is what closes that hole.

set -uo pipefail

INPUT=""
if [ ! -t 0 ]; then INPUT=$(cat); fi

HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

jqget() {
  [ "$HAVE_JQ" -eq 1 ] || return 0
  printf '%s' "$INPUT" | jq -r "$1 // empty" 2>/dev/null
}

# The source may be passed as an ARGUMENT by the settings registration
# (`session-state.sh startup`, `session-state.sh compact`) or read from the hook
# payload. The argument wins so one script can serve every registered source
# even where the payload is unavailable or jq is absent.
SOURCE="${1:-}"
[ -z "$SOURCE" ] && SOURCE=$(jqget '.source')
SESSION_CWD=$(jqget '.cwd')
[ -z "$SESSION_CWD" ] && SESSION_CWD=$(printf '%s' "$INPUT" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')

# --- resolve repo root (worktree-safe; mirrors verify-gate.sh) --------------
ROOT=""
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
  ROOT=$(git -C "$CLAUDE_PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null) \
    || ROOT="$CLAUDE_PROJECT_DIR"
fi
if [ -z "$ROOT" ] && [ -n "$SESSION_CWD" ] && [ -d "$SESSION_CWD" ]; then
  ROOT=$(git -C "$SESSION_CWD" rev-parse --show-toplevel 2>/dev/null)
fi
[ -z "$ROOT" ] && ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0

QDIR="$ROOT/.quetrex"
# Not a Quetrex-managed repo -> nothing to restate.
[ -d "$QDIR" ] || exit 0

# Read a single scalar out of a JSON file; empty when jq is absent or the file
# is missing/malformed. Never fatal — a degraded briefing beats no briefing.
jqfile() {
  [ "$HAVE_JQ" -eq 1 ] || return 0
  [ -f "$2" ] || return 0
  jq -r "$1 // empty" "$2" 2>/dev/null
}

OUT=""
add() { OUT="${OUT}$1
"; }

add "[quetrex-state] Restored from .quetrex/ on disk (source: ${SOURCE:-unknown}). This is ground truth, not a recollection."

# --- 1. ESCALATION — always first, it overrides everything below ------------
if [ -f "$QDIR/ESCALATION" ]; then
  NOTE=$(head -c 600 "$QDIR/ESCALATION" 2>/dev/null | tr '\n' ' ')
  add "  !! ESCALATION IS ACTIVE. A bounded loop hit its cap. STOP self-healing, do NOT report the task as done, and do NOT delete this marker to force progress. Surface it to the user and wait for direction."
  [ -n "$NOTE" ] && add "     note: $NOTE"
  if [ "$SOURCE" = "startup" ]; then
    # A marker found at STARTUP was written by an earlier run. It is still
    # binding — merge-gate.sh blocks on it — but the human needs to know it is
    # not from this session, because the fix may already have happened.
    WHEN=$(ls -l "$QDIR/ESCALATION" 2>/dev/null | awk '{print $6, $7, $8}')
    add "     this marker is from a PRIOR run${WHEN:+ (last written $WHEN)} — it still blocks the merge gate. Resolve it with the user; do not clear it yourself."
  fi
fi

# --- 2. task + loop counters -----------------------------------------------
TASK=$(jqfile '.task' "$QDIR/state.json")
REVIEW_ITER=$(jqfile '.review_iter' "$QDIR/state.json")
[ -n "$TASK" ] && add "  task: $TASK"
[ -n "$REVIEW_ITER" ] && add "  review_iter: $REVIEW_ITER (the reviewer escalates at 3 — this counter survived the compaction; do not restart it at 0)"

ATTEMPTS=""
[ -f "$QDIR/verify-attempts" ] && ATTEMPTS=$(head -c 16 "$QDIR/verify-attempts" 2>/dev/null | tr -dc '0-9')
[ -n "$ATTEMPTS" ] && add "  verify self-heal attempts used: $ATTEMPTS (cap 3, then ESCALATION)"

# --- 3. the plan: owned files are the anti-collision contract ---------------
PLAN=""
if [ -n "$TASK" ] && [ -f "$QDIR/plan/$TASK.json" ]; then
  PLAN="$QDIR/plan/$TASK.json"
else
  PLAN=$(ls -1 "$QDIR"/plan/*.json 2>/dev/null | head -n1)
fi
if [ -n "$PLAN" ] && [ -f "$PLAN" ]; then
  add "  plan: ${PLAN#"$ROOT"/}"
  if [ "$HAVE_JQ" -eq 1 ]; then
    WS=$(jq -r '[.workstreams[]? | "\(.id)[\(.agent)]"] | join(", ")' "$PLAN" 2>/dev/null)
    [ -n "$WS" ] && [ "$WS" != "" ] && add "     workstreams: $WS"
    OWNED=$(jq -r '[.workstreams[]?.owns[]?] | unique | join(", ")' "$PLAN" 2>/dev/null)
    [ -n "$OWNED" ] && add "     owned files (a workstream must not touch any file outside its own set): $OWNED"
    # `ownership` is the AUTHORITY (the globs in `owns` are its shorthand), so
    # restate the explicit path -> workstream map too. Bounded so a large plan
    # cannot flood the restored context.
    OWNMAP=$(jq -r '(.ownership // {}) | to_entries | .[:40] | map("\(.key)=\(.value)") | join(", ")' "$PLAN" 2>/dev/null)
    [ -n "$OWNMAP" ] && add "     ownership map (path=workstream, authoritative): $OWNMAP"
    SECREQ=$(jq -r '.security_review_required // empty' "$PLAN" 2>/dev/null)
    [ "$SECREQ" = "true" ] && add "     security_review_required: true"
  fi
fi

# --- 4. review verdict ------------------------------------------------------
# Declared up front: `set -u` would abort on the stale-commit comparison below
# if no verdict file existed to define them.
V=""
VSHA=""
if [ -f "$QDIR/review-verdict.json" ]; then
  V=$(jqfile '.verdict' "$QDIR/review-verdict.json")
  VSHA=$(jqfile '.sha' "$QDIR/review-verdict.json")
  [ -n "$V" ] && add "  review verdict: $V${VSHA:+ (for commit ${VSHA:0:12})}"
fi

# --- 5. where we are ---------------------------------------------------------
BRANCH=$(git -C "$ROOT" branch --show-current 2>/dev/null)
HEAD_SHA=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)
WT=""
[ -f "$ROOT/.git" ] && WT=" (linked worktree)"
add "  worktree: $ROOT$WT${BRANCH:+ on branch $BRANCH}${HEAD_SHA:+ @ $HEAD_SHA}"
if [ -n "$VSHA" ] && [ -n "$HEAD_SHA" ] && [ "${VSHA:0:${#HEAD_SHA}}" != "$HEAD_SHA" ]; then
  add "     the review verdict above is for a DIFFERENT commit than HEAD — the merge gate will refuse it as stale."
fi

# --- 6. startup-only: report misconfigurations that are otherwise invisible --
# On a fresh start (not a compaction) surface the states that silently disable
# enforcement. Each of these is currently discoverable only by auditing.
if [ "$SOURCE" = "startup" ]; then
  if [ ! -f "$QDIR/verify.json" ]; then
    add "  ! .quetrex/verify.json is missing — verify-gate will fall back to autodetect and may prove far less than you think."
  fi
  SETTINGS="$ROOT/.claude/settings.json"
  # A repo's own settings are only ONE of the two places the gate can be wired.
  # quetrex-factory registers merge-gate.sh for every repo that ENABLES it, and a
  # repo that lets the plugin own the engine guards is CORRECT, not unwired —
  # registering them locally too runs every guard twice (measured 2026-08-17:
  # two full verify chains per Stop, ~6m26s turns). Warn only when NEITHER owner
  # has it, or this fires forever on a properly configured repo and joins the
  # class of diagnostics an operator learns to ignore.
  factory_owns_merge_gate() {
    local s h
    for s in "$SETTINGS" "$HOME/.claude/settings.json"; do
      [ -f "$s" ] || continue
      # ONLY the boolean true counts. A version-PIN array (["1.7.1"]) makes the
      # plugin count as DISABLED for dependency resolution — measured across four
      # checkouts: pin absent -> enabled, pin true -> enabled, pin ["1.2.1"] ->
      # "failed to load", pin ["1.1.0"] -> "failed to load". Treating a pin as
      # enabled would silence this banner in precisely the configuration already
      # measured as the plugin NOT loading, which is the outage this repo's
      # no-version-pins rule exists to prevent.
      grep -q '"quetrex-factory@quetrex"[[:space:]]*:[[:space:]]*true' "$s" 2>/dev/null || continue
      # LIVE, not merely CACHED. A dir under plugins/cache/ records that a version
      # was once downloaded; it is NOT evidence anything loads now. Accepting it
      # silenced this banner for a repo whose plugin cannot load — measured: an
      # orphaned cache (quetrex.gone27700 and friends, 3 of them on this machine)
      # or a cache left by ordinary version churn with the marketplace removed both
      # went SILENT while genuinely ungated. That is the failure this banner exists
      # to catch, so only a marketplace install counts. Factory's marketplace entry
      # is "source": "./plugins/quetrex-factory", so it really does install there.
      # NOTE: this signal does NOT generalise to quetrex@quetrex, which is
      # GitHub-sourced and lives only under cache/ — extending this helper to that
      # plugin needs a different liveness test.
      for h in "$HOME"/.claude/plugins/marketplaces/*/plugins/quetrex-factory/hooks/hooks.json; do
        [ -f "$h" ] && grep -q 'merge-gate\.sh' "$h" 2>/dev/null && return 0
      done
    done
    return 1
  }
  if [ -f "$SETTINGS" ] && ! grep -q 'merge-gate\.sh' "$SETTINGS" 2>/dev/null \
     && ! factory_owns_merge_gate; then
    add "  ! this repo has .quetrex/ but merge-gate.sh is wired NEITHER in .claude/settings.json NOR by an enabled quetrex-factory — the merge boundary is unenforced. Run /quetrex:init."
  fi
  if [ -f "$SETTINGS" ] && grep -q '~/\.claude/hooks' "$SETTINGS" 2>/dev/null; then
    add "  ! a committed hook command points at ~/.claude — it exits 127 in a fresh clone or cloud runner, which is NON-blocking, so enforcement fails open silently."
  fi
fi

printf '%s' "$OUT"
exit 0
