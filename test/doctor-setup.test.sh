#!/usr/bin/env bash
# test/doctor-setup.test.sh — /quetrex-setup:doctor: question-free, user-scope,
# and its four new checks actually run (bash AND zsh).
#
# Run: bash test/doctor-setup.test.sh
#
# THE OPERATOR'S ASK. Re-running /quetrex-setup:init on an ALREADY-LINKED repo
# asked nine AskUserQuestion rounds — which cloud environment, confirm a
# verify chain that .quetrex/verify.json already committed, fourteen
# requiredEnv pairings (two of whose "read sites" were markdown), which
# .env.local names to import — most of which the operator had to guess at.
# "We should have a doctor that checks an application thoroughly and makes
# sure all these are correct without a ton of questions."
#
# So doctor (a) moved into quetrex-setup — user scope, so it exists on a repo
# BEFORE its project plugins are enabled — and (b) gained four question-free
# checks, each ending in ✓/✗ and a Fix line that names the writer command.
#
#   AC1  doctor.md lives at plugins/quetrex-setup/commands/doctor.md, its
#        Usage is /quetrex-setup:doctor, the old path is gone, and the
#        quetrex-setup manifest lists all four commands.
#   AC2  the four new check headings are present; the file contains NO
#        `AskUserQuestion` token anywhere; the roll-up counts 14 and the intro's
#        spelled-out count agrees with the number of `## Check N` headings.
#   AC3  Check 11 (Cloud environment), EXECUTED: id set -> ✓; unset with one
#        `repo` environment -> ✗ + `Fix: quetrex-cloud-env set . <id>`; two
#        -> one Fix line per id; none -> the claude.ai/code instruction.
#   AC4  Check 12 (Verification block), EXECUTED: match -> ✓; drift -> ✗ and
#        the Fix prints the exact block; no CLAUDE.md -> ✗; no verify.json
#        -> ✓ nothing to compare.
#   AC5  Check 13 (Vault coverage), EXECUTED against a stub quetrex-api:
#        missing names -> ✗ with one `secret-put` Fix line per name and
#        placeholders listed separately; all present -> ✓ with the count; no
#        .env.local -> ✓ nothing to compare. NO VALUE from .env.local ever
#        reaches stdout — asserted on every run (the fixture values are
#        inert markers, not credentials).
#   AC6  Check 5's requiredEnv section, EXECUTED: an outstanding candidate is
#        listed as `NAME (read at file:line)` with a Fix naming
#        /quetrex-setup:init, and doctor wrote nothing.
#   AC7  Check 14 (Webhook registered), EXECUTED against stub gh + quetrex-api:
#        all four conditions hold -> ✓; each of hook / vault name / githubRepo
#        missing -> ✗ naming it + one 'Fix: re-run /quetrex-setup:init' line;
#        non-GitHub origin -> ✗; gh absent -> ✗ with an install hint. Names
#        only — the export endpoint is never called.
#   PARITY: AC3-AC7 run under zsh as well when it is installed — the
#        operator's shell must not change a diagnosis.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_MD="$TOOLROOT/plugins/quetrex-setup/commands/doctor.md"
FIXTURE="$TOOLROOT/test/fixtures/remote-triggers.json"

FAIL=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'NOT OK - %s\n' "$1"; FAIL=1; }

if [ ! -f "$DOCTOR_MD" ]; then
  echo "NOT OK - doctor.md not found at $DOCTOR_MD (doctor must live in quetrex-setup)"
  echo "doctor-setup.test.sh: FAILURES above"
  exit 1
