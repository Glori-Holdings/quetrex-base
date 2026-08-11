#!/usr/bin/env bash
# test/doctor-tracked.test.sh — behavioural test for .claude/commands/doctor.md
# Check 8 ("Arming is COMMITTED, not just present on disk").
#
# Run: bash test/doctor-tracked.test.sh
#
# THE DEFECT (audit finding #21, severity critical). Every doctor check read
# the WORKING TREE: Setup resolves SETTINGS="$REPO_ROOT/.claude/settings.json"
# and BIND="$REPO_ROOT/.quetrex/project.json", Check 1 gates on [ -f "$BIND" ],
# Check 2 parses $SETTINGS off disk, Check 5 parses $REPO_ROOT/.quetrex/
# verify.json off disk. There was no `git ls-files`, no `git cat-file
# -e HEAD:`, no `git check-ignore` anywhere in the file.
#
# So a repo whose arming artifacts exist on disk but are UNTRACKED — the
# common shape being a `.gitignore` line for `.quetrex/` or `.claude/` — got a
# clean bill of health while being unarmed for every other clone. That matters
# because a cloud routine starts from a FRESH CLONE and can only ever see
# committed files: doctor says green, the operator dispatches a build from the
# phone, and the routine clones a repo with no project binding, no engine
# enablement and no verify chain.
#
# REPRODUCED BEFORE THE FIX: a fixture repo with `.gitignore` = `.quetrex/`,
# arming files written to disk, and only `.gitignore`/`package.json`/
# `.claude/settings.json` committed. doctor.md's Check 2 and Check 5 fences,
# extracted and run verbatim, printed:
#     ✓ Engine — enabled, unpinned, auto-updating (running Quetrex v2.4.0).
#     ✓ Verify chain configured — .quetrex/verify.json has a non-empty chain.
# while `git ls-files` listed neither .quetrex file and both
# `git cat-file -e HEAD:.quetrex/*.json` were ABSENT. STATE 1 below is that
# exact fixture.
#
# THE FIX: Check 8 re-asks Checks 1/2/5's questions of HEAD instead of the
# working tree, using git ls-files / cat-file / check-ignore.
#
#   STATE 1 (the reported case): arming files on disk, .quetrex/ gitignored
#           and untracked -> ✗, and the untracked binding is NAMED.
#   STATE 2 (the fix's other half): the same repo with those files tracked
#           and committed -> ✓.
#   STATE 3: untracked but NOT ignored -> ✗ with the "never git add'ed"
#           reason (not the .gitignore one) — the two causes need different
#           fixes, so they must not be conflated.
#   STATE 4: `git add`ed but never committed -> ✗. Tracked is not enough; a
#           clone materialises HEAD, so an index-only file reaches nobody.
#   STATE 5: settings.json long tracked AND committed, but the arming edit
#           (enabledPlugins) only on disk -> ✗. The committed BLOB is read,
#           never the file on disk.
#   STATE 6: no git repository at all -> ✗, with its own message (never a
#           crash, never a silent ✓).
#   STATE 7 (no false ✗ on the documented fallback): no committed
#           .quetrex/verify.json, but a committed .claude/CLAUDE.md with a
#           `## Verification` section -> ✓. Check 8 mirrors Check 5's
#           either/or; it must not demand verify.json specifically.
#   STATE 8 (no double-reporting): working tree has NEITHER verify.json nor
#           CLAUDE.md -> Check 8 says nothing about a verify chain (Check 5
#           owns that failure) and is otherwise ✓.
#   SOURCE: Check 8 actually interrogates git (ls-files + cat-file -e HEAD:),
#           so the check can never regress into another working-tree read
#           that happens to print the same words.
#   PARITY: identical verdict under bash and zsh for the same fixture (the
#           same portability rule DEFECT C in doctor-checks.test.sh exists
#           for — an operator's shell must not change a diagnosis).
#
# Assertions live HERE, not in test/doctor-checks.test.sh, which is shared
# history covering Check 2 / Check 3.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_MD="$TOOLROOT/.claude/commands/doctor.md"

