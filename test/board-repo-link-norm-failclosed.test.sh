#!/usr/bin/env bash
# test/board-repo-link-norm-failclosed.test.sh — a broken `quetrex-api repo-norm`
# must fail CLOSED and LOUD, never silent (bash AND zsh, fail-first).
#
# Run: bash test/board-repo-link-norm-failclosed.test.sh
#
# OPERATOR EVIDENCE. `repo-norm` became the single normalization every repo-link
# comparison runs through — four calls in init's qx_link_project_repo block, four
# in doctor's Check 14 — and not one of them took its exit status. Every one of
# those comparisons is an EQUALITY test between two normalized values, so a
# helper that hands back "" collapses BOTH sides at once: `"" != ""` is false, no
# mismatch is found, and a board link pointing at a GENUINELY DIFFERENT
# repository reads as a match. init printed nothing at all — no warning, no
# success line, nothing — and doctor drew a ✓ saying "board shows the repository
# as linked" over a project linked to somebody else's repo. Nothing PATCHed, so
# nothing was corrupted; the operator was simply never told, which is fail-SILENT,
# not fail-closed. No committed test drove a broken repo-norm before this one.
#
#   AC-N1 EXECUTED (bash + zsh), for all four broken-helper shapes — exits
#         non-zero; prints nothing and exits 0; prints only whitespace; is
#         entirely absent from PATH (127, command not found) — with the board
#         holding a DIFFERENT repo (Someone-Else/other-app vs origin
#         Glori-Holdings/dealerq): init issues NO PATCH, prints the "could not
#         compare" line, and never claims a match or a mismatch.
#   AC-N2 EXECUTED (bash + zsh), same four shapes: doctor's Check 14 prints ✗,
#         names the half as "could not be verified", never prints ✓, and never
#         offers the `quetrex-api PATCH` one-liner — no mismatch was established,
#         so no fix for one is advertised.
#   AC-N3 EXECUTED (bash + zsh): the same four shapes over a MATCHING board link
#         are refused just as loudly. A failed normalization is not a match
#         either, so the ✓ is withheld and init still says nothing was verified.
#   AC-N4 EXECUTED (bash + zsh): the legitimate path is unaffected — with the
#         REAL repo-norm, a matching link is silent from init and ✓ from doctor,
#         and an empty project still gets its PATCH. That last one is the proof
#         that an EMPTY input normalizing to empty stays a SUCCESS: init reaches
#         the PATCH arm only by normalizing the unset stored halves without
#         treating them as helper failures.
#   AC-N5 STATIC: the qx_norm wrapper is byte-identical (modulo indentation) in
#         init.md and doctor.md — one wrapper, two callers, so a call site cannot
#         reintroduce a bare unchecked `quetrex-api repo-norm`. Also asserts
#         neither file calls the bare helper on a comparison path any more.
#   AC-N6 FAIL-FIRST against the literal pre-change sha bc64a9b (never `main`):
#         driven by the identical silent stub (prints nothing, exits 0) with the
#         board holding Someone-Else/other-app, bc64a9b's init block prints
#         ABSOLUTELY NOTHING and PATCHes nothing, and bc64a9b's doctor Check 14
#         prints "✓ Webhook registered … project linked to Someone-Else/other-app
#         — board shows the repository as linked". Both reproduce the silent mask.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$ROOT/plugins/quetrex-setup/commands/init.md"
DOCTOR_MD="$ROOT/plugins/quetrex-setup/commands/doctor.md"
REAL_BIN="$ROOT/plugins/quetrex-setup/bin"
BASE_SHA="bc64a9b"   # the pre-change sha; the silent mask must reproduce HERE

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() { printf '\n%s\n' "board-repo-link-norm-failclosed.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq unavailable (init builds the PATCH body with jq)"; exit 0; }
[ -f "$INIT_MD" ]   || { echo "NOT OK - init.md not found at $INIT_MD"; exit 1; }
[ -f "$DOCTOR_MD" ] || { echo "NOT OK - doctor.md not found at $DOCTOR_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/repo-norm-failclosed.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- extraction (identical to board-repo-link.test.sh) ------------------------
extract_exec_block() {  # extract_exec_block <md> <name>
  awk -v name="$2" '
    $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
    inb { print }
    $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
  ' "$1"
}
extract_check14() {  # extract_check14 <doctor.md> — every bash fence under Check 14
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
if [ -s "$WORK/check14.sh" ] && bash -n "$WORK/check14.sh" 2>/dev/null; then
  ok "doctor.md Check 14 extracts and parses"
else
  notok "could not extract a parseable doctor Check 14"
  finish
fi

# --- harness -----------------------------------------------------------------
# The stub forks ONLY repo-norm, and only under QX_NORM_MODE. Everything else —
# code-ok, json-get, the PATCH recorder, the project GET — behaves exactly as in
# board-repo-link.test.sh, so any difference in the output is attributable to the
# helper's failure and to nothing else.
#
#   QX_NORM_MODE=rc      exit 3, print nothing        (helper errors)
#   QX_NORM_MODE=empty   exit 0, print nothing        (the QA-reproduced case)
#   QX_NORM_MODE=ws      exit 0, print "   "          (whitespace only)
#   QX_NORM_MODE=absent  exec a binary that is not on PATH -> 127
#   QX_NORM_MODE unset   the REAL quetrex-api repo-norm
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/quetrex-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  json-get) exec "$QX_REAL_API" json-get "$2" "$3" ;;
  code-ok)  exec "$QX_REAL_API" code-ok "${2:-}" ;;
  repo-norm)
    case "${QX_NORM_MODE:-}" in
      rc)     exit 3 ;;
      empty)  exit 0 ;;
      ws)     printf '   \n'; exit 0 ;;
      absent) exec qx-no-such-repo-norm-helper "${2:-}" ;;
      *)      exec "$QX_REAL_API" repo-norm "${2:-}" ;;
    esac ;;
  kanban-url) printf 'https://kanban.test/\n' ;;
  GET) case "$2" in
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
RUN_PATH="$STUB:$NODE_DIR:$GIT_BIN_DIR:$JQ_DIR:/usr/bin:/bin"
export QX_REAL_API="$REAL_BIN/quetrex-api"