fi
command -v node >/dev/null 2>&1 || { echo "SKIP: node not installed — doctor's checks are node-assisted"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed — quetrex-cloud-env candidates needs it"; exit 0; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qx-doctor-setup.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

extract_section() {  # extract_section <heading-literal> — every bash fence under it
  awk -v heading="$1" '
    index($0, heading) == 1 { insec = 1; next }
    insec && /^## / { exit }
    insec && /^```bash/ { infence = 1; next }
    insec && /^```/ { infence = 0; next }
    insec && infence { print }
  ' "$DOCTOR_MD"
}

# --- AC1: location, name, manifest -------------------------------------------
if [ ! -e "$TOOLROOT/.claude/commands/doctor.md" ]; then
  pass "AC1: .claude/commands/doctor.md is gone — doctor is not shipped twice"
else
  fail "AC1: .claude/commands/doctor.md still exists alongside the quetrex-setup copy"
fi
if head -5 "$DOCTOR_MD" | grep -q 'Usage: /quetrex-setup:doctor'; then
  pass "AC1: frontmatter Usage is /quetrex-setup:doctor"
else
  fail "AC1: frontmatter Usage is not /quetrex-setup:doctor"
fi
LIVE_SURFACES="$DOCTOR_MD $TOOLROOT/plugins/quetrex-setup/commands/init.md $TOOLROOT/GOLDEN.md $TOOLROOT/docs/onboarding/quetrex-onboarding.html"
# shellcheck disable=SC2086
if ! grep -q '/quetrex:doctor' $LIVE_SURFACES; then
  pass "AC1: no live surface still names /quetrex:doctor"
else
  # shellcheck disable=SC2086
  fail "AC1: a live surface still names /quetrex:doctor: $(grep -l '/quetrex:doctor' $LIVE_SURFACES | tr '\n' ' ')"
fi
MANIFEST_OK="$(node -e '
  const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
  const d=String(p.description||"");
  const all=["/quetrex-setup:login","/quetrex-setup:init","/quetrex-setup:doctor","/quetrex-setup:update"].every(c=>d.includes(c));
  const ver=/^\d+\.\d+\.\d+$/.test(p.version) && !(p.version==="1.0.3");
  process.stdout.write(all && ver ? "ok" : "bad:"+p.version);
' "$TOOLROOT/plugins/quetrex-setup/.claude-plugin/plugin.json")"
if [ "$MANIFEST_OK" = "ok" ]; then
  pass "AC1: quetrex-setup plugin.json lists all four commands and was bumped past 1.0.3"
else
  fail "AC1: quetrex-setup plugin.json description/version wrong ($MANIFEST_OK)"
fi

# --- AC2: headings, no questions, roll-up ------------------------------------
for H in '## Check 11 — Cloud environment' '## Check 12 — Verification block' '## Check 13 — Vault coverage' 'requiredEnv outstanding'; do
  if grep -qF "$H" "$DOCTOR_MD"; then pass "AC2: doctor.md has '$H'"; else fail "AC2: doctor.md lacks '$H'"; fi
done
if ! grep -q 'AskUserQuestion' "$DOCTOR_MD"; then
  pass "AC2: doctor.md contains no AskUserQuestion token — doctor never asks"
else
  fail "AC2: doctor.md mentions AskUserQuestion ($(grep -c 'AskUserQuestion' "$DOCTOR_MD") time(s))"
fi
if grep -q 'N/14 green' "$DOCTOR_MD"; then
  pass "AC2: the roll-up counts 14 checks"
else
  fail "AC2: the roll-up does not say N/14 green"
fi
if grep -qF '## Check 14 — Webhook registered' "$DOCTOR_MD"; then
  pass "AC2: doctor.md has '## Check 14 — Webhook registered'"
else
  fail "AC2: doctor.md lacks '## Check 14 — Webhook registered'"
fi
# The intro's spelled-out count must agree with the headings (it said "thirteen" once).
N_HEAD="$(grep -cE '^## Check [0-9]+ ' "$DOCTOR_MD")"
WORDS=(zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty)
if [ "$N_HEAD" -le 20 ] && grep -q "are the ${WORDS[$N_HEAD]} Quetrex-app checks" "$DOCTOR_MD"; then
  pass "AC2: the intro says '${WORDS[$N_HEAD]}' checks and there are $N_HEAD '## Check N' headings"
else
  fail "AC2: the intro's spelled-out check count disagrees with the $N_HEAD '## Check N' headings"
fi

# --- harness -----------------------------------------------------------------
NODE_DIR="$(dirname "$(command -v node)")"
GIT_BIN_DIR="$(dirname "$(command -v git)")"
PY_DIR="$(dirname "$(command -v python3)")"
REAL_BIN="$TOOLROOT/plugins/quetrex-setup/bin"
# A stub quetrex-api: json-get delegates to the real file reader; GET returns a
# fixed masked vault list; anything else fails. Never touches the network.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/quetrex-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  json-get) exec "$QX_REAL_API" json-get "$2" "$3" ;;
  kanban-url) printf 'https://kanban.test/\n' ;;
  GET) case "$2" in
         */secrets/export) echo "export endpoint called" >&2; exit 1 ;;
         */secrets) [ -n "${QX_STUB_VAULT:-}" ] || exit 1; cat "$QX_STUB_VAULT" ;;
         *) [ -n "${QX_STUB_PROJECT:-}" ] || exit 1; cat "$QX_STUB_PROJECT" ;;
       esac ;;
  POST) echo "export endpoint called" >&2; exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/quetrex-api"
