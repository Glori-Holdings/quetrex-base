#!/usr/bin/env bash
# test/project-json-killswitch.test.sh — SEC-ONECOPY-1 (security review,
# ONE-COPY rework): .quetrex/project.json is what makes a repo "armed" for
# every floor script (deny-guard, secret-scan, enforce-branch, merge-gate,
# verify-gate, edit-gate, protected-files-guard). Nothing stopped a gated
# agent from `rm`/`mv`/`cp`-overwriting/redirecting-into/`git rm`/`git
# checkout <ref> --`-restoring that one file (or the whole .quetrex
# directory) to silently disarm the ENTIRE floor for the rest of the
# session — a one-command kill switch. This file proves the fix in the two
# scripts that now close it:
#
#   plugins/quetrex-factory/scripts/deny-guard.sh — Bash vector (rm, mv, cp,
#     shell redirects, tee, git rm, git checkout/restore -- <path>).
#   .claude/hooks/protected-files-guard.sh — Write/Edit vector.
#
# AC1: every Bash kill-switch vector against deny-guard.sh -> DENY in an
#      ARMED repo.
# AC2: every AC1 vector -> ALLOW (silent) only with a SCOPED unlock that NAMES
#      the file it unlocks. A blanket QUETREX_UNLOCK_FLOOR=1 -- an ambient
#      export, or a settings.json env block, which reaches every hook
#      subprocess -- authorizes NOTHING (SEC-6). AC2b/AC2c prove the blanket
#      form is refused and that a scoped value does not leak across targets.
# AC3: Write AND Edit of .quetrex/project.json -> DENY in an ARMED repo,
#      both an absolute and a cwd-relative path shape.
# AC4: AC3 -> ALLOW+RECORDED with QUETREX_UNLOCK_FLOOR=1.
# AC5: creating .quetrex/project.json for the FIRST TIME in an UNARMED repo
#      (the /quetrex-setup:init shape) stays ALLOWED on both vectors — armed-only
#      gating protects init, not just the kill-switch fix.
# AC6: an unrelated rm/Write in an ARMED repo is untouched (no false deny).
# AC7: deny-guard's PRE-EXISTING catastrophic-command rules (force-push) and
#      protected-files-guard's PRE-EXISTING floor-script protection are both
#      still enforced — this fix adds a rule, it does not replace one.
# AC8 (FAIL-FIRST, mechanical): the pre-fix scripts at 2ffde3a (this task's
#      base sha) emit ZERO decisions for the AC1/AC3 fixtures — proving the
#      kill switch is real at that sha and that this fix is new coverage,
#      not a restatement of something already caught.
#
# Run: bash test/project-json-killswitch.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
PROTECTED_GUARD="${QX_PROTECTED_FILES_GUARD_HOOK:-$REPO_ROOT/.claude/hooks/protected-files-guard.sh}"
BASE_SHA="2ffde3a"

for h in "$DENY_GUARD" "$PROTECTED_GUARD"; do
  if [ ! -f "$h" ]; then
    echo "FAIL: hook not found at $h"
    echo
    echo "project-json-killswitch.test.sh: 0 passed, 1 failed"
    exit 1
  fi
done
if ! command -v jq >/dev/null 2>&1; then
  echo "SKIP: jq is not installed — payload construction for this file relies on it"
  echo
  echo "project-json-killswitch.test.sh: 0 passed, 0 failed"
  exit 0
fi

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/pj-killswitch.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email "test@example.com"
git -C "$FIXTURE" config user.name "Fixture"
echo "fixture" > "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
git -C "$FIXTURE" commit -q -m "chore: fixture commit"

