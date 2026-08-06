#!/usr/bin/env bash
# test/cloud-prep.test.sh — behavioural test for bin/quetrex-cloud-prep.
#
# Run: bash test/cloud-prep.test.sh
#
# EVERY ASSERTION IN THIS FILE EXECUTES THE SCRIPT. There is not one grep over
# prose here, and that is the whole reason the file exists in this shape: two
# earlier rounds of this feature shipped a fully green suite over a feature that
# did not work, because the "tests" were greps over a markdown prompt and a grep
# cannot fail when the behaviour is broken. So:
#
#   - `sync` is exercised against REAL bare repositories acting as origin, and
#     every claim is checked by asking git — is the branch on the remote, is
#     this sha an ancestor of that one, does a real `git push` come back clean.
#   - `hydrate` is exercised by running it and then SOURCING the file it wrote,
#     so a value that is not actually exported cannot pass.
#   - Every placeholder value the script can emit is fed to the repo's own
#     .claude/hooks/secret-scan.sh, with a positive control proving the hook is
#     live in this environment (otherwise "nothing was denied" would be
#     indistinguishable from "the gate is not running").
#
# Style follows test/quetrex-arm.test.sh: pass/fail helpers, mktemp fixtures,
# trap cleanup, no network.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREP="$REPO_ROOT/bin/quetrex-cloud-prep"
SCAN="$REPO_ROOT/.claude/hooks/secret-scan.sh"

if [ ! -f "$PREP" ]; then
  echo "FAIL: bin/quetrex-cloud-prep not found at $PREP"
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed — quetrex-cloud-prep projects the plan with node"
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not installed — the sync half is entirely git behaviour"
  exit 0
fi

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-cloud-prep-test.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# git fixture helpers — a real bare repo as origin, plus a "container clone"
# standing in for the checkout the platform hands a cloud session.
# ---------------------------------------------------------------------------
G() { git -C "$1" "${@:2}"; }

new_origin() {                       # new_origin <name> -> echoes the seed path
  local name="$1"
  local origin="$WORK/$name.git" seed="$WORK/$name-seed"
  git init -q --bare "$origin"
  # Name the default branch without depending on `git init -b` (2.28+).
  git -C "$origin" symbolic-ref HEAD refs/heads/main
  git init -q "$seed"
  git -C "$seed" symbolic-ref HEAD refs/heads/main
  git -C "$seed" config user.name "Fixture"
  git -C "$seed" config user.email "fixture@example.test"
  printf 'seed\n' > "$seed/README.md"
  git -C "$seed" add README.md
  git -C "$seed" commit -q -m "seed"
  git -C "$seed" remote add origin "$origin"
  git -C "$seed" push -q origin main
  printf '%s' "$seed"
}

container_clone() {                  # container_clone <name> <clone-suffix>
  local name="$1" suffix="$2"
  local dest="$WORK/$name-$suffix"
  git clone -q "$WORK/$name.git" "$dest"
  git -C "$dest" config user.name "Cloud"
  git -C "$dest" config user.email "cloud@example.test"
  printf '%s' "$dest"
}

remote_heads() {                     # remote_heads <name>
  git -C "$WORK/$1.git" for-each-ref --format='%(refname)' refs/heads
}

SYNC_OUT=""; SYNC_ERR=""; SYNC_RC=0
run_sync() {                         # run_sync <repo> <base-branch> <base-sha> <unit>
  local errf="$WORK/sync.err"
  unset QX_APPROVED_BASE_SHA QX_LIVE_BASE_SHA QX_BASE_STATE \
        QX_UNIT_BRANCH QX_BRANCH_STATE QX_UNIT_HEAD_SHA
  SYNC_OUT="$("$PREP" sync "$2" "$3" "$4" --repo "$1" 2>"$errf")"
  SYNC_RC=$?
  SYNC_ERR="$(cat "$errf")"
  # Evaluating stdout is itself an assertion on the output contract: stdout is
  # eval-safe key='value' lines and nothing else. Prose on stdout would break
  # here rather than being quietly tolerated.
  eval "$SYNC_OUT"
}

# ===========================================================================
# 0. The tool itself.
# ===========================================================================
if [ -x "$PREP" ]; then
  pass "bin/quetrex-cloud-prep is executable"
else
  fail "bin/quetrex-cloud-prep must be executable (chmod +x)"
fi
if bash -n "$PREP"; then
  pass "bin/quetrex-cloud-prep passes bash -n"
else
  fail "bin/quetrex-cloud-prep has a bash syntax error"
fi

USAGE_OUT="$("$PREP" 2>&1)"; RC_USAGE=$?
if [ "$RC_USAGE" -eq 2 ]; then
  pass "no subcommand exits 2 (usage), never a silent no-op"
else
  fail "no subcommand should exit 2 (got rc=$RC_USAGE)"
fi
if printf '%s' "$USAGE_OUT" | grep -q 'usage:'; then
  pass "no subcommand prints usage"
else
  fail "no subcommand should print usage (got: $USAGE_OUT)"
fi

# ===========================================================================
# 1. sync — BASE EQUAL, and FIRST FIRE CREATES THE BRANCH.
#
#    The first fire must end with the branch ON THE REMOTE, carrying an empty
#    start commit, because "no branch on the remote minutes after firing" is
#    the only cheap signal that a run died before publishing anything — one did,
#    and it stayed invisible for 15h.
# ===========================================================================
SEED1="$(new_origin r1)"
C1="$(container_clone r1 a)"
BASE1="$(git -C "$SEED1" rev-parse main)"

