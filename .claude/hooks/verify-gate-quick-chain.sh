#!/usr/bin/env bash
# verify-gate-quick-chain.sh — sourced-only helper for .claude/hooks/verify-gate.sh.
#
# WHY A SEPARATE FILE (2026-08-21, HOOKFIX, structural AC10 fix): the bounded
# quick-chain machinery (declarative env-skip eligibility + the heavy-command
# filter + the quick-chain wall-clock cap) is a cohesive, self-contained unit
# — every function here is a pure function of $ROOT/$HEAD_SHA/env plus the
# arguments verify-gate.sh passes in, with no dependency on anything defined
# LATER in that file (LOG, LEDGER, the run loop). Extracting it keeps
# verify-gate.sh itself under the size-regression guard (AC10 /
# test/verify-gate.test.sh) without cutting the fail-closed rationale
# comments that guard exists to protect. UNLIKE merge-gate.sh's tokenizer
# (which protected-files-guard.sh COPIES rather than sources — see that
# file's header), verify-gate.sh has no load-time execution that a second
# file could break: it never computes anything at `source` time, so sourcing
# this file costs nothing structurally.
#
# NOT SELF-EXECUTING. This file defines functions only and must be SOURCED,
# never invoked directly — `set -uo pipefail` is inherited from the caller,
# nothing here runs until verify-gate.sh calls a function.
#
# CROSS-REPO PUBLISH (same class as verify-gate.sh's own note): this file
# must ship ALONGSIDE verify-gate.sh in the published quetrex-factory copy
# (plugins/quetrex-factory/scripts/), or the published verify-gate.sh's
# `source "$(dirname ...)/verify-gate-quick-chain.sh"` fails at runtime. That
# republish is a cross-repo follow-up outside this workstream's file
# ownership — see the developer's report.

# --- qx_apply_quick_cap: narrow BUDGET_TOTAL on the QUICK path only --------
# Reads/writes globals: QUICK (in), BUDGET_TOTAL (in/out), QUETREX_VERIFY_QUICK_CAP (env).
# Own var, never overloaded into BUDGET_DEFAULT (fixed-regex parsed by
# verify-gate-timeout-margin.test.sh). This is the STRUCTURAL bound — see the
# AMENDMENT note in verify-gate.sh's own header.
qx_apply_quick_cap() {
  QUICK_CAP_DEFAULT=90
  QUICK_CAP="${QUETREX_VERIFY_QUICK_CAP:-$QUICK_CAP_DEFAULT}"
  case "$QUICK_CAP" in ''|*[!0-9]*) QUICK_CAP="$QUICK_CAP_DEFAULT" ;; esac
  [ "$QUICK_CAP" -gt 0 ] 2>/dev/null || QUICK_CAP="$QUICK_CAP_DEFAULT"
  [ "$QUICK" -eq 1 ] && [ "$QUICK_CAP" -lt "$BUDGET_TOTAL" ] && BUDGET_TOTAL="$QUICK_CAP"
  return 0
}

