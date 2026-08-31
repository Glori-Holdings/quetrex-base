#!/usr/bin/env bash
# shipped-blocks-shell-portable.test.sh — a shipped exec block runs in the OPERATOR's shell.
#
# On macOS that is zsh, where an unquoted parameter is NOT word-split
# (SH_WORD_SPLIT is off by default). `set -- $VERSIONS` therefore assigned the
# whole "2.6.4 1.7.20 1.0.2" string to $1: /quetrex-setup:update misprinted its
# "Published:" line and then falsely announced "A newer engine is published" on a
# machine that was already on the latest. /quetrex-setup:login carried the exact
# same construct (`set -- $DEVICE_FIELDS`), which would have blanked every field
# after the first.
#
# Textual assertion 1 kills the CLASS. Assertions 2-4 EXECUTE the shipped blocks
# under bash, zsh and dash so the proof is behavioral, not a grep.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract fenced ```bash blocks from a markdown file.
extract_bash() {
  awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "$1"
}

# --- ASSERTION 1: no shipped command block word-splits an unquoted parameter ---
OFFENDERS=""
while IFS= read -r md; do
  blk="$(extract_bash "$md")"
  # `set -- $FOO` / `set -- $1` with no quotes: bash-only splitting.
  if printf '%s\n' "$blk" | grep -vE '^\s*#' | grep -qE '(^|;|\bthen\b|\bdo\b)\s*set --\s+\$[A-Za-z_{]'; then
    OFFENDERS="$OFFENDERS $md"
  fi
done < <(find "$ROOT/plugins" "$ROOT/.claude/commands" -name '*.md' -type f 2>/dev/null | sort)

if [ -z "$OFFENDERS" ]; then
  ok "no shipped command block relies on unquoted word splitting (set -- \$VAR)"
else
  notok "shipped blocks word-split an unquoted parameter:$OFFENDERS"
fi

# --- Harness: stub PATH for the update block ----------------------------------
mkdir -p "$TMP/bin"
cat > "$TMP/manifest.json" <<'JSON'
{"plugins":[{"name":"quetrex","version":"2.6.4"},
            {"name":"quetrex-factory","version":"1.7.20"},
            {"name":"quetrex-setup","version":"1.0.2"}]}
JSON
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
cat "$TMP/manifest.json"
EOF
cat > "$TMP/bin/quetrex-version" <<'EOF'
#!/usr/bin/env bash
echo "${STUB_RUNNING:-2.6.4}"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/quetrex-version"

extract_bash "$ROOT/plugins/quetrex-setup/commands/update.md" \
  | awk '/^RUNNING="\$\(quetrex-version/{on=1} on' > "$TMP/update-block.sh"
[ -s "$TMP/update-block.sh" ] || { notok "could not extract the update.md report block"; }

run_update() { # $1=shell  $2=running-version
  PATH="$TMP/bin:$PATH" STUB_RUNNING="$2" "$1" "$TMP/update-block.sh" 2>&1
}

# --- ASSERTION 2: the report is correct in EVERY shell, on the latest ---------
for sh_bin in bash zsh dash; do
  command -v "$sh_bin" >/dev/null 2>&1 || { ok "$sh_bin not present, skipped"; continue; }
  out="$(run_update "$sh_bin" 2.6.4)"
  if printf '%s' "$out" | grep -qF "Published: quetrex 2.6.4, quetrex-factory 1.7.20, quetrex-setup 1.0.2"; then
    ok "$sh_bin: Published line names all three versions separately"
  else
    notok "$sh_bin: Published line is wrong -> $(printf '%s' "$out" | tr '\n' '|')"
  fi
  if printf '%s' "$out" | grep -qF "This machine is on the latest engine."; then
    ok "$sh_bin: an up-to-date machine is NOT told a newer engine is published"
  else
    notok "$sh_bin: false 'newer engine' claim on a latest machine -> $(printf '%s' "$out" | tr '\n' '|')"
  fi
done

# --- ASSERTION 3: a genuinely stale machine still gets the restart line -------
for sh_bin in bash zsh dash; do
  command -v "$sh_bin" >/dev/null 2>&1 || continue
  out="$(run_update "$sh_bin" 2.6.0)"
  if printf '%s' "$out" | grep -qF "A newer engine is published"; then
    ok "$sh_bin: a stale machine IS told to restart"
  else
    notok "$sh_bin: stale machine got no restart line -> $(printf '%s' "$out" | tr '\n' '|')"
  fi
done

# --- ASSERTION 4: login.md's device-flow fields survive zsh -------------------
extract_bash "$ROOT/plugins/quetrex-setup/commands/login.md" \
  | awk '/^DEVICE_FIELDS="\$\(node -e/{on=1} on{print} /^  \|\| \{ echo "Unexpected device-flow response/{if(on)exit}' \
  > "$TMP/login-block.sh"

cat > "$TMP/login-pre.sh" <<'EOF'
START_BODY='{"deviceCode":"dc-123","userCode":"WXYZ-89","verificationUrl":"https://example.test/approve","intervalSeconds":7,"expiresInSeconds":900}'
EOF
printf 'echo "F=$DEVICE_CODE|$USER_CODE|$VERIFICATION_URL|$INTERVAL|$EXPIRES"\n' > "$TMP/login-post.sh"
cat "$TMP/login-pre.sh" "$TMP/login-block.sh" "$TMP/login-post.sh" > "$TMP/login-run.sh"

# `<<<` is a bash/zsh construct, so dash is out of scope for this one.
for sh_bin in bash zsh; do
  command -v "$sh_bin" >/dev/null 2>&1 || { ok "$sh_bin not present, skipped"; continue; }
  out="$("$sh_bin" "$TMP/login-run.sh" 2>&1)"
  if printf '%s' "$out" | grep -qF "F=dc-123|WXYZ-89|https://example.test/approve|7|900"; then
    ok "$sh_bin: all five device-flow fields parse individually"
  else
    notok "$sh_bin: device-flow fields collapsed -> $(printf '%s' "$out" | tr '\n' '|')"
  fi
done

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "shipped-blocks-shell-portable.test.sh: all checks passed"
else
  echo "shipped-blocks-shell-portable.test.sh: FAILURES above"
fi
exit "$FAIL"