run_sync "$C1" main "$BASE1" "claude/QUE-1"

if [ "$SYNC_RC" -eq 0 ]; then
  pass "sync with base EQUAL to the approved sha exits 0"
else
  fail "sync with base EQUAL should exit 0 (rc=$SYNC_RC, stderr: $SYNC_ERR)"
fi
if [ "${QX_BASE_STATE:-}" = "equal" ]; then
  pass "sync reports QX_BASE_STATE=equal when origin/base IS the approved sha"
else
  fail "QX_BASE_STATE should be 'equal' (got: ${QX_BASE_STATE:-<unset>})"
fi
if [ "${QX_LIVE_BASE_SHA:-}" = "$BASE1" ]; then
  pass "sync reports the resolved live base sha it used"
else
  fail "QX_LIVE_BASE_SHA should be $BASE1 (got: ${QX_LIVE_BASE_SHA:-<unset>})"
fi
if [ "${QX_BRANCH_STATE:-}" = "created" ]; then
  pass "first fire reports QX_BRANCH_STATE=created"
else
  fail "first fire should report created (got: ${QX_BRANCH_STATE:-<unset>})"
fi

R1_TIP="$(git -C "$WORK/r1.git" rev-parse -q --verify refs/heads/claude/QUE-1 2>/dev/null)"
if [ -n "$R1_TIP" ]; then
  pass "first fire PUBLISHES the unit branch to origin (the liveness signal)"
else
  fail "first fire must push the unit branch to origin — remote heads: $(remote_heads r1)"
fi
if [ "$R1_TIP" = "${QX_UNIT_HEAD_SHA:-}" ]; then
  pass "the sha sync reports is the sha now on the remote"
else
  fail "remote tip ($R1_TIP) must equal QX_UNIT_HEAD_SHA (${QX_UNIT_HEAD_SHA:-<unset>})"
fi
if [ "$(git -C "$C1" rev-parse "claude/QUE-1^")" = "$BASE1" ] \
   && git -C "$C1" diff --quiet "claude/QUE-1^" "claude/QUE-1"; then
  pass "the start commit is EMPTY and parented on the fetched base"
else
  fail "the start commit must be empty and parented on $BASE1"
fi

# ===========================================================================
# 2. sync — BASE MOVED AHEAD: this MUST PROCEED.
#
#    A differing sha is the NORMAL, HEALTHY case (another task merged into main
#    while this one was in flight). A string comparison or a timestamp check
#    would abort every healthy run; only ancestry separates "ahead" from
#    "stale". The container clone is deliberately left stale, so proceeding
#    from the NEW commit also proves sync fetched the base itself instead of
#    trusting the checkout it was handed.
# ===========================================================================
SEED2="$(new_origin r2)"
C2="$(container_clone r2 a)"          # cloned BEFORE the base moves
OLD2="$(git -C "$SEED2" rev-parse main)"
printf 'moved on\n' >> "$SEED2/README.md"
git -C "$SEED2" commit -qam "another task merged while this one was in flight"
git -C "$SEED2" push -q origin main
NEW2="$(git -C "$SEED2" rev-parse main)"

run_sync "$C2" main "$OLD2" "claude/QUE-2"

if [ "$SYNC_RC" -eq 0 ]; then
  pass "sync PROCEEDS when the base legitimately moved AHEAD (exit 0)"
else
  fail "a base that moved ahead must NOT fail the run (rc=$SYNC_RC, stderr: $SYNC_ERR)"
fi
if [ "${QX_BASE_STATE:-}" = "ahead" ]; then
  pass "sync distinguishes 'ahead' from 'equal' by ancestry"
else
  fail "QX_BASE_STATE should be 'ahead' (got: ${QX_BASE_STATE:-<unset>})"
fi
if [ "${QX_LIVE_BASE_SHA:-}" = "$NEW2" ]; then
  pass "sync prints the LIVE sha it actually used, not the approved one"
else
  fail "QX_LIVE_BASE_SHA should be the live base $NEW2 (got: ${QX_LIVE_BASE_SHA:-<unset>})"
fi
if git -C "$C2" merge-base --is-ancestor "$NEW2" "claude/QUE-2"; then
  pass "the unit branch is cut from the LIVE base — sync fetched it rather than trusting the stale checkout"
else
  fail "the unit branch must contain the live base $NEW2 (it was cut from the stale handed checkout)"
fi
if git -C "$WORK/r2.git" rev-parse -q --verify refs/heads/claude/QUE-2 >/dev/null; then
  pass "the ahead case still publishes the unit branch"
else
  fail "the ahead case must still publish the unit branch"
fi

# ===========================================================================
# 3. sync — APPROVED BASE IS NOT AN ANCESTOR: FAIL, and push NOTHING.
#
#    This is the measured bug: the environment served a snapshot that did not
#    contain work a human had already approved, and the run spent itself
#    opening unrelated housekeeping PRs to unblock the stale tree. A run that
#    builds on a base the approver never saw is worse than a run that does
#    nothing — so the ONLY correct outcome is transport_failure with an
#    untouched remote.
# ===========================================================================
SEED3="$(new_origin r3)"
C3="$(container_clone r3 a)"
git -C "$C3" checkout -q -b sidework
printf 'divergent\n' > "$C3/side.txt"
git -C "$C3" add side.txt
git -C "$C3" commit -q -m "a commit origin/main does not contain"
SIDE3="$(git -C "$C3" rev-parse HEAD)"
git -C "$C3" checkout -q main
HEADS3_BEFORE="$(remote_heads r3)"

