#!/usr/bin/env bash
# test/verify-chain-required.test.sh — C6 (review finding, medium): an armed
# repo (.quetrex/project.json present) with NO resolvable verify chain (no
# .quetrex/verify.json, no CLAUDE.md "## Verification" fence) used to make
# verify-gate.sh exit 0 SILENTLY — Stop allowed on any tree, red or not, with
# no signal anywhere that the gate had stopped gating. AC5 deleted
# resolve_autodetect (a sanctioned change) but left this fallback path a
# silent no-op instead of turning it into a visible block.
#
# THE FIX:
#   verify-gate.sh — the final `resolve_from_verify_json ||
#     resolve_from_claude_md || { ... }` fallback now BLOCKS once with a
#     labelled, actionable line, instead of exiting 0. An UNARMED repo is
#     unaffected — it already exits earlier, before this fallback runs.
#   deny-guard.sh — .quetrex/verify.json is now protected the SAME way as
#     project.json (same SEC-ONECOPY-1 kill-switch check, same
#     scoped QUETREX_UNLOCK_FLOOR unlock): rm/mv/cp-overwrite/redirect/git-rm/git
#     checkout targeting it in an armed repo is denied.
#
# AC1: ARMED + no verify.json + no CLAUDE.md fence -> BLOCK, labelled reason.
# AC2: UNARMED + no chain -> silent exit 0 (unaffected).
# AC3: ARMED + a real verify.json -> no chain-missing block (unaffected).
# AC4: ARMED + no verify.json but a CLAUDE.md Verification fence -> no
#      chain-missing block (resolve_from_claude_md still satisfies it).
# AC5: deny-guard denies rm/redirect-overwrite of .quetrex/verify.json in an
#      armed repo, and only a SCOPED QUETREX_UNLOCK_FLOOR=verify.json permits
#      it -- a blanket "1" does not (SEC-6).
# AC6: deny-guard's project.json protection (SEC-ONECOPY-1) is unregressed.
# AC7: FAIL-FIRST (mechanical) against this task's own base sha (2ffde3a)
#      for both halves.
#
# Run: bash test/verify-chain-required.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_GATE="${QX_VERIFY_GATE_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate.sh}"
DENY_GUARD="${QX_DENY_GUARD_HOOK:-$REPO_ROOT/plugins/quetrex-factory/scripts/deny-guard.sh}"
BASE_SHA="2ffde3a"

