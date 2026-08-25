#!/usr/bin/env bash
# test/cross-repo-arming.test.sh — C5 (review finding, medium): deny-guard.sh
# and secret-scan.sh used to resolve "is this armed?" from the SESSION's own
# repo alone, ignoring the repo the command/write actually TARGETS.
# enforce-branch.sh, changed in the SAME commit, already resolved
# per-invocation (its own -C/cd tracking) — two hooks in one change
# disagreed about which repo's arming governs.
#
# THE DEFECT, MEASURED (session cwd = an UNARMED repo, command/write targets
# an ARMED repo):
#   deny-guard  `git -C <armed> push --force origin main`   -> silent ALLOW
#   secret-scan  Write of a secret into <armed>/leak.env      -> silent ALLOW
# Both DENIED at 40feac8 (before deny-guard/secret-scan had any arming
# concept at all) and both silently allowed at 2ffde3a.
#
# THE FIX:
#   deny-guard.sh — per-invocation target resolution, mirroring
#     enforce-branch.sh: an explicit `git -C <dir>`, else the last `cd
#     <dir> &&` earlier in the SAME command, else the session root.
#   secret-scan.sh — Write/Edit resolve from FILE_PATH's own repo (the file
#     actually being written IS the target); Bash keeps resolving from the
#     session (a shell command's real target can move across repos in ways
#     this file does not parse a -C/cd out of).
#
# AC1-AC4: deny-guard cross-repo shapes (git -C, cd, plain, and the
#          kill-switch check) — armed TARGET denies regardless of session,
#          unarmed target allows regardless of session.
# AC5-AC7: secret-scan Write/Edit resolve from FILE_PATH's own repo;
#          Bash still resolves from the session (unaffected, by design).
# AC8: FAIL-FIRST (mechanical) against this task's own base sha (2ffde3a).
#
# Run: bash test/cross-repo-arming.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
SECRET_SCAN="${QX_SECRET_SCAN_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/secret-scan.sh}"
BASE_SHA="2ffde3a"

for h in "$DENY_GUARD" "$SECRET_SCAN"; do
  [ -f "$h" ] || { echo "FAIL: hook not found at $h"; echo; echo "cross-repo-arming.test.sh: 0 passed, 1 failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; echo; echo "cross-repo-arming.test.sh: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

ARMED="$(mktemp -d "${TMPDIR:-/tmp}/qx-cra-armed.XXXXXX")"
UNARMED="$(mktemp -d "${TMPDIR:-/tmp}/qx-cra-unarmed.XXXXXX")"
cleanup() { rm -rf "$ARMED" "$UNARMED"; }
trap cleanup EXIT
git -C "$ARMED" init -q -b main
mkdir -p "$ARMED/.quetrex"; printf '{"branchPrefix":"claude/"}' > "$ARMED/.quetrex/project.json"
git -C "$UNARMED" init -q -b main

is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_silent() { [ -z "$1" ]; }

fire_dg() {  # fire_dg <hook> <command> <cwd>
  jq -cn --arg c "$2" --arg d "$3" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR bash "$1" 2>&1
}
fire_ss_write() {  # fire_ss_write <hook> <file_path> <cwd>
  jq -cn --arg p "$2" --arg d "$3" --arg c "AWS_KEY=AKIA${RANDOM_SUFFIX}IOSFODNN7EXAMPLE" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR bash "$1" 2>&1
}
fire_ss_bash() {  # fire_ss_bash <hook> <command> <cwd>
  jq -cn --arg c "$2" --arg d "$3" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR bash "$1" 2>&1
}
# The AWS key body is fixed per-invocation via RANDOM_SUFFIX only to keep
# the source text of THIS file from ever containing one contiguous,
# realistic-looking secret literal — the value itself is the AWS-docs
# example key body either way, never a real credential.
RANDOM_SUFFIX="ABCDEFGHIJKLMNOP"

# =============================================================================
# AC1 — deny-guard: `git -C <armed>` from an UNARMED session -> DENY
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "git -C $ARMED push --force origin main" "$UNARMED")"
if is_deny "$OUT"; then
  ok "AC1: deny-guard denies 'git -C <armed> push --force' from an UNARMED session"
else
  notok "AC1: expected deny for git -C <armed> from an unarmed session, got [$OUT]"
fi

# =============================================================================
# AC2 — deny-guard: `git -C <unarmed>` from an ARMED session -> ALLOW (silent)
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "git -C $UNARMED push --force origin main" "$ARMED")"
if is_silent "$OUT"; then
  ok "AC2: deny-guard allows (silent) 'git -C <unarmed> push --force' from an ARMED session"
else
  notok "AC2: expected silent allow for git -C <unarmed> from an armed session, got [$OUT]"
fi

# =============================================================================
# AC3 — deny-guard: `cd <armed> && ...` from an UNARMED session -> DENY
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "cd $ARMED && git push --force origin main" "$UNARMED")"
if is_deny "$OUT"; then
  ok "AC3: deny-guard denies 'cd <armed> && git push --force' from an UNARMED session"