if [ ! -f "$DOCTOR_MD" ]; then
  echo "FAIL: doctor.md not found at $DOCTOR_MD"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — doctor.md's Check 8 is node-assisted"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — Check 8 is entirely a git-tracking check"
  exit 0
fi
if command -v zsh >/dev/null 2>&1; then ZSH_AVAILABLE=1; else ZSH_AVAILABLE=0; fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-doctor-tracked.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Extract the "## Check 8" bash fence out of doctor.md — the same technique
# test/doctor-checks.test.sh and test/env-derive.test.sh use, so this is proven
# against the REAL shipped prose, never a copy that can drift from it.
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

CHECK8_SCRIPT="$(extract_section '## Check 8')"

NODE_DIR="$(dirname "$(command -v node)")"
GIT_DIR_BIN="$(dirname "$(command -v git)")"
ISOLATED_PATH="$TOOLROOT/bin:$NODE_DIR:$GIT_DIR_BIN:/usr/bin:/bin"

if [ -z "$CHECK8_SCRIPT" ]; then
  fail "setup: could not extract Check 8's bash fence from $DOCTOR_MD — doctor still has no committed-vs-present check, so a half-armed repo (arming files on disk, untracked) still reports all-green while every clone and every cloud routine sees an unarmed repo"
else
  pass "setup: extracted Check 8's bash fence from doctor.md"
fi

# run_check8 <fixture-repo-root> [shell]
run_check8() {
  local repo="$1" shell="${2:-bash}"
  (
    REPO_ROOT="$repo"; export REPO_ROOT
    SETTINGS="$repo/.claude/settings.json"; export SETTINGS
    HOME_SETTINGS="$repo/no-such-home/.claude/settings.json"; export HOME_SETTINGS
    PATH="$ISOLATED_PATH"; export PATH
    "$shell" -c "$CHECK8_SCRIPT"
  )
}

gitq() {  # gitq <repo> <args...> — quiet, identity-pinned, config-independent
  local repo="$1"; shift
  git -C "$repo" \
    -c user.email=doctor-tracked@test.invalid \
    -c user.name='Doctor Tracked Test' \
    -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null \
    "$@"
}

ARMED_SETTINGS='{ "enabledPlugins": { "quetrex@quetrex": true, "quetrex-factory@quetrex": true },
  "extraKnownMarketplaces": { "quetrex": { "autoUpdate": true } } }'
UNARMED_SETTINGS='{ "enabledPlugins": {} }'

# mk_repo <dir> — a repo with every arming artifact written to DISK and
# nothing but package.json committed. Callers then decide what gets tracked.
mk_repo() {
  local r="$1"
  mkdir -p "$r/.claude" "$r/.quetrex"
  git -C "$r" init -q -b main
  printf '%s\n' "$ARMED_SETTINGS" > "$r/.claude/settings.json"
  printf '%s\n' '{ "projectCode": "QUE", "branchPrefix": "que/" }' > "$r/.quetrex/project.json"
  printf '%s\n' '{ "steps": [ { "cmd": "npm test" } ] }' > "$r/.quetrex/verify.json"
  printf '%s\n' '{}' > "$r/package.json"
  gitq "$r" add package.json
  gitq "$r" commit -qm init
}

# =============================================================================
# STATE 1 — the reported case: .quetrex/ gitignored, arming files untracked.
# =============================================================================
S1="$WORK/s1"
mk_repo "$S1"
printf '.quetrex/\n' > "$S1/.gitignore"
gitq "$S1" add .gitignore .claude/settings.json
gitq "$S1" commit -qm arming-partial

# Guard the fixture itself: if this ever stops being half-armed, every
# assertion below is vacuously "passing" against the wrong input.
S1_TRACKED="$(git -C "$S1" ls-files)"
if printf '%s\n' "$S1_TRACKED" | grep -q '^\.quetrex/'; then
  fail "STATE 1 fixture: expected NOTHING under .quetrex/ to be tracked, got [$S1_TRACKED]"
