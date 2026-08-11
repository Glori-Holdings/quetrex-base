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

# --- THE CLI MUST BEHAVE, NOT MERELY MENTION ---------------------------------
# The previous version of this block grepped $BIN for the phrase "refusing a task reference".
# A reviewer deleted the guard entirely, left the phrase in a dead comment, and this file still
# reported `ok` while the binary happily constructed /api/tasks/../admin/secrets. That is the
# sixth says-not-does assertion found in this repo — and the second one written INSIDE a test
# meant to prevent the class. So drive the real binary and watch what it does.
CLI_PROBE="$TMP/cli"; mkdir -p "$CLI_PROBE"
# Stub the network at the lowest layer the CLI uses, so the guard is what is under test rather
# than curl's own refusal to accept a malformed URL.
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -uo pipefail'
  printf 'source %q\n' "$BIN"
  printf '%s\n' 'qapi() { printf "%s\n" "$2" >> "$QX_PROBE_LOG"; printf "{\"id\":\"x\"}"; }'
  printf '%s\n' '_qx_task_json "$1" >/dev/null 2>&1; echo "$?"'
} > "$CLI_PROBE/run.sh"
chmod +x "$CLI_PROBE/run.sh"

if grep -q '^_qx_main' "$BIN" 2>/dev/null || true; then :; fi

export QX_PROBE_LOG="$TMP/cli-paths.txt"
: > "$QX_PROBE_LOG"
CLI_RC="$(bash "$CLI_PROBE/run.sh" '../admin/secrets' 2>/dev/null | tail -1)"
CLI_SENT="$(grep -c . "$QX_PROBE_LOG" 2>/dev/null)"; CLI_SENT="${CLI_SENT:-0}"
if [ "$CLI_RC" != "0" ] && [ "$CLI_SENT" = "0" ]; then
  ok "the CLI itself refuses a traversal and builds no request (executed, not grepped)"
else
  notok "the CLI constructed $CLI_SENT request(s) for '../admin/secrets' (rc=$CLI_RC) — every command-line caller is traversable"
fi

: > "$QX_PROBE_LOG"
CLI_RC2="$(bash "$CLI_PROBE/run.sh" 'QDM-2.1' 2>/dev/null | tail -1)"
CLI_PATH="$(head -1 "$QX_PROBE_LOG" 2>/dev/null || true)"
if [ "$CLI_RC2" = "0" ] && [ "$CLI_PATH" = "/api/tasks/QDM-2.1" ]; then
  ok "the CLI still routes a legitimate child id correctly"
else
  notok "the CLI broke a legitimate ref: rc=$CLI_RC2 path='$CLI_PATH'"
fi

# --- EMBEDDED NEWLINE: an anchored regex matches PER LINE ----------------------
# `grep -E '^...$'` is satisfied by ANY line, so "SMA-1\n../admin/secrets" passed the first
# version of this guard. It was contained only by curl refusing control characters — i.e. by
# another program's parser, not by us.
: > "$TMP/paths.txt"
NL_REF="$(printf 'SMA-1\n../admin/secrets')"
nl_rc="$(probe "$LIB" "$NL_REF")"
nl_sent="$(grep -c . "$TMP/paths.txt" 2>/dev/null)"; nl_sent="${nl_sent:-0}"
if [ "$nl_rc" != "0" ] && [ "$nl_sent" = "0" ]; then
  ok "a ref with an embedded newline is refused, and builds no request"
else
  notok "NEWLINE BYPASS: an embedded newline produced rc=$nl_rc with $nl_sent request(s) — the anchor matches per line"
fi

echo
echo "api-ref-traversal.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
