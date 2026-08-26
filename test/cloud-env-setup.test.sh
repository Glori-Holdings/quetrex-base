#!/usr/bin/env bash
# test/cloud-env-setup.test.sh — proves scripts/cloud-env-setup.sh actually
# configures a cloud container, by RUNNING it against a sandbox HOME.
#
# WHY. What the cloud environment does at boot used to live only in a web
# textarea: untracked, untested, and hand-edited. A stale copy of it pinned a
# cloud run to an old engine. The script is now in this repo, so it gets what
# every other executable path here gets — execution against a real fixture,
# not a reading of what it claims to do.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/cloud-env-setup.sh"
PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq is required to inspect the results"; echo "cloud-env-setup.test.sh: SKIP (no jq)"; exit 0; }
[ -f "$SCRIPT" ] || { notok "scripts/cloud-env-setup.sh is missing"; echo "cloud-env-setup.test.sh: $PASS passed, $FAIL failed"; exit 1; }

# Normalize: macOS $TMPDIR ends in a slash, so a naive join yields "T//name" --
# the same DIRECTORY but a different STRING, and trust is keyed by string. That
# mismatch is exactly the class of bug this file exists to catch, so do not let
# the fixture itself introduce one.
TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cloud-env-setup.XXXXXX")" && pwd)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/workspace"; mkdir -p "$WS"; git -C "$WS" init -q

# run_case <label> <home> [force-python]  -> echoes the exit code
run_case() {
  local home="$2" out rc pathspec
  mkdir -p "$home"
  if [ "${3:-}" = "force-python" ]; then
    # A container without jq must still work. Build a PATH that deliberately
    # has NO jq on it, only the coreutils the script needs plus python3.
    local shim="$TMP/shim-$1"; mkdir -p "$shim"
    local b
    for b in bash sh git mkdir mv rm dirname python3 cat sed grep printf; do
      local p; p="$(command -v "$b" 2>/dev/null)"; [ -n "$p" ] && ln -sf "$p" "$shim/$b"
    done
    pathspec="$shim"
  else
    pathspec="$PATH"
  fi
  out="$(cd "$WS" && HOME="$home" PATH="$pathspec" bash "$SCRIPT" 2>&1)"; rc=$?
  printf '%s\n' "$out" > "$TMP/out-$1.txt"
  return $rc
}

assert_configured() {  # assert_configured <label> <home>
  local label="$1" home="$2"
  if jq -e --arg ws "$WS" '.projects[$ws].hasTrustDialogAccepted == true' "$home/.claude.json" >/dev/null 2>&1; then
    ok "$label: workspace marked trusted in ~/.claude.json"
  else
    notok "$label: workspace NOT trusted — cloud would discard the repo's settings.json (no plugins, no permissions.allow)"
  fi
  if jq -e '.env.BASH_DEFAULT_TIMEOUT_MS == "900000" and .env.BASH_MAX_TIMEOUT_MS == "1800000"' "$home/.claude/settings.json" >/dev/null 2>&1; then
    ok "$label: long Bash timeouts set at user scope"
  else
    notok "$label: timeouts NOT set — a >2-minute verify command gets killed and respun in cloud"
  fi
}

# 1. jq path.
if run_case jq "$TMP/home-jq"; then ok "jq backend: exits 0"; else notok "jq backend: exited non-zero"; fi
assert_configured "jq backend" "$TMP/home-jq"

# 2. No-jq container: the python3 fallback must do the same job.
if run_case py "$TMP/home-py" force-python; then ok "python3 fallback: exits 0"; else notok "python3 fallback: exited non-zero ($(tail -1 "$TMP/out-py.txt"))"; fi
if grep -q 'using python3' "$TMP/out-py.txt"; then
  ok "python3 fallback: actually took the python3 branch (jq was absent from PATH)"
else
  notok "python3 fallback: did NOT take the python3 branch — the fallback is untested by this run ($(head -1 "$TMP/out-py.txt"))"
fi
assert_configured "python3 fallback" "$TMP/home-py"

# 3. Idempotent: a cached environment re-runs this on every boot.
run_case jq2 "$TMP/home-jq" && ok "second run on the same HOME exits 0 (idempotent)" || notok "second run failed — not idempotent"
assert_configured "after re-run" "$TMP/home-jq"

# 4. Pre-existing user settings must survive: the script merges, never clobbers.
mkdir -p "$TMP/home-merge/.claude"
printf '{"env":{"KEEP_ME":"yes"},"model":"opus"}\n' > "$TMP/home-merge/.claude/settings.json"
printf '{"projects":{"/other/repo":{"hasTrustDialogAccepted":true}},"numStartups":7}\n' > "$TMP/home-merge/.claude.json"
run_case merge "$TMP/home-merge" >/dev/null 2>&1
if jq -e '.env.KEEP_ME == "yes" and .model == "opus"' "$TMP/home-merge/.claude/settings.json" >/dev/null 2>&1; then
  ok "existing user settings survive the merge"
else
  notok "the script CLOBBERED pre-existing user settings"
fi
if jq -e '.numStartups == 7 and .projects["/other/repo"].hasTrustDialogAccepted == true' "$TMP/home-merge/.claude.json" >/dev/null 2>&1; then
  ok "existing ~/.claude.json content survives the merge"
else
  notok "the script CLOBBERED pre-existing ~/.claude.json content"
fi
assert_configured "merge case" "$TMP/home-merge"

# 5. It must NOT install plugins — pinning an install here is what went stale.
if grep -qE '^[^#]*claude plugin (install|marketplace)' "$SCRIPT"; then
  notok "the setup script installs/pins plugins — the repo's settings.json must do that at session start"
else
  ok "no plugin install in the setup script (the repo's settings.json installs the current engine)"
fi

# 6. The one-line contract must be documented in the file itself, so the web
#    textarea can never drift back into holding real logic.
if grep -q 'bash scripts/cloud-env-setup.sh' "$SCRIPT"; then
  ok "the file documents the one-line Setup script contract"
else
  notok "the file does not state what the environment's Setup script field must contain"
fi

# 7. The cloud routine must REFUSE an environment whose setup script did not run
#    (or ran stale). A misconfigured environment that proceeds quietly is how a build
#    ends up unarmed while looking normal.
ROUTINE="$ROOT/.claude/lib/cloud-build-routine.md"
if grep -q 'BASH_DEFAULT_TIMEOUT_MS' "$ROUTINE"; then
  ok "cloud-build-routine.md checks the timeout the setup script installs"
else
  notok "cloud-build-routine.md never checks BASH_DEFAULT_TIMEOUT_MS — a stale setup script stays silent"
fi
if grep -q 'bash scripts/cloud-env-setup.sh' "$ROUTINE"; then
  ok "cloud-build-routine.md names the one-line Setup script field content in its failure path"
else
  notok "cloud-build-routine.md does not tell the operator what the Setup script field must contain"
fi

b="$(basename "${BASH_SOURCE[0]}")"
echo "$b: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "$b: all checks passed"
[ "$FAIL" -eq 0 ]
