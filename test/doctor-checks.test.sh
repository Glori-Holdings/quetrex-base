#!/usr/bin/env bash
# test/doctor-checks.test.sh — behavioural test for two false positives in
# .claude/commands/doctor.md, verified live on quetrex-base and reported by
# the operator:
#
# Run: bash test/doctor-checks.test.sh
#
# DEFECT A (Check 2 — Engine). AUTOUP was read from
# extraKnownMarketplaces.quetrex.autoUpdate in the REPO's settings.json ONLY.
# quetrex-base has no extraKnownMarketplaces key there at all — the operator's
# autoUpdate:true lives in ~/.claude/settings.json (a perfectly valid, common
# setup) — so doctor printed a false "✗ Engine" and sent the operator to
# /quetrex:init for nothing. The fix resolves the setting the way Claude Code
# actually does: repo overrides global at the top-level key, but ABSENCE of
# the key at the repo level falls back to global rather than being read as a
# failure.
#   AC-A1 (false positive gone): repo settings has no extraKnownMarketplaces
#          key; global has autoUpdate:true -> Check 2 does NOT print the
#          "extraKnownMarketplaces...is not true" line.
#   AC-A2 (still fires when genuinely bad): neither repo nor global enables
#          autoUpdate -> Check 2 DOES print the ✗ line.
#   AC-A3 (repo still overrides global): repo explicitly sets autoUpdate:false
#          while global has autoUpdate:true -> Check 2 DOES print the ✗ line
#          (repo's explicit value wins, proving this isn't a blind OR).
#
# DEFECT B (Check 3 — legacy artifacts). The legacy list flagged
# ~/.claude/statusline-command.sh unconditionally, but that file is commonly
# the operator's ACTIVE status line (referenced by statusLine.command in a
# live settings.json) — and the status bar is the ONLY place the running
# engine version is shown by design (config carries no version). Quarantining
# it breaks the status bar. statusline-command.sh STAYS in the candidate
# list (an earlier fix removed it entirely — see AC29 below for why that
# was wrong) and a generic EXACT-PATH guard suppresses only the file a live
# settings.json statusLine.command actually targets, for ANY candidate, not
# just that one name — a superstring or substring match must not suppress.
#   AC-B1 (the exact reported case): statusline-command.sh exists AND is
#          referenced by a live global statusLine.command -> never flagged.
#   AC-B3 (guard is generic, not name-specific): a DIFFERENT still-listed
#          legacy candidate (team-protocol.md) that IS referenced by a live
#          statusLine.command -> not flagged.
#   AC-B4 (still fires correctly): that SAME candidate, existing but NOT
#          referenced by any live statusLine.command -> IS flagged (proves
#          the guard suppresses only genuinely-live files, not everything).
#
# See AC29 below for the SEC-6 correction: statusline-command.sh must stay
# a candidate (a genuinely orphaned copy must still be reported) and the
# guard must be exact-path, never substring.
#
# DEFECT C (Check 3 — npm-era command glob). `compgen -G` is a bash-only
# builtin: under zsh it is "command not found" (exit 127), which the `if`
# swallows as false — so the check silently never fires under zsh regardless
# of what is on disk, which is the opposite failure from a false positive but
# still wrong: the SAME input must produce the SAME verdict under both
# shells. The fix uses `find` (pattern is a literal argument, not shell-
# expanded) so the check is portable.
#   AC-C1: no quetrex-*.md files present -> no "npm-era commands" entry,
#          under BOTH bash and zsh.
#   AC-C2: a quetrex-*.md file IS present -> the "npm-era commands" entry
#          DOES appear, under BOTH bash and zsh.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_MD="$TOOLROOT/.claude/commands/doctor.md"

if [ ! -f "$DOCTOR_MD" ]; then
  echo "FAIL: doctor.md not found at $DOCTOR_MD"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — doctor.md's checks are node-assisted"
  exit 0
fi
if ! command -v zsh >/dev/null 2>&1; then
  ZSH_AVAILABLE=0
else
  ZSH_AVAILABLE=1
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-doctor-checks.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Extract a single "## Check N" (or "## Setup") bash fence out of doctor.md,
# the same technique test/env-derive.test.sh (AC16) already uses so a
# doctor.md edit is proven against the REAL committed prose, never a copy.
# -----------------------------------------------------------------------------
extract_section() {  # extract_section <heading-regex-literal>
  local heading="$1"
  awk -v heading="$heading" '
    index($0, heading) == 1 { insec = 1; next }
    insec && /^## / { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$DOCTOR_MD"
}