# A stub gh: 'gh api repos/<slug>/hooks --jq ...' prints QX_STUB_HOOK_ID (empty = no hook).
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "api repos/"*"/hooks") printf '%s\n' "${QX_STUB_HOOK_ID:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/gh"
RUN_PATH="$STUB:$REAL_BIN:$NODE_DIR:$GIT_BIN_DIR:$PY_DIR:/usr/bin:/bin"
export QX_REAL_API="$REAL_BIN/quetrex-api"

write_json() { node -e 'require("fs").writeFileSync(process.argv[1], process.argv[2]+"\n")' "$1" "$2"; }

run_check() {  # run_check <shell> <section> <repo-root> [extra env assignments...]
  local sh="$1" sec="$2" root="$3"; shift 3
  local script="$WORK/$(printf '%s' "$sec" | tr -c 'A-Za-z0-9' '_').sh"
  {
    printf 'REPO_ROOT=%q\nBIND="$REPO_ROOT/.quetrex/project.json"\nSETTINGS="$REPO_ROOT/.claude/settings.json"\nHOME_SETTINGS="$HOME/.claude/settings.json"\n' "$root"
    extract_section "$sec"
  } > "$script"
  ( cd "$root" && env "$@" PATH="$RUN_PATH" "$sh" "$script" 2>&1 )
}

mkrepo() {  # mkrepo <name> <origin-url> -> path
  local d="$WORK/$1"
  mkdir -p "$d/.quetrex" "$d/.claude"
  git -C "$d" init -q -b main
  git -C "$d" config user.email t@example.com; git -C "$d" config user.name T
  [ -n "$2" ] && git -C "$d" remote add origin "$2"
  printf '%s' "$d"
}

