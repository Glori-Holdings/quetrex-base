#!/usr/bin/env bash
# test/onecopy-installed-hint.test.sh — SEC-ONECOPY-5 (Medium, round 2):
# .claude/hooks/protected-files-guard.sh's PROT_INSTALLED_HINT_ERE required
# the literal substring `quetrex-factory` before it would bypass the
# ARMED-ONLY exit for a machine-global installed-plugin path. That covered
# the STANDALONE quetrex-factory plugin's cache/marketplace copy, but NOT
# the floor-script copies cached under the "quetrex" plugin's OWN versions
# — e.g. ~/.claude/plugins/cache/quetrex/quetrex/2.5.3/.claude/hooks/
# merge-gate.sh, and every OTHER installed version on the machine (2.4.0,
# 2.5.0, 2.5.1, 2.5.2, ...). Those paths never hit the hint, so from an
# UNARMED session they fell straight through the ARMED-ONLY exit and were
# silently ALLOWED — even though PROT_PATH_ERE (matched later, on the real
# candidate token) already recognizes the `hooks/<floor-name>.sh` tail as
# protected.
#
# THE FIX: PROT_INSTALLED_HINT_ERE now matches ANY
# `.claude/plugins/(cache|marketplaces)/` path, dropping the
# `quetrex-factory`-only restriction — that segment alone is already the
# whole "this is a machine-global installed-plugin path" signal;
# PROT_PATH_ERE still makes the real protect/allow decision on the token.
#
# AC1: the "quetrex" plugin's OWN versioned cache, nested
#      `.claude/hooks/<floor-name>.sh` shape, denies from an UNARMED
#      session, for several version segments.
# AC2: the same shape denies from an ARMED session too (non-regression).
# AC3: QUETREX_UNLOCK_FLOOR=1 still permits it (the unlock is unaffected).
# AC4: a REAL, unrelated file living at a similarly-shaped installed path
#      (not one of the 6 protected basenames) is left alone — the broadened
#      hint does not turn into a blanket deny of the whole cache tree.
# AC5: FAIL-FIRST (mechanical) against e384c11: the exact same AC1 fixture
#      was a silent ALLOW there.
#
# Run: bash test/onecopy-installed-hint.test.sh

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${QX_PROTECTED_FILES_GUARD_HOOK:-$ROOT/.claude/hooks/protected-files-guard.sh}"
BASE_SHA_R2="e384c11"