CHECK2_SCRIPT="$(extract_section '## Check 2')"
CHECK3_SCRIPT="$(extract_section '## Check 3')"

# Isolated PATH: bin/ (for quetrex-version) + node's own directory (both
# Check 2 and Check 3 are node-assisted) + the base system dirs — but
# deliberately WITHOUT the directory holding the operator's real `claude`
# CLI, so Check 2's separate "Engine loads" sub-check never runs live
# against this machine's actual plugin list inside a fixture test.
NODE_DIR="$(dirname "$(command -v node)")"
ISOLATED_PATH="$TOOLROOT/bin:$NODE_DIR:/usr/bin:/bin"

if [ -z "$CHECK2_SCRIPT" ]; then
  fail "setup: could not extract Check 2's bash fence from $DOCTOR_MD"
else
  pass "setup: extracted Check 2's bash fence from doctor.md"
fi
if [ -z "$CHECK3_SCRIPT" ]; then
  fail "setup: could not extract Check 3's bash fence from $DOCTOR_MD"
else
  pass "setup: extracted Check 3's bash fence from doctor.md"
fi

# run_check2 <fixture-repo-root> <fixture-home> [shell]
run_check2() {
  local repo="$1" home="$2" shell="${3:-bash}"
  (
    REPO_ROOT="$repo"; export REPO_ROOT
    HOME="$home"; export HOME
    SETTINGS="$repo/.claude/settings.json"; export SETTINGS
    HOME_SETTINGS="$home/.claude/settings.json"; export HOME_SETTINGS
    PATH="$ISOLATED_PATH"; export PATH
    "$shell" -c "$CHECK2_SCRIPT"
  )
}

# run_check3 <fixture-home> [shell]
run_check3() {
  local home="$1" shell="${2:-bash}"
  (
    HOME="$home"; export HOME
    SETTINGS="$home/does-not-exist/.claude/settings.json"; export SETTINGS
    HOME_SETTINGS="$home/.claude/settings.json"; export HOME_SETTINGS
    PATH="$ISOLATED_PATH"; export PATH
    "$shell" -c "$CHECK3_SCRIPT"
  )
}

# =============================================================================
# DEFECT A — Check 2 AUTOUP fallback
# =============================================================================
mk_repo_settings() {  # mk_repo_settings <dir> <extra-json-or-empty>
  mkdir -p "$1/.claude"
  cat > "$1/.claude/settings.json" <<EOF
{
  "enabledPlugins": { "quetrex@quetrex": true, "quetrex-factory@quetrex": true }${2:+,
  $2}
}
EOF
}

# --- AC-A1: repo has NO extraKnownMarketplaces key; global has autoUpdate:true
A1_REPO="$WORK/a1-repo"
A1_HOME="$WORK/a1-home"
mk_repo_settings "$A1_REPO" ""
mkdir -p "$A1_HOME/.claude"
cat > "$A1_HOME/.claude/settings.json" <<'EOF'
{ "extraKnownMarketplaces": { "quetrex": { "autoUpdate": true } } }
EOF

OUT_A1="$(run_check2 "$A1_REPO" "$A1_HOME" bash 2>&1)"
if printf '%s' "$OUT_A1" | grep -q 'extraKnownMarketplaces.*is not true'; then
  fail "AC-A1: false positive — Check 2 still reports autoUpdate not true when only the repo level is absent (out: [$OUT_A1])"
else
  pass "AC-A1: no false-positive autoUpdate line when repo is absent but global enables it"
fi
if printf '%s' "$OUT_A1" | grep -q '✓ Engine'; then
  pass "AC-A1: Check 2 prints a green Engine line"
else
  fail "AC-A1: expected a green Engine line (out: [$OUT_A1])"
fi

# --- AC-A2: neither repo nor global enables autoUpdate (genuinely bad)
A2_REPO="$WORK/a2-repo"
A2_HOME="$WORK/a2-home"
mk_repo_settings "$A2_REPO" ""
mkdir -p "$A2_HOME/.claude"
echo '{}' > "$A2_HOME/.claude/settings.json"