for SH in $SHELLS; do
  # --- AC3: Check 11 ---------------------------------------------------------
  R="$(mkrepo "c11-set-$SH" https://github.com/Glori-Holdings/quetrex-plugins)"
  write_json "$R/.quetrex/project.json" '{"projectCode":"QDM","branchPrefix":"claude/","cloudEnvironmentId":"env_already"}'
  OUT="$(run_check "$SH" '## Check 11' "$R")"
  if printf '%s' "$OUT" | grep -q '✓ Cloud environment — builds run in env_already'; then
    pass "AC3/$SH: a recorded cloudEnvironmentId reports ✓ with the id"
  else
    fail "AC3/$SH: recorded id not reported ✓: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$(mkrepo "c11-one-$SH" https://github.com/Glori-Holdings/quetrex-plugins)"
  write_json "$R/.quetrex/project.json" '{"projectCode":"QDM","branchPrefix":"claude/"}'
  OUT="$(run_check "$SH" '## Check 11' "$R" TRIGGERS_JSON="$FIXTURE")"
  if printf '%s' "$OUT" | grep -q '^✗ Cloud environment' && printf '%s' "$OUT" | grep -qF 'Fix: quetrex-cloud-env set . env_011CUpkAEM4fzsAD6dx1zW3r' && [ "$(printf '%s\n' "$OUT" | grep -c 'Fix:')" -eq 1 ]; then
    pass "AC3/$SH: exactly one repo environment -> ✗ + one 'quetrex-cloud-env set . <id>' Fix line, no question"
  else
    fail "AC3/$SH: one-candidate case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if printf '%s' "$OUT" | grep -q 'AskUserQuestion'; then fail "AC3/$SH: check output mentions AskUserQuestion"; fi

  R="$(mkrepo "c11-two-$SH" https://github.com/Glori-Holdings/quetrex-base)"
  write_json "$R/.quetrex/project.json" '{"projectCode":"QUE","branchPrefix":"claude/"}'
  OUT="$(run_check "$SH" '## Check 11' "$R" TRIGGERS_JSON="$FIXTURE")"
  if printf '%s' "$OUT" | grep -q '^✗ Cloud environment' && [ "$(printf '%s\n' "$OUT" | grep -c 'Fix: quetrex-cloud-env set \. env_')" -eq 2 ]; then
    pass "AC3/$SH: two repo environments -> ✗ listing both, one Fix line per id"
  else
    fail "AC3/$SH: two-candidate case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$(mkrepo "c11-none-$SH" https://github.com/Nobody/never-ran)"
  write_json "$R/.quetrex/project.json" '{"projectCode":"NEW","branchPrefix":"claude/"}'
  OUT="$(run_check "$SH" '## Check 11' "$R" TRIGGERS_JSON="$FIXTURE")"
  if printf '%s' "$OUT" | grep -q '^✗ Cloud environment' && printf '%s' "$OUT" | grep -q 'claude.ai/code' && ! printf '%s' "$OUT" | grep -q 'Fix: quetrex-cloud-env set \. env_'; then
    pass "AC3/$SH: no repo environment -> ✗ + the claude.ai/code create instruction, no id prescribed"
  else
    fail "AC3/$SH: none case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_check "$SH" '## Check 11' "$R")"   # RemoteTrigger failed / unset
  if printf '%s' "$OUT" | grep -q '^✗ Cloud environment' && printf '%s' "$OUT" | grep -q 'claude.ai/code'; then
    pass "AC3/$SH: TRIGGERS_JSON unset (RemoteTrigger failed) still yields a ✗ with the fallback, never a crash"
  else
    fail "AC3/$SH: unset TRIGGERS_JSON case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC4: Check 12 ---------------------------------------------------------
  R="$(mkrepo "c12-match-$SH" "")"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm run lint","npm test"]}'
  printf '# P\n\n## Verification\nRun in order:\n\n```bash\nnpm run lint\n\nnpm test\n```\n\n## Other\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_check "$SH" '## Check 12' "$R")"
  if printf '%s' "$OUT" | grep -q '✓ Verification block' && printf '%s' "$OUT" | grep -q '2 command(s)'; then
    pass "AC4/$SH: a CLAUDE.md block equal to .verify[] (blank line ignored) reports ✓"
  else
    fail "AC4/$SH: match case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$(mkrepo "c12-drift-$SH" "")"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm run lint","npm test","npm run build"]}'
  printf '## Verification\n\n```bash\nnpm test\n```\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_check "$SH" '## Check 12' "$R")"
  if printf '%s' "$OUT" | grep -q '^✗ Verification block' && printf '%s' "$OUT" | grep -q 'Fix:' \
     && printf '%s\n' "$OUT" | grep -q '^    npm run lint$' && printf '%s\n' "$OUT" | grep -q '^    npm run build$' \
     && printf '%s\n' "$OUT" | grep -q '^    ```bash$'; then
    pass "AC4/$SH: a drifted block reports ✗ and the Fix prints the exact fenced block to paste"
  else
    fail "AC4/$SH: drift case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$(mkrepo "c12-nomd-$SH" "")"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm test"]}'
  OUT="$(run_check "$SH" '## Check 12' "$R")"
  if printf '%s' "$OUT" | grep -q '^✗ Verification block' && printf '%s' "$OUT" | grep -q 'no .claude/CLAUDE.md'; then
    pass "AC4/$SH: no CLAUDE.md -> ✗ naming the cause"
  else
    fail "AC4/$SH: no-CLAUDE.md case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$(mkrepo "c12-nochain-$SH" "")"
  printf '## Verification\n\n```bash\nnpm test\n```\n' > "$R/.claude/CLAUDE.md"
  OUT="$(run_check "$SH" '## Check 12' "$R")"
  if printf '%s' "$OUT" | grep -q '✓ Verification block' && printf '%s' "$OUT" | grep -q 'no .quetrex/verify.json'; then
    pass "AC4/$SH: no verify.json -> ✓ nothing to compare (Check 5 owns that)"
  else
    fail "AC4/$SH: no-verify.json case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC5: Check 13 ---------------------------------------------------------
  # Fixture values are inert MARKER strings (never credentials); the leak
  # assertion below greps for them to prove no value reaches stdout.
  VAULT="$WORK/vault.json"
  write_json "$VAULT" '[{"name":"DATABASE_URL","isSet":true,"last4":"5432"},{"name":"RESEND_API_KEY","isSet":true,"last4":"abcd"}]'
  R="$(mkrepo "c13-missing-$SH" "")"
  write_json "$R/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'
  cat > "$R/.env.local" <<'EOF'