write_json() { node -e 'require("fs").writeFileSync(process.argv[1], process.argv[2]+"\n")' "$1" "$2"; }

REPO="$WORK/repo"; mkdir -p "$REPO/.quetrex"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin git@github.com:Glori-Holdings/dealerq.git
write_json "$REPO/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'

run_init() {  # run_init <shell> <block-file> <log-dir> [env assignments...]
  local sh="$1" blk="$2" log="$3"; shift 3
  rm -rf "$log"; mkdir -p "$log"
  { printf 'REPO_ROOT=%q\nQX_PROJECT_CODE=DEA\nQX_SLUG=Glori-Holdings/dealerq\n' "$REPO"; cat "$blk"; } > "$log/run.sh"
  ( cd "$REPO" && env "$@" QX_LOG="$log" PATH="$RUN_PATH" "$sh" "$log/run.sh" 2>&1 )
}
run_doctor() {  # run_doctor <shell> <check-file> <log-dir> [env assignments...]
  local sh="$1" blk="$2" log="$3"; shift 3
  rm -rf "$log"; mkdir -p "$log"
  { printf 'REPO_ROOT=%q\nBIND="$REPO_ROOT/.quetrex/project.json"\n' "$REPO"; cat "$blk"; } > "$log/run.sh"
  ( cd "$REPO" && env "$@" QX_LOG="$log" PATH="$RUN_PATH" "$sh" "$log/run.sh" 2>&1 )
}
patch_count() { ls "$1"/patch.*.json 2>/dev/null | wc -l | tr -d ' '; }
patch_field() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=j.body[process.argv[2]];process.stdout.write(v==null?"":String(v))' "$1/patch.0.json" "$2"; }
flat() { printf '%s' "$1" | tr '\n' '|'; }