run_sync "$C3" main "$SIDE3" "claude/QUE-3"

if [ "$SYNC_RC" -ne 0 ]; then
  pass "a non-ancestor base exits non-zero (rc=$SYNC_RC)"
else
  fail "a non-ancestor base MUST fail — it built on a base nobody approved"
fi
if [ "$SYNC_RC" -eq 3 ]; then
  pass "the non-ancestor exit code is 3, the distinct transport_failure code"
else
  fail "a non-ancestor base should exit 3 so a watcher can tell 'RE-FIRE THE RUN' from 'the CODE needs a human' (got rc=$SYNC_RC)"
fi
if printf '%s' "$SYNC_ERR" | grep -q 'transport_failure'; then
  pass "the non-ancestor reason is printed as transport_failure on stderr"
else
  fail "stderr must carry a transport_failure reason (got: $SYNC_ERR)"
fi
if [ "$(remote_heads r3)" = "$HEADS3_BEFORE" ]; then
  pass "a non-ancestor base pushes NOTHING — the remote is byte-identical"
else
  fail "a non-ancestor base must push nothing (heads before: $HEADS3_BEFORE / after: $(remote_heads r3))"
fi
if [ -z "$SYNC_OUT" ]; then
  pass "a failed sync emits no machine-readable stdout to mistake for success"
else
  fail "a failed sync must not print result lines (got: $SYNC_OUT)"
fi

# 3b. The same verdict when the approved base is not in the clone AT ALL — the
#     purest form of the stale-snapshot bug. merge-base would only say "not a
#     valid object name"; the tool must name the real problem.
MISSING_SHA="$(printf '0123456789abcdef%s' "0123456789abcdef01234567")"
run_sync "$C3" main "$MISSING_SHA" "claude/QUE-3b"
if [ "$SYNC_RC" -eq 3 ] && printf '%s' "$SYNC_ERR" | grep -q 'transport_failure'; then
  pass "an approved base absent from the clone is also transport_failure"
else
  fail "an absent approved base should be transport_failure (rc=$SYNC_RC, stderr: $SYNC_ERR)"
fi
if [ "$(remote_heads r3)" = "$HEADS3_BEFORE" ]; then
  pass "an absent approved base also pushes nothing"
else
  fail "an absent approved base must push nothing (heads: $(remote_heads r3))"
fi

# ===========================================================================
# 4. sync — RESUME from an already-pushed tip, then push a new slice.
#
#    A re-fire after transport death already has commits on the remote. A plain
#    re-checkout from the base loses that resume point and the very next push
#    comes back "! [rejected] (non-fast-forward)" — which is how a "resume"
#    quietly became a data-loss bug. So: resume must keep the pushed work AND
#    the following push must be clean, with no --force anywhere.
# ===========================================================================
SEED4="$(new_origin r4)"
C4A="$(container_clone r4 a)"
BASE4="$(git -C "$SEED4" rev-parse main)"

run_sync "$C4A" main "$BASE4" "claude/QUE-4"
if [ "$SYNC_RC" -eq 0 ] && [ "${QX_BRANCH_STATE:-}" = "created" ]; then
  pass "resume fixture: first fire created claude/QUE-4"
else
  fail "resume fixture setup failed (rc=$SYNC_RC, state=${QX_BRANCH_STATE:-<unset>}, stderr: $SYNC_ERR)"
fi

# The dead run's work: one committed, PUSHED slice.
printf 'slice one\n' > "$C4A/slice1.txt"
git -C "$C4A" add slice1.txt
git -C "$C4A" commit -q -m "feat: slice one (pushed before the container died)"
git -C "$C4A" push -q origin claude/QUE-4
PUSHED_TIP="$(git -C "$C4A" rev-parse HEAD)"

# The re-fire: a brand-new container, i.e. a brand-new clone.
C4B="$(container_clone r4 b)"
run_sync "$C4B" main "$BASE4" "claude/QUE-4"

if [ "$SYNC_RC" -eq 0 ]; then
  pass "a re-fire over an existing remote branch exits 0"
else
  fail "a re-fire should exit 0 (rc=$SYNC_RC, stderr: $SYNC_ERR)"
fi
if [ "${QX_BRANCH_STATE:-}" = "resumed" ]; then
  pass "a re-fire reports QX_BRANCH_STATE=resumed"
else
  fail "a re-fire should report resumed (got: ${QX_BRANCH_STATE:-<unset>})"
fi
if [ "${QX_UNIT_HEAD_SHA:-}" = "$PUSHED_TIP" ]; then
  pass "the resumed HEAD is exactly the pushed tip — no pushed work discarded"
else
  fail "resumed HEAD must be the pushed tip $PUSHED_TIP (got: ${QX_UNIT_HEAD_SHA:-<unset>})"
fi
if [ -f "$C4B/slice1.txt" ]; then
  pass "the dead run's committed file is present in the resumed work tree"
else
  fail "the resume must restore the dead run's pushed work (slice1.txt missing)"
fi