arm()    { mkdir -p "$FIXTURE/.quetrex"; printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json"; git -C "$FIXTURE" add -f .quetrex/project.json >/dev/null 2>&1 || true; }
disarm() { rm -rf "$FIXTURE/.quetrex"; }

# NEVER trust the ambient environment for the "locked" baseline. Disclosed,
# documented limitation (protected-files-guard.sh's own header, SEC-6): once
# QUETREX_UNLOCK_FLOOR=1 reaches a process's environment by ANY path, it
# stays there for that process's lifetime — this test suite's own run can
# inherit a stray "1" from an operator's earlier unlocked session and would
# then silently assert nothing at all. Both fire_* helpers therefore always
# pass an EXPLICIT env, never the ambient one: `env -u` clears the var for
# the locked case, `env VAR=1` sets it for the unlocked case.

# fire_bash <hook> <command> [1 to unlock] -> emits the hook's stdout
fire_bash() {
  local hook="$1" cmd="$2" unlock="${3:-}"
  local payload
  payload="$(jq -cn --arg c "$cmd" --arg d "$FIXTURE" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  # Pass the unlock value through LITERALLY. This used to hardcode `=1` and
  # treat every other value as "unset" -- which silently turned any scoped-value
  # assertion into a test of the unset path, passing for the wrong reason.
  if [ -n "$unlock" ]; then
    printf '%s' "$payload" | env QUETREX_UNLOCK_FLOOR="$unlock" bash "$hook" 2>&1
  else
    printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR bash "$hook" 2>&1
  fi
}

# fire_write <hook> <tool> <file_path> [unlock-value] -> emits the hook's
# stdout. Used only against PROTECTED_GUARD (.claude/hooks/protected-files-
# guard.sh) in this file -- SEC-6 (2026-08-26) scopes its unlock to the
# exact basename being written, so <unlock-value> must now be that basename
# (e.g. "project.json"), never a bare "1", to permit the write.
fire_write() {
  local hook="$1" tool="$2" fp="$3" unlock="${4:-}"
  local payload
  payload="$(jq -cn --arg t "$tool" --arg p "$fp" --arg d "$FIXTURE" '{tool_name:$t,tool_input:{file_path:$p},cwd:$d}')"
  if [ -n "$unlock" ]; then
    printf '%s' "$payload" | env QUETREX_UNLOCK_FLOOR="$unlock" bash "$hook" 2>&1
  else
    printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR bash "$hook" 2>&1
  fi
}

is_deny()  { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_allow() { printf '%s' "$1" | grep -q '"permissionDecision":"allow"'; }
is_silent(){ [ -z "$1" ]; }

# =============================================================================
# AC1/AC2 — deny-guard.sh Bash-vector kill-switch coverage
# =============================================================================
arm
VECTORS=(
  "rm -f .quetrex/project.json"
  "rm -rf .quetrex"
  "mv .quetrex/project.json /tmp/quetrex-killswitch-exfil"
  "cp /tmp/quetrex-killswitch-evil.json .quetrex/project.json"
  "echo pwned > .quetrex/project.json"
  "echo pwned | tee .quetrex/project.json"
  "git rm -f .quetrex/project.json"
  "git checkout HEAD~1 -- .quetrex/project.json"
)
for v in "${VECTORS[@]}"; do
  OUT="$(fire_bash "$DENY_GUARD" "$v")"
  if is_deny "$OUT"; then
    ok "AC1: deny-guard denies kill-switch vector: $v"
  else
    notok "AC1: deny-guard did NOT deny kill-switch vector: $v [$OUT]"
  fi

  # The scoped value this vector requires. `rm -rf .quetrex` removes BOTH
  # arming files, so it must name both -- naming one is not enough.
  case "$v" in
    "rm -rf .quetrex") SCOPED="project.json:verify.json" ;;
    *)                 SCOPED="project.json" ;;
  esac

  OUT_SCOPED="$(fire_bash "$DENY_GUARD" "$v" "$SCOPED")"
  if is_silent "$OUT_SCOPED"; then
    ok "AC2: deny-guard allows (silent) with the SCOPED unlock '$SCOPED': $v"
  else
    notok "AC2: deny-guard did NOT allow the correctly-scoped unlock '$SCOPED': $v [$OUT_SCOPED]"
  fi

  # AC2b -- the blanket form. This is the NEW block: it ALLOWED before this
  # change, which is exactly why an ambient export silently unlocked the whole
  # session. AC2d below proves that against main's own guard.
  OUT_BLANKET="$(fire_bash "$DENY_GUARD" "$v" "1")"
  if is_deny "$OUT_BLANKET"; then
    ok "AC2b: deny-guard REFUSES a blanket QUETREX_UNLOCK_FLOOR=1: $v"
  else
    notok "AC2b: a blanket QUETREX_UNLOCK_FLOOR=1 still unlocked the kill switch: $v [$OUT_BLANKET]"
  fi

  # AC2c -- a scoped value must not leak across targets.
  OUT_WRONG="$(fire_bash "$DENY_GUARD" "$v" "merge-gate.sh")"
  if is_deny "$OUT_WRONG"; then
    ok "AC2c: a value naming a DIFFERENT file does not unlock: $v"
  else
    notok "AC2c: an unrelated scoped value unlocked this vector: $v [$OUT_WRONG]"
  fi
done

# AC2e -- the refusal must TEACH: an operator who hits the blanket case needs
# the exact value to set, and needs to be told their ambient one is inert.
# A deny nobody can act on just gets worked around.
OUT_MSG="$(fire_bash "$DENY_GUARD" "rm -f .quetrex/project.json" "1")"
if printf '%s' "$OUT_MSG" | grep -q 'QUETREX_UNLOCK_FLOOR=project.json'; then
  ok "AC2e: the blanket-case refusal names the exact scoped value to set"