PROJ_EMPTY="$WORK/proj-empty.json";    write_json "$PROJ_EMPTY" '{}'
PROJ_OTHER="$WORK/proj-other.json";    write_json "$PROJ_OTHER" '{"code":"DEA","githubOwner":"Someone-Else","githubRepo":"other-app"}'
PROJ_BOTH="$WORK/proj-both.json";      write_json "$PROJ_BOTH"  '{"code":"DEA","githubOwner":"Glori-Holdings","githubRepo":"dealerq"}'
PROJ_REPO_ONLY="$WORK/proj-repo.json"; write_json "$PROJ_REPO_ONLY" '{"code":"DEA","githubOwner":null,"githubRepo":"dealerq"}'
VAULT="$WORK/vault.json";              write_json "$VAULT" '[{"name":"GITHUB_WEBHOOK_SECRET","isSet":true,"last4":"beef"}]'

MODES="rc empty ws absent"

for SH in $SHELLS; do
  for MODE in $MODES; do
    # --- AC-N1: init, broken helper, board holds a DIFFERENT repo -------------
    L="$WORK/n1-$SH-$MODE"
    OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_OTHER" QX_NORM_MODE="$MODE")"
    if [ "$(patch_count "$L")" = 0 ]; then
      ok "AC-N1/$SH/$MODE: init issues NO PATCH when repo-norm cannot answer"
    else
      notok "AC-N1/$SH/$MODE: init PATCHed $(patch_count "$L") time(s) on an unverifiable comparison: $(flat "$OUT")"
    fi
    if printf '%s' "$OUT" | grep -q "could not compare project DEA's repo link against Glori-Holdings/dealerq"; then
      ok "AC-N1/$SH/$MODE: init PRINTS that the comparison could not be made"
    else
      notok "AC-N1/$SH/$MODE: init said nothing about the failed comparison (fail-silent): $(flat "$OUT")"
    fi
    if printf '%s' "$OUT" | grep -q 'linked to a different repo'; then
      notok "AC-N1/$SH/$MODE: init claimed a MISMATCH it never established: $(flat "$OUT")"
    else
      ok "AC-N1/$SH/$MODE: init claims no mismatch it could not demonstrate"
    fi
    if printf '%s' "$OUT" | grep -q '^project DEA linked to '; then
      notok "AC-N1/$SH/$MODE: init printed a success line without a working comparison: $(flat "$OUT")"
    else
      ok "AC-N1/$SH/$MODE: init prints no success line"
    fi

    # --- AC-N2: doctor, broken helper, board holds a DIFFERENT repo -----------
    L="$WORK/n2-$SH-$MODE"
    OUT="$(run_doctor "$SH" "$WORK/check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_OTHER" QX_STUB_HOOK_ID=4242 QX_NORM_MODE="$MODE")"
    if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && ! printf '%s' "$OUT" | grep -q '^✓ Webhook registered'; then
      ok "AC-N2/$SH/$MODE: doctor draws ✗, never a passing ✓, when repo-norm cannot answer"
    else
      notok "AC-N2/$SH/$MODE: doctor did not report a failed check: $(flat "$OUT")"
    fi
    if printf '%s' "$OUT" | grep -q 'githubOwner (could not be verified' \
       && printf '%s' "$OUT" | grep -q 'githubRepo (could not be verified' \
       && printf '%s' "$OUT" | grep -q "repo-norm' returned no value"; then
      ok "AC-N2/$SH/$MODE: doctor names BOTH halves as could-not-be-verified and says why"
    else
      notok "AC-N2/$SH/$MODE: doctor's report does not say the halves were unverifiable: $(flat "$OUT")"
    fi
    if printf '%s' "$OUT" | grep -q 'quetrex-api PATCH'; then
      notok "AC-N2/$SH/$MODE: doctor offered the mismatch PATCH one-liner without a demonstrated mismatch: $(flat "$OUT")"
    else
      ok "AC-N2/$SH/$MODE: doctor offers no PATCH one-liner for a mismatch it never established"
    fi

    # --- AC-N3: broken helper over a MATCHING link is refused just as loudly ---
    L="$WORK/n3i-$SH-$MODE"
    OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_BOTH" QX_NORM_MODE="$MODE")"
    if [ "$(patch_count "$L")" = 0 ] && printf '%s' "$OUT" | grep -q 'could not compare project DEA'; then
      ok "AC-N3/$SH/$MODE: init refuses to certify even a matching link when repo-norm fails"
    else
      notok "AC-N3/$SH/$MODE: init treated an unverifiable comparison as a match: $(flat "$OUT")"
    fi
    L="$WORK/n3d-$SH-$MODE"
    OUT="$(run_doctor "$SH" "$WORK/check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_BOTH" QX_STUB_HOOK_ID=4242 QX_NORM_MODE="$MODE")"
    if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && printf '%s' "$OUT" | grep -q 'could not be verified'; then
      ok "AC-N3/$SH/$MODE: doctor withholds ✓ on a matching link it could not actually compare"
    else
      notok "AC-N3/$SH/$MODE: doctor passed a link it never compared: $(flat "$OUT")"
    fi
  done

  # --- AC-N4: the legitimate path is untouched (REAL repo-norm) --------------
  L="$WORK/n4i-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_BOTH")"
  if [ "$(patch_count "$L")" = 0 ] && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
    ok "AC-N4/$SH: real repo-norm + a matching link -> init still PATCHes nothing and says nothing"
  else
    notok "AC-N4/$SH: the legitimate matching path changed (count=$(patch_count "$L")): $(flat "$OUT")"
  fi
  # An UNSET stored half normalizes to empty — a SUCCESS, not a helper failure.
  # If qx_norm confused the two, init could never reach the PATCH arm again.
  L="$WORK/n4p-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_REPO_ONLY")"
  if [ "$(patch_count "$L")" = 1 ] && [ "$(patch_field "$L" githubOwner)" = Glori-Holdings ] \
     && [ "$(patch_field "$L" githubRepo)" = dealerq ] \
     && printf '%s' "$OUT" | grep -q '^project DEA linked to Glori-Holdings/dealerq$'; then
    ok "AC-N4/$SH: an EMPTY stored half normalizing to empty is a success — init still writes the pair"
  else
    notok "AC-N4/$SH: empty-in/empty-out was mistaken for a helper failure (count=$(patch_count "$L")): $(flat "$OUT")"
  fi
  L="$WORK/n4e-$SH"
  OUT="$(run_init "$SH" "$WORK/link.sh" "$L" QX_STUB_PROJECT="$PROJ_EMPTY")"
  if [ "$(patch_count "$L")" = 1 ] && [ "$(patch_field "$L" githubOwner)" = Glori-Holdings ]; then
    ok "AC-N4/$SH: real repo-norm + an unlinked project -> init still writes both halves"
  else
    notok "AC-N4/$SH: the legitimate PATCH path regressed (count=$(patch_count "$L")): $(flat "$OUT")"
  fi
  L="$WORK/n4d-$SH"
  OUT="$(run_doctor "$SH" "$WORK/check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_BOTH" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✓ Webhook registered' && printf '%s' "$OUT" | grep -q 'board shows the repository as linked'; then
    ok "AC-N4/$SH: real repo-norm + a matching link -> doctor still reports ✓"
  else
    notok "AC-N4/$SH: the legitimate doctor ✓ regressed: $(flat "$OUT")"
  fi
