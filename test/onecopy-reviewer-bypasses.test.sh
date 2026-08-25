#!/usr/bin/env bash
# test/onecopy-reviewer-bypasses.test.sh — ONE-COPY round 2, additional
# executable bypasses reported directly against the shipped hooks by the
# round-2 reviewer (all measured at e384c11, payload cwd = an UNARMED repo
# U, target = an ARMED repo A unless noted). Each becomes a fail-first row
# here, driving the SAME shipped scripts the reviewer drove.
#
# C2 (deny-guard.sh kill-switch scanner, defence in depth — qx_repo_armed's
# HEAD/default-branch-tip signal already makes deletion non-disarming once
# project.json is committed, but the scanner should still actively DENY the
# common shapes rather than silently letting them run against an
# uncommitted or not-yet-pushed project.json): a relative candidate is now
# anchored against the tracked cd (_kill_cd) BEFORE matching, and
# normalized (collapsing `//`, `/./`) via the shared qx_normalize_path.
# `find` and `chmod` are added to the verb list.
#
# D2 (deny-guard.sh resolve_root_for): `--git-dir=<X>` and
# `--git-dir=<X> --work-tree=<Y>` now resolve correctly instead of failing
# to resolve at all (rev-parse on a .git DIR fails outright).
#
# D3 (deny-guard.sh): a relative -C/cd target is now anchored against the
# TRACKED cd (LAST_CD), never unconditionally the payload's session cwd.
#
# D4 (secret-scan.sh): the target root no longer falls back to the session
# just because the file's IMMEDIATE parent directory does not exist yet —
# it walks up to the first EXISTING ancestor first.
#
# AC1-AC10: C2 shapes -> DENY (armed A, cwd = A, no unlock).
# AC11-AC12: D2 shapes -> DENY (armed A, cwd = UNARMED U — proves the git-dir
#            TARGET's arming is what's being judged, not the session).
# AC13-AC15: D3 shapes -> DENY (payload cwd = Z, an UNRELATED, unarmed
#            directory that is NOT the parent of A — isolates the anchor
#            fix from the case where session cwd happens to already match).
# AC16-AC17: D4 shapes -> DENY (session cwd = U, unarmed and NOT A — the
#            file's own parent directory does not exist yet, isolating the
#            ancestor-walk fix from the case where session cwd happens to
#            already be A).
# AC18: FAIL-FIRST (mechanical) against e384c11 for one representative row
#       from EACH of C2/D2/D3/D4 — all four silently allowed there.
#
# Run: bash test/onecopy-reviewer-bypasses.test.sh

set -uo pipefail
unset QUETREX_UNLOCK_FLOOR

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
SECRET_SCAN="${QX_SECRET_SCAN_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/secret-scan.sh}"
BASE_SHA_R2="e384c11"

for h in "$DENY_GUARD" "$SECRET_SCAN"; do
  [ -f "$h" ] || { echo "FAIL: hook not found at $h"; echo; echo "onecopy-reviewer-bypasses.test.sh: 0 passed, 1 failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; echo; echo "onecopy-reviewer-bypasses.test.sh: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

A="$(mktemp -d "${TMPDIR:-/tmp}/qx-rb-armed.XXXXXX")"
U="$(mktemp -d "${TMPDIR:-/tmp}/qx-rb-unarmed.XXXXXX")"
Z="$(mktemp -d "${TMPDIR:-/tmp}/qx-rb-unrelated.XXXXXX")"
cleanup() { rm -rf "$A" "$U" "$Z"; }
trap cleanup EXIT
git -C "$A" init -q -b main
mkdir -p "$A/.quetrex"; printf '{"branchPrefix":"claude/"}' > "$A/.quetrex/project.json"
git -C "$U" init -q -b main
PARENT="$(dirname "$A")"
ABASE="$(basename "$A")"

fire_dg() {  # fire_dg <hook> <command> <cwd>
  jq -cn --arg c "$2" --arg d "$3" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR bash "$1" 2>&1
}
fire_ss() {  # fire_ss <hook> <file_path> <cwd>
  jq -cn --arg p "$2" --arg d "$3" --arg c "AWS_KEY=AKIA${RANDOM_SUFFIX}IOSFODNN7EXAMPLE" \
    '{tool_name:"Write",tool_input:{file_path:$p,content:$c},cwd:$d}' \
    | env -u QUETREX_UNLOCK_FLOOR bash "$1" 2>&1
}
RANDOM_SUFFIX="ABCDEFGHIJKLMNOP"
is_deny()   { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_silent() { [ -z "$1" ]; }

# =============================================================================
# AC1-AC10 — C2: deny-guard kill-switch scanner shapes, armed A, cwd = A.
# =============================================================================
C2_VECTORS=(
  "cd .quetrex && rm -f project.json"
  "cd .quetrex; rm project.json"
  "cd .quetrex && rm -f verify.json"
  "cd .quetrex && mv project.json /tmp/qx-rb-exfil-$$"
  "cd .quetrex && echo {} > project.json"
  "cd .quetrex && truncate -s 0 project.json"
  "rm -f .quetrex/./project.json"
  "rm -f .quetrex//project.json"
  "find .quetrex -name project.json -delete"
  "rm -f .quetrex/project.js*"
)
_ac=0
for v in "${C2_VECTORS[@]}"; do
  _ac=$((_ac+1))
  OUT="$(fire_dg "$DENY_GUARD" "$v" "$A")"
  if is_deny "$OUT"; then
    ok "AC$_ac (C2): deny-guard denies [$v]"
  else
    notok "AC$_ac (C2): expected deny for [$v], got [$OUT]"
  fi
done

# =============================================================================
# AC11-AC12 — D2: --git-dir / --work-tree resolution, session cwd = UNARMED U.
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "git --git-dir=$A/.git push --force origin main" "$U")"
if is_deny "$OUT"; then
  ok "AC11 (D2): deny-guard denies 'git --git-dir=<A>/.git push --force' from an unarmed session"
else
  notok "AC11 (D2): expected deny, got [$OUT]"
fi
OUT="$(fire_dg "$DENY_GUARD" "git --git-dir=$A/.git --work-tree=$A push --force origin main" "$U")"
if is_deny "$OUT"; then
  ok "AC12 (D2): deny-guard denies 'git --git-dir=<A>/.git --work-tree=<A> push --force' from an unarmed session"
else
  notok "AC12 (D2): expected deny, got [$OUT]"
fi

# =============================================================================
# AC13-AC15 — D3: relative -C/cd anchored against the TRACKED cd, never the
# ORIGINAL session cwd. Payload cwd = Z, an UNRELATED, UNARMED directory
# (deliberately NOT the parent of A) — this is what actually distinguishes
# the fix: anchoring the relative -C against the tracked cd chain lands on
# A; anchoring it against the untouched session cwd Z lands on a directory
# under Z that does not exist at all.
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "cd $A/.. && git -C $ABASE push --force origin main" "$Z")"
if is_deny "$OUT"; then
  ok "AC13 (D3): deny-guard denies 'cd <A>/.. && git -C <A-basename> push --force' (session cwd is unrelated Z)"
