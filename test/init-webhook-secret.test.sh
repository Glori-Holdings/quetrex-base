#!/usr/bin/env bash
# test/init-webhook-secret.test.sh — /quetrex-setup:init 4i GENERATES the
# webhook secret when the project vault has none (bash AND zsh, fail-first).
#
# Run: bash test/init-webhook-secret.test.sh
#
# OPERATOR EVIDENCE. 4i registered the GitHub webhook with GITHUB_WEBHOOK_SECRET
# from the PROJECT vault, but nothing ever wrote that entry: a fresh project
# printed "no GITHUB_WEBHOOK_SECRET in project X's vault — skipped" and cards
# never moved to pr_ready. The board now verifies each delivery against the
# vault entry of the project whose repo it came from, so the secret is needed
# by exactly two parties — GitHub (signs) and the board (verifies) — and init
# is the one writer: mint 32 random bytes, store them with the existing
# `quetrex-api secret-put` helper, and only THEN register the hook with the
# same value. A failed store must NOT register (a hook GitHub signs with a value
# the board cannot see is worse than none).
#
#   AC1  the qx_register_webhook exec block exists in 4i, extracts, parses, and
#        the old "Add it at $QX_KANBAN_URL/keys" hint is gone.
#   AC2  EXECUTED (bash + zsh) with a stub vault export returning nothing and a
#        recording stub secret-put: (i) secret-put is called with name
#        GITHUB_WEBHOOK_SECRET and a 64-hex value; (ii) gh api -X POST
#        repos/<slug>/hooks then receives the SAME value; (iii) no output line
#        contains the value.
#   AC3  EXECUTED: secret-put failing -> gh POST is NOT called, one labelled
#        line names the cause; an existing vault value is reused (no
#        secret-put, POST carries it); an already-registered hook is left alone
#        (no secret-put, no POST).
#   AC4  FAIL-FIRST against the literal pre-change sha 5d383b8 (never `main`):
#        its 4i block, driven by the same stubs, prints the "skipped" line and
#        never calls secret-put.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INIT_MD="$ROOT/plugins/quetrex-setup/commands/init.md"
BASE_SHA="5d383b8"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() { printf '\n%s\n' "init-webhook-secret.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq unavailable (4i builds the hook payload with jq)"; exit 0; }
[ -f "$INIT_MD" ] || { echo "NOT OK - init.md not found at $INIT_MD"; exit 1; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/init-webhook-secret.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- AC1: the block exists and the operator hint is gone ---------------------
SECTION_4I="$(awk '/^## 4i\./{s=1} s && /^## 4j\./{exit} s' "$INIT_MD")"
awk -v name="qx_register_webhook" '
  $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
' "$INIT_MD" > "$WORK/block.sh"
if [ -s "$WORK/block.sh" ] && bash -n "$WORK/block.sh" 2>/dev/null; then
  ok "AC1: 4i carries the qx_register_webhook exec block and it parses"
else
  notok "AC1: could not extract a parseable qx_register_webhook block from 4i"
  finish
fi
if ! printf '%s' "$SECTION_4I" | grep -q 'Add it at \$QX_KANBAN_URL/keys' \
   && printf '%s' "$SECTION_4I" | grep -q 'randomBytes(32)' \
   && printf '%s' "$SECTION_4I" | grep -q 'quetrex-api secret-put'; then
  ok "AC1: 4i generates the secret via the secret-put helper; the 'Add it at /keys' operator hint is gone"
else
  notok "AC1: 4i still tells the operator to add the secret by hand, or does not generate one"
fi

# --- harness -----------------------------------------------------------------
# Stub quetrex-api: POST .../secrets/export prints QX_STUB_EXPORT (JSON);
# secret-put reads the env FILE exactly as the real helper does (node
# readFileSync on the path it is handed — proving the /dev/fd process
# substitution works through an exec'd script under both shells), records
# {name,value} to $QX_LOG/put.json and exits QX_STUB_PUT_RC.
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/quetrex-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  POST) case "$2" in
          */secrets/export) printf '%s\n' "${QX_STUB_EXPORT:-{\}}" ;;
          *) exit 1 ;;
        esac ;;
  secret-put)
    node -e '
      const fs=require("fs"); const [file,raw,canon,log]=process.argv.slice(1);
      let txt; try { txt=fs.readFileSync(file,"utf8"); } catch { process.exit(1); }
      let val=null;
      for (let line of txt.split(/\r?\n/)) {
        line=line.replace(/^\s*export\s+/,"").trim();
        if (!line || line.startsWith("#")) continue;
        const eq=line.indexOf("="); if (eq<0) continue;
        if (line.slice(0,eq).trim()!==raw) continue;
        val=line.slice(eq+1).trim();
      }
      if (val==null) process.exit(1);
      fs.writeFileSync(log+"/put.json", JSON.stringify({name:canon,value:val}));
    ' "$2" "$3" "$4" "$QX_LOG" || exit 1
    exit "${QX_STUB_PUT_RC:-0}" ;;
  *) exit 1 ;;