done

# --- AC-N5: ONE wrapper, two callers -----------------------------------------
# The fix is only durable if both files share the wrapper rather than each
# remembering to check. Compare the qx_norm bodies with leading indentation
# stripped (init nests it one level deeper), and prove neither file still calls
# the bare helper on a comparison path.
norm_body() { awk '/^ *qx_norm\(\) \{/{f=1} f{sub(/^ +/,"");print} f && /^ *\}$/{exit}' "$1"; }
IB="$(norm_body "$WORK/link.sh")"; DB="$(norm_body "$WORK/check14.sh")"
if [ -n "$IB" ] && [ "$IB" = "$DB" ]; then
  ok "AC-N5: qx_norm is one wrapper, byte-identical in init.md and doctor.md"
else
  notok "AC-N5: the qx_norm wrappers differ between init.md and doctor.md — one can be hardened while the other stays fail-silent"
fi
# The defect's exact shape is a command substitution whose value is used without
# its status: `X="$(quetrex-api repo-norm …)"`. Only the wrapper is allowed to be
# one. (Prose that merely NAMES the command inside an echo is not a call site,
# which is why the pattern is `$(` rather than the bare command name.)
BARE="$( { grep -n '\$(quetrex-api repo-norm' "$WORK/link.sh" "$WORK/check14.sh" || true; } | grep -v '_qn_out=' || true)"
if [ -z "$BARE" ]; then
  ok "AC-N5: no comparison path calls the bare \`quetrex-api repo-norm\` — every call goes through the checked wrapper"