# local creds
DATABASE_URL=postgres://localhost:5432/marker_value_one
export RESEND_API_KEY="marker_value_two"
STRIPE_SECRET_KEY='marker_value_three'
FLY_API_TOKEN=your-secret-here
OPENAI_API_KEY=
GITHUB_TOKEN=<paste token>
NEXT_PUBLIC_APP_URL=http://localhost:3000
EOF
  OUT="$(run_check "$SH" '## Check 13' "$R" QX_STUB_VAULT="$VAULT")"
  if printf '%s' "$OUT" | grep -q '^✗ Vault coverage' \
     && printf '%s' "$OUT" | grep -qF 'Fix: quetrex-api secret-put .env.local STRIPE_SECRET_KEY STRIPE_SECRET_KEY' \
     && printf '%s' "$OUT" | grep -qF 'Fix: quetrex-api secret-put .env.local NEXT_PUBLIC_APP_URL NEXT_PUBLIC_APP_URL' \
     && [ "$(printf '%s\n' "$OUT" | grep -c 'Fix: quetrex-api secret-put')" -eq 2 ]; then
    pass "AC5/$SH: names missing from the vault -> ✗ with one secret-put Fix line per missing name (and none for names already in the vault)"
  else
    fail "AC5/$SH: missing case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if printf '%s' "$OUT" | grep -q 'skipped (placeholder):' && printf '%s' "$OUT" | grep 'skipped (placeholder)' | grep -q 'FLY_API_TOKEN' \
     && printf '%s' "$OUT" | grep 'skipped (placeholder)' | grep -q 'OPENAI_API_KEY' && printf '%s' "$OUT" | grep 'skipped (placeholder)' | grep -q 'GITHUB_TOKEN' \
     && ! printf '%s' "$OUT" | grep -q 'secret-put .env.local FLY_API_TOKEN'; then
    pass "AC5/$SH: placeholder values (your-secret-here, empty, <paste>) are listed separately and never prescribed for import"
  else
    fail "AC5/$SH: placeholder classification wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  LEAKED=0
  for LEAK in marker_value_one marker_value_two marker_value_three 'paste token' 'localhost:3000'; do
    if printf '%s' "$OUT" | grep -qF "$LEAK"; then LEAKED=1; fail "AC5/$SH: a .env.local VALUE fragment ('$LEAK') reached doctor's output"; fi
  done
  [ "$LEAKED" -eq 0 ] && pass "AC5/$SH: no .env.local value fragment appears in the output"

  R="$(mkrepo "c13-all-$SH" "")"
  write_json "$R/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'
  printf 'DATABASE_URL=postgres://localhost/x\nRESEND_API_KEY=marker_x\n' > "$R/.env.local"
  OUT="$(run_check "$SH" '## Check 13' "$R" QX_STUB_VAULT="$VAULT")"
  if printf '%s' "$OUT" | grep -q '✓ Vault coverage — 2 name(s) in .env.local, all in project DEA'; then
    pass "AC5/$SH: every name in the vault -> ✓ with the count"
  else
    fail "AC5/$SH: all-present case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  R="$(mkrepo "c13-none-$SH" "")"
  write_json "$R/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'
  OUT="$(run_check "$SH" '## Check 13' "$R" QX_STUB_VAULT="$VAULT")"
  if printf '%s' "$OUT" | grep -q '✓ Vault coverage — no .env.local'; then
    pass "AC5/$SH: no .env.local -> ✓ nothing to compare"
  else
    fail "AC5/$SH: no-.env.local case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC6: Check 5 requiredEnv outstanding ----------------------------------
  R="$(mkrepo "c5-req-$SH" "")"
  mkdir -p "$R/src"
  printf 'DATABASE_URL=\n' > "$R/.env.example"
  printf 'const u = process.env.DATABASE_URL;\n' > "$R/src/db.js"
  write_json "$R/.quetrex/verify.json" '{"verify":["npm test"]}'
  git -C "$R" add -A && git -C "$R" commit -q -m fixture
  BEFORE="$(cat "$R/.quetrex/verify.json")"
  OUT="$(run_check "$SH" '## Check 5' "$R")"
  if printf '%s' "$OUT" | grep -q '^✗ requiredEnv outstanding' && printf '%s' "$OUT" | grep -q 'DATABASE_URL (read at src/db.js:1)' \
     && printf '%s' "$OUT" | grep 'Fix:' | grep -q '/quetrex-setup:init'; then
    pass "AC6/$SH: an outstanding candidate is listed as NAME (read at file:line) with a Fix naming /quetrex-setup:init"
  else
    fail "AC6/$SH: requiredEnv section wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if [ "$(cat "$R/.quetrex/verify.json")" = "$BEFORE" ]; then
    pass "AC6/$SH: doctor wrote nothing to .quetrex/verify.json (report-only)"
  else
    fail "AC6/$SH: doctor modified .quetrex/verify.json"
  fi
  # --- AC7: Check 14 Webhook registered --------------------------------------
  VAULT_WH="$WORK/vault-wh.json"
  write_json "$VAULT_WH" '[{"name":"DATABASE_URL","isSet":true,"last4":"5432"},{"name":"GITHUB_WEBHOOK_SECRET","isSet":true,"last4":"beef"}]'
  # The board links a project only when BOTH githubOwner and githubRepo are set
  # (board-repo-link.test.sh owns the owner-half cases; this file keeps the
  # original hook / vault / githubRepo arms).
  PROJ_WH="$WORK/project-wh.json"; write_json "$PROJ_WH" '{"code":"DEA","githubOwner":"Glori-Holdings","githubRepo":"dealerq"}'
  PROJ_NOREPO="$WORK/project-norepo.json"; write_json "$PROJ_NOREPO" '{"code":"DEA","githubOwner":"Glori-Holdings","githubRepo":null}'
  R="$(mkrepo "c14-ok-$SH" git@github.com:Glori-Holdings/dealerq.git)"
  write_json "$R/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'
  OUT="$(run_check "$SH" '## Check 14' "$R" QX_STUB_VAULT="$VAULT_WH" QX_STUB_PROJECT="$PROJ_WH" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✓ Webhook registered' && printf '%s' "$OUT" | grep -q 'Glori-Holdings/dealerq hook 4242 -> https://kanban.test/api/webhooks/github' \
     && ! printf '%s' "$OUT" | grep -q 'export endpoint called'; then
    pass "AC7/$SH: hook + vault name + githubRepo all present -> ✓ (names-only GET, export never called)"
  else
    fail "AC7/$SH: all-present case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_check "$SH" '## Check 14' "$R" QX_STUB_VAULT="$VAULT_WH" QX_STUB_PROJECT="$PROJ_WH" QX_STUB_HOOK_ID=)"
  if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && printf '%s' "$OUT" | grep -q 'missing: GitHub hook on Glori-Holdings/dealerq' \
     && ! printf '%s' "$OUT" | grep -q 'vault;' && [ "$(printf '%s\n' "$OUT" | grep -c 'Fix: re-run /quetrex-setup:init')" -eq 1 ]; then
    pass "AC7/$SH: no hook on the repo -> ✗ naming the hook only, one init Fix line"
  else
    fail "AC7/$SH: no-hook case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_check "$SH" '## Check 14' "$R" QX_STUB_VAULT="$VAULT" QX_STUB_PROJECT="$PROJ_WH" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && printf '%s' "$OUT" | grep -q "GITHUB_WEBHOOK_SECRET in project DEA's vault" \
     && ! printf '%s' "$OUT" | grep -q 'GitHub hook on' && printf '%s' "$OUT" | grep -q 'Fix: re-run /quetrex-setup:init'; then
    pass "AC7/$SH: vault lacks the name -> ✗ naming the vault entry only"
  else
    fail "AC7/$SH: no-vault-name case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  OUT="$(run_check "$SH" '## Check 14' "$R" QX_STUB_VAULT="$VAULT_WH" QX_STUB_PROJECT="$PROJ_NOREPO" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✗ Webhook registered' && printf '%s' "$OUT" | grep -q 'project DEA githubRepo' \
     && ! printf '%s' "$OUT" | grep -q 'GitHub hook on' && printf '%s' "$OUT" | grep -q 'Fix: re-run /quetrex-setup:init'; then
    pass "AC7/$SH: project.githubRepo unset -> ✗ naming githubRepo only"
  else
    fail "AC7/$SH: no-githubRepo case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  R2="$(mkrepo "c14-nogh-$SH" https://gitlab.example.com/x/y.git)"
  write_json "$R2/.quetrex/project.json" '{"projectCode":"DEA","branchPrefix":"claude/"}'
  OUT="$(run_check "$SH" '## Check 14' "$R2" QX_STUB_VAULT="$VAULT_WH" QX_STUB_PROJECT="$PROJ_WH" QX_STUB_HOOK_ID=4242)"
  if printf '%s' "$OUT" | grep -q '^✗ Webhook registered — origin is not a GitHub repo'; then
    pass "AC7/$SH: a non-GitHub origin -> ✗ naming it"
  else
    fail "AC7/$SH: non-GitHub origin case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  NOGH="$WORK/nogh-bin"; mkdir -p "$NOGH"; cp "$STUB/quetrex-api" "$NOGH/quetrex-api"
  NOGH_PATH="$NOGH:$REAL_BIN:$NODE_DIR:$GIT_BIN_DIR:/usr/bin:/bin"
  if ! PATH="$NOGH_PATH" command -v gh >/dev/null 2>&1; then
    OUT="$(RUN_PATH="$NOGH_PATH" run_check "$SH" '## Check 14' "$R" QX_STUB_VAULT="$VAULT_WH" QX_STUB_PROJECT="$PROJ_WH")"
    if printf '%s' "$OUT" | grep -q '^✗ Webhook registered — gh CLI not installed' && printf '%s' "$OUT" | grep -q 'Fix: install gh'; then
      pass "AC7/$SH: gh absent -> ✗ with an install hint"
    else
      fail "AC7/$SH: gh-absent case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
    fi
  else
    pass "AC7/$SH: (skipped) gh is on the system PATH, cannot simulate its absence"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "doctor-setup.test.sh: all checks passed"
else
  echo "doctor-setup.test.sh: FAILURES above"
fi
exit "$FAIL"
