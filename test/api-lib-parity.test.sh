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
BIN="$ROOT/plugins/quetrex-setup/bin/quetrex-api"
LIB="$ROOT/.claude/lib/quetrex-api.sh"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

# Every helper the lib duplicates from the CLI. Adding a shared helper to either file
# without adding it here is itself drift, so ASSERTION 3 checks for that too.
#
# resolve_project, resolve_auth, qx_code_is_board_shaped were absent from this list for
# as long as it existed, and NOT because anyone judged them exempt — ASSERTION 3's
# discovery pattern was `^_?qx_[a-z_]+\(\) \{`, so it could only ever see helpers whose
# names happen to start with `qx_`. Every function outside that naming convention was
# invisible to the drift check by construction. That blind spot was exploited in
# practice: the CLI's resolve_project was hardened to reject a projectCode the board
# could not have issued, the lib's was not, and a cloned repo's `../admin/secrets`
# binding rode through the lib to a caller-chosen route on the operator's own board
# with the operator's own bearer token attached. ASSERTION 3 now discovers EVERY
# top-level function in both files, so a name is covered because it is compared, never
# because of how it is spelled.
SHARED="_qx_node qx_create_child qx_add_dep qx_is_unblocked qx_task_status qx_task_type qx_task_ainote qx_task_comment qx_binding_path qx_env_scan qx_secret_put_from_env _qx_trim _qx_task_json _qx_task_uuid _qx_json_get _qx_require_ref qx_code_is_board_shaped resolve_project resolve_auth"

# Functions that exist in BOTH files and are deliberately NOT pinned byte-identical.
# This list is the ONLY way out of ASSERTION 2, so every entry needs a stated reason
# here and is itself checked (ASSERTION 6) — a name that stops existing in both files
# must leave this list rather than sit here silently widening it.
#
#   qapi — same contract, deliberately different bodies. The CLI's qapi carries an
#     interactive operator harness the sourceable lib does not want: a 3-attempt retry
#     loop with per-curl-exit-code idempotency classification, connect/max timeouts,
#     and a response-body error reporter that scrubs the bearer token and truncates.
#     The lib is sourced inside an agent's shell where a retry loop would re-issue a
#     write nobody is watching, so it stays a thin one-shot. The two invariants that
#     are security-critical rather than ergonomic — the bearer reaching curl only
#     through a 0600 -K config, never argv, and the URL passed via --url rather than as
#     a bare trailing token curl could parse as an option — are pinned across BOTH
#     copies by test/board-repo-link-code-ok-flags.test.sh, not left to this file.
EXEMPT="qapi"

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
#
# The discovery pattern is `^[A-Za-z_][A-Za-z0-9_]*\(\) \{` — EVERY top-level function,
# not a naming convention. It used to be `^_?qx_[a-z_]+\(\) \{`, which made the parity
# list an allowlist twice over: a helper had to be added to SHARED *and* be spelled with
# a `qx_` prefix to be compared at all. resolve_project, resolve_auth and qapi are all
# real shared helpers that the old pattern could never see, and the security fix that
# landed in the CLI's resolve_project and not the lib's went unnoticed for exactly that
# reason. A function is now covered because it is in SHARED (compared byte-for-byte) or
# in EXEMPT (a stated reason above); there is no third, silent category.
fn_names() { grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\) \{' "$1" | sed 's/() {//' | sort -u; }
BIN_FNS="$(fn_names "$BIN")"
LIB_FNS="$(fn_names "$LIB")"
COMMON="$(comm -12 <(printf '%s\n' "$BIN_FNS") <(printf '%s\n' "$LIB_FNS"))"
UNLISTED=""
for fn in $COMMON; do
  case " $SHARED " in *" $fn "*) continue ;; esac
  case " $EXEMPT " in *" $fn "*) continue ;; esac
  UNLISTED="$UNLISTED $fn"
done
if [ -z "$UNLISTED" ]; then
  ok "ASSERTION 3: every function present in both files is either compared byte-for-byte or exempt with a stated reason"
else
  notok "ASSERTION 3: these functions exist in BOTH files but are compared by nothing:$UNLISTED — add them to SHARED, or to EXEMPT with a written reason"
fi

# --- ASSERTION 6: EXEMPT is not a dumping ground ------------------------------
# An exemption is only meaningful while the function it names still exists in both
# files. A stale entry is drift in its own right and, worse, it is the cheap way to
# make ASSERTION 3 go quiet — so a name that no longer sits in both copies fails here
# instead of silently pre-approving whatever gets added under it later.
STALE=""
for fn in $EXEMPT; do
  if ! printf '%s\n' "$BIN_FNS" | grep -qx "$fn" || ! printf '%s\n' "$LIB_FNS" | grep -qx "$fn"; then
    STALE="$STALE $fn"
  fi
done
if [ -z "$STALE" ]; then
  ok "ASSERTION 6: every EXEMPT entry names a function that really is in both files"
else
  notok "ASSERTION 6: EXEMPT names functions that are not in both files:$STALE — remove them; a stale exemption pre-approves drift"
fi

# --- ASSERTION 4: the lib still parses ----------------------------------------
# A sync that corrupts the lib is worse than drift: every sourcing caller dies at once.
if bash -n "$LIB" 2>/dev/null; then
  ok "ASSERTION 4: .claude/lib/quetrex-api.sh parses"
else
  notok "ASSERTION 4: .claude/lib/quetrex-api.sh has a syntax error — every caller that sources it fails"
fi

# --- ASSERTION 5: BEHAVIORAL — a synced helper must actually run when sourced ----
# Byte-identical bodies prove nothing if a callee they depend on was left behind. This is the
# assertion that would have caught the private-helper omission; the three above could not.
PROBE="$(bash -c 'source "'"$LIB"'" 2>/dev/null; qapi(){ printf "{}"; }; QX_PROJECT_CODE=X; qx_create_child P t d 2>&1 >/dev/null; ' 2>&1)"
if printf '%s' "$PROBE" | grep -q 'command not found'; then
  notok "ASSERTION 5: sourcing the lib and calling qx_create_child hits a missing callee — a helper it depends on was not synced ($(printf '%s' "$PROBE" | grep -o '[_a-z]*: command not found' | head -1))"
else
  ok "ASSERTION 5: the synced helpers resolve their callees when the lib is sourced"
fi

echo
echo "api-lib-parity.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