# The push that used to be rejected.
printf 'slice two\n' > "$C4B/slice2.txt"
git -C "$C4B" add slice2.txt
git -C "$C4B" commit -q -m "feat: slice two (after the resume)"
PUSH_OUT="$(git -C "$C4B" push origin claude/QUE-4 2>&1)"; PUSH_RC=$?
if [ "$PUSH_RC" -eq 0 ]; then
  pass "the next slice pushes with exit 0 after a resume"
else
  fail "the next slice must push cleanly after a resume (rc=$PUSH_RC, output: $PUSH_OUT)"
fi
if printf '%s' "$PUSH_OUT" | grep -qi 'rejected'; then
  fail "the post-resume push was REJECTED — the resume point was discarded ($PUSH_OUT)"
else
  pass "the post-resume push reports no 'rejected' — it fast-forwarded"
fi
if git -C "$WORK/r4.git" merge-base --is-ancestor "$PUSHED_TIP" refs/heads/claude/QUE-4; then
  pass "the remote branch still contains the dead run's commit (nothing force-overwritten)"
else
  fail "the remote branch must still contain $PUSHED_TIP"
fi

# ===========================================================================
# 5. sync — a PHANTOM remote-tracking ref is NOT a resume.
#
#    The environment cache is "a filesystem snapshot reused as the starting
#    point for later sessions", so the checkout can carry a
#    refs/remotes/origin/<unit> for work that is no longer on the remote.
#    Resuming from a phantom is its own kind of stale base: the run would build
#    on commits nobody can see and then fail to push. Authority is the remote,
#    via ls-remote — never the local tracking ref.
# ===========================================================================
SEED5="$(new_origin r5)"
C5="$(container_clone r5 a)"
BASE5="$(git -C "$SEED5" rev-parse main)"

git -C "$C5" checkout -q -b phantom-work
printf 'from a previous, vanished session\n' > "$C5/phantom.txt"
git -C "$C5" add phantom.txt
git -C "$C5" commit -q -m "work that never reached the remote"
PHANTOM_SHA="$(git -C "$C5" rev-parse HEAD)"
git -C "$C5" checkout -q main
git -C "$C5" branch -q -D phantom-work
# The stale snapshot: a remote-tracking ref for a branch origin does not have.
git -C "$C5" update-ref "refs/remotes/origin/claude/QUE-5" "$PHANTOM_SHA"

if ! git -C "$WORK/r5.git" rev-parse -q --verify refs/heads/claude/QUE-5 >/dev/null 2>&1; then
  pass "phantom fixture: origin genuinely has no claude/QUE-5"
else
  fail "phantom fixture is wrong — origin should not have the branch"
fi

run_sync "$C5" main "$BASE5" "claude/QUE-5"

if [ "$SYNC_RC" -eq 0 ]; then
  pass "a phantom tracking ref does not fail the run"
else
  fail "a phantom tracking ref should still allow a first fire (rc=$SYNC_RC, stderr: $SYNC_ERR)"
fi
if [ "${QX_BRANCH_STATE:-}" = "created" ]; then
  pass "a phantom tracking ref is treated as a FIRST FIRE, not a resume"
else
  fail "a phantom tracking ref must not be treated as a resume (got: ${QX_BRANCH_STATE:-<unset>})"
fi
if git -C "$C5" merge-base --is-ancestor "$PHANTOM_SHA" "claude/QUE-5" 2>/dev/null; then
  fail "the unit branch was built on the PHANTOM commit $PHANTOM_SHA"
else
  pass "the unit branch does NOT contain the phantom commit"
fi
if git -C "$C5" rev-parse -q --verify "refs/remotes/origin/claude/QUE-5" >/dev/null 2>&1; then
  # After the push the tracking ref may legitimately exist again — but it must
  # now point at the REAL remote tip, never at the phantom.
  TRACK5="$(git -C "$C5" rev-parse "refs/remotes/origin/claude/QUE-5")"
  if [ "$TRACK5" != "$PHANTOM_SHA" ]; then
    pass "the phantom tracking ref no longer resolves to the vanished commit"
  else
    fail "refs/remotes/origin/claude/QUE-5 still points at the phantom $PHANTOM_SHA"
  fi
else
  pass "the phantom tracking ref was deleted outright"
fi
if [ "$(git -C "$WORK/r5.git" rev-parse -q --verify refs/heads/claude/QUE-5)" = "${QX_UNIT_HEAD_SHA:-}" ]; then
  pass "the first fire after a phantom publishes the real branch to origin"
else
  fail "origin should carry the newly created claude/QUE-5 at ${QX_UNIT_HEAD_SHA:-<unset>}"
fi

