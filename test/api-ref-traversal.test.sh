#!/usr/bin/env bash
# api-ref-traversal.test.sh — a task reference must never steer the request path.
#
# SEC-EPIC-2 (found by the review gate, reproduced against a real listener).
# `_qx_task_json` interpolated its argument straight into `/api/tasks/$ref`, and curl performs
# RFC 3986 dot-segment removal BEFORE sending — so `../admin/secrets` left the machine as
# `GET /api/admin/secrets`, carrying the operator's bearer token to an endpoint the caller
# chose, and the helper printed whatever 2xx body came back.
#
# The token is the whole point: qapi is deliberately built so the bearer never reaches argv or
# a log. Sending it to an arbitrary path defeats that from the inside.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${QX_API_BIN:-$ROOT/bin/quetrex-api}"
LIB="$ROOT/.claude/lib/quetrex-api.sh"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# Drive the helper with a stubbed qapi that RECORDS the path instead of making a request.
# Recording rather than blocking is deliberate: it proves the refusal happens BEFORE the
# request is built, not that the request merely failed somewhere downstream.
probe() {  # probe <file-defining-the-helper> <ref> -> "<exit>|<path-or-empty>"
  local src="$1" ref="$2" out
  out="$(bash -c '
    source "'"$src"'" 2>/dev/null
    qapi() { printf "%s" "$2" >> "'"$TMP"'/paths.txt"; printf "\n" >> "'"$TMP"'/paths.txt"; printf "{\"id\":\"x\"}"; }
    _qx_task_json "'"$ref"'" >/dev/null 2>&1
    echo "$?"
  ' 2>/dev/null)"
  printf '%s' "$out"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- HOSTILE REFS: must be refused, and must reach no request ------------------
HOSTILE='../admin/secrets
../../etc/passwd
..%2Fadmin
QDM-4/../../admin
a b
QDM-4;rm -rf /
$(whoami)
/api/admin'

while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  : > "$TMP/paths.txt"
  rc="$(probe "$LIB" "$ref")"
  sent="$(grep -c . "$TMP/paths.txt" 2>/dev/null)"; sent="${sent:-0}"
  if [ "$rc" != "0" ] && [ "$sent" = "0" ]; then
    ok "REFUSED before any request: '$ref'"
  else
    notok "TRAVERSAL: '$ref' produced exit=$rc with $sent request(s) — the bearer token would have been sent to a caller-chosen path"
  fi
done <<< "$HOSTILE"

# --- LEGITIMATE REFS: must still work, and reach the intended path -------------
for ref in "QDM-4" "QDM-2.1" "3d3f18e7-be33-4fc0-a92a-294d55e3ba39"; do
  : > "$TMP/paths.txt"
  rc="$(probe "$LIB" "$ref")"
  path="$(head -1 "$TMP/paths.txt" 2>/dev/null || true)"
  if [ "$rc" = "0" ] && [ "$path" = "/api/tasks/$ref" ]; then
    ok "ACCEPTED and routed correctly: '$ref' -> $path"
  else
    notok "REGRESSION: legitimate ref '$ref' gave exit=$rc path='$path' — the guard is over-tight and blocks real work"
  fi
done

# --- THE SAME GUARD MUST EXIST IN THE CLI, NOT ONLY THE LIB -------------------
# The two files carry parallel copies; a fix in one is not a fix. api-lib-parity.test.sh pins
# them byte-for-byte, but assert the guard's presence here too so this file fails on its own
# terms if someone syncs the wrong direction.
if grep -q 'refusing a task reference' "$BIN"; then
  ok "the CLI carries the same guard, not just the sourceable lib"
else
  notok "bin/quetrex-api has no reference guard — every command-line caller is still traversable"
fi

echo
echo "api-ref-traversal.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
