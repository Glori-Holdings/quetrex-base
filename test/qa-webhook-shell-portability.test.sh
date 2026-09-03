#!/usr/bin/env bash
# test/qa-webhook-shell-portability.test.sh — INDEPENDENT QA adversarial
# coverage for the doctor/init/quetrex-cloud-env change (7333ab0..HEAD).
# Written by QA, not the developer: a separate harness, separate stub bin,
# separate extraction of the shipped blocks, to catch what the developer's
# own tests might share a blind spot with.
#
# Run: bash test/qa-webhook-shell-portability.test.sh
#
#   AC1  STATIC SWEEP: every ```bash fence in doctor.md and init.md is free
#        of the two known bash-only-splits-under-zsh antipatterns —
#        `set -- $VAR` (unquoted, relies on bash word-splitting; zsh does
#        not split an unquoted $VAR by default) and a bare `$VAR:something`
#        (unbraced colon suffix, which zsh's history/modifier expansion can
#        read as a `:r`/`:h`/... modifier instead of literal text). This is
#        a sweep across EVERY block, not just the ones a developer thought
#        to hand-test.
#   AC2  INDEPENDENT re-proof that the qx_register_webhook mint path never
#        leaks the freshly generated secret to stdout/stderr, under both
#        bash and zsh, using a harness and stub bin/ this file owns (not
#        the developer's stub) so the assertion does not share a blind
#        spot with test/init-webhook-secret.test.sh.
#   AC3  doctor.md contains zero `AskUserQuestion` tokens — a regression
#        guard locking the "question-free" doctor claim.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCTOR_MD="$ROOT/plugins/quetrex-setup/commands/doctor.md"
INIT_MD="$ROOT/plugins/quetrex-setup/commands/init.md"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }
finish() { printf '\n%s\n' "qa-webhook-shell-portability.test.sh: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ] || exit 1; exit 0; }

[ -f "$DOCTOR_MD" ] || { echo "NOT OK - doctor.md not found at $DOCTOR_MD"; exit 1; }
[ -f "$INIT_MD" ]   || { echo "NOT OK - init.md not found at $INIT_MD"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
command -v jq   >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; exit 0; }
if command -v zsh >/dev/null 2>&1; then SHELLS="bash zsh"; else SHELLS="bash"; fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/qa-webhook-shell.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- AC1: static sweep over every shipped ```bash fence -----------------------
extract_fences() { awk '/^```bash/{f=1;next} /^```/{f=0} f' "$1"; }
for f in "$DOCTOR_MD" "$INIT_MD"; do
  extract_fences "$f" > "$WORK/fences.sh"
  BAD="$(grep -nE 'set[[:space:]]+--[[:space:]]+\$[A-Za-z_]|(^|[^{])\$[A-Za-z_][A-Za-z0-9_]*:[A-Za-z]' "$WORK/fences.sh" || true)"
  if [ -z "$BAD" ]; then
    ok "AC1: $(basename "$f") — no shipped bash fence has an unquoted 'set -- \$VAR' or a bare '\$VAR:letter' zsh-modifier collision"
  else
    notok "AC1: $(basename "$f") carries a bash-only-under-zsh antipattern: $(printf '%s' "$BAD" | tr '\n' '|')"
  fi
done

# --- AC2: independent re-proof of AC2(iii) in init-webhook-secret.test.sh ----
STUB="$WORK/stub-bin"; mkdir -p "$STUB"
cat > "$STUB/quetrex-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  POST) case "$2" in
          */secrets/export) printf '{}\n' ;;
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
      fs.writeFileSync(log+"/qa-captured-secret.txt", val);
    ' "$2" "$3" "$4" "$QA_LOG" || exit 1
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = api ] && [ "$2" = -X ] && [ "$3" = POST ]; then
  cat > /dev/null; printf '{"id":991}\n'; exit 0
fi
case "$1 $2" in
  "api repos/"*"/hooks") printf '\n' ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$STUB/quetrex-api" "$STUB/gh"
NODE_DIR="$(dirname "$(command -v node)")"; GIT_BIN_DIR="$(dirname "$(command -v git)")"; JQ_DIR="$(dirname "$(command -v jq)")"
RUN_PATH="$STUB:$NODE_DIR:$GIT_BIN_DIR:$JQ_DIR:/usr/bin:/bin"

REPO="$WORK/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" remote add origin git@github.com:Glori-Holdings/qa-portability.git

awk '
  $0 ~ /quetrex:exec-block qx_register_webhook([^A-Za-z0-9_]|$)/ && $0 !~ /end quetrex:exec-block/ { inb=1 }
  inb { print }
  $0 ~ /end quetrex:exec-block qx_register_webhook([^A-Za-z0-9_]|$)/ { inb=0 }
' "$INIT_MD" > "$WORK/block.sh"

if [ ! -s "$WORK/block.sh" ]; then
  notok "AC2: could not independently extract qx_register_webhook from init.md"
else
  for SH in $SHELLS; do
    L="$WORK/run-$SH"; mkdir -p "$L"
    { printf 'REPO_ROOT=%q\nQX_KANBAN_URL=https://qa.test\nQX_PROJECT_CODE=QAP\n' "$REPO"; cat "$WORK/block.sh"; } > "$L/run.sh"
    OUT="$(cd "$REPO" && env QA_LOG="$L" PATH="$RUN_PATH" "$SH" "$L/run.sh" 2>&1)"
    if [ -f "$L/qa-captured-secret.txt" ]; then
      SECRET="$(cat "$L/qa-captured-secret.txt")"
      if printf '%s' "$SECRET" | grep -Eq '^[0-9a-f]{64}$' && ! printf '%s' "$OUT" | grep -qF "$SECRET"; then
        ok "AC2/$SH: freshly-minted 64-hex secret captured independently and does NOT appear in the block's combined stdout+stderr"
      else
        notok "AC2/$SH: the minted secret leaked to output, or was not the expected shape: $(printf '%s' "$OUT" | tr '\n' '|')"
      fi
    else
      notok "AC2/$SH: independent harness never observed a secret-put call: $(printf '%s' "$OUT" | tr '\n' '|')"
    fi
  done
fi

# --- AC3: doctor.md is genuinely question-free --------------------------------
COUNT="$(grep -c 'AskUserQuestion' "$DOCTOR_MD" || true)"
if [ "${COUNT:-0}" -eq 0 ]; then
  ok "AC3: doctor.md contains zero AskUserQuestion tokens"
else
  notok "AC3: doctor.md contains $COUNT AskUserQuestion token(s) — doctor must stay question-free"
fi

finish
