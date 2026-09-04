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

finish
