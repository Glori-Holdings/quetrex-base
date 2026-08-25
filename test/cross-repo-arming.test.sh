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
# ROUND 2 AMENDMENT (SEC-ONECOPY-3 Critical / SEC-ONECOPY-4 Medium): the C5
# fix above made the TARGET's arming the ONLY signal these two hooks judged —
# so naming ANY directory that fails to resolve to an armed repo (a
# non-repo dir, a nonexistent dir, `/`, `$HOME`, `..`, or — the shape THIS
# file's own AC2/AC6 exercise — an unarmed SIBLING repo) turned deny-guard's
# and secret-scan's rules off entirely, even from a fully ARMED session.
# `cd <unarmed> && rm -rf /` and a secret Write into an unarmed sibling repo
# both went from DENY to silent ALLOW at e384c11. THE FIX (design A, round 2):
# the session's own arming is now unconditionally ONE of two signals — gate
# iff qx_repo_armed(SESSION) OR qx_repo_armed(TARGET) — so AC2/AC6 below now
# assert DENY from an ARMED session (this round's fix), with a NEW AC2b/AC6b
# proving the gate still correctly stands down when BOTH session and target
# are unarmed (the legitimate case the additive rule must not break).
#
# AC1, AC3, AC4: deny-guard cross-repo shapes (git -C, cd, and the
#                kill-switch check) — armed TARGET denies regardless of
#                session (unaffected by round 2).
# AC2/AC2b: deny-guard — an unarmed target denies when the SESSION is armed
#           (round 2 fix), but still allows when BOTH are unarmed.
# AC5: secret-scan Write/Edit resolves from FILE_PATH's own repo (unaffected).
# AC6/AC6b: secret-scan — a Write into an unarmed target denies when the
#           SESSION is armed (round 2 fix), but still allows when BOTH are
#           unarmed.
# AC7: secret-scan Bash vector still resolves from the session (unaffected).
# AC8: FAIL-FIRST (mechanical) against this task's own base sha (2ffde3a) —
#      the ARMED-TARGET/UNARMED-SESSION direction, unaffected by round 2.
# AC9: FAIL-FIRST (mechanical) against e384c11 (round-2 base sha) — proves
#      SEC-ONECOPY-3/4's ARMED-SESSION/UNARMED-TARGET bypass was real there.
#
# Run: bash test/cross-repo-arming.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
SECRET_SCAN="${QX_SECRET_SCAN_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/secret-scan.sh}"
BASE_SHA="2ffde3a"
BASE_SHA_R2="e384c11"

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
# AC2 — deny-guard: `git -C <unarmed>` from an ARMED session -> DENY
# (SEC-ONECOPY-3, round 2: the session's own arming is now an unconditional
# signal — naming an unarmed sibling repo no longer turns the gate off.)
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "git -C $UNARMED push --force origin main" "$ARMED")"
if is_deny "$OUT"; then
  ok "AC2: deny-guard denies 'git -C <unarmed> push --force' from an ARMED session (SEC-ONECOPY-3 fix)"
else
  notok "AC2: expected deny for git -C <unarmed> from an armed session, got [$OUT]"
fi

# =============================================================================
# AC2b — deny-guard: `git -C <unarmed>` from an UNARMED session -> ALLOW
# (silent). The additive fix must not turn EVERY cross-repo command into a
# deny — when neither the session nor the named target is armed, there is
# genuinely nothing to gate.
# =============================================================================
UNARMED2="$(mktemp -d "${TMPDIR:-/tmp}/qx-cra-unarmed2.XXXXXX")"
git -C "$UNARMED2" init -q -b main
OUT="$(fire_dg "$DENY_GUARD" "git -C $UNARMED2 push --force origin main" "$UNARMED")"
if is_silent "$OUT"; then
  ok "AC2b: deny-guard allows (silent) 'git -C <unarmed> push --force' when BOTH session and target are unarmed"
else
  notok "AC2b: expected silent allow when both session and target are unarmed, got [$OUT]"
fi
rm -rf "$UNARMED2"

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
# AC6 — secret-scan: Write into <unarmed>'s own file, from an ARMED session -> DENY
# (SEC-ONECOPY-4, round 2: the session's own arming is now an unconditional
# signal — a Write into an unarmed sibling repo no longer sails through just
# because that repo itself lacks project.json.)
# =============================================================================
OUT="$(fire_ss_write "$SECRET_SCAN" "$UNARMED/leak.env" "$ARMED")"
if is_deny "$OUT"; then
  ok "AC6: secret-scan denies a Write into <unarmed>/leak.env from an ARMED session (SEC-ONECOPY-4 fix)"
else
  notok "AC6: expected deny for a Write into <unarmed> from an armed session, got [$OUT]"
fi

# =============================================================================
# AC6b — secret-scan: Write into <unarmed>'s own file, from an UNARMED
# session -> ALLOW (silent). Neither side is armed, so there is genuinely
# nothing to gate.
# =============================================================================
UNARMED3="$(mktemp -d "${TMPDIR:-/tmp}/qx-cra-unarmed3.XXXXXX")"
git -C "$UNARMED3" init -q -b main
OUT="$(fire_ss_write "$SECRET_SCAN" "$UNARMED3/leak.env" "$UNARMED")"
if is_silent "$OUT"; then
  ok "AC6b: secret-scan allows (silent) a Write into <unarmed>/leak.env when BOTH session and target are unarmed"
else
  notok "AC6b: expected silent allow when both session and target are unarmed, got [$OUT]"
fi
rm -rf "$UNARMED3"

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

# =============================================================================
# AC9 — FAIL-FIRST (mechanical) against e384c11 (round-2 base sha): proves
# SEC-ONECOPY-3/4's ARMED-SESSION/UNARMED-TARGET bypass (AC2/AC6's shapes)
# was real at that commit before this round's additive fix.
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA_R2}^{commit}" 2>/dev/null; then
  notok "AC9 FAIL-FIRST: baseline commit $BASE_SHA_R2 is not reachable in this checkout — cannot prove the SEC-ONECOPY-3/4 regression existed pre-fix"
else
  OLD_DG_R2="$ARMED/.old-deny-guard-r2.sh"; OLD_SS_R2="$ARMED/.old-secret-scan-r2.sh"
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/deny-guard.sh" > "$OLD_DG_R2" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA_R2:plugins/quetrex-factory/scripts/secret-scan.sh" > "$OLD_SS_R2" 2>/dev/null

  OLD_DG_R2_OUT="$(fire_dg "$OLD_DG_R2" "git -C $UNARMED push --force origin main" "$ARMED")"
  OLD_SS_R2_OUT="$(fire_ss_write "$OLD_SS_R2" "$UNARMED/leak.env" "$ARMED")"
  if is_silent "$OLD_DG_R2_OUT" && is_silent "$OLD_SS_R2_OUT"; then
    ok "AC9 FAIL-FIRST: at $BASE_SHA_R2, both deny-guard's git -C <unarmed> and secret-scan's Write into <unarmed> silently ALLOWED from an ARMED session — SEC-ONECOPY-3/4 were real, this is a genuine fix"
  else
    notok "AC9 FAIL-FIRST: expected both to silently allow at $BASE_SHA_R2; deny-guard=[$OLD_DG_R2_OUT] secret-scan=[$OLD_SS_R2_OUT]"
  fi
  rm -f "$OLD_DG_R2" "$OLD_SS_R2"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "cross-repo-arming.test.sh: all checks passed"
else
  echo "cross-repo-arming.test.sh: FAILURES above"
fi
exit "$FAIL"