OUT_A2="$(run_check2 "$A2_REPO" "$A2_HOME" bash 2>&1)"
if printf '%s' "$OUT_A2" | grep -q '✗ Engine.*extraKnownMarketplaces.*is not true'; then
  pass "AC-A2: Check 2 still correctly reports ✗ when neither level enables autoUpdate"
else
  fail "AC-A2: expected the ✗ autoUpdate line when genuinely absent at both levels (out: [$OUT_A2])"
fi

# --- AC-A3: repo explicitly sets autoUpdate:false, global has true (repo wins)
A3_REPO="$WORK/a3-repo"
A3_HOME="$WORK/a3-home"
mk_repo_settings "$A3_REPO" '"extraKnownMarketplaces": { "quetrex": { "autoUpdate": false } }'
mkdir -p "$A3_HOME/.claude"
cat > "$A3_HOME/.claude/settings.json" <<'EOF'
{ "extraKnownMarketplaces": { "quetrex": { "autoUpdate": true } } }
EOF

OUT_A3="$(run_check2 "$A3_REPO" "$A3_HOME" bash 2>&1)"
if printf '%s' "$OUT_A3" | grep -q '✗ Engine.*extraKnownMarketplaces.*is not true'; then
  pass "AC-A3: a repo-level autoUpdate:false overrides a global autoUpdate:true (repo wins, not a blind OR)"
else
  fail "AC-A3: expected ✗ when the repo explicitly disables autoUpdate even though global enables it (out: [$OUT_A3])"
fi

# =============================================================================
# DEFECT B — Check 3 statusLine guard
# =============================================================================

# --- AC-B1: the exact reported case — statusline-command.sh exists AND is
# referenced by a live global statusLine.command.
B1_HOME="$WORK/b1-home"
mkdir -p "$B1_HOME/.claude"
echo '#!/usr/bin/env bash' > "$B1_HOME/.claude/statusline-command.sh"
cat > "$B1_HOME/.claude/settings.json" <<EOF
{ "statusLine": { "type": "command", "command": "bash $B1_HOME/.claude/statusline-command.sh" } }
EOF

OUT_B1="$(run_check3 "$B1_HOME" bash 2>&1)"
if printf '%s' "$OUT_B1" | grep -q 'statusline-command.sh'; then
  fail "AC-B1: statusline-command.sh is flagged even though a live statusLine.command references it (out: [$OUT_B1])"
else
  pass "AC-B1: statusline-command.sh referenced by a live statusLine.command is never flagged"
fi

# AC-B2 removed: it asserted that an unreferenced statusline-command.sh is
# NEVER flagged, which was the codified form of an earlier wrong instruction
# ("remove it from the candidate list entirely"). The architect's re-plan
# (AC29) corrected this: statusline-command.sh must stay a candidate so a
# genuinely orphaned copy is still reported (the SEC-6 lost-detection case).
# AC29 STATE 4 below is the identical fixture (statusline-command.sh present,
# no statusLine reference anywhere) asserting the now-authoritative outcome
# (IS flagged) — AC-B2 was a literal contradiction of it, not a
# complementary case, so it is deleted rather than kept alongside AC29.

# --- AC-B3: a DIFFERENT still-listed candidate (team-protocol.md), referenced
# by a live statusLine.command -> the guard is generic, not name-specific.
B3_HOME="$WORK/b3-home"
mkdir -p "$B3_HOME/.claude"
echo 'legacy content' > "$B3_HOME/.claude/team-protocol.md"
cat > "$B3_HOME/.claude/settings.json" <<EOF
{ "statusLine": { "type": "command", "command": "bash $B3_HOME/.claude/team-protocol.md" } }
EOF

OUT_B3="$(run_check3 "$B3_HOME" bash 2>&1)"
if printf '%s' "$OUT_B3" | grep -q 'team-protocol.md'; then
  fail "AC-B3: team-protocol.md is flagged even though a live statusLine.command references it — guard is not generic (out: [$OUT_B3])"
else
  pass "AC-B3: the statusLine guard suppresses ANY candidate referenced by a live command, not just statusline-command.sh"
fi

# --- AC-B4: the SAME candidate, existing but genuinely orphaned (no
# statusLine reference at all) -> the check still correctly flags it.
B4_HOME="$WORK/b4-home"
mkdir -p "$B4_HOME/.claude"
echo 'legacy content' > "$B4_HOME/.claude/team-protocol.md"