else
  pass "STATE 1 fixture: arming files are on disk and .quetrex/ is untracked (what the audit reproduced)"
fi

OUT_S1="$(run_check8 "$S1" bash 2>&1)"
if printf '%s' "$OUT_S1" | grep -q '^✗'; then
  pass "STATE 1: an untracked, gitignored .quetrex/ is reported ✗ (no longer all-green)"
else
  fail "STATE 1: doctor still reports no problem for a repo whose arming files are on disk but untracked — a cloud routine cloning this repo gets no binding and no verify chain (out: [$OUT_S1])"
fi
if printf '%s' "$OUT_S1" | grep -q '\.quetrex/project\.json'; then
  pass "STATE 1: the untracked binding is named in the message"
else
  fail "STATE 1: expected .quetrex/project.json to be named as missing from a clone (out: [$OUT_S1])"
fi
# Scoped to the per-file REASON, never the generic Fix line (which mentions
# .gitignore for everyone): a mutation that read the working tree instead of
# the index still printed a ✗ naming the file, just with the WRONG cause, and
# a whole-output grep happily passed on it.
if printf '%s' "$OUT_S1" | grep -q "\.quetrex/project\.json (on disk but UNTRACKED — a .gitignore rule excludes it)"; then
  pass "STATE 1: the binding's reason is 'untracked, a .gitignore rule excludes it', so the fix is actionable"
else
  fail "STATE 1: expected the binding to be reported as untracked BECAUSE a .gitignore rule excludes it (out: [$OUT_S1])"
fi

if [ "$ZSH_AVAILABLE" -eq 1 ]; then
  OUT_S1_ZSH="$(run_check8 "$S1" zsh 2>&1)"
  # `-n` guard: two EMPTY outputs are byte-identical too, so without it this
  # assertion passes on a check that prints nothing at all in either shell.
  if [ -n "$OUT_S1" ] && [ "$OUT_S1" = "$OUT_S1_ZSH" ]; then
    pass "PARITY: bash and zsh produce byte-identical output for the STATE 1 fixture"
  else
    fail "PARITY: bash and zsh diverged on the same fixture (bash: [$OUT_S1], zsh: [$OUT_S1_ZSH])"
  fi
else
  echo "SKIP-note: zsh not installed — the bash/zsh parity assertion did not run"
fi

# =============================================================================
# STATE 2 — the same repo, now actually committed -> green.
# =============================================================================
S2="$WORK/s2"
mk_repo "$S2"
gitq "$S2" add .claude/settings.json .quetrex/project.json .quetrex/verify.json
gitq "$S2" commit -qm armed

OUT_S2="$(run_check8 "$S2" bash 2>&1)"
if printf '%s' "$OUT_S2" | grep -q '^✓'; then
  pass "STATE 2: a fully committed arming set is reported ✓"
else
  fail "STATE 2: a correctly armed, fully committed repo must be green — this check must not fire on the repos it is meant to bless (out: [$OUT_S2])"
fi
if printf '%s' "$OUT_S2" | grep -q '^✗'; then
  fail "STATE 2: a ✗ line appeared for a fully committed repo (out: [$OUT_S2])"
else
  pass "STATE 2: no ✗ line for a fully committed repo"
fi

# =============================================================================
# STATE 3 — untracked but NOT ignored: a different cause, a different fix.
# =============================================================================
S3="$WORK/s3"
mk_repo "$S3"
gitq "$S3" add .claude/settings.json
gitq "$S3" commit -qm settings-only

OUT_S3="$(run_check8 "$S3" bash 2>&1)"
if printf '%s' "$OUT_S3" | grep -q '^✗.*\.quetrex/project\.json'; then
  pass "STATE 3: a merely-never-added binding is reported ✗"