else
  notok "AC2e: the refusal does not name the required scoped form [$OUT_MSG]"
fi
if printf '%s' "$OUT_MSG" | grep -qi 'ambient\|blanket'; then
  ok "AC2e: the refusal states that an ambient/blanket value no longer authorizes anything"
else
  notok "AC2e: the refusal never explains that the ambient value was ignored [$OUT_MSG]"
fi

# AC2d FAIL-FIRST -- prove AC2b is a genuine NEW block by running the identical
# blanket payload against main's deny-guard, which must ALLOW it. Without this
# the whole change could be a no-op and every assertion above would still pass.
MAIN_GUARD="$(mktemp "${TMPDIR:-/tmp}/deny-guard-main.XXXXXX")"
# BASELINE PINNED TO A FIXED SHA, NEVER `main`. A fail-first proof compares the
# shipped file against the code as it was BEFORE the fix. Pointing that at the
# moving `main` ref makes the assertion self-destruct the moment the fix merges:
# `main` then IS the fixed file, "the old code allowed it" becomes false, and the
# test goes red forever -- which is exactly what happened, turning main red right
# after the merge while every pre-merge gate had been green. 58bd632 is the commit main
# sat at before this fix landed, so the comparison stays meaningful for good.
if git -C "$REPO_ROOT" show 58bd632:plugins/quetrex-factory/scripts/deny-guard.sh > "$MAIN_GUARD" 2>/dev/null && [ -s "$MAIN_GUARD" ]; then
  OUT_MAIN="$(fire_bash "$MAIN_GUARD" "rm -f .quetrex/project.json" "1")"
  if is_silent "$OUT_MAIN"; then
    ok "AC2d FAIL-FIRST: the deny-guard at 58bd632 DID allow a blanket QUETREX_UNLOCK_FLOOR=1 -- the new refusal is a real, deliberate change"
  else
    notok "AC2d FAIL-FIRST: the guard at 58bd632 already denied the blanket form, so AC2b proves nothing new [$OUT_MAIN]"
  fi
else
  notok "AC2d FAIL-FIRST: could not read 58bd632:plugins/quetrex-factory/scripts/deny-guard.sh to prove the block is new"
fi
rm -f "$MAIN_GUARD"

# =============================================================================
# AC6 (deny-guard side) — an unrelated command in the SAME armed repo is
# completely untouched.
# =============================================================================
OUT="$(fire_bash "$DENY_GUARD" "rm -f README.md")"
if is_silent "$OUT"; then
  ok "AC6: deny-guard leaves an unrelated rm alone in an armed repo"
else
  notok "AC6: deny-guard wrongly reacted to an unrelated rm [$OUT]"
fi

# =============================================================================
# AC7 (deny-guard side) — the PRE-EXISTING catastrophic-command rule set is
# still enforced; this fix adds a rule, it does not regress one.
# =============================================================================
OUT="$(fire_bash "$DENY_GUARD" "git push --force origin main")"
if is_deny "$OUT"; then
  ok "AC7: deny-guard still blocks unconditional force-push (pre-existing rule, unregressed)"
else
  notok "AC7: deny-guard no longer blocks force-push — PRE-EXISTING rule regressed [$OUT]"
fi

# =============================================================================
# AC5 (deny-guard side) — an UNARMED repo creating project.json for the
# first time (the /quetrex-setup:init shape, via a Bash redirect) stays allowed:
# "unarmed repo = no gates at all" is unaffected by this fix.
# =============================================================================
disarm
OUT="$(fire_bash "$DENY_GUARD" 'mkdir -p .quetrex && echo "{}" > .quetrex/project.json')"
if is_silent "$OUT"; then
  ok "AC5: deny-guard allows creating .quetrex/project.json in an UNARMED repo (init path)"
else
  notok "AC5: deny-guard wrongly reacted to first-time project.json creation [$OUT]"
fi
rm -rf "$FIXTURE/.quetrex"
arm

