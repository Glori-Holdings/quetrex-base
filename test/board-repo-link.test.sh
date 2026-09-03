#!/usr/bin/env bash
# test/board-repo-link.test.sh — the board shows a project's repository as
# LINKED only when BOTH githubOwner and githubRepo are set; init writes the
# pair and doctor checks the pair (bash AND zsh, fail-first).
#
# Run: bash test/board-repo-link.test.sh
#
# OPERATOR EVIDENCE. quetrex-kanban's RepoLink.tsx computes
# `hasRepo = Boolean(project.githubOwner && project.githubRepo)`. init's
# "record its repo" block PATCHed only {githubRepo:"<bare name>"}, so every
# project init linked showed "repository not linked" on the board (DEA did;
# fixed by hand with a PATCH of both fields). doctor's Check 14 only looked at
# githubRepo, so it reported ✓ on exactly that broken state.
#
#   AC1  EXECUTED (bash + zsh): init's qx_link_project_repo block with a GET
#        stub returning {} records ONE PATCH whose body has githubOwner and
#        githubRepo equal to the origin slug's halves, and prints
#        "project <CODE> linked to <owner>/<repo>".
#   AC2  EXECUTED: GET returning only githubRepo (the DEA state) -> the PATCH
#        still carries BOTH fields.
#   AC3  EXECUTED: GET returning a DIFFERENT repo -> no PATCH, exactly one
#        "linked to a different repo" line; both already matching -> no PATCH,
#        no line.
#   AC4  EXECUTED: doctor Check 14 with a project GET lacking githubOwner ->
#        ✗ naming githubOwner (not githubRepo); owner MISMATCHED -> ✗ naming
#        githubOwner with both values; both matching -> ✓ ending in
#        "board shows the repository as linked".
#   AC5  FAIL-FIRST against the literal pre-change sha 87dc34a (never `main`):
#        (a) its init block, driven by the same {} GET stub, PATCHes a body
#        WITHOUT githubOwner; (d) its doctor Check 14 prints ✓ on a project
#        that has githubRepo but no githubOwner — the exact board-unlinked state.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$ROOT/plugins/quetrex-setup/commands/init.md"
DOCTOR_MD="$ROOT/plugins/quetrex-setup/commands/doctor.md"
REAL_BIN="$ROOT/plugins/quetrex-setup/bin"
BASE_SHA="87dc34a"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() { printf '\n%s\n' "board-repo-link.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq unavailable (init builds the PATCH body with jq)"; exit 0; }
[ -f "$INIT_MD" ]   || { echo "NOT OK - init.md not found at $INIT_MD"; exit 1; }
[ -f "$DOCTOR_MD" ] || { echo "NOT OK - doctor.md not found at $DOCTOR_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/board-repo-link.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- extraction ---------------------------------------------------------------
extract_exec_block() {  # extract_exec_block <md> <name>
  awk -v name="$2" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$1"
}
extract_check14() {  # extract_check14 <doctor.md> — every bash fence under the Check 14 heading
  awk '
    index($0, "## Check 14") == 1 { insec = 1; next }
    insec && /^## / { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$1"
}
extract_exec_block "$INIT_MD" qx_link_project_repo > "$WORK/link.sh"
if [ -s "$WORK/link.sh" ] && bash -n "$WORK/link.sh" 2>/dev/null; then
  ok "init.md carries the qx_link_project_repo exec block and it parses"
else
  notok "could not extract a parseable qx_link_project_repo block from init.md"
  finish
fi
extract_check14 "$DOCTOR_MD" > "$WORK/check14.sh"
[ -s "$WORK/check14.sh" ] || { notok "could not extract doctor Check 14"; finish; }

# --- harness -----------------------------------------------------------------
# Stub quetrex-api: GET /api/projects/<code> prints the file QX_STUB_PROJECT
# (or {} when unset); GET .../secrets prints QX_STUB_VAULT; PATCH records its
# path and body to $QX_LOG/patch.<n>.json (one file per call, so a second PATCH
# is visible); json-get / kanban-url serve doctor's preamble.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/quetrex-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  json-get) exec "$QX_REAL_API" json-get "$2" "$3" ;;
  kanban-url) printf 'https://kanban.test/\n' ;;
  GET) case "$2" in
         */secrets/export) echo "export endpoint called" >&2; exit 1 ;;
         */secrets) [ -n "${QX_STUB_VAULT:-}" ] || exit 1; cat "$QX_STUB_VAULT" ;;
         /api/projects/*) if [ -n "${QX_STUB_PROJECT:-}" ]; then cat "$QX_STUB_PROJECT"; else printf '{}\n'; fi ;;
         *) exit 1 ;;
       esac ;;
  PATCH)
    n=0; while [ -e "$QX_LOG/patch.$n.json" ]; do n=$((n+1)); done
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({path:process.argv[2], body:JSON.parse(process.argv[3])}))' \
      "$QX_LOG/patch.$n.json" "$2" "$3" || exit 1
    printf '{}\n' ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*"/hooks") printf '%s\n' "${QX_STUB_HOOK_ID:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/quetrex-api" "$STUB/gh"
NODE_DIR="$(dirname "$(command -v node)")"; GIT_BIN_DIR="$(dirname "$(command -v git)")"; JQ_DIR="$(dirname "$(command -v jq)")"
RUN_PATH="$STUB:$REAL_BIN:$NODE_DIR:$GIT_BIN_DIR:$JQ_DIR:/usr/bin:/bin"
export QX_REAL_API="$REAL_BIN/quetrex-api"

write_json() { node -e 'require("fs").writeFileSync(process.argv[1], process.argv[2]+"\n")' "$1" "$2"; }

REPO="$WORK/repo"; mkdir -p "$REPO/.quetrex"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin git@github.com:Glori-Holdings/dealerq.git
write_json "$REPO/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'

run_init() {  # run_init <shell> <block-file> <log-dir> [env assignments...]
  local sh="$1" blk="$2" log="$3"; shift 3
  mkdir -p "$log"
  { printf 'REPO_ROOT=%q\nQX_PROJECT_CODE=DEA\nQX_SLUG=Glori-Holdings/dealerq\n' "$REPO"; cat "$blk"; } > "$log/run.sh"
  ( cd "$REPO" && env "$@" QX_LOG="$log" PATH="$RUN_PATH" "$sh" "$log/run.sh" 2>&1 )
}
run_doctor() {  # run_doctor <shell> <check-file> <log-dir> [env assignments...]
  local sh="$1" blk="$2" log="$3"; shift 3
  mkdir -p "$log"
  { printf 'REPO_ROOT=%q\nBIND="$REPO_ROOT/.quetrex/project.json"\n' "$REPO"; cat "$blk"; } > "$log/run.sh"
  ( cd "$REPO" && env "$@" QX_LOG="$log" PATH="$RUN_PATH" "$sh" "$log/run.sh" 2>&1 )
}
patch_count() { ls "$1"/patch.*.json 2>/dev/null | wc -l | tr -d ' '; }
patch_field() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=j.body[process.argv[2]];process.stdout.write(v==null?"":String(v))' "$1/patch.0.json" "$2"; }
patch_path()  { node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).path)' "$1/patch.0.json"; }

PROJ_EMPTY="$WORK/proj-empty.json";     write_json "$PROJ_EMPTY" '{}'
PROJ_REPO_ONLY="$WORK/proj-repo.json";  write_json "$PROJ_REPO_ONLY" '{"code":"DEA","githubOwner":null,"githubRepo":"dealerq"}'
PROJ_OTHER="$WORK/proj-other.json";     write_json "$PROJ_OTHER" '{"code":"DEA","githubOwner":"Someone-Else","githubRepo":"other-app"}'
PROJ_BOTH="$WORK/proj-both.json";       write_json "$PROJ_BOTH" '{"code":"DEA","githubOwner":"Glori-Holdings","githubRepo":"dealerq"}'
PROJ_OWNER_WRONG="$WORK/proj-ow.json";  write_json "$PROJ_OWNER_WRONG" '{"code":"DEA","githubOwner":"Someone-Else","githubRepo":"dealerq"}'
VAULT="$WORK/vault.json";               write_json "$VAULT" '[{"name":"GITHUB_WEBHOOK_SECRET","isSet":true,"last4":"beef"}]'

for SH in $SHELLS; do
  # --- AC1: nothing recorded -> one PATCH with both halves ------------------
  L="$WORK/ac1-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_EMPTY")"
  if [ "$(patch_count "$L")" = 1 ] && [ "$(patch_path "$L")" = /api/projects/DEA ] \
     && [ "$(patch_field "$L" githubOwner)" = Glori-Holdings ] && [ "$(patch_field "$L" githubRepo)" = dealerq ]; then
    ok "AC1/$SH: empty project -> ONE PATCH /api/projects/DEA with githubOwner=Glori-Holdings and githubRepo=dealerq"
  else
    notok "AC1/$SH: PATCH wrong or missing (count=$(patch_count "$L")): $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if printf '%s' "$OUT" | grep -q '^project DEA linked to Glori-Holdings/dealerq$'; then
    ok "AC1/$SH: prints 'project DEA linked to Glori-Holdings/dealerq'"
  else
    notok "AC1/$SH: no success line: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC2: only githubRepo recorded (the DEA state) -> PATCH carries both ---
  L="$WORK/ac2-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_REPO_ONLY")"
  if [ "$(patch_count "$L")" = 1 ] \
     && [ "$(patch_field "$L" githubOwner)" = Glori-Holdings ] && [ "$(patch_field "$L" githubRepo)" = dealerq ] \
     && printf '%s' "$OUT" | grep -q '^project DEA linked to Glori-Holdings/dealerq$'; then
    ok "AC2/$SH: githubRepo-only project -> the PATCH still carries BOTH fields"
  else
    notok "AC2/$SH: repo-only case wrong (count=$(patch_count "$L")): $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC3: a different repo is never overwritten; a matching one is left alone
  L="$WORK/ac3-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_OTHER")"
  if [ "$(patch_count "$L")" = 0 ] \
     && [ "$(printf '%s\n' "$OUT" | grep -c 'linked to a different repo')" -eq 1 ] \
     && printf '%s' "$OUT" | grep -q 'Someone-Else/other-app' && ! printf '%s' "$OUT" | grep -q '^project DEA linked to'; then
    ok "AC3/$SH: a project linked elsewhere -> NO PATCH, one 'linked to a different repo' line naming it"
  else
    notok "AC3/$SH: different-repo case wrong (count=$(patch_count "$L")): $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  L="$WORK/ac3b-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_BOTH")"
  if [ "$(patch_count "$L")" = 0 ] && [ -z "$OUT" ]; then
    ok "AC3/$SH: both halves already matching -> no PATCH, silent"
  else
    notok "AC3/$SH: already-linked case wrong (count=$(patch_count "$L")): $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC4: doctor Check 14 sees the owner half ------------------------------
  L="$WORK/ac4-$SH"
  OUT="$(run_doctor "$SH" "$WORK/check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_REPO_ONLY" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && printf '%s' "$OUT" | grep -q 'project DEA githubOwner' \
     && ! printf '%s' "$OUT" | grep -q 'project DEA githubRepo' && ! printf '%s' "$OUT" | grep -q 'GitHub hook on' \
     && [ "$(printf '%s\n' "$OUT" | grep -c 'Fix: re-run /quetrex-setup:init')" -eq 1 ]; then
    ok "AC4/$SH: githubRepo set but githubOwner missing -> ✗ naming githubOwner only, one init Fix line"
  else
    notok "AC4/$SH: owner-missing case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_doctor "$SH" "$WORK/check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_OWNER_WRONG" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && printf '%s' "$OUT" | grep -q 'project DEA githubOwner (is Someone-Else, origin is Glori-Holdings)' \
     && ! printf '%s' "$OUT" | grep -q 'project DEA githubRepo'; then
    ok "AC4/$SH: githubOwner mismatching the origin -> ✗ naming githubOwner with both values"
  else
    notok "AC4/$SH: owner-mismatch case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_doctor "$SH" "$WORK/check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_BOTH" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✓ Webhook registered' && printf '%s' "$OUT" | grep -q 'project linked to Glori-Holdings/dealerq — board shows the repository as linked' \
     && ! printf '%s' "$OUT" | grep -q 'export endpoint called'; then
    ok "AC4/$SH: both halves equal to the origin -> ✓ ending in 'board shows the repository as linked'"
  else
    notok "AC4/$SH: both-match case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
done

# --- AC5: fail-first against the pre-change sha ------------------------------
# A baseline that cannot be read is a FAILURE, never a skip.
if git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-setup/commands/init.md" > "$WORK/old-init.md" 2>/dev/null \
   && [ -s "$WORK/old-init.md" ] \
   && git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-setup/commands/doctor.md" > "$WORK/old-doctor.md" 2>/dev/null \
   && [ -s "$WORK/old-doctor.md" ]; then
  # (a) the old link block had no markers: the first bash fence after the
  # "record its repo" paragraph.
  awk '/The project must also record its repo/{s=1} s && /^```bash/{f=1;next} s && f && /^```/{exit} s && f' \
    "$WORK/old-init.md" > "$WORK/old-link.sh"
  L="$WORK/old-init-bash"
  OUT="$(run_init bash "$WORK/old-link.sh" "$L" QX_STUB_PROJECT="$PROJ_EMPTY")"
  if [ -s "$WORK/old-link.sh" ] && [ "$(patch_count "$L")" = 1 ] \
     && [ "$(patch_field "$L" githubRepo)" = dealerq ] && [ -z "$(patch_field "$L" githubOwner)" ]; then
    ok "AC5: FAIL-FIRST (a) — $BASE_SHA's init block PATCHes githubRepo WITHOUT githubOwner (the board-unlinked state)"
  else
    notok "AC5: $BASE_SHA's init block did not behave as the pre-change baseline (count=$(patch_count "$L")): $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  # (d) the old Check 14 could not see the missing owner: it printed ✓.
  extract_check14 "$WORK/old-doctor.md" > "$WORK/old-check14.sh"
  L="$WORK/old-doctor-bash"
  OUT="$(run_doctor bash "$WORK/old-check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_REPO_ONLY" QX_STUB_HOOK_ID=4242)"
  if [ -s "$WORK/old-check14.sh" ] && printf '%s' "$OUT" | grep -q '^✓ Webhook registered' && ! printf '%s' "$OUT" | grep -q 'githubOwner'; then
    ok "AC5: FAIL-FIRST (d) — $BASE_SHA's doctor Check 14 reports ✓ on a project with githubRepo but no githubOwner"
  else
    notok "AC5: $BASE_SHA's doctor Check 14 did not behave as the pre-change baseline: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
else
  notok "AC5: baseline blobs at $BASE_SHA are unreadable (shallow clone?) — fail-first arm cannot run"
fi

finish