# ===========================================================================
# 6. hydrate — the shipped OBJECT schema.
#
#    Contract A: required_env is an array of OBJECTS and `name` is the only key
#    a consumer reads. The measured defect: `.join()` over these objects yields
#    the single string "[object Object]", so the loop iterated "[object" and
#    "Object]", exported NOTHING, and exited 0 — inert feature, green suite.
#    Every value below is checked by SOURCING the file the tool wrote.
#
#    Fixture names are deliberately prefixed QXT_ — names no repo would set and
#    that appear nowhere in the script. If the classifier worked by matching a
#    baked-in name list, none of these would get a sensible value.
# ===========================================================================
PLAN_A="$WORK/plan-a.json"
cat > "$PLAN_A" <<'JSON'
{
  "task": "QUE-9",
  "base_sha": "deadbeef",
  "ownership": { "src/x.ts": "dev-a" },
  "required_env": [
    { "name": "QXT_DATABASE_URL",   "read_at": "build",   "placeholderable": true, "why": "db client parses it at import time" },
    { "name": "QXT_REDIS_URL",      "read_at": "runtime", "placeholderable": true, "why": "cache client parses it at import time" },
    { "name": "QXT_MONGODB_URI",    "read_at": "runtime", "placeholderable": true, "why": "document store client parses it" },
    { "name": "QXT_AMQP_URL",       "read_at": "runtime", "placeholderable": true, "why": "broker client parses it" },
    { "name": "QXT_MYSQL_URL",      "read_at": "runtime", "placeholderable": true, "why": "second store client parses it" },
    { "name": "QXT_SMTP_URL",       "read_at": "runtime", "placeholderable": true, "why": "mail transport parses it" },
    { "name": "QXT_PUBLIC_APP_URL", "read_at": "build",   "placeholderable": true, "why": "absolute links are built from it" },
    { "name": "QXT_DB_HOST",        "read_at": "runtime", "placeholderable": true, "why": "driver expects a bare host" },
    { "name": "QXT_DB_PORT",        "read_at": "runtime", "placeholderable": true, "why": "driver parses it as an integer" },
    { "name": "QXT_SESSION_SECRET", "read_at": "runtime", "placeholderable": true, "why": "signing key, any value parses" },
    "QXT_BARE_STRING_ENTRY",
    { "read_at": "build", "why": "an entry with no name at all" },
    { "name": "QXT-BAD-NAME" },
    { "name": 123 },
    null
  ]
}
JSON

HREPO="$WORK/hydrate-repo"
mkdir -p "$HREPO"
ENVF="$HREPO/env-a.sh"

unset QX_ENV_FILE QX_ENV_PROVENANCE QX_ENV_PLACEHOLDERED QX_ENV_PRESET
HOUT="$("$PREP" hydrate "$PLAN_A" --env-file "$ENVF" --repo "$HREPO" 2>"$WORK/h.err")"
HRC=$?
HERR="$(cat "$WORK/h.err")"
eval "$HOUT"

if [ "$HRC" -eq 0 ]; then
  pass "hydrate on the shipped object schema exits 0"
else
  fail "hydrate should exit 0 (rc=$HRC, stderr: $HERR)"
fi
if [ "${QX_ENV_FILE:-}" = "$ENVF" ] && [ -f "$ENVF" ]; then
  pass "hydrate prints the env file path and the file exists"
else
  fail "hydrate must print the env file path it wrote (got: ${QX_ENV_FILE:-<unset>})"
fi
if bash -n "$ENVF"; then
  pass "the env file is syntactically sourceable bash"
else
  fail "the env file must be valid bash"
fi

# The strongest available check: SOURCE it and read the variable back.
envget() {                            # envget <env-file> <NAME>
  ( set +u; . "$1" >/dev/null 2>&1; n="$2"; printf '%s' "${!n:-}" )
}

check_val() {                         # check_val <NAME> <expected>
  local got
  got="$(envget "$ENVF" "$1")"
  if [ "$got" = "$2" ]; then
    pass "sourcing the env file exports $1=$2"
  else
    fail "$1 should be '$2' after sourcing (got: '$got')"
  fi
}

check_val QXT_DATABASE_URL   'postgres://localhost:5432/quetrex_placeholder_db'
check_val QXT_REDIS_URL      'redis://localhost:6379'
check_val QXT_MONGODB_URI    'mongodb://localhost:27017/quetrex_placeholder_db'
check_val QXT_AMQP_URL       'amqp://localhost:5672'
check_val QXT_MYSQL_URL      'mysql://localhost:3306/quetrex_placeholder_db'
check_val QXT_SMTP_URL       'smtp://localhost:1025'
check_val QXT_PUBLIC_APP_URL 'http://localhost:3000'
check_val QXT_DB_HOST        'localhost'
check_val QXT_DB_PORT        '3000'
check_val QXT_SESSION_SECRET 'placeholder'

# SCHEME AWARENESS, stated as its own claim: a blanket *_URL -> http:// map
# would re-red exactly the build this tool exists to green, because these
# clients throw on parse before they ever connect.
for pair in "QXT_REDIS_URL:redis" "QXT_MONGODB_URI:mongodb" "QXT_AMQP_URL:amqp" "QXT_MYSQL_URL:mysql"; do
  vn="${pair%%:*}"; want="${pair#*:}"
  got="$(envget "$ENVF" "$vn")"
  case "$got" in
    "$want://"*) pass "$vn keeps its own scheme ($want://), not http://" ;;
    *)           fail "$vn must not receive a $want-incompatible value (got: '$got')" ;;
  esac
  case "$got" in
    http://*|https://*) fail "$vn was handed an http:// URI — the client throws on parse" ;;
    *)                  pass "$vn is not an http:// URI" ;;
  esac
done

# Malformed entries are DROPPED, not crashed on, and never emitted as a shell
# fragment. Sourcing the file above already proved nothing broke; assert the
# junk is genuinely absent from the artifact too.
EXPORT_COUNT="$(grep -c '^export ' "$ENVF")"
if [ "$EXPORT_COUNT" -eq 10 ]; then
  pass "exactly the 10 well-formed names are exported; 5 malformed entries dropped"
else
  fail "expected 10 export lines, got $EXPORT_COUNT ($(grep '^export ' "$ENVF" | tr '\n' ' '))"
