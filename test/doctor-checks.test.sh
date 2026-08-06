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
# it breaks the status bar. The fix removes statusline-command.sh from the
# static candidate list entirely AND adds a generic guard: no file referenced
# by any live settings.json statusLine.command is ever flagged, for ANY
# candidate, not just that one name.
#   AC-B1 (the exact reported case): statusline-command.sh exists AND is
#          referenced by a live global statusLine.command -> never flagged.
#   AC-B2 (unconditional removal): statusline-command.sh exists with NO
#          settings referencing it at all -> still never flagged (it is no
#          longer a candidate, full stop).
#   AC-B3 (guard is generic, not name-specific): a DIFFERENT still-listed
#          legacy candidate (team-protocol.md) that IS referenced by a live
#          statusLine.command -> not flagged.
#   AC-B4 (still fires correctly): that SAME candidate, existing but NOT
#          referenced by any live statusLine.command -> IS flagged (proves
#          the guard suppresses only genuinely-live files, not everything).
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

# --- AC-B2: statusline-command.sh exists with NO settings referencing it —
# still never flagged (removed from the static list entirely).
B2_HOME="$WORK/b2-home"
mkdir -p "$B2_HOME/.claude"
echo '#!/usr/bin/env bash' > "$B2_HOME/.claude/statusline-command.sh"

OUT_B2="$(run_check3 "$B2_HOME" bash 2>&1)"
if printf '%s' "$OUT_B2" | grep -q 'statusline-command.sh'; then
  fail "AC-B2: statusline-command.sh is flagged even with no statusLine reference at all (out: [$OUT_B2])"
else
  pass "AC-B2: statusline-command.sh is never a candidate, even unreferenced"
fi
if printf '%s' "$OUT_B2" | grep -q '✓ No leftover legacy artifacts'; then
  pass "AC-B2: Check 3 reports fully healthy for a home with only an unreferenced statusline-command.sh"
else
  fail "AC-B2: expected the green legacy-artifacts line (out: [$OUT_B2])"
fi

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