esac
EOF
# Stub gh: the hooks GET prints QX_STUB_HOOK_ID; the POST records its stdin
# payload to $QX_LOG/post.json and answers with an id.
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ] && [ "$2" = -X ] && [ "$3" = POST ]; then
  cat > "$QX_LOG/post.json"; printf '{"id":77}\n'; exit 0
fi
case "$1 $2" in
  "api repos/"*"/hooks") printf '%s\n' "${QX_STUB_HOOK_ID:-}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/quetrex-api" "$STUB/gh"
NODE_DIR="$(dirname "$(command -v node)")"; GIT_BIN_DIR="$(dirname "$(command -v git)")"; JQ_DIR="$(dirname "$(command -v jq)")"
RUN_PATH="$STUB:$NODE_DIR:$GIT_BIN_DIR:$JQ_DIR:/usr/bin:/bin"

REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin git@github.com:Glori-Holdings/dealerq.git

run_block() {  # run_block <shell> <block-file> <log-dir> [env assignments...]
  local sh="$1" blk="$2" log="$3"; shift 3
  mkdir -p "$log"
  { printf 'REPO_ROOT=%q\nQX_KANBAN_URL=https://kanban.test\nQX_PROJECT_CODE=DEA\n' "$REPO"; cat "$blk"; } > "$log/run.sh"
  ( cd "$REPO" && env "$@" QX_LOG="$log" PATH="$RUN_PATH" "$sh" "$log/run.sh" 2>&1 )
}
put_field()  { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(j[process.argv[2]]||""))' "$1/put.json" "$2"; }
post_field() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((j.config||{})[process.argv[2]]||""))' "$1/post.json" "$2"; }