else
  notok "AC-N5: a bare unchecked repo-norm call survives: $(flat "$BARE")"
fi

# --- AC-N6: fail-first against the literal pre-change sha --------------------
# A baseline that cannot be read is a FAILURE, never a skip.
if git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-setup/commands/init.md" > "$WORK/old-init.md" 2>/dev/null \
   && [ -s "$WORK/old-init.md" ] \
   && git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-setup/commands/doctor.md" > "$WORK/old-doctor.md" 2>/dev/null \
   && [ -s "$WORK/old-doctor.md" ]; then
  extract_exec_block "$WORK/old-init.md" qx_link_project_repo > "$WORK/old-link.sh"
  extract_check14 "$WORK/old-doctor.md" > "$WORK/old-check14.sh"
  # `empty` is the exact shape QA reproduced: exit 0, print nothing. It is also
  # the only silent one, so "printed NOTHING" is assertable without a stub's own
  # command-not-found noise confusing it.
  L="$WORK/old-init"
  OUT="$(run_init bash "$WORK/old-link.sh" "$L" QX_STUB_PROJECT="$PROJ_OTHER" QX_NORM_MODE=empty)"
  if [ -s "$WORK/old-link.sh" ] && [ "$(patch_count "$L")" = 0 ] \
     && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then
    ok "AC-N6: FAIL-FIRST (init) — $BASE_SHA prints ABSOLUTELY NOTHING while the board is linked to Someone-Else/other-app"
  else
    notok "AC-N6: $BASE_SHA's init block did not reproduce the silent mask (count=$(patch_count "$L")): $(flat "$OUT")"
  fi
  L="$WORK/old-doctor"
  OUT="$(run_doctor bash "$WORK/old-check14.sh" "$L" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_OTHER" QX_STUB_HOOK_ID=4242 QX_NORM_MODE=empty)"
  if [ -s "$WORK/old-check14.sh" ] && printf '%s' "$OUT" | grep -q '^✓ Webhook registered' \
     && printf '%s' "$OUT" | grep -q 'project linked to Someone-Else/other-app'; then
    ok "AC-N6: FAIL-FIRST (doctor) — $BASE_SHA reports ✓ 'board shows the repository as linked' over Someone-Else/other-app"
  else
    notok "AC-N6: $BASE_SHA's doctor Check 14 did not reproduce the false ✓: $(flat "$OUT")"
  fi
else
  notok "AC-N6: baseline blobs at $BASE_SHA are unreadable (shallow clone?) — fail-first arm cannot run"
fi

finish