fi
for junk in QXT_BARE_STRING_ENTRY 'QXT-BAD-NAME' 123; do
  if grep -q -- "$junk" "$ENVF"; then
    fail "malformed required_env entry '$junk' reached the env file"
  else
    pass "malformed required_env entry '$junk' was dropped"
  fi
done

# ---------------------------------------------------------------------------
# 6b. Contract B — the provenance artifact: exactly four keys, NAMES ONLY.
# ---------------------------------------------------------------------------
PROV="$HREPO/.quetrex/env-provenance.json"
if [ "${QX_ENV_PROVENANCE:-}" = "$PROV" ] && [ -f "$PROV" ]; then
  pass "hydrate writes .quetrex/env-provenance.json and reports its path"
else
  fail "provenance should be at $PROV (got: ${QX_ENV_PROVENANCE:-<unset>})"
fi

prov_probe() {                        # prov_probe <expr> -> prints result
  node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write(String(eval(process.argv[2])));
  ' "$PROV" "$1"
}

if [ "$(prov_probe 'Object.keys(o).sort().join(",")')" = "env_placeholdered,hydrated_at,note,required_env" ]; then
  pass "provenance carries exactly the four Contract B keys"
else
  fail "provenance keys must be the four Contract B keys (got: $(prov_probe 'Object.keys(o).sort().join(",")'))"
fi
if [ "$(prov_probe 'o.env_placeholdered.join(" ")')" = "QXT_DATABASE_URL QXT_REDIS_URL QXT_MONGODB_URI QXT_AMQP_URL QXT_MYSQL_URL QXT_SMTP_URL QXT_PUBLIC_APP_URL QXT_DB_HOST QXT_DB_PORT QXT_SESSION_SECRET" ]; then
  pass "env_placeholdered lists exactly the hydrated NAMES (the one field consumers read)"
else
  fail "env_placeholdered is wrong (got: $(prov_probe 'JSON.stringify(o.env_placeholdered)'))"
fi
if [ "$(prov_probe 'o.env_placeholdered.every(n => typeof n === "string")')" = "true" ]; then
  pass "env_placeholdered holds strings, not objects"
else
  fail "env_placeholdered must hold name strings"
fi
if [ "$(prov_probe 'o.required_env.length')" = "15" ]; then
  pass "required_env mirrors the plan array verbatim (all 15 entries, objects included)"
else
  fail "required_env should mirror the plan verbatim (got length $(prov_probe 'o.required_env.length'))"
fi
# NAMES ONLY. A value here would turn the anti-green-washing record into a
# credential sink, and secret-scan.sh would refuse to write it at all.
if grep -q '://' "$PROV"; then
  fail "provenance contains a URI — it must record NAMES ONLY, never values"
else
  pass "provenance contains no URI value"
fi
if grep -q 'localhost' "$PROV"; then
  fail "provenance contains a placeholder host — NAMES ONLY"
else
  pass "provenance contains no placeholder host value"
fi
if [ "$(prov_probe 'JSON.stringify(o).includes("placeholder_db")')" = "false" ]; then
  pass "no placeholder database name leaked into the provenance artifact"
else
  fail "a placeholder value leaked into the provenance artifact"
fi

# ---------------------------------------------------------------------------
# 6c. An already-set name is NEVER overwritten.
#
#     A real value beats a placeholder every time; clobbering it would silently
#     downgrade the run from "proven against a real service" to "proven against
#     nothing" while the provenance artifact claimed the opposite.
# ---------------------------------------------------------------------------
REAL_DB='postgres://localhost:5432/qxt_real_db_do_not_touch'
ENVF2="$HREPO/env-b.sh"
HREPO2="$WORK/hydrate-repo-2"
mkdir -p "$HREPO2"
unset QX_ENV_FILE QX_ENV_PROVENANCE QX_ENV_PLACEHOLDERED QX_ENV_PRESET
HOUT2="$(QXT_DATABASE_URL="$REAL_DB" "$PREP" hydrate "$PLAN_A" --env-file "$ENVF2" --repo "$HREPO2" 2>/dev/null)"
HRC2=$?
eval "$HOUT2"

if [ "$HRC2" -eq 0 ]; then
  pass "hydrate with one name already set exits 0"
else
  fail "hydrate with a preset name should exit 0 (rc=$HRC2)"
fi
if grep -q 'QXT_DATABASE_URL' "$ENVF2"; then
  fail "an already-set name must NOT appear in the env file (it would clobber the real value)"
else
  pass "an already-set name is omitted from the env file entirely"
fi
if printf '%s' "${QX_ENV_PRESET:-}" | grep -q 'QXT_DATABASE_URL'; then
  pass "the already-set name is reported as preset, not as placeholdered"
else
  fail "QX_ENV_PRESET should name the already-set variable (got: ${QX_ENV_PRESET:-<unset>})"
fi
if printf '%s' "${QX_ENV_PLACEHOLDERED:-}" | grep -q 'QXT_DATABASE_URL'; then
  fail "an already-set name must not be claimed as placeholdered — that inverts the evidence"
else
  pass "the already-set name is excluded from QX_ENV_PLACEHOLDERED"
