#!/usr/bin/env bash
# test/board-repo-link-code-ok-flags.test.sh — adversarial QA probe on
# `quetrex-api code-ok` / qx_code_is_board_shaped (bin/quetrex-api), the
# predicate resolve_project and init's qx_link_project_repo advisory line
# both rely on to prove a `.quetrex/project.json` projectCode is one the
# board could actually have issued before it is interpolated into a
# copy-paste `quetrex-api PATCH` one-liner.
#
# qx_code_is_board_shaped is implemented as:
#   node -e '<fixed regex test script>' "$1"
# "$1" is untrusted (it comes straight from a cloned repo's committed
# .quetrex/project.json) and is passed to `node` as a bare extra argv
# entry AFTER the -e script, not after a `--` separator. Node's own CLI
# parser inspects that entry for flags it recognises BEFORE ever handing
# control to the eval'd script — so a projectCode that happens to look
# like a node flag is consumed by node itself instead of ever reaching
# the regex test.
#
#   AC1  A projectCode of "--version" (or "-v") makes node print its own
#        version banner and exit 0 — qx_code_is_board_shaped reports
#        "board-shaped" (exit 0) for a value that is not even close to
#        the `^[A-Z]{3}[0-9]*$` shape it claims to enforce. This is a
#        real bypass of the exact guard resolve_project/init's advisory
#        line document themselves as depending on.
#   AC2  A projectCode of "--help" similarly exits 0 (and dumps node's
#        full usage text) instead of correctly rejecting.
#   AC3  Sanity: an ordinary non-flag, non-board-shaped code ("lowercase",
#        "TOOLONGCODE123456") is still correctly rejected (exit 1), so
#        this is specifically a flag-parsing bypass, not a blanket break.
#   AC4  Sanity: a real board-issued code ("DEA", "DEA2") is still
#        accepted (exit 0).
#
# Run: bash test/board-repo-link-code-ok-flags.test.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/plugins/quetrex-setup/bin/quetrex-api"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() { printf '\n%s\n' "board-repo-link-code-ok-flags.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
[ -x "$BIN" ] || { notok "quetrex-api not found/executable at $BIN"; finish; }

if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

for SH in $SHELLS; do
  # AC1 — "--version" must be REJECTED (exit != 0), never accepted.
  out="$("$SH" "$BIN" code-ok "--version" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$SH/code-ok --version: correctly rejected (exit $rc)"
  else
    notok "$SH/code-ok --version: BYPASS — exited 0 (node consumed it as a CLI flag; stdout was: ${out:0:60})"
  fi

  # AC1b — same bypass via the short form.
  out="$("$SH" "$BIN" code-ok "-v" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$SH/code-ok -v: correctly rejected (exit $rc)"
  else
    notok "$SH/code-ok -v: BYPASS — exited 0 (node consumed it as a CLI flag; stdout was: ${out:0:60})"
  fi

  # AC2 — "--help" must be REJECTED, not dump node's usage text with exit 0.
  out="$("$SH" "$BIN" code-ok "--help" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "$SH/code-ok --help: correctly rejected (exit $rc)"
  else
    notok "$SH/code-ok --help: BYPASS — exited 0 (node consumed it as a CLI flag; $(printf '%s' "$out" | wc -l | tr -d ' ') lines of node usage text leaked to stdout)"
  fi

  # AC3 — ordinary non-flag junk is still correctly rejected.
  for bad in lowercase TOOLONGCODE123456 "AB" "1QUE" ".."; do
    "$SH" "$BIN" code-ok "$bad" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      ok "$SH/code-ok '$bad': correctly rejected"
    else
      notok "$SH/code-ok '$bad': should have been rejected but exited 0"
    fi
  done

  # AC4 — a real board-shaped code is still accepted.
  for good in DEA DEA2 QUE; do
    "$SH" "$BIN" code-ok "$good" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      ok "$SH/code-ok '$good': correctly accepted"
    else
      notok "$SH/code-ok '$good': should have been accepted but was rejected"
    fi
  done
done

# ---------------------------------------------------------------------------
# ADDED WITH THE FIX — the same argv/option-parser bypass everywhere else in
# bin/quetrex-api it reached, and the full hostile value set for code-ok.
#
# THE FIX. Every node one-liner in bin/quetrex-api now goes through _qx_node,
# which hands untrusted values to node in the ENVIRONMENT (process.env.QX_A1
# ..QX_A4) instead of argv, so node's CLI parser never sees them at all. A `--`
# terminator would also have closed the parse, but it leaves the value on argv
# and leaves the next call site one forgotten `--` away from the same bug.
#
# Every case below drives the SHIPPED tool end to end (never a sub-expression),
# under both shells, and each is proven fail-first against the pre-fix binary:
#   git show 39df7fc:plugins/quetrex-setup/bin/quetrex-api > /tmp/pre/quetrex-api
#   QX_API_BIN=/tmp/pre/quetrex-api bash test/board-repo-link-code-ok-flags.test.sh
BIN_UT="${QX_API_BIN:-$BIN}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/code-ok-flags.XXXXXX")"
cleanup_added() { rm -rf "$WORK"; }
trap cleanup_added EXIT