# =============================================================================
# AC3/AC4 — protected-files-guard.sh Write/Edit-vector kill-switch coverage
# =============================================================================
for shape in "$FIXTURE/.quetrex/project.json" ".quetrex/project.json"; do
  for tool in Write Edit; do
    OUT="$(fire_write "$PROTECTED_GUARD" "$tool" "$shape")"
    if is_deny "$OUT"; then
      ok "AC3: protected-files-guard denies $tool of .quetrex/project.json (shape: $shape)"
    else
      notok "AC3: protected-files-guard did NOT deny $tool of .quetrex/project.json (shape: $shape) [$OUT]"
    fi

    OUT_UNLOCKED="$(fire_write "$PROTECTED_GUARD" "$tool" "$shape" "project.json")"
    if is_allow "$OUT_UNLOCKED"; then
      ok "AC4: protected-files-guard allows+records unlocked (QUETREX_UNLOCK_FLOOR=project.json) $tool of .quetrex/project.json (shape: $shape)"
    else
      notok "AC4: protected-files-guard did NOT allow the unlocked $tool (shape: $shape) [$OUT_UNLOCKED]"
    fi

    OUT_BLANKET="$(fire_write "$PROTECTED_GUARD" "$tool" "$shape" "1")"
    if is_deny "$OUT_BLANKET"; then
      ok "AC4 (SEC-6): a blanket QUETREX_UNLOCK_FLOOR=1 no longer unlocks $tool of .quetrex/project.json (shape: $shape)"
    else
      notok "AC4 (SEC-6): expected a blanket =1 to be denied for $tool of .quetrex/project.json (shape: $shape) [$OUT_BLANKET]"
    fi
  done
done

# =============================================================================
# AC5 (protected-files-guard side) — first-time creation in an UNARMED repo.
# =============================================================================
disarm
OUT="$(fire_write "$PROTECTED_GUARD" "Write" "$FIXTURE/.quetrex/project.json")"
if is_silent "$OUT"; then
  ok "AC5: protected-files-guard allows creating .quetrex/project.json in an UNARMED repo (init path)"
else
  notok "AC5: protected-files-guard wrongly reacted to first-time project.json creation [$OUT]"
fi
arm

# =============================================================================
# AC6 (protected-files-guard side) — an unrelated Write in the same armed
# repo is untouched.
# =============================================================================
OUT="$(fire_write "$PROTECTED_GUARD" "Write" "$FIXTURE/README.md")"
if is_silent "$OUT"; then
  ok "AC6: protected-files-guard leaves an unrelated Write alone in an armed repo"
else
  notok "AC6: protected-files-guard wrongly reacted to an unrelated Write [$OUT]"
fi

# =============================================================================
# AC7 (protected-files-guard side) — the PRE-EXISTING floor-script
# protection is still enforced.
# =============================================================================
OUT="$(fire_write "$PROTECTED_GUARD" "Write" "$FIXTURE/plugins/quetrex-factory/scripts/verify-gate.sh")"
if is_deny "$OUT"; then
  ok "AC7: protected-files-guard still blocks a Write to a floor script (pre-existing rule, unregressed)"
else
  notok "AC7: protected-files-guard no longer blocks a floor-script Write — PRE-EXISTING rule regressed [$OUT]"
fi

# =============================================================================
# AC8 — FAIL-FIRST (mechanical): the scripts at this task's own base sha
# (2ffde3a) emit ZERO decisions for the kill-switch fixtures above. Same
# `git cat-file -e` + exact-sha self-heal shape test/protected-files-
# guard.sh's own AC11 already uses, so a shallow-clone CI checkout can still
# prove this by fetching the one commit it needs.
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$BASE_SHA" 2>/dev/null || true
fi
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  notok "AC8 FAIL-FIRST: baseline commit $BASE_SHA is not reachable in this checkout — cannot prove the kill switch existed pre-fix"
else
  OLD_DENY_GUARD="$FIXTURE/.old-deny-guard.sh"
  OLD_PROTECTED_GUARD="$FIXTURE/.old-protected-files-guard.sh"
  git -C "$REPO_ROOT" show "$BASE_SHA:plugins/quetrex-factory/scripts/deny-guard.sh" > "$OLD_DENY_GUARD" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA:.claude/hooks/protected-files-guard.sh" > "$OLD_PROTECTED_GUARD" 2>/dev/null

  BASELINE_HITS=0
  for v in "${VECTORS[@]}"; do
    OUT_OLD="$(fire_bash "$OLD_DENY_GUARD" "$v")"
    [ -n "$OUT_OLD" ] && BASELINE_HITS=$((BASELINE_HITS + 1))
  done
  for tool in Write Edit; do
    OUT_OLD="$(fire_write "$OLD_PROTECTED_GUARD" "$tool" "$FIXTURE/.quetrex/project.json")"
    [ -n "$OUT_OLD" ] && BASELINE_HITS=$((BASELINE_HITS + 1))
  done
  if [ "$BASELINE_HITS" -eq 0 ]; then
    ok "AC8 FAIL-FIRST: 0 decisions from either hook at $BASE_SHA for all 10 kill-switch fixtures — the kill switch is real pre-fix, this is new coverage"
  else
    notok "AC8 FAIL-FIRST: $BASELINE_HITS decision(s) emitted at $BASE_SHA — the pre-fix baseline unexpectedly already caught this, cannot demonstrate this is new coverage"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "project-json-killswitch.test.sh: all checks passed"
else
  echo "project-json-killswitch.test.sh: FAILURES above"
fi
exit "$FAIL"