else
  fail "STATE 3: expected ✗ naming .quetrex/project.json when it is untracked with no ignore rule (out: [$OUT_S3])"
fi
# Scoped to the per-file REASON, not the whole block: the generic Fix line
# legitimately mentions .gitignore as one possible cause to look at.
if printf '%s' "$OUT_S3" | grep -q "a .gitignore rule excludes it"; then
  fail "STATE 3: blamed .gitignore for a file that is simply un-added — that sends the operator to edit an ignore rule that does not exist (out: [$OUT_S3])"
elif printf '%s' "$OUT_S3" | grep -q "never git add"; then
  pass "STATE 3: the reason given is 'never git add'ed', not a non-existent ignore rule"
else
  fail "STATE 3: expected the never-added reason for an un-added, un-ignored file (out: [$OUT_S3])"
fi

# =============================================================================
# STATE 4 — staged but never committed. A clone materialises HEAD.
# =============================================================================
S4="$WORK/s4"
mk_repo "$S4"
gitq "$S4" add .claude/settings.json .quetrex/project.json .quetrex/verify.json
# deliberately NOT committed

S4_LS="$(git -C "$S4" ls-files)"
if printf '%s\n' "$S4_LS" | grep -q '^\.quetrex/project\.json$'; then
  pass "STATE 4 fixture: the binding IS tracked (in the index), so only a HEAD test can catch it"
else
  fail "STATE 4 fixture: expected .quetrex/project.json to be tracked in the index (got [$S4_LS])"
fi

OUT_S4="$(run_check8 "$S4" bash 2>&1)"
if printf '%s' "$OUT_S4" | grep -q '^✗'; then
  pass "STATE 4: staged-but-never-committed arming is reported ✗ (tracked alone is not armed)"
else
  fail "STATE 4: a git add with no commit passed as armed — a clone materialises HEAD, so none of these files exist for anyone else (out: [$OUT_S4])"
fi
# Isolate the index-vs-HEAD distinction on the BINDING itself. Without this,
# the ✗ above is also satisfied by some other artifact failing for an
# unrelated reason (a mutation that neutered the HEAD test entirely still
# produced a ✗ here, from the settings.json content path), so the assertion
# would silently stop covering the thing it names.
if printf '%s' "$OUT_S4" | grep -q '\.quetrex/project\.json (staged'; then
  pass "STATE 4: the binding is specifically reported as staged-but-never-committed"
else
  fail "STATE 4: expected .quetrex/project.json to be called out as staged-but-never-committed — tracked-in-the-index is being read as committed (out: [$OUT_S4])"
fi

# =============================================================================
# STATE 5 — settings.json committed for ages, arming edit only on disk.
# =============================================================================
S5="$WORK/s5"
mk_repo "$S5"
printf '%s\n' "$UNARMED_SETTINGS" > "$S5/.claude/settings.json"
gitq "$S5" add .claude/settings.json .quetrex/project.json .quetrex/verify.json
gitq "$S5" commit -qm "settings committed, but unarmed"
# now arm it ON DISK ONLY — exactly what an uncommitted /quetrex:init leaves
printf '%s\n' "$ARMED_SETTINGS" > "$S5/.claude/settings.json"

OUT_S5="$(run_check8 "$S5" bash 2>&1)"
if printf '%s' "$OUT_S5" | grep -q '^✗.*settings\.json'; then
  pass "STATE 5: an arming edit that exists only in the working copy of a tracked settings.json is reported ✗"
else
  fail "STATE 5: the COMMITTED settings.json does not enable quetrex/quetrex-factory, yet the check read the file on disk and passed it (out: [$OUT_S5])"
fi

# =============================================================================
# STATE 6 — not a git repository at all.
# =============================================================================
S6="$WORK/s6"
mkdir -p "$S6/.claude" "$S6/.quetrex"
printf '%s\n' "$ARMED_SETTINGS" > "$S6/.claude/settings.json"
printf '%s\n' '{ "projectCode": "QUE" }' > "$S6/.quetrex/project.json"