fi
if [ "$(node -e '
      const fs=require("fs");
      const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.stdout.write(String(o.env_placeholdered.includes("QXT_DATABASE_URL")));
    ' "$HREPO2/.quetrex/env-provenance.json")" = "false" ]; then
  pass "provenance excludes the already-set name from env_placeholdered"
else
  fail "provenance must not claim an already-set name was placeholdered"
fi
# And sourcing must leave a live value alone.
SURVIVED="$( export QXT_DATABASE_URL="$REAL_DB"; set +u; . "$ENVF2" >/dev/null 2>&1; printf '%s' "$QXT_DATABASE_URL" )"
if [ "$SURVIVED" = "$REAL_DB" ]; then
  pass "sourcing the env file leaves an already-set real value untouched"
else
  fail "sourcing must not overwrite a live value (got: '$SURVIVED')"
fi
# The other nine names are still hydrated — a preset name costs only itself.
if [ "$(grep -c '^export ' "$ENVF2")" -eq 9 ]; then
  pass "the remaining nine names are still hydrated"
else
  fail "expected 9 export lines with one name preset (got $(grep -c '^export ' "$ENVF2"))"
fi

# ---------------------------------------------------------------------------
# 6d. NO NAME IS HARDCODED. A plan in the WRONG shape (a {NAME: value} map, one
#     of the shapes Contract A explicitly rules out) must hydrate NOTHING and
#     still exit 0 with an empty, positive `[]` claim. If any name were baked
#     into the script, something would be exported here.
# ---------------------------------------------------------------------------
PLAN_B="$WORK/plan-b.json"
cat > "$PLAN_B" <<'JSON'
{ "task": "QUE-10", "required_env": { "QXT_MAP_SHAPE_URL": "should-not-be-read" } }
JSON
ENVF3="$WORK/env-c.sh"
HREPO3="$WORK/hydrate-repo-3"
mkdir -p "$HREPO3"
HOUT3="$("$PREP" hydrate "$PLAN_B" --env-file "$ENVF3" --repo "$HREPO3" 2>/dev/null)"; HRC3=$?

if [ "$HRC3" -eq 0 ]; then
  pass "a wrong-shape required_env exits 0 rather than crashing"
else
  fail "a wrong-shape required_env should not crash (rc=$HRC3)"
fi
if [ "$(grep -c '^export ' "$ENVF3")" -eq 0 ]; then
  pass "a wrong-shape required_env exports NOTHING — no name is baked into the script"
else
  fail "nothing may be exported from a wrong-shape plan (got: $(grep '^export ' "$ENVF3"))"
fi
if [ "$(node -e '
      const fs=require("fs");
      const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.stdout.write(JSON.stringify(o.env_placeholdered));
    ' "$HREPO3/.quetrex/env-provenance.json")" = "[]" ]; then
  pass "provenance records the empty [] claim explicitly"
else
  fail "provenance should record env_placeholdered as []"
fi
# The LEAK the crash above was hiding: "required_env mirrors the plan verbatim"
# is only safe when the plan's value IS an array. Mirror a {NAME: value} map and
# the artifact carries VALUES — the credential sink Contract B forbids — and a jq
# consumer reading `.required_env[]?` over an object iterates its VALUES, handing
# the leaked string to the next stage as if it were a name.
if grep -q 'should-not-be-read' "$HREPO3/.quetrex/env-provenance.json"; then
  fail "a VALUE from a wrong-shape required_env leaked into the provenance artifact"
else
  pass "a wrong-shape required_env mirrors as [] — no value reaches the artifact"
fi
if [ "$(node -e '
      const fs=require("fs");
      const o=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
      process.stdout.write(String(Array.isArray(o.required_env)));
    ' "$HREPO3/.quetrex/env-provenance.json")" = "true" ]; then
  pass "provenance required_env is an array even when the plan's was not"
else
  fail "provenance required_env must always be an array — a consumer iterates it"
fi
# A plan whose whole body is not an object at all (JSON.parse("null") succeeds and
# a bare property read on it throws) must also be survivable, not fatal.
PLAN_C="$WORK/plan-c.json"
printf 'null' > "$PLAN_C"
HREPO5="$WORK/hydrate-repo-5"
mkdir -p "$HREPO5"
"$PREP" hydrate "$PLAN_C" --env-file "$WORK/env-d.sh" --repo "$HREPO5" >/dev/null 2>&1
HRC5=$?
if [ "$HRC5" -eq 0 ] && [ -f "$HREPO5/.quetrex/env-provenance.json" ]; then
  pass "a plan body of literal null hydrates nothing and still exits 0"
else
  fail "a null plan body must not crash hydrate (rc=$HRC5)"
fi

# ---------------------------------------------------------------------------
# 6e. Failure paths: a clear reason, non-zero, and NO temp file left behind —
#     on success or on throw.
# ---------------------------------------------------------------------------
BADPLAN="$WORK/plan-bad.json"
printf '{ this is not json' > "$BADPLAN"
HREPO4="$WORK/hydrate-repo-4"
mkdir -p "$HREPO4"
BAD_ERR="$("$PREP" hydrate "$BADPLAN" --env-file "$HREPO4/env.sh" --repo "$HREPO4" 2>&1 >/dev/null)"
BAD_RC=$?
if [ "$BAD_RC" -ne 0 ]; then
  pass "an unparseable plan exits non-zero (rc=$BAD_RC)"
else
  fail "an unparseable plan must fail, not hydrate nothing silently"
fi
if printf '%s' "$BAD_ERR" | grep -qi 'json'; then
  pass "the unparseable-plan failure names the reason"
else
  fail "the failure should say the plan does not parse (got: $BAD_ERR)"
fi
MISSING_ERR="$("$PREP" hydrate "$WORK/no-such-plan.json" --repo "$HREPO4" 2>&1 >/dev/null)"
MISSING_RC=$?
if [ "$MISSING_RC" -ne 0 ] && printf '%s' "$MISSING_ERR" | grep -qi 'not found'; then
  pass "a missing plan exits non-zero with a clear reason"
else
  fail "a missing plan should fail clearly (rc=$MISSING_RC, err: $MISSING_ERR)"
fi

# Search the WHOLE fixture tree, not a hand-listed set of repos: `hydrate
# --env-file` creates its temp next to the env file, which is not always inside a
# repo directory, and a hand-listed set silently stops covering the paths added
# after it was written.
LEFTOVER="$(find "$WORK" -name '.qxcp.*' 2>/dev/null | tr '\n' ' ')"
if [ -z "$LEFTOVER" ]; then
  pass "no temp file is left behind by hydrate, on success or on throw"
else
  fail "temp files left behind: $LEFTOVER"
fi

# ===========================================================================
# 7. Every placeholder value the script can emit survives THIS repo's own
#    secret gate, unredacted.
#
#    Why this is a real risk and not paranoia: secret-scan.sh:151 matches a
#    db/amqp scheme followed by //user:password@. On Write/Edit such a value is
#    DENIED; on Bash it is silently rewritten to __QUETREX_REDACTED_SECRET__ —
#    so the build would run against a mangled value and go red for a reason
#    nobody could diagnose. The values above are credential-less by
#    construction; this proves it by running the hook.
#
#    The positive controls matter as much as the negatives: without them,
#    "nothing was denied" is indistinguishable from "the gate never ran".
# ===========================================================================
if [ ! -f "$SCAN" ]; then
  fail "secret-scan.sh not found at $SCAN — cannot prove the placeholders survive the gate"
else

scan_write() {                        # scan_write <content> -> SCAN_OUT / SCAN_RC
  local payload
  payload="$(node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "Write",
      tool_input: { file_path: "/tmp/qxcp-probe.sh", content: process.argv[1] }
    }));
  ' "$1")"
  SCAN_OUT="$(printf '%s' "$payload" | bash "$SCAN" 2>&1)"
  SCAN_RC=$?
}