for h in "$VERIFY_GATE" "$DENY_GUARD"; do
  [ -f "$h" ] || { echo "FAIL: hook not found at $h"; echo; echo "verify-chain-required.test.sh: 0 passed, 1 failed"; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; echo; echo "verify-chain-required.test.sh: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

new_fixture() {  # new_fixture -> prints a fresh git repo path
  local f
  f="$(mktemp -d "${TMPDIR:-/tmp}/qx-vcr.XXXXXX")"
  git -C "$f" init -q -b main >/dev/null 2>&1
  printf '%s' "$f"
}
arm() { mkdir -p "$1/.quetrex"; printf '{"branchPrefix":"claude/"}' > "$1/.quetrex/project.json"; }

run_vg() {  # run_vg <hook> <fixture> -> stdout, sets CODE
  local hook="$1" fixture="$2" payload
  payload="$(jq -cn --arg cwd "$fixture" '{cwd:$cwd,hook_event_name:"Stop"}')"
  printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR CLAUDE_PROJECT_DIR="$fixture" bash "$hook" 2>&1
}
is_block() { printf '%s' "$1" | grep -q '"decision":"block"'; }

fire_dg() {  # fire_dg <hook> <command> <cwd> [scoped unlock value]
  local hook="$1" cmd="$2" cwd="$3" unlock="${4:-}" payload
  payload="$(jq -cn --arg c "$cmd" --arg d "$cwd" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  # Pass the value through LITERALLY -- hardcoding `=1` would turn any
  # scoped-value assertion into a silent test of the unset path.
  if [ -n "$unlock" ]; then
    printf '%s' "$payload" | env QUETREX_UNLOCK_FLOOR="$unlock" bash "$hook" 2>&1
  else
    printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR bash "$hook" 2>&1
  fi
}
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_silent() { [ -z "$1" ]; }

# =============================================================================
# AC1 — ARMED, no verify.json, no CLAUDE.md fence -> BLOCK
# =============================================================================
F1="$(new_fixture)"; arm "$F1"
OUT="$(run_vg "$VERIFY_GATE" "$F1")"
if is_block "$OUT" && printf '%s' "$OUT" | grep -q 'has no verify chain' && printf '%s' "$OUT" | grep -q '/quetrex-setup:init'; then
  ok "AC1: armed repo with no resolvable verify chain BLOCKS, naming .quetrex/project.json, 'no verify chain', and /quetrex-setup:init"
else
  notok "AC1: expected a labelled block for an armed repo with no chain, got [$OUT]"
fi
rm -rf "$F1"

# =============================================================================
# AC2 — UNARMED, no chain -> silent exit 0 (unaffected)
# =============================================================================
F2="$(new_fixture)"
OUT="$(run_vg "$VERIFY_GATE" "$F2")"
if is_silent "$OUT"; then
  ok "AC2: an UNARMED repo with no chain stays silent (exit 0) — the C6 fix does not touch the unarmed path"
else
  notok "AC2: expected silent allow for an unarmed repo with no chain, got [$OUT]"
fi
rm -rf "$F2"

# =============================================================================
# AC3 — ARMED, a real (green) verify.json -> no chain-missing block
# =============================================================================
F3="$(new_fixture)"; arm "$F3"
jq -cn '{verify:["true"]}' > "$F3/.quetrex/verify.json"
OUT="$(run_vg "$VERIFY_GATE" "$F3")"
if printf '%s' "$OUT" | grep -q 'has no verify chain'; then
  notok "AC3: an armed repo WITH verify.json still hit the chain-missing block: [$OUT]"
else
  ok "AC3: an armed repo with a real verify.json never hits the chain-missing block"
fi
rm -rf "$F3"

# =============================================================================
# AC4 — ARMED, no verify.json, but a CLAUDE.md Verification fence -> no
# chain-missing block (resolve_from_claude_md alone satisfies it).
# =============================================================================
F4="$(new_fixture)"; arm "$F4"
mkdir -p "$F4/.claude"
cat > "$F4/.claude/CLAUDE.md" <<'EOF'
## Verification

```
true
```
EOF
OUT="$(run_vg "$VERIFY_GATE" "$F4")"
if printf '%s' "$OUT" | grep -q 'has no verify chain'; then
  notok "AC4: an armed repo with a CLAUDE.md Verification fence still hit the chain-missing block: [$OUT]"
else
  ok "AC4: an armed repo with only a CLAUDE.md Verification fence never hits the chain-missing block"
fi
rm -rf "$F4"

# =============================================================================
# AC5 — deny-guard: .quetrex/verify.json is protected the same way as
# project.json, same unlock.
# =============================================================================
F5="$(new_fixture)"; arm "$F5"
jq -cn '{verify:["true"]}' > "$F5/.quetrex/verify.json"

OUT="$(fire_dg "$DENY_GUARD" "rm -f .quetrex/verify.json" "$F5")"
if is_deny "$OUT"; then
  ok "AC5: deny-guard denies 'rm -f .quetrex/verify.json' in an armed repo"
else
  notok "AC5: expected deny for rm of verify.json in an armed repo, got [$OUT]"
fi

OUT="$(fire_dg "$DENY_GUARD" "echo pwned > .quetrex/verify.json" "$F5")"
if is_deny "$OUT"; then
  ok "AC5: deny-guard denies a redirect-overwrite of .quetrex/verify.json in an armed repo"
else
  notok "AC5: expected deny for a redirect overwrite of verify.json, got [$OUT]"
fi

# The unlock must NAME the file it unlocks (SEC-6): a blanket "1" -- which an
# ambient export or a settings.json env block supplies to every hook -- no
# longer authorizes anything, and a value naming a different file must not leak.
OUT="$(fire_dg "$DENY_GUARD" "rm -f .quetrex/verify.json" "$F5" "verify.json")"
if is_silent "$OUT"; then
  ok "AC5: the SCOPED unlock QUETREX_UNLOCK_FLOOR=verify.json permits rm of .quetrex/verify.json"
else
  notok "AC5: expected the scoped unlock to allow rm of verify.json, got [$OUT]"
fi

OUT="$(fire_dg "$DENY_GUARD" "rm -f .quetrex/verify.json" "$F5" "1")"
if is_deny "$OUT"; then
  ok "AC5: a blanket QUETREX_UNLOCK_FLOOR=1 does NOT permit rm of .quetrex/verify.json"
else
  notok "AC5: a blanket unlock still permitted rm of verify.json, got [$OUT]"
fi

OUT="$(fire_dg "$DENY_GUARD" "rm -f .quetrex/verify.json" "$F5" "project.json")"
if is_deny "$OUT"; then
  ok "AC5: an unlock naming a DIFFERENT file does not permit rm of verify.json"
else
  notok "AC5: a scoped unlock leaked across targets, got [$OUT]"
fi

# =============================================================================
# AC6 — deny-guard's project.json protection (SEC-ONECOPY-1) is unregressed.
# =============================================================================
OUT="$(fire_dg "$DENY_GUARD" "rm -f .quetrex/project.json" "$F5")"
if is_deny "$OUT"; then
  ok "AC6: deny-guard still denies rm of .quetrex/project.json (SEC-ONECOPY-1, unregressed)"
else
  notok "AC6: expected deny for rm of project.json (regression), got [$OUT]"
fi
rm -rf "$F5"

# =============================================================================
# AC7 — FAIL-FIRST (mechanical) against this task's own base sha (2ffde3a).
# =============================================================================
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  git -C "$REPO_ROOT" fetch --quiet --depth=1 origin "$BASE_SHA" 2>/dev/null || true
fi
if ! git -C "$REPO_ROOT" cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
  notok "AC7 FAIL-FIRST: baseline commit $BASE_SHA is not reachable in this checkout — cannot prove the regression existed pre-fix"
else
  OLD_VG="$(mktemp "${TMPDIR:-/tmp}/qx-vcr-old-vg.XXXXXX")"
  OLD_DG="$(mktemp "${TMPDIR:-/tmp}/qx-vcr-old-dg.XXXXXX")"
  OLD_QC="$(mktemp "${TMPDIR:-/tmp}/qx-vcr-old-qc.XXXXXX")"
  git -C "$REPO_ROOT" show "$BASE_SHA:plugins/quetrex-factory/scripts/verify-gate.sh" > "$OLD_VG" 2>/dev/null
  git -C "$REPO_ROOT" show "$BASE_SHA:plugins/quetrex-factory/scripts/deny-guard.sh" > "$OLD_DG" 2>/dev/null
  # verify-gate.sh sources its quick-chain helper by sibling path -- copy it
  # alongside the extracted baseline so the OLD script can actually load.
  cp "$REPO_ROOT/plugins/quetrex-factory/scripts/verify-gate-quick-chain.sh" "$(dirname "$OLD_VG")/verify-gate-quick-chain.sh" 2>/dev/null
  mv "$OLD_VG" "$(dirname "$OLD_VG")/verify-gate.sh" 2>/dev/null
  OLD_VG="$(dirname "$OLD_VG")/verify-gate.sh"

  F7="$(new_fixture)"; arm "$F7"
  OLD_VG_OUT="$(run_vg "$OLD_VG" "$F7")"
  OLD_DG_OUT="$(fire_dg "$OLD_DG" "rm -f .quetrex/verify.json" "$F7")"
  rm -rf "$F7" "$OLD_VG" "$OLD_DG" "$OLD_QC" "$(dirname "$OLD_VG")/verify-gate-quick-chain.sh" 2>/dev/null

  if is_silent "$OLD_VG_OUT" && is_silent "$OLD_DG_OUT"; then
    ok "AC7 FAIL-FIRST: at $BASE_SHA, an armed repo with no chain silently allowed Stop, and rm of verify.json silently allowed — both regressions are real, this is genuine new coverage"
  else
    notok "AC7 FAIL-FIRST: expected both to silently allow at $BASE_SHA; verify-gate=[$OLD_VG_OUT] deny-guard=[$OLD_DG_OUT]"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "verify-chain-required.test.sh: all checks passed"
else
  echo "verify-chain-required.test.sh: FAILURES above"
fi
exit "$FAIL"