OUT_S6="$(run_check8 "$S6" bash 2>&1)"
if printf '%s' "$OUT_S6" | grep -q '^✗'; then
  pass "STATE 6: a non-git directory is reported ✗ (nothing to clone), not silently blessed"
else
  fail "STATE 6: expected ✗ for a directory that is not a git repository (out: [$OUT_S6])"
fi
if printf '%s' "$OUT_S6" | grep -qi 'not a git repository'; then
  pass "STATE 6: the message says the directory is not a git repository"
else
  fail "STATE 6: expected the not-a-git-repository reason (out: [$OUT_S6])"
fi

# =============================================================================
# STATE 7 — the documented Check 5 fallback: no verify.json, but a committed
# CLAUDE.md with ## Verification. Must be green.
# =============================================================================
S7="$WORK/s7"
mk_repo "$S7"
rm -f "$S7/.quetrex/verify.json"
printf '# proj\n\n## Verification\n\n```\nnpm test\n```\n' > "$S7/.claude/CLAUDE.md"
gitq "$S7" add .claude/settings.json .claude/CLAUDE.md .quetrex/project.json
gitq "$S7" commit -qm "armed via CLAUDE.md fallback"

OUT_S7="$(run_check8 "$S7" bash 2>&1)"
if printf '%s' "$OUT_S7" | grep -q '^✓'; then
  pass "STATE 7: a committed CLAUDE.md ## Verification section satisfies the chain, mirroring Check 5's either/or"
else
  fail "STATE 7: a repo armed via the documented CLAUDE.md fallback was reported unarmed — Check 8 must mirror Check 5's either/or, not demand verify.json (out: [$OUT_S7])"
fi

# =============================================================================
# STATE 8 — neither verify.json nor CLAUDE.md on disk: Check 5 owns that,
# Check 8 must not double-report it.
# =============================================================================
S8="$WORK/s8"
mk_repo "$S8"
rm -f "$S8/.quetrex/verify.json"
gitq "$S8" add .claude/settings.json .quetrex/project.json
gitq "$S8" commit -qm "armed, no verify chain anywhere"

OUT_S8="$(run_check8 "$S8" bash 2>&1)"
# Matches the COMPLAINT specifically (the note_gone text), not any mention of
# the words "verify chain" — the green summary is allowed to use them.
if printf '%s' "$OUT_S8" | grep -q 'neither a committed .quetrex/verify.json'; then
  fail "STATE 8: Check 8 re-reported the missing verify chain that Check 5 already owns — the operator gets the same failure twice with two different fixes (out: [$OUT_S8])"
else
  pass "STATE 8: no verify-chain complaint when the working tree has neither file (Check 5 owns that)"
fi
if printf '%s' "$OUT_S8" | grep -q '^✓'; then
  pass "STATE 8: committed binding + committed settings is green on the committed-ness question"
else
  fail "STATE 8: expected ✓ on the committed-ness question when binding and settings are both committed (out: [$OUT_S8])"
fi

# =============================================================================
# SOURCE — the check must interrogate git, not the working tree in disguise.
# =============================================================================
if printf '%s\n' "$CHECK8_SCRIPT" | grep -q 'git -C "\$REPO_ROOT" ls-files'; then
  pass "SOURCE: Check 8 uses git ls-files"
else
  fail "SOURCE: Check 8 does not call git ls-files — presence on disk is not tracking, and this is the exact hole the finding is about"
fi
if printf '%s\n' "$CHECK8_SCRIPT" | grep -q 'cat-file -e "HEAD:'; then
  pass "SOURCE: Check 8 tests HEAD with git cat-file -e"
else
  fail "SOURCE: Check 8 never asks HEAD anything — a clone materialises HEAD, so an index-only file would still pass"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "doctor-tracked.test.sh: all checks passed"
  exit 0
else
  echo "doctor-tracked.test.sh: FAILURES above"
  exit 1
fi
