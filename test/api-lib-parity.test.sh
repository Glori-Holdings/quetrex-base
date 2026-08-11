#!/usr/bin/env bash
# api-lib-parity.test.sh — the sourceable lib must not be a stale fork of the CLI.
#
# WHY THIS EXISTS
# `.claude/lib/quetrex-api.sh` carries copies of the same kanban helpers `bin/quetrex-api`
# implements. When the CLI's child-creation, dependency and unblocked logic was fixed, the lib
# kept the OLD bodies — a second, silently-wrong implementation of the exact defect that had
# just been closed. Nothing compared them, and the lib is genuinely live: it is sourced
# directly, allowed by `.claude/settings.local.json`, and referenced by
# `.claude/lib/dev-pipeline.md`.
#
# This is the same failure class as the shipped hooks drifting from the audited hooks. That one
# hid a de-gatable security floor for weeks; this one would hand a caller a top-level task and
# call it a child.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/quetrex-api"
LIB="$ROOT/.claude/lib/quetrex-api.sh"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# Every helper the lib duplicates from the CLI. Adding a shared helper to either file
# without adding it here is itself drift, so ASSERTION 3 checks for that too.
SHARED="qx_create_child qx_add_dep qx_is_unblocked qx_task_status qx_task_type qx_task_ainote qx_task_comment qx_binding_path qx_env_scan qx_secret_put_from_env"

for f in "$BIN" "$LIB"; do
  [ -f "$f" ] || { echo "NOT OK - missing $f"; exit 1; }
done

# body <file> <fn> — the function's source, from `fn() {` to its matching top-level `}`.
body() { awk -v n="$2" '$0 == n"() {" {f=1} f {print} f && $0 == "}" {exit}' "$1"; }

for fn in $SHARED; do
  B="$(body "$BIN" "$fn")"
  L="$(body "$LIB" "$fn")"
  if [ -z "$B" ]; then
    notok "ASSERTION 1: $fn not found in bin/quetrex-api — the parity list is stale"
    continue
  fi
  if [ -z "$L" ]; then
    notok "ASSERTION 1: $fn not found in .claude/lib/quetrex-api.sh — the lib is missing a helper the CLI has"
    continue
  fi
  if [ "$B" = "$L" ]; then
    ok "ASSERTION 2: $fn is byte-identical in bin/quetrex-api and .claude/lib/quetrex-api.sh"
  else
    notok "ASSERTION 2: $fn DIFFERS between the CLI and the lib — a caller that sources the lib gets the old behavior (bin $(printf '%s' "$B" | wc -l | tr -d ' ') lines, lib $(printf '%s' "$L" | wc -l | tr -d ' '))"
  fi
done

# --- ASSERTION 3: no shared helper escapes the list above ---------------------
# Catches the drift-of-the-drift-check: a helper added to BOTH files but never compared.
BIN_FNS="$(grep -oE '^qx_[a-z_]+\(\) \{' "$BIN" | sed 's/() {//' | sort)"
LIB_FNS="$(grep -oE '^qx_[a-z_]+\(\) \{' "$LIB" | sed 's/() {//' | sort)"
COMMON="$(comm -12 <(printf '%s\n' "$BIN_FNS") <(printf '%s\n' "$LIB_FNS"))"
UNLISTED=""
for fn in $COMMON; do
  case " $SHARED " in *" $fn "*) ;; *) UNLISTED="$UNLISTED $fn" ;; esac
done
if [ -z "$UNLISTED" ]; then
  ok "ASSERTION 3: every helper present in both files is covered by the parity list"
else
  notok "ASSERTION 3: these helpers exist in BOTH files but are compared by nothing:$UNLISTED — add them to SHARED"
fi

# --- ASSERTION 4: the lib still parses ----------------------------------------
# A sync that corrupts the lib is worse than drift: every sourcing caller dies at once.
if bash -n "$LIB" 2>/dev/null; then
  ok "ASSERTION 4: .claude/lib/quetrex-api.sh parses"
else
  notok "ASSERTION 4: .claude/lib/quetrex-api.sh has a syntax error — every caller that sources it fails"
fi

echo
echo "api-lib-parity.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