OUT_B4="$(run_check3 "$B4_HOME" bash 2>&1)"
if printf '%s' "$OUT_B4" | grep -q '✗ Leftover legacy artifacts.*team-protocol.md'; then
  pass "AC-B4: a genuinely orphaned legacy file is still correctly flagged"
else
  fail "AC-B4: expected team-protocol.md to be flagged when it is genuinely orphaned (out: [$OUT_B4])"
fi

# =============================================================================
# AC29 (plan VERIFY-GATE-QUIET, workstream doctorfix) — QA-AUTHORED,
# independent of AC-B1/AC-B3/AC-B4 above. The plan requires
# statusline-command.sh RESTORED to the LEGACY candidate list (not
# permanently removed) with an EXACT-path guard (tokenize, expand a leading
# ~ to $HOME, resolve, compare for equality) so a genuinely stale/orphaned
# statusline-command.sh is still detected (the SEC-6 lost-detection case)
# while a live statusLine.command target is still suppressed. AC-B1/AC-B3/
# AC-B4 above are compatible with this and stay green under it. The former
# AC-B2 asserted the OPPOSITE of this plan requirement (unconditional
# removal from the list) — it encoded an earlier, wrong instruction rather
# than the plan's acceptance criterion, contradicted AC29 STATE 4 on the
# identical fixture, and has been deleted (see the note above DEFECT B's
# AC-B3 section). These assertions test the plan's actual measure directly
# against the shipped doctor.md source and a live fixture.
# =============================================================================

# --- AC29 RESTORED-TO-LIST: the plan's own source-level measure.
STATUSLINE_IN_LIST="$(awk '/^for f in/,/^done$/' "$DOCTOR_MD" | grep -c 'statusline-command.sh' || true)"
[ -n "$STATUSLINE_IN_LIST" ] || STATUSLINE_IN_LIST=0
if [ "$STATUSLINE_IN_LIST" -eq 1 ]; then
  pass "AC29 RESTORED-TO-LIST: 'statusline-command.sh' appears exactly once in the Check 3 LEGACY for-loop list"
else
  fail "AC29 RESTORED-TO-LIST: expected 'statusline-command.sh' to appear exactly 1 time in the Check 3 LEGACY list, got $STATUSLINE_IN_LIST — the plan (.quetrex/plan/VERIFY-GATE-QUIET.json AC29) requires it RESTORED, not permanently removed; removing it entirely reintroduces the SEC-6 lost-detection case for every OTHER stale artifact class too, since a repo with a genuinely orphaned statusline-command.sh now gets 0 signal, silently, forever"
fi

# --- AC29 STATE 4 (behavioural): orphaned statusline-command.sh, NO
# statusLine key anywhere -> the plan requires it IS reported.
B29S4_HOME="$WORK/b29-state4-home"
mkdir -p "$B29S4_HOME/.claude"
echo '#!/usr/bin/env bash' > "$B29S4_HOME/.claude/statusline-command.sh"
OUT_B29S4="$(run_check3 "$B29S4_HOME" bash 2>&1)"
if printf '%s' "$OUT_B29S4" | grep -q 'statusline-command.sh'; then
  pass "AC29 STATE 4: an orphaned statusline-command.sh with NO statusLine key anywhere IS reported (SEC-6 lost-detection case restored)"
else
  fail "AC29 STATE 4: an orphaned statusline-command.sh with NO statusLine key anywhere is NOT reported (out: [$OUT_B29S4]) — this IS the SEC-6 lost-detection defect the plan required closed: a genuinely stale statusline-command.sh now produces zero signal in any repo, forever"
fi

# --- AC29 STATE-2-equivalent (behavioural, exact-match guard): a candidate
# STILL in the list (team-protocol.md) is orphaned, but statusLine.command
# references a SUPERSTRING of its path (team-protocol.md.bak) — the plan
# requires exact-path comparison, so a superstring must NOT suppress it.
B29SUP_HOME="$WORK/b29-superstring-home"
mkdir -p "$B29SUP_HOME/.claude"
echo 'legacy content' > "$B29SUP_HOME/.claude/team-protocol.md"
cat > "$B29SUP_HOME/.claude/settings.json" <<EOF
{ "statusLine": { "type": "command", "command": "bash $B29SUP_HOME/.claude/team-protocol.md.bak" } }
EOF
OUT_B29SUP="$(run_check3 "$B29SUP_HOME" bash 2>&1)"
if printf '%s' "$OUT_B29SUP" | grep -q 'team-protocol.md'; then
  pass "AC29 SUPERSTRING: a statusLine.command referencing team-protocol.md.bak (a superstring) does not suppress the orphaned team-protocol.md — exact-path guard confirmed"