# --- DECLARATIVE ENV SKIP (fix part c) --------------------------------------
# Moved ABOVE the heavy filter in the caller's invocation order: a missing-env
# skip must be RECORDED by the run loop, never silently dropped by the
# filter. Pre-flight only — NEVER inferred from a command's output. Returns 0
# (skip) and sets MISSING_ENV_VAR when `cmd` has a requiredEnv entry in
# verify.json and every constraint below is satisfied; returns 1 (run it)
# otherwise, which is the fail-closed default for anything ambiguous.
#
# DECLARATIVE ENV SKIP, full contract (unabridged, matches verify-gate.sh's
# own former inline copy byte-for-byte): a command whose verify.json
# `requiredEnv` entry names a variable that is genuinely unavailable in THIS
# checkout is never executed — skipped pre-flight, never inferred from output
# (that would be env-error laundering). The ENTIRE requiredEnv mapping (and
# the verify[] membership check) is read from the COMMITTED .quetrex/verify.json
# blob at the ONE sha this invocation pinned up front ($HEAD_SHA) — NEVER the
# working-tree file, NEVER a fresh `HEAD` re-resolved mid-run (SEC-2), so a
# command that commits mid-chain cannot author the authorization for a LATER
# command in the SAME run. A skip fires ONLY when ALL of:
#   1. `cmd` is byte-for-byte a member of the COMMITTED verify[] ARRAY
#      (type-asserted — a STRING `.verify` degrades jq's index() to a
#      SUBSTRING search, which would let a merely-containing command pass);
#   2. the variable name appears as a NAME= key in the COMMITTED blob of a
#      tracked $ROOT/.env.example or $ROOT/.env.sample at HEAD (a reviewed
#      diff must show the declaration; an uncommitted edit to the declaring
#      line does not count);
#   3. the variable is unset-or-empty in the hook's own environment AND is
#      not a key in $ROOT/.env, .env.local, .env.development, .env.test that
#      exist in this checkout (their presence means the command would have
#      had the value).
# If the committed verify.json cannot be read at all, NOTHING is treated as
# declared and no command is ever skipped.
MISSING_ENV_VAR=""
should_skip_for_env() {
  local cmd="$1"
  MISSING_ENV_VAR=""
  command -v jq >/dev/null 2>&1 || return 1
  # EMPTY-HEAD TRAP (SEC-2): empty $HEAD_SHA would degrade the show below to
  # `git show ":path"` (reads the INDEX, fail-OPEN). Return before any show.
  [ -n "$HEAD_SHA" ] || return 1
  local committed_verify_json
  committed_verify_json=$(git -C "$ROOT" show "$HEAD_SHA:.quetrex/verify.json" 2>/dev/null) || return 1
  [ -n "$committed_verify_json" ] || return 1
  printf '%s' "$committed_verify_json" | jq -e --arg c "$cmd" \
    '(.verify // []) as $v | ($v | type) == "array" and (($v | index($c)) != null)' \
    >/dev/null 2>&1 || return 1
  local vars
  vars=$(printf '%s' "$committed_verify_json" | jq -r --arg c "$cmd" '
      if (.requiredEnv // {}) | type == "object"
      then (.requiredEnv[$c] // []) | if type == "array" then .[] else empty end
      else empty end
    ' 2>/dev/null)
  [ -n "$vars" ] || return 1
  local v declared exfile committed
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    # Only well-formed shell identifiers are safe to look up.
    case "$v" in
      [A-Za-z_]*) : ;;
      *) continue ;;
    esac
    case "$v" in *[!A-Za-z0-9_]*) continue ;; esac
    declared=0
    for exfile in .env.example .env.sample; do
      committed=$(git -C "$ROOT" show "$HEAD_SHA:$exfile" 2>/dev/null) || continue
      if printf '%s\n' "$committed" | grep -qE "^${v}="; then
        declared=1
        break
      fi
    done
    [ "$declared" -eq 1 ] || continue
    local val="${!v-}"
    [ -z "$val" ] || continue
    local envfile skip_this=0
    for envfile in "$ROOT/.env" "$ROOT/.env.local" "$ROOT/.env.development" "$ROOT/.env.test"; do
      if [ -f "$envfile" ] && grep -qE "^${v}=" "$envfile" 2>/dev/null; then
        skip_this=1
        break
      fi
    done
    [ "$skip_this" -eq 0 ] || continue
    MISSING_ENV_VAR="$v"
    return 0
  done <<EOF
$vars
EOF
  return 1
}

# --- qx_filter_heavy_chain: the heavy-command filter (CORRECTED 2026-08-21) -
# QUICK path only, declared verifyQuick included — a declared chain is not
# exempt. Heavy = bounded case-insensitive match on
# test|tests|build|e2e|playwright|vitest|jest|cypress ("testing-lib" is NOT
# flagged; "npm test"/"npm run build" are). CORRECTED: a requiredEnv-skip-
# eligible command is never excluded (kept so the run loop records its skip);
# if filtering would leave the CHAIN array EMPTY, the caller's array is left
# UNTOUCHED (the ORIGINAL selected chain still runs, under the cap) — never
# "filter to empty, run nothing". The regex is an optimization; the cap is
# the safety property. Bias to over-exclusion otherwise — merge-gate GATE 3
# backstops with the FULL chain at the merge boundary. Reads/writes the
# global array CHAIN in place; no new customer-controlled input.
qx_filter_heavy_chain() {
  [ "$QUICK" -eq 1 ] || return 0
  local _c
  local -a filtered=()
  local heavy_ere='(^|[^A-Za-z0-9])(test|tests|build|e2e|playwright|vitest|jest|cypress)([^A-Za-z0-9]|$)'
  for _c in "${CHAIN[@]}"; do
    if should_skip_for_env "$_c" || ! printf '%s' "$_c" | grep -Eiq "$heavy_ere"; then
      filtered+=("$_c")
    fi
  done
  [ "${#filtered[@]}" -gt 0 ] && CHAIN=("${filtered[@]}")
  return 0
}
