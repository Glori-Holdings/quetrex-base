#!/usr/bin/env bash
# test/board-repo-link-origin-forms.test.sh — adversarial QA probe on init's
# qx_link_project_repo block (introduced alongside board-repo-link.test.sh):
# does the origin -> owner/repo derivation hold for every real remote URL
# form, and does an origin with characters outside the API's allowed charset
# ever reach the PATCH? Run: bash test/board-repo-link-origin-forms.test.sh
#
#   AC1  EXECUTED (bash + zsh): git@github.com:Owner/repo.git,
#        https://github.com/Owner/repo.git, https://github.com/Owner/repo
#        (no .git), http://github.com/Owner/repo.git,
#        ssh://git@github.com/Owner/repo.git, git://github.com/Owner/repo.git,
#        and the trailing-slash forms https://github.com/Owner/repo/ and
#        https://github.com/Owner/repo.git/ all derive owner=Owner repo=repo
#        and PATCH exactly once.
#   AC2  EXECUTED: a non-GitHub origin (gitlab.com) never PATCHes; nor does
#        a GitHub URL with an explicit port (ssh://git@github.com:22/...) —
#        it is not a bare owner/repo slug, so the block skips cleanly.
#   AC3  EXECUTED: an origin whose owner or repo half contains a character
#        outside ^[A-Za-z0-9._-]+$ (space, semicolon, backtick, shell
#        metacharacters) never reaches the PATCH and injects nothing into the
#        working tree.
#   AC4  EXECUTED: the PATCH body is valid JSON for a dotted/hyphenated/
#        underscored owner+repo pair (proves it is built with jq, not string
#        interpolation).
#   HISTORY: the ssh://, git:// and trailing-slash forms in AC1 were a
#        documented GAP (clean skip, no link) until the derivation was
#        widened; the AC1 assertions for those forms are the fail-first for
#        that fix — they fail against the old two-pattern sed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$ROOT/plugins/quetrex-setup/commands/init.md"
REAL_BIN="$ROOT/plugins/quetrex-setup/bin"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() { printf '\n%s\n' "board-repo-link-origin-forms.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
[ -f "$INIT_MD" ] || { echo "NOT OK - init.md not found at $INIT_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-repo-link-origin-forms.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

awk '
  $0 ~ ("quetrex:exec-block qx_link_project_repo([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block qx_link_project_repo([^A-Za-z0-9_]|$)") { inb=0 }
' "$INIT_MD" > "$WORK/link.sh"
[ -s "$WORK/link.sh" ] && bash -n "$WORK/link.sh" 2>/dev/null || { notok "could not extract qx_link_project_repo"; finish; }

STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/quetrex-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  GET) case "$2" in /api/projects/*) printf '{}\n' ;; *) exit 1 ;; esac ;;
  PATCH)
    n=0; while [ -e "$QX_LOG/patch.$n.json" ]; do n=$((n+1)); done
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({body:process.argv[2]}))' \
      "$QX_LOG/patch.$n.json" "$3" || exit 1
    printf '{}\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/quetrex-api"
NODE_DIR="$(dirname "$(command -v node)")"; GIT_BIN_DIR="$(dirname "$(command -v git)")"; JQ_DIR="$(dirname "$(command -v jq)")"
RUN_PATH="$STUB:$REAL_BIN:$NODE_DIR:$GIT_BIN_DIR:$JQ_DIR:/usr/bin:/bin"

patch_count() { ls "$1"/patch.*.json 2>/dev/null | wc -l | tr -d ' '; }
patch_field() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const b=JSON.parse(j.body);process.stdout.write(b[process.argv[2]]||"")' "$1/patch.0.json" "$2"; }
patch_body_valid_json() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));JSON.parse(j.body);process.exit(0)' "$1/patch.0.json" 2>/dev/null; }

run_case() {  # run_case <shell> <origin> <suffix> -> stdout captured by caller
  local sh="$1" origin="$2" suffix="$3"
  local REPO="$WORK/repo-$suffix"; rm -rf "$REPO"; mkdir -p "$REPO/.quetrex"
  git -C "$REPO" init -q -b main
  git -C "$REPO" remote add origin "$origin"
  node -e 'require("fs").writeFileSync(process.argv[1], process.argv[2]+"\n")' "$REPO/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'
  local L="$WORK/log-$suffix"; mkdir -p "$L"
  { printf 'REPO_ROOT=%q\nQX_PROJECT_CODE=DEA\n' "$REPO"; cat "$WORK/link.sh"; } > "$L/run.sh"
  ( cd "$REPO" && env QX_LOG="$L" PATH="$RUN_PATH" "$sh" "$L/run.sh" 2>&1 )
}

for SH in $SHELLS; do
  # AC1
  for entry in \
    "git@github.com:Owner/repo.git|git-scp" \
    "https://github.com/Owner/repo.git|https-dotgit" \
    "https://github.com/Owner/repo|https-nodotgit" \
    "http://github.com/Owner/repo.git|http-dotgit" \
    "ssh://git@github.com/Owner/repo.git|ssh-scheme" \
    "git://github.com/Owner/repo.git|git-scheme" \
    "https://github.com/Owner/repo/|https-trailing-slash" \
    "https://github.com/Owner/repo.git/|https-dotgit-trailing-slash"; do
    origin="${entry%%|*}"; tag="${entry##*|}"; suf="$tag-$SH"
    run_case "$SH" "$origin" "$suf" >/dev/null
    L="$WORK/log-$suf"
    if [ "$(patch_count "$L")" = 1 ] && [ "$(patch_field "$L" githubOwner)" = Owner ] && [ "$(patch_field "$L" githubRepo)" = repo ]; then
      ok "$SH/$tag ($origin): derives owner=Owner repo=repo"
    else
      notok "$SH/$tag ($origin): wrong derivation (patches=$(patch_count "$L"))"
    fi
  done

  # AC2
  for entry in \
    "https://gitlab.com/Owner/repo.git|non-github" \
    "ssh://git@github.com:22/Owner/repo.git|github-explicit-port"; do
    origin="${entry%%|*}"; tag="${entry##*|}"; suf="$tag-$SH"
    run_case "$SH" "$origin" "$suf" >/dev/null
    L="$WORK/log-$suf"
    if [ "$(patch_count "$L")" = 0 ]; then ok "$SH/$tag ($origin): no PATCH"; else notok "$SH/$tag ($origin): unexpected PATCH"; fi
  done

  # AC3
  for entry in \
    'git@github.com:Ow ner/repo.git|space' \
    'git@github.com:Owner/re;po.git|semicolon' \
    'git@github.com:Owner/re$(touch INJECTED).git|metachar' \
    'git@github.com:Own`er/repo.git|backtick'; do
    origin="${entry%%|*}"; tag="${entry##*|}"; suf="bad-$tag-$SH"
    run_case "$SH" "$origin" "$suf" >/dev/null
    L="$WORK/log-$suf"
    if [ "$(patch_count "$L")" = 0 ] && [ ! -e "$WORK/repo-$suf/INJECTED" ]; then
      ok "$SH/bad-$tag: invalid char in origin -> no PATCH, no injection"
    else
      notok "$SH/bad-$tag: PATCH count=$(patch_count "$L") injected=$([ -e "$WORK/repo-$suf/INJECTED" ] && echo yes || echo no)"
    fi
  done

  # AC4
  suf="jsonvalid-$SH"
  run_case "$SH" "git@github.com:Weird.Owner-1_x/re.po-2_y.git" "$suf" >/dev/null
  L="$WORK/log-$suf"
  if [ "$(patch_count "$L")" = 1 ] && patch_body_valid_json "$L"; then
    ok "$SH/jsonvalid: PATCH body is valid JSON (jq-built, not interpolated)"
  else
    notok "$SH/jsonvalid: invalid or missing PATCH body"
  fi
done

finish