else
  fail "AC29 SUPERSTRING: a statusLine.command referencing team-protocol.md.bak wrongly SUPPRESSED the orphaned team-protocol.md (out: [$OUT_B29SUP]) — is_live_statusline() still uses a substring \`grep -qF\` match, not the exact-path (tokenize/expand ~/resolve/compare-equal) guard the plan requires; this is the original SEC-6 fail-open, still reachable for every candidate still in the list"
fi

# =============================================================================
# DEFECT C — Check 3 npm-era command glob, bash/zsh parity
# =============================================================================

# --- AC-C1: no quetrex-*.md files present
C1_HOME="$WORK/c1-home"
mkdir -p "$C1_HOME/.claude/commands"

OUT_C1_BASH="$(run_check3 "$C1_HOME" bash 2>&1)"
if printf '%s' "$OUT_C1_BASH" | grep -q 'npm-era commands'; then
  fail "AC-C1 (bash): reported a match with no quetrex-*.md files present (out: [$OUT_C1_BASH])"
else
  pass "AC-C1 (bash): no npm-era-commands entry when none exist"
fi

if [ "$ZSH_AVAILABLE" -eq 1 ]; then
  OUT_C1_ZSH="$(run_check3 "$C1_HOME" zsh 2>&1)"
  if printf '%s' "$OUT_C1_ZSH" | grep -q 'npm-era commands'; then
    fail "AC-C1 (zsh): reported a match with no quetrex-*.md files present (out: [$OUT_C1_ZSH])"
  else
    pass "AC-C1 (zsh): no npm-era-commands entry when none exist"
  fi
  if [ "$OUT_C1_BASH" = "$OUT_C1_ZSH" ]; then
    pass "AC-C1: bash and zsh produce byte-identical output for the same (empty) input"
  else
    fail "AC-C1: bash and zsh output diverged for the same input (bash: [$OUT_C1_BASH], zsh: [$OUT_C1_ZSH])"
  fi
else
  echo "SKIP: zsh not installed — AC-C1/AC-C2 zsh-parity assertions skipped"
fi

# --- AC-C2: a quetrex-*.md file IS present
C2_HOME="$WORK/c2-home"
mkdir -p "$C2_HOME/.claude/commands"
echo '# old command' > "$C2_HOME/.claude/commands/quetrex-old.md"

OUT_C2_BASH="$(run_check3 "$C2_HOME" bash 2>&1)"
if printf '%s' "$OUT_C2_BASH" | grep -q 'npm-era commands'; then
  pass "AC-C2 (bash): correctly reports the npm-era-commands entry when a quetrex-*.md file exists"
else
  fail "AC-C2 (bash): expected the npm-era-commands entry (out: [$OUT_C2_BASH])"
fi

if [ "$ZSH_AVAILABLE" -eq 1 ]; then
  OUT_C2_ZSH="$(run_check3 "$C2_HOME" zsh 2>&1)"
  if printf '%s' "$OUT_C2_ZSH" | grep -q 'npm-era commands'; then
    pass "AC-C2 (zsh): correctly reports the npm-era-commands entry when a quetrex-*.md file exists"
  else
    fail "AC-C2 (zsh): expected the npm-era-commands entry (out: [$OUT_C2_ZSH])"
  fi
  if [ "$OUT_C2_BASH" = "$OUT_C2_ZSH" ]; then
    pass "AC-C2: bash and zsh produce byte-identical output for the same (matching) input"
  else
    fail "AC-C2: bash and zsh output diverged for the same input (bash: [$OUT_C2_BASH], zsh: [$OUT_C2_ZSH])"
  fi
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "doctor-checks.test.sh: all checks passed"
  exit 0
else
  echo "doctor-checks.test.sh: FAILURES above"
  exit 1
fi