for SH in $SHELLS; do
  # --- AC2: empty vault -> generate, store, then register with the same value
  L="$WORK/gen-$SH"
  OUT="$(run_block "$SH" "$WORK/block.sh" "$L" QX_STUB_EXPORT='{}' QX_STUB_HOOK_ID=)"
  if [ -f "$L/put.json" ] && [ "$(put_field "$L" name)" = GITHUB_WEBHOOK_SECRET ] \
     && put_field "$L" value | grep -Eq '^[0-9a-f]{64}$'; then
    ok "AC2/$SH: (i) secret-put called with name GITHUB_WEBHOOK_SECRET and a 64-hex value"
  else
    notok "AC2/$SH: (i) secret-put not called as expected: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if [ -f "$L/post.json" ] && [ -f "$L/put.json" ] && [ "$(post_field "$L" secret)" = "$(put_field "$L" value)" ] \
     && [ "$(post_field "$L" url)" = https://kanban.test/api/webhooks/github ] \
     && printf '%s' "$OUT" | grep -q 'webhook: registered on Glori-Holdings/dealerq (id 77)'; then
    ok "AC2/$SH: (ii) gh api -X POST repos/<slug>/hooks carries the SAME value at the board's URL"
  else
    notok "AC2/$SH: (ii) POST payload wrong or missing: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  if [ -f "$L/put.json" ] && ! printf '%s' "$OUT" | grep -qF "$(put_field "$L" value)"; then
    ok "AC2/$SH: (iii) no output line contains the value"
  else
    notok "AC2/$SH: (iii) the generated value reached stdout/stderr"
  fi
  if printf '%s' "$OUT" | grep -q "generated GITHUB_WEBHOOK_SECRET and stored it in project DEA's vault"; then
    ok "AC2/$SH: the store is reported as one labelled line"
  else
    notok "AC2/$SH: no labelled store line: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi

  # --- AC3: store fails -> no POST; existing value reused; existing hook left alone
  L="$WORK/putfail-$SH"
  OUT="$(run_block "$SH" "$WORK/block.sh" "$L" QX_STUB_EXPORT='{}' QX_STUB_HOOK_ID= QX_STUB_PUT_RC=1)"
  if [ ! -f "$L/post.json" ] && printf '%s' "$OUT" | grep -q 'could not store GITHUB_WEBHOOK_SECRET' && printf '%s' "$OUT" | grep -q 'NOT registered'; then
    ok "AC3/$SH: secret-put failing -> gh POST never called, one labelled line"
  else
    notok "AC3/$SH: store-failure case wrong (post.json present=$([ -f "$L/post.json" ] && echo yes || echo no)): $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  L="$WORK/existing-$SH"
  OUT="$(run_block "$SH" "$WORK/block.sh" "$L" QX_STUB_EXPORT='{"GITHUB_WEBHOOK_SECRET":"marker_existing_value"}' QX_STUB_HOOK_ID=)"
  if [ ! -f "$L/put.json" ] && [ -f "$L/post.json" ] && [ "$(post_field "$L" secret)" = marker_existing_value ] \
     && ! printf '%s' "$OUT" | grep -q 'marker_existing_value'; then
    ok "AC3/$SH: an existing vault value is reused as-is (no secret-put), never printed"
  else
    notok "AC3/$SH: existing-value case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
  L="$WORK/already-$SH"
  OUT="$(run_block "$SH" "$WORK/block.sh" "$L" QX_STUB_EXPORT='{}' QX_STUB_HOOK_ID=4242)"
  if [ ! -f "$L/put.json" ] && [ ! -f "$L/post.json" ] && printf '%s' "$OUT" | grep -q 'already registered on Glori-Holdings/dealerq (id 4242) — left alone'; then
    ok "AC3/$SH: an already-registered hook is left alone (no secret-put, no POST)"
  else
    notok "AC3/$SH: already-registered case wrong: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
done

# --- AC4: fail-first against the pre-change sha ------------------------------
if git -C "$ROOT" cat-file -e "$BASE_SHA^{commit}" 2>/dev/null; then
  git -C "$ROOT" show "$BASE_SHA:plugins/quetrex-setup/commands/init.md" \
    | awk '/^## 4i\./{s=1} s && /^```bash/{f=1;next} s && f && /^```/{exit} s && f' > "$WORK/old-block.sh"
  # The old block called a bare `qapi` (a function inside quetrex-api, never on
  # the operator's PATH); route it to the stub so the comparison is fair.
  { printf 'qapi() { quetrex-api "$@"; }\n'; cat "$WORK/old-block.sh"; } > "$WORK/old-block-shimmed.sh"
  L="$WORK/old-bash"
  OUT="$(run_block bash "$WORK/old-block-shimmed.sh" "$L" QX_STUB_EXPORT='{}' QX_STUB_HOOK_ID=)"
  if [ -s "$WORK/old-block.sh" ] && printf '%s' "$OUT" | grep -q "no GITHUB_WEBHOOK_SECRET in project DEA's vault — skipped" \
     && [ ! -f "$L/put.json" ] && [ ! -f "$L/post.json" ]; then
    ok "AC4: FAIL-FIRST — $BASE_SHA's 4i prints the 'skipped' line and never calls secret-put or gh POST"
  else
    notok "AC4: $BASE_SHA's 4i did not behave as the pre-change baseline: $(printf '%s' "$OUT" | tr '\n' '|')"
  fi
else
  ok "AC4: (skipped) $BASE_SHA not present in this clone (shallow) — fail-first baseline unavailable"
fi

finish