else
  notok "AC13 (D3): expected deny, got [$OUT]"
fi
OUT="$(fire_dg "$DENY_GUARD" "cd $PARENT; git -C ./$ABASE push --force origin main" "$Z")"
if is_deny "$OUT"; then
  ok "AC14 (D3): deny-guard denies 'cd <parent>; git -C ./<A-basename> push --force' (session cwd is unrelated Z)"
else
  notok "AC14 (D3): expected deny, got [$OUT]"
fi
OUT="$(fire_dg "$DENY_GUARD" "cd $PARENT && cd $ABASE && git push --force origin main" "$Z")"
if is_deny "$OUT"; then
  ok "AC15 (D3): deny-guard denies 'cd <parent> && cd <A-basename> && git push --force' (two chained cd's, session cwd is unrelated Z)"
else
  notok "AC15 (D3): expected deny, got [$OUT]"
fi

# =============================================================================
# AC16-AC17 — D4: secret-scan, nonexistent parent dir(s). Session cwd = U
# (UNARMED, deliberately NOT A) — this is what actually distinguishes the
# fix: walking up from the nonexistent parent lands on A (armed); falling
# back to the session (the old behavior) lands on U (unarmed).
# =============================================================================
OUT="$(fire_ss "$SECRET_SCAN" "$A/newdir/leak.env" "$U")"
if is_deny "$OUT"; then
  ok "AC16 (D4): secret-scan denies a Write to <A>/newdir/leak.env (newdir does not exist; session cwd is unarmed U)"
else
  notok "AC16 (D4): expected deny, got [$OUT]"
fi
OUT="$(fire_ss "$SECRET_SCAN" "$A/a/b/c/leak.env" "$U")"
if is_deny "$OUT"; then
  ok "AC17 (D4): secret-scan denies a Write to <A>/a/b/c/leak.env (a/b/c do not exist; session cwd is unarmed U)"
else
  notok "AC17 (D4): expected deny, got [$OUT]"
fi

# =============================================================================
# AC18 — FAIL-FIRST (mechanical) against e384c11: one representative row
# from each of C2/D2/D3/D4, all measured silent ALLOW there.
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA_R2}^{commit}" 2>/dev/null; then
  notok "AC18 FAIL-FIRST: baseline commit $BASE_SHA_R2 is not reachable in this checkout — cannot prove these bypasses were open pre-fix"
else
  OLD_DG="$A/.old-deny-guard.sh"; OLD_SS="$A/.old-secret-scan.sh"
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/deny-guard.sh" > "$OLD_DG" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/secret-scan.sh" > "$OLD_SS" 2>/dev/null

  OLD_C2="$(fire_dg "$OLD_DG" "cd .quetrex && rm -f project.json" "$A")"
  OLD_D2="$(fire_dg "$OLD_DG" "git --git-dir=$A/.git push --force origin main" "$U")"
  OLD_D3="$(fire_dg "$OLD_DG" "cd $A/.. && git -C $ABASE push --force origin main" "$Z")"
  OLD_D4="$(fire_ss "$OLD_SS" "$A/newdir/leak.env" "$U")"

  if is_silent "$OLD_C2" && is_silent "$OLD_D2" && is_silent "$OLD_D3" && is_silent "$OLD_D4"; then
    ok "AC18 FAIL-FIRST: at $BASE_SHA_R2, one representative C2/D2/D3/D4 row EACH silently ALLOWED — all four were real, this is a genuine fix"
  else
    notok "AC18 FAIL-FIRST: expected all four to silently allow at $BASE_SHA_R2; C2=[$OLD_C2] D2=[$OLD_D2] D3=[$OLD_D3] D4=[$OLD_D4]"
  fi
  rm -f "$OLD_DG" "$OLD_SS"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "onecopy-reviewer-bypasses.test.sh: all checks passed"
else
  echo "onecopy-reviewer-bypasses.test.sh: FAILURES above"
fi
exit "$FAIL"