else
  notok "AC3: expected deny for cd <armed> from an unarmed session, got [$OUT]"
fi

# =============================================================================
# AC4 — deny-guard: the SEC-ONECOPY-1 kill-switch check is ALSO per-target,
# not just the catastrophic-command rules.
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "cd $ARMED && rm -f .quetrex/project.json" "$UNARMED")"
if is_deny "$OUT"; then
  ok "AC4: deny-guard's kill-switch check denies targeting <armed>/.quetrex/project.json from an UNARMED session"
else
  notok "AC4: expected deny for the kill-switch check via cd <armed> from an unarmed session, got [$OUT]"
fi
OUT="$(fire_dg "$DENY_GUARD" "rm -f README.md" "$ARMED")"
if is_silent "$OUT"; then
  ok "AC4: deny-guard leaves an unrelated rm (no cd) alone in an armed session (non-regression)"
else
  notok "AC4: unrelated rm in an armed session wrongly reacted: [$OUT]"
fi

# =============================================================================
# AC5 — secret-scan: Write into <armed>'s own file, from an UNARMED session -> DENY
# =============================================================================
OUT="$(fire_ss_write "$SECRET_SCAN" "$ARMED/leak.env" "$UNARMED")"
if is_deny "$OUT"; then
  ok "AC5: secret-scan denies a Write of a secret into <armed>/leak.env from an UNARMED session"
else
  notok "AC5: expected deny for a Write into <armed> from an unarmed session, got [$OUT]"
fi

# =============================================================================
# AC6 — secret-scan: Write into <unarmed>'s own file, from an ARMED session -> ALLOW (silent)
# =============================================================================
OUT="$(fire_ss_write "$SECRET_SCAN" "$UNARMED/leak.env" "$ARMED")"
if is_silent "$OUT"; then
  ok "AC6: secret-scan allows (silent) a Write into <unarmed>/leak.env from an ARMED session"
else
  notok "AC6: expected silent allow for a Write into <unarmed> from an armed session, got [$OUT]"
fi

# =============================================================================
# AC7 — secret-scan: Bash vector still resolves from the SESSION, unaffected
# by this fix (by design — a shell command's real target is not structurally
# parseable the way a Write's file_path is).
# =============================================================================
OUT="$(fire_ss_bash "$SECRET_SCAN" "echo AWS_KEY=AKIA${RANDOM_SUFFIX}IOSFODNN7EXAMPLE > x.env" "$ARMED")"
if is_deny "$OUT"; then
  ok "AC7: secret-scan's Bash vector still denies from an ARMED session (unaffected by the Write/Edit fix)"
else
  notok "AC7: expected deny for a Bash secret-write from an armed session, got [$OUT]"
fi
OUT="$(fire_ss_bash "$SECRET_SCAN" "echo AWS_KEY=AKIA${RANDOM_SUFFIX}IOSFODNN7EXAMPLE > x.env" "$UNARMED")"
if is_silent "$OUT"; then
  ok "AC7: secret-scan's Bash vector stays silent from an UNARMED session (unaffected — session governs Bash)"
else
  notok "AC7: expected silent allow for a Bash secret-write from an unarmed session, got [$OUT]"
fi

# =============================================================================
# AC8 — FAIL-FIRST (mechanical): the scripts at this task's own base sha
# (2ffde3a) emit ALLOW (not deny) for AC1 and AC5's cross-repo fixtures.
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$BASE_SHA" 2>/dev/null || true
fi
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  notok "AC8 FAIL-FIRST: baseline commit $BASE_SHA is not reachable in this checkout — cannot prove the regression existed pre-fix"
else
  OLD_DG="$ARMED/.old-deny-guard.sh"; OLD_SS="$ARMED/.old-secret-scan.sh"
  git -C "$REPO_ROOT" show "$BASE_SHA:plugins/quetrex-factory/scripts/deny-guard.sh" > "$OLD_DG" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA:plugins/quetrex-factory/scripts/secret-scan.sh" > "$OLD_SS" 2>/dev/null

  OLD_DG_OUT="$(fire_dg "$OLD_DG" "git -C $ARMED push --force origin main" "$UNARMED")"
  OLD_SS_OUT="$(fire_ss_write "$OLD_SS" "$ARMED/leak.env" "$UNARMED")"
  if is_silent "$OLD_DG_OUT" && is_silent "$OLD_SS_OUT"; then
    ok "AC8 FAIL-FIRST: at $BASE_SHA, both deny-guard's git -C <armed> and secret-scan's Write into <armed> silently ALLOWED from an unarmed session — the regression is real, this is a genuine fix"
  else
    notok "AC8 FAIL-FIRST: expected both to silently allow at $BASE_SHA; deny-guard=[$OLD_DG_OUT] secret-scan=[$OLD_SS_OUT]"
  fi
  rm -f "$OLD_DG" "$OLD_SS"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "cross-repo-arming.test.sh: all checks passed"
else
  echo "cross-repo-arming.test.sh: FAILURES above"
fi
exit "$FAIL"