# --- positive control 1: an unambiguous provider key, assembled from fragments
#     so this test FILE does not itself carry a matchable literal (the hook
#     blocks the Write that creates such a file — it blocked a spec document
#     earlier today).
CTRL_KEY="AKIA"
CTRL_KEY="${CTRL_KEY}ABCDEFGHIJKLMNOP"
scan_write "export QXT_PROBE_CLOUD_ID='$CTRL_KEY'"
if printf '%s' "$SCAN_OUT" | grep -q '"permissionDecision":"deny"'; then
  pass "positive control: secret-scan.sh IS live here and denies a provider key"
else
  fail "positive control failed — the gate is not running, so the negatives below prove nothing (rc=$SCAN_RC, out: $SCAN_OUT)"
fi

# --- positive control 2: the exact shape the placeholders must avoid — a
#     connection URI WITH a credential segment. Assembled in three steps so no
#     contiguous literal exists in this file.
CTRL_URI="postgres://qxuser"
CTRL_URI="$CTRL_URI:qxpass"
CTRL_URI="$CTRL_URI@localhost:5432/qxdb"
scan_write "export QXT_PROBE_STORE_URL='$CTRL_URI'"
if printf '%s' "$SCAN_OUT" | grep -q '"permissionDecision":"deny"'; then
  pass "positive control: a credential-bearing connection URI IS denied by the gate"
else
  fail "the gate should deny a user:pass@ connection URI (out: $SCAN_OUT)"
fi

# --- the negatives: every line the script actually emitted, then the whole file.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  scan_write "$line"
  vname="${line#export }"; vname="${vname%%=*}"
  if [ "$SCAN_RC" -ne 0 ]; then
    fail "secret-scan errored on the placeholder line for $vname (rc=$SCAN_RC, out: $SCAN_OUT)"
  elif printf '%s' "$SCAN_OUT" | grep -q '"permissionDecision":"deny"'; then
    fail "the placeholder for $vname is DENIED by secret-scan: $SCAN_OUT"
  elif printf '%s' "$SCAN_OUT" | grep -q 'updatedInput\|REDACTED'; then
    fail "the placeholder for $vname would be silently REDACTED — the build would run on a mangled value: $SCAN_OUT"
  else
    pass "the placeholder for $vname passes secret-scan unredacted"
  fi
done < <(grep '^export ' "$ENVF")

scan_write "$(cat "$ENVF")"
if [ "$SCAN_RC" -eq 0 ] && ! printf '%s' "$SCAN_OUT" | grep -q '"permissionDecision":"deny"\|updatedInput'; then
  pass "the whole hydrated env file passes secret-scan as a single Write"
else
  fail "the hydrated env file must be writable past the gate (rc=$SCAN_RC, out: $SCAN_OUT)"
fi

scan_write "$(cat "$PROV")"
if [ "$SCAN_RC" -eq 0 ] && ! printf '%s' "$SCAN_OUT" | grep -q '"permissionDecision":"deny"\|updatedInput'; then
  pass "the provenance artifact passes secret-scan (it records names, never values)"
else
  fail "the provenance artifact must be writable past the gate (rc=$SCAN_RC, out: $SCAN_OUT)"
fi

fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "cloud-prep.test.sh: all checks passed"
  exit 0
else
  echo "cloud-prep.test.sh: FAILURES above"
  exit 1
fi
