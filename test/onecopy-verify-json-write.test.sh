#!/usr/bin/env bash
# test/onecopy-verify-json-write.test.sh — OBS-9 (round 2): the C6 fix
# protects .quetrex/verify.json against deny-guard's Bash vector (rm/mv/
# redirect/git rm/git checkout --) but the Write/Edit vector in
# .claude/hooks/protected-files-guard.sh covered ONLY project.json.
# verify-gate.sh accepts a hand-written verify.json (e.g.
# {"verify":["true"]}) as the gate's own definition of green, so a single
# Write/Edit there replaces the real chain with a no-op and lets every
# future Stop pass on a red tree — the same class of hole project.json's
# own protection closes for arming itself.
#
# THE FIX: protected-files-guard.sh's Write/Edit vector now denies a target
# that normalizes to `.quetrex/verify.json`, alongside the existing
# `.quetrex/project.json` case, with the same QUETREX_UNLOCK_FLOOR=1 unlock.
#
# AC1: Write AND Edit of .quetrex/verify.json -> DENY in an ARMED repo, both
#      an absolute and a cwd-relative path shape.
# AC2: AC1 -> ALLOW+RECORDED with QUETREX_UNLOCK_FLOOR=1.
# AC3: creating .quetrex/verify.json for the FIRST TIME in an UNARMED repo
#      (the /quetrex-setup:init shape) stays ALLOWED — armed-only gating protects
#      init, not just this fix.
# AC4: an unrelated Write in the same armed repo is untouched.
# AC5: project.json's OWN protection is unregressed (both cases share one
#      case-statement; adding verify.json must not shadow it).
# AC6: FAIL-FIRST (mechanical) against e384c11: the same AC1 fixture was a
#      silent ALLOW there.
#
# Run: bash test/onecopy-verify-json-write.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${QX_PROTECTED_FILES_GUARD_HOOK:-$ROOT/.claude/hooks/protected-files-guard.sh}"
BASE_SHA_R2="e384c11"

[ -f "$GUARD" ] || { echo "FAIL: guard not found at $GUARD"; echo; echo "onecopy-verify-json-write.test.sh: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; echo; echo "onecopy-verify-json-write.test.sh: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/qx-vjw.XXXXXX")"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT
git -C "$FIXTURE" init -q -b main
echo fixture > "$FIXTURE/README.md"

arm()    { mkdir -p "$FIXTURE/.quetrex"; printf '{"branchPrefix":"claude/"}' > "$FIXTURE/.quetrex/project.json"; printf '{"verify":["true"]}' > "$FIXTURE/.quetrex/verify.json"; }
disarm() { rm -rf "$FIXTURE/.quetrex"; }

fire_write() {  # fire_write <tool> <file_path> [1 to unlock]
  local tool="$1" fp="$2" unlock="${3:-}" payload
  payload="$(jq -cn --arg t "$tool" --arg p "$fp" --arg d "$FIXTURE" '{tool_name:$t,tool_input:{file_path:$p},cwd:$d}')"
  if [ "$unlock" = "1" ]; then
    printf '%s' "$payload" | env QUETREX_UNLOCK_FLOOR=1 bash "$GUARD" 2>&1
  else
    printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR bash "$GUARD" 2>&1
  fi
}
is_deny()   { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_allow()  { printf '%s' "$1" | grep -q '"permissionDecision":"allow"'; }
is_silent() { [ -z "$1" ]; }

arm

# =============================================================================
# AC1/AC2 — Write and Edit of .quetrex/verify.json, both path shapes.
# =============================================================================
for shape in "$FIXTURE/.quetrex/verify.json" ".quetrex/verify.json"; do
  for tool in Write Edit; do
    OUT="$(fire_write "$tool" "$shape")"
    if is_deny "$OUT"; then
      ok "AC1: protected-files-guard denies $tool of .quetrex/verify.json (shape: $shape)"
    else
      notok "AC1: protected-files-guard did NOT deny $tool of .quetrex/verify.json (shape: $shape) [$OUT]"
    fi

    OUT_UNLOCKED="$(fire_write "$tool" "$shape" "1")"
    if is_allow "$OUT_UNLOCKED"; then
      ok "AC2: protected-files-guard allows+records unlocked $tool of .quetrex/verify.json (shape: $shape)"
    else
      notok "AC2: protected-files-guard did NOT allow the unlocked $tool (shape: $shape) [$OUT_UNLOCKED]"
    fi
  done
done

# =============================================================================
# AC3 — first-time creation in an UNARMED repo stays allowed.
# =============================================================================
disarm
OUT="$(fire_write "Write" "$FIXTURE/.quetrex/verify.json")"
if is_silent "$OUT"; then
  ok "AC3: protected-files-guard allows creating .quetrex/verify.json in an UNARMED repo (init path)"
else
  notok "AC3: protected-files-guard wrongly reacted to first-time verify.json creation [$OUT]"
fi
arm

# =============================================================================
# AC4 — an unrelated Write in the same armed repo is untouched.
# =============================================================================
OUT="$(fire_write "Write" "$FIXTURE/README.md")"
if is_silent "$OUT"; then
  ok "AC4: protected-files-guard leaves an unrelated Write alone in an armed repo"
else
  notok "AC4: protected-files-guard wrongly reacted to an unrelated Write [$OUT]"
fi

# =============================================================================
# AC5 — project.json's own protection is unregressed by adding the
# verify.json case arm alongside it.
# =============================================================================
OUT="$(fire_write "Write" "$FIXTURE/.quetrex/project.json")"
if is_deny "$OUT"; then
  ok "AC5: protected-files-guard still denies a Write to .quetrex/project.json (unregressed)"
else
  notok "AC5: project.json protection regressed [$OUT]"
fi

# =============================================================================
# AC6 — FAIL-FIRST (mechanical) against e384c11.
# =============================================================================
if ! git -C "$ROOT" cat-file -e "${BASE_SHA_R2}^{commit}" 2>/dev/null; then
  notok "AC6 FAIL-FIRST: baseline commit $BASE_SHA_R2 is not reachable in this checkout — cannot prove OBS-9 was open pre-fix"
else
  OLD_GUARD="$FIXTURE/.old-pfg.sh"
  git -C "$ROOT" show "$BASE_SHA_R2:.claude/hooks/protected-files-guard.sh" > "$OLD_GUARD" 2>/dev/null
  OLD_PAYLOAD="$(jq -cn --arg p "$FIXTURE/.quetrex/verify.json" --arg d "$FIXTURE" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$d}')"
  OLD_OUT="$(printf '%s' "$OLD_PAYLOAD" | env -u QUETREX_UNLOCK_FLOOR bash "$OLD_GUARD" 2>&1)"
  if is_silent "$OLD_OUT"; then
    ok "AC6 FAIL-FIRST: at $BASE_SHA_R2, a Write to .quetrex/verify.json silently ALLOWED — OBS-9 was real, this is a genuine fix"
  else
    notok "AC6 FAIL-FIRST: expected silent allow at $BASE_SHA_R2, got [$OLD_OUT]"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "onecopy-verify-json-write.test.sh: all checks passed"
else
  echo "onecopy-verify-json-write.test.sh: FAILURES above"
fi
exit "$FAIL"