write_file() { printf '%s\n' "$2" > "$1"; }

# A repo binding carrying CODE, for driving resolve_project through
# `project-code` — a cloned repo's committed binding is attacker-supplied.
mk_binding() {
  local dir="$WORK/$1" code="$2"
  mkdir -p "$dir/.quetrex"
  write_file "$dir/.quetrex/project.json" "{\"projectCode\":\"$code\",\"kanbanUrl\":\"https://example.invalid\"}"
  printf '%s' "$dir"
}

# A fake HOME whose auth.json carries expiry EXP.
mk_home() {
  local home="$WORK/home-$1"
  mkdir -p "$home/.quetrex"
  write_file "$home/.quetrex/auth.json" "{\"kanbanUrl\":\"https://example.invalid\",\"token\":\"t\",\"expiresAt\":\"$2\"}"
  printf '%s' "$home"
}

for SH in $SHELLS; do
  # --- code-ok: the rest of the hostile set -------------------------------
  # "" and "-" were never option-parsed; they are here so the accept/reject
  # boundary is pinned by one list, not just by its exploitable half.
  for bad in "-e" "--" "-" "" "--version=1" "--QUEjunk" "-p" "--eval" "--print" "--input-type=module" "-r" "--require"; do
    "$SH" "$BIN_UT" code-ok "$bad" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
      ok "$SH/code-ok '$bad': correctly rejected"
    else
      notok "$SH/code-ok '$bad': BYPASS — exited 0 for a value that is not ^[A-Z]{3}[0-9]*\$"
    fi
  done

  # A flag-shaped value must also produce NO stdout — node's version banner or
  # usage text leaking here is exactly what a caller goes on to interpolate.
  for bad in "--version" "-v" "--help" "-e"; do
    out="$("$SH" "$BIN_UT" code-ok "$bad" 2>/dev/null)"
    if [ -z "$out" ]; then
      ok "$SH/code-ok '$bad': printed nothing on stdout"
    else
      notok "$SH/code-ok '$bad': leaked node output to stdout (${out:0:40})"
    fi
  done

  # Legitimate board-issued codes are unaffected.
  for good in DEA DEA2 QUE ABC XYZ99; do
    "$SH" "$BIN_UT" code-ok "$good" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      ok "$SH/code-ok '$good': correctly accepted"
    else
      notok "$SH/code-ok '$good': should have been accepted but was rejected"
    fi
  done

  # --- json-get (_qx_json_get: the file path was node's argv[1]) -----------
  write_file "$WORK/ok.json" '{"projectCode":"DEA"}'
  out="$("$SH" "$BIN_UT" json-get "$WORK/ok.json" projectCode 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "DEA" ]; then
    ok "$SH/json-get: still reads a real field out of a real file"
  else
    notok "$SH/json-get: regression — exit $rc, stdout '$out' (wanted 0 / DEA)"
  fi
  for bad in "--version" "-v" "--help"; do
    out="$("$SH" "$BIN_UT" json-get "$bad" projectCode 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
      ok "$SH/json-get '$bad' <path>: correctly failed with no stdout"
    else
      notok "$SH/json-get '$bad' <path>: BYPASS — exit $rc, stdout '${out:0:40}' (node parsed the file path as its own flag)"
    fi
  done

  # --- env-scan (qx_env_scan: the directory was node's argv[1]) ------------
  mkdir -p "$WORK/envdir"
  write_file "$WORK/envdir/.env" 'FOO_API_KEY=abcd1234'
  out="$("$SH" "$BIN_UT" env-scan "$WORK/envdir" 2>/dev/null)"
  case "$out" in
    *FOO_API_KEY*'****1234'*) ok "$SH/env-scan: still reports a real credential" ;;
    *) notok "$SH/env-scan: regression — did not report FOO_API_KEY (got '${out:0:60}')" ;;
  esac
  for bad in "--version" "-v" "--help"; do
    out="$("$SH" "$BIN_UT" env-scan "$bad" 2>/dev/null)"
    if [ -z "$out" ]; then
      ok "$SH/env-scan '$bad': printed nothing"
    else
      notok "$SH/env-scan '$bad': BYPASS — node's own output leaked into the scan results ('${out:0:40}')"
    fi
  done

  # --- resolve_project end to end (THE boundary init.md:1175 depends on) ---
  for bad in "--version" "-v" "--help"; do
    d="$(mk_binding "bind-flag" "$bad")"
    out="$(cd "$d" && "$SH" "$BIN_UT" project-code 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
      ok "$SH/project-code with projectCode '$bad': refused, nothing printed"
    else
      notok "$SH/project-code with projectCode '$bad': BYPASS — exit $rc, printed '${out:0:40}'; resolve_project carried a code the board could not have issued"
    fi
    rm -rf "$d"
  done
  d="$(mk_binding "bind-ok" "DEA")"
  out="$(cd "$d" && "$SH" "$BIN_UT" project-code 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "DEA" ]; then
    ok "$SH/project-code with projectCode 'DEA': still resolves"
  else
    notok "$SH/project-code with projectCode 'DEA': regression — exit $rc, stdout '$out'"
  fi
  rm -rf "$d"

  # --- resolve_auth expiry (expiresAt was node's argv[1]) ------------------
  # exit 0 from that node call means "token still valid", so a flag-shaped
  # expiresAt made an unusable auth.json read as live.
  for bad in "--version" "-v" "--help"; do
    h="$(mk_home "flag" "$bad")"
    out="$(HOME="$h" "$SH" "$BIN_UT" kanban-url 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
      ok "$SH/kanban-url with expiresAt '$bad': treated as not valid"
    else
      notok "$SH/kanban-url with expiresAt '$bad': BYPASS — exit $rc, printed '${out:0:40}'; an unparseable expiry read as a live token"
    fi
    rm -rf "$h"
  done
  h="$(mk_home "ok" "2099-01-01T00:00:00.000Z")"
  out="$(HOME="$h" "$SH" "$BIN_UT" kanban-url 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "https://example.invalid" ]; then
    ok "$SH/kanban-url with a real future expiry: still accepted"
  else
    notok "$SH/kanban-url with a real future expiry: regression — exit $rc, stdout '$out'"
  fi
  rm -rf "$h"