[ -f "$GUARD" ] || { echo "FAIL: guard not found at $GUARD"; echo; echo "onecopy-installed-hint.test.sh: 0 passed, 1 failed"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is not installed"; echo; echo "onecopy-installed-hint.test.sh: 0 passed, 0 failed"; exit 0; }

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
UNARMED="$TMP/unarmed"; mkdir -p "$UNARMED"
git -C "$UNARMED" init -q -b main >/dev/null 2>&1
ARMED="$TMP/armed"; mkdir -p "$ARMED/.quetrex"
git -C "$ARMED" init -q -b main >/dev/null 2>&1
printf '{}' > "$ARMED/.quetrex/project.json"

FLOOR_NAMES="deny-guard secret-scan enforce-branch merge-gate verify-gate"
QUETREX_OWN_CACHE_PATHS=()
for v in 2.4.0 2.5.0 2.5.1 2.5.2 2.5.3; do
  for name in $FLOOR_NAMES; do
    QUETREX_OWN_CACHE_PATHS+=("$TMP/fakehome/.claude/plugins/cache/quetrex/quetrex/${v}/.claude/hooks/${name}.sh")
  done
done

fire() {  # fire <file_path> <cwd> [unlock-value]
  local p="$1" d="$2" unlock="${3:-}" payload
  payload="$(jq -cn --arg p "$p" --arg d "$d" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$d}')"
  if [ -n "$unlock" ]; then
    printf '%s' "$payload" | env QUETREX_UNLOCK_FLOOR="$unlock" bash "$GUARD" 2>&1
  else
    printf '%s' "$payload" | env -u QUETREX_UNLOCK_FLOOR bash "$GUARD" 2>&1
  fi
}
is_deny()   { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_silent() { [ -z "$1" ]; }

# =============================================================================
# AC1 — "quetrex" plugin's own versioned cache, UNARMED session -> DENY
# =============================================================================
AC1_TOTAL="${#QUETREX_OWN_CACHE_PATHS[@]}"
AC1_DENY=0
for p in "${QUETREX_OWN_CACHE_PATHS[@]}"; do
  OUT="$(fire "$p" "$UNARMED")"
  is_deny "$OUT" && AC1_DENY=$((AC1_DENY+1)) || echo "# AC1 miss (expected deny from an UNARMED session): [$p] -> [$OUT]"
done
[ "$AC1_DENY" -eq "$AC1_TOTAL" ] \
  && ok "AC1: $AC1_TOTAL of $AC1_TOTAL quetrex-plugin-own-cache floor-script paths deny from an UNARMED session" \
  || notok "AC1: expected $AC1_TOTAL deny decisions from an unarmed session, got $AC1_DENY"

# =============================================================================
# AC2 — same shape, ARMED session -> DENY (non-regression)
# =============================================================================
P2="${QUETREX_OWN_CACHE_PATHS[0]}"
OUT="$(fire "$P2" "$ARMED")"
if is_deny "$OUT"; then
  ok "AC2: the quetrex-plugin-own-cache shape also denies from an ARMED session"
else
  notok "AC2: expected deny from an armed session for [$P2], got [$OUT]"
fi

# =============================================================================
# AC3 — SEC-6 (2026-08-26): a blanket QUETREX_UNLOCK_FLOOR=1 no longer
# permits it; the correctly-scoped basename does.
# =============================================================================
OUT_BLANKET="$(fire "$P2" "$UNARMED" "1")"
if is_deny "$OUT_BLANKET"; then
  ok "AC3: a blanket QUETREX_UNLOCK_FLOOR=1 no longer permits the write (SEC-6 fix)"
else
  notok "AC3: expected a blanket =1 to be denied post-SEC-6 [$P2], got [$OUT_BLANKET]"
fi

P2_BASENAME="$(basename "$P2")"
OUT_SCOPED="$(fire "$P2" "$UNARMED" "$P2_BASENAME")"
if ! is_deny "$OUT_SCOPED"; then
  ok "AC3: QUETREX_UNLOCK_FLOOR=$P2_BASENAME (correctly scoped) permits the write"
else
  notok "AC3: expected the scoped unlock to permit [$P2] with QUETREX_UNLOCK_FLOOR=$P2_BASENAME, got [$OUT_SCOPED]"
fi

# =============================================================================
# AC4 — an unrelated file at a similarly-shaped installed path (not one of
# the 6 protected basenames) is left alone: the broadened hint decides
# whether to bypass the ARMED-ONLY exit, never the protect/allow verdict
# itself (that is still PROT_PATH_ERE, matched on the real token).
# =============================================================================
UNRELATED="$TMP/fakehome/.claude/plugins/cache/quetrex/quetrex/2.5.3/.claude/hooks/some-unrelated-hook.sh"
OUT="$(fire "$UNRELATED" "$UNARMED")"
if is_silent "$OUT"; then
  ok "AC4: an unrelated file under the same installed-cache tree is left alone (silent)"
else
  notok "AC4: expected silence for an unrelated installed-cache file, got [$OUT]"
fi

# =============================================================================
# AC5 — FAIL-FIRST (mechanical) against e384c11.
# =============================================================================
if ! git -C "$ROOT" cat-file -e "${BASE_SHA_R2}^{commit}" 2>/dev/null; then
  notok "AC5 FAIL-FIRST: baseline commit $BASE_SHA_R2 is not reachable in this checkout — cannot prove SEC-ONECOPY-5 was open pre-fix"
else
  OLD_GUARD="$TMP/.old-pfg.sh"
  git -C "$ROOT" show "$BASE_SHA_R2:.claude/hooks/protected-files-guard.sh" > "$OLD_GUARD" 2>/dev/null
  OLD_HITS=0
  for p in "${QUETREX_OWN_CACHE_PATHS[@]}"; do
    OUT_OLD="$(printf '%s' "$(jq -cn --arg p "$p" --arg d "$UNARMED" '{tool_name:"Write",tool_input:{file_path:$p},cwd:$d}')" | env -u QUETREX_UNLOCK_FLOOR bash "$OLD_GUARD" 2>&1)"
    is_deny "$OUT_OLD" && OLD_HITS=$((OLD_HITS+1))
  done
  if [ "$OLD_HITS" -eq 0 ]; then
    ok "AC5 FAIL-FIRST: at $BASE_SHA_R2, 0 of $AC1_TOTAL quetrex-plugin-own-cache shapes were denied from an UNARMED session — SEC-ONECOPY-5 was real, this is a genuine fix"
  else
    notok "AC5 FAIL-FIRST: $OLD_HITS/$AC1_TOTAL shapes were already denied at $BASE_SHA_R2 — cannot demonstrate this is new coverage"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "onecopy-installed-hint.test.sh: all checks passed"
else
  echo "onecopy-installed-hint.test.sh: FAILURES above"
fi
exit "$FAIL"