done

# --- the class, not just the instances --------------------------------------
# A new node call site added beside these would reintroduce the bug silently,
# so pin the SHAPE: no node invocation in the tool may take a bare trailing
# argv token, no script may read process.argv, and curl may not be handed a
# URL it could parse as an option either.
SRC="$ROOT/plugins/quetrex-setup/bin/quetrex-api"
NODE_SITES="$(grep -n 'node -e' "$SRC" | grep -v '^[0-9]*:[[:space:]]*#')"
if [ "$(printf '%s\n' "$NODE_SITES" | grep -c 'node -e')" = "1" ] \
   && printf '%s' "$NODE_SITES" | grep -q 'node -e "\$_qx_script"'; then
  ok "quetrex-api: exactly one 'node -e' call site remains, inside _qx_node — every untrusted value goes through the environment"
else
  notok "quetrex-api: a raw 'node -e' call site remains outside _qx_node — untrusted values must not reach node's argv: $(printf '%s' "$NODE_SITES" | tr '\n' ' ')"
fi
if grep -q 'process\.argv' "$SRC"; then
  notok "quetrex-api: a node script still reads process.argv — node's CLI parser sees those tokens first"
else
  ok "quetrex-api: no node script reads process.argv"
fi
if grep -n 'curl -q' "$SRC" | grep -q -- '-w .%{http_code}. "\$url"'; then
  notok "quetrex-api: curl is still handed \$url as a bare trailing token — use --url"
else
  ok "quetrex-api: curl receives its URL via --url, never as a bare token"
fi

# --- the SOURCEABLE copy carries the same bypass ----------------------------
# .claude/lib/quetrex-api.sh duplicates these helpers and is genuinely live (it
# is sourced directly and referenced by .claude/lib/dev-pipeline.md), so fixing
# only the CLI would leave a second, silently-vulnerable implementation behind.
# test/api-lib-parity.test.sh pins them byte-identical; this drives the lib.
LIB_SRC="$ROOT/.claude/lib/quetrex-api.sh"
if [ -f "$LIB_SRC" ]; then
  if grep -q 'process\.argv' "$LIB_SRC"; then
    notok "lib: a node script in .claude/lib/quetrex-api.sh still reads process.argv"
  else
    ok "lib: no node script in .claude/lib/quetrex-api.sh reads process.argv"
  fi

  write_file "$WORK/lib-ok.json" '{"projectCode":"DEA"}'
  out="$(bash -c 'source "$1" >/dev/null 2>&1; _qx_json_get "$2" projectCode' _ "$LIB_SRC" "$WORK/lib-ok.json" 2>/dev/null)"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "DEA" ]; then
    ok "lib: sourced _qx_json_get still reads a real field"
  else
    notok "lib: sourced _qx_json_get regressed — exit $rc, stdout '$out'"
  fi
  for bad in "--version" "-v" "--help"; do
    out="$(bash -c 'source "$1" >/dev/null 2>&1; _qx_json_get "$2" projectCode' _ "$LIB_SRC" "$bad" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
      ok "lib: sourced _qx_json_get '$bad': correctly failed with no stdout"
    else
      notok "lib: sourced _qx_json_get '$bad': BYPASS — exit $rc, stdout '${out:0:40}'"
    fi
  done
else
  notok "lib: .claude/lib/quetrex-api.sh not found — the parity copy moved and this check went blind"
fi

finish
