#!/usr/bin/env bash
# protected-files-guard.test.sh — proves G4 (HOOKFIX, .quetrex/plan/HOOKFIX.json)
# and its own correction 2: writes to the five safety-floor scripts are
# DENIED by default (never silently allowed, never merely "asked" — see
# CORRECTION 2 below for why), covering BOTH the Write/Edit vector and every
# Bash-mediated write vector named in the plan, while staying completely out
# of the way of unrelated files. It also carries the tokenizer anti-drift
# assertion (AC16) and the G5 CLAUDE.md non-regression assertion (AC17), per
# design.G3_tests.new_test_g4.
#
# EVERY ASSERTION DRIVES THE SHIPPED SCRIPT
# .claude/hooks/protected-files-guard.sh end to end via real PreToolUse
# payloads on stdin, and asserts on the emitted decision JSON.
#
# CORRECTION 2 (operator-approved, 2026-08-21): the ORIGINAL plan specified
# permissionDecision:"ask". That was replaced with "deny" (default) + an
# explicit QUETREX_UNLOCK_FLOOR=1 env-var unlock, because the Claude Code docs
# do not define what "ask" does when prompts are disabled — it may be
# silently ignored, which would make this guard look installed while gating
# nothing. This file asserts "deny", never "ask", and separately proves the
# unlock permits + records the write.
#
# AC13: Write/Edit on all 5 floor scripts, both path shapes -> DENY, never
#       silence, never a deny... (20 invocations).
# AC14: 11 write-shaped Bash commands -> DENY; 3 read-only controls -> silent.
# AC15: 4 unrelated targets -> silent.
# AC16: the copied tokenizer functions are byte-identical to merge-gate.sh's.
# AC17: the new G5 CLAUDE.md block does not change what resolve_from_claude_md
#       resolves.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${QX_PROTECTED_FILES_GUARD_HOOK:-$ROOT/.claude/hooks/protected-files-guard.sh}"
VERIFY_HOOK="${QX_VERIFY_GATE_HOOK:-$ROOT/.claude/hooks/verify-gate.sh}"
MERGE_HOOK="$ROOT/.claude/hooks/merge-gate.sh"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq unavailable"; echo; echo "protected-files-guard.test.sh: $PASS passed, $FAIL failed"; exit 0; }

if [ ! -f "$GUARD" ]; then
  echo "NOT OK - protected-files-guard.sh not found at $GUARD"
  echo
  echo "protected-files-guard.test.sh: 0 passed, 1 failed"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
NAMES="deny-guard secret-scan enforce-branch merge-gate verify-gate"

fire() { printf '%s' "$1" | bash "$GUARD" 2>&1; }
is_deny() { printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; }
is_ask()  { printf '%s' "$1" | grep -q '"permissionDecision":"ask"'; }
decision_count() { printf '%s' "$1" | grep -c 'permissionDecision'; }

# =============================================================================
# AC13 — Write/Edit on all 5 floor scripts, both path shapes -> DENY.
# =============================================================================
DENY13=0; ASK13=0; TOTAL13=0
for name in $NAMES; do
  for shape in "$TMP/repo/.claude/hooks/${name}.sh" "$TMP/plugin-root/scripts/${name}.sh"; do
    for tool in Write Edit; do
      TOTAL13=$((TOTAL13+1))
      OUT="$(fire "$(jq -cn --arg t "$tool" --arg p "$shape" '{tool_name:$t,tool_input:{file_path:$p}}')")"
      if is_deny "$OUT"; then DENY13=$((DENY13+1)); fi
      if is_ask "$OUT"; then ASK13=$((ASK13+1)); fi
      printf '%s' "$OUT" | grep -q "$shape" \
        || notok "AC13: reason does not name the offending path for $tool $shape [$OUT]"
    done
  done
done
[ "$TOTAL13" -eq 20 ] && ok "AC13: exercised all 20 combinations (5 names x 2 path shapes x Write|Edit)" \
  || notok "AC13: expected 20 combinations, computed $TOTAL13"
[ "$DENY13" -eq 20 ] && ok "AC13: 20 of 20 invocations emit permissionDecision:\"deny\"" \
  || notok "AC13: expected 20 deny decisions, got $DENY13"
[ "$ASK13" -eq 0 ] && ok "AC13: 0 of 20 invocations emit permissionDecision:\"ask\" (CORRECTION 2 — deny, never ask)" \
  || notok "AC13: expected 0 ask decisions, got $ASK13"

# =============================================================================
# AC14 — write-shaped Bash commands -> DENY; read-only controls -> silent.
# =============================================================================
TARGET14="$TMP/repo/.claude/hooks/verify-gate.sh"
WRITE_CMDS=(
  "cp /tmp/x $TARGET14"
  "mv /tmp/x $TARGET14"
  "install -m 0755 /tmp/x $TARGET14"
  "rsync -a /tmp/x $TARGET14"
  "tee $TARGET14 < /tmp/x"
  "sed -i s/a/b/ $TARGET14"
  "echo bad > $TARGET14"
  "echo bad >> $TARGET14"
  "sudo cp /tmp/x $TARGET14"
  "bash -c 'cp /tmp/x $TARGET14'"
  "echo hi && cp /tmp/x $TARGET14"
)
DENY14=0
for cmd in "${WRITE_CMDS[@]}"; do
  OUT="$(fire "$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')")"
  if is_deny "$OUT"; then DENY14=$((DENY14+1)); else echo "# AC14 miss: [$cmd] -> [$OUT]"; fi
done
[ "$DENY14" -eq 11 ] && ok "AC14: 11 of 11 write-shaped Bash commands produce exactly a deny decision" \
  || notok "AC14: expected 11 deny decisions, got $DENY14"

READONLY_CMDS=("cat $TARGET14" "grep foo $TARGET14" "shasum -a 256 $TARGET14")
SILENT14=0
for cmd in "${READONLY_CMDS[@]}"; do
  OUT="$(fire "$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')")"
  BYTES=$(printf '%s' "$OUT" | wc -c | tr -d ' ')
  if [ "$BYTES" -eq 0 ]; then SILENT14=$((SILENT14+1)); else echo "# AC14 read-only miss: [$cmd] -> [$OUT]"; fi
done
[ "$SILENT14" -eq 3 ] && ok "AC14: 0 of 3 read-only controls (cat, grep, shasum -a 256) produce any decision" \
  || notok "AC14: expected 3 of 3 read-only controls silent, got $SILENT14"

# =============================================================================
# AC15 — 4 unrelated targets -> silent (0 bytes, 0 decisions).
# =============================================================================
SILENT15=0
check15() {  # check15 <label> <payload>
  local label="$1" payload="$2" out bytes
  out="$(fire "$payload")"
  bytes=$(printf '%s' "$out" | wc -c | tr -d ' ')
  if [ "$bytes" -eq 0 ]; then
    SILENT15=$((SILENT15+1))
  else
    echo "# AC15 miss ($label): [$out]"
  fi
}
check15 "src/app.ts Write" "$(jq -cn '{tool_name:"Write",tool_input:{file_path:"src/app.ts"}}')"
check15 "README.md Edit" "$(jq -cn '{tool_name:"Edit",tool_input:{file_path:"README.md"}}')"
check15 "session-state.sh Write (not part of the floor)" \
  "$(jq -cn '{tool_name:"Write",tool_input:{file_path:".claude/hooks/session-state.sh"}}')"
check15 "cp notes.txt /tmp/notes.txt" \
  "$(jq -cn '{tool_name:"Bash",tool_input:{command:"cp notes.txt /tmp/notes.txt"}}')"
[ "$SILENT15" -eq 4 ] && ok "AC15: 4 of 4 unrelated targets are completely silent (0 bytes, 0 decisions)" \
  || notok "AC15: expected 4 of 4 silent, got $SILENT15"

# =============================================================================
# AC16 — the copied tokenizer (split_segments_quote_aware, normalize_segment)
# is byte-identical to merge-gate.sh's own copy, extracted by function-name
# boundary from BOTH files. A 0-byte extraction is a FAIL, not a vacuous pass.
# =============================================================================
extract_fn() {  # extract_fn <file> <fn-name>
  awk -v fn="$2" '
    $0 ~ ("^" fn "\\(\\) \\{$") { on=1 }
    on { print }
    on && /^}$/ { exit }
  ' "$1"
}
for fn in split_segments_quote_aware normalize_segment; do
  extract_fn "$MERGE_HOOK" "$fn" > "$TMP/mg_$fn.txt"
  extract_fn "$GUARD" "$fn" > "$TMP/pg_$fn.txt"
  MGN=$(wc -l < "$TMP/mg_$fn.txt" | tr -d ' ')
  PGN=$(wc -l < "$TMP/pg_$fn.txt" | tr -d ' ')
  if [ "$MGN" -eq 0 ] || [ "$PGN" -eq 0 ]; then
    notok "AC16: extraction of $fn found an EMPTY region (merge-gate.sh: $MGN lines, protected-files-guard.sh: $PGN lines) — a 0-byte extraction is a FAIL"
    continue
  fi
  ok "AC16: extracted a non-empty $fn from both files (merge-gate.sh: $MGN lines, protected-files-guard.sh: $PGN lines)"
  DIFFLINES=$(diff "$TMP/mg_$fn.txt" "$TMP/pg_$fn.txt" | grep -c . || true)
  [ "${DIFFLINES:-0}" -eq 0 ] \
    && ok "AC16: $fn is byte-identical between merge-gate.sh and protected-files-guard.sh (diff produces 0 lines)" \
    || notok "AC16: $fn DIFFERS between merge-gate.sh and protected-files-guard.sh ($DIFFLINES diff line(s)) — the copy has drifted from its source of truth"
done

# =============================================================================
# AC17 — the new G5 CLAUDE.md block does not change what
# resolve_from_claude_md resolves. A fixture repo with NO .quetrex/verify.json
# forces the CLAUDE.md fallback; QUETREX_VERIFY_FULL=1 forces the full chain
# so the fixture's own "npm test" is not filtered as heavy.
# =============================================================================
F17="$TMP/ac17"
mkdir -p "$F17/.claude" "$F17/fakebin"
git -C "$F17" init -q -b main 2>/dev/null || git -C "$F17" init -q 2>/dev/null
git -C "$F17" config user.email t@t; git -C "$F17" config user.name t
cp "$ROOT/.claude/CLAUDE.md" "$F17/.claude/CLAUDE.md"
git -C "$F17" add -A; git -C "$F17" commit -qm init

# A `npm` shim on PATH so all 4 "## Verification" commands genuinely RUN and
# succeed in this bare fixture (which has no real package.json/node_modules
# of its own) — the point of AC17 is proving the CHAIN RESOLUTION is
# unaffected by the new CLAUDE.md block, not re-proving this repo's own
# scripts, and a real npm ENOENT here would stop the chain after 1 command.
cat > "$F17/fakebin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$F17/fakebin/npm"

BLOCK_TEXT="$(awk '/^# quetrex-base$/{exit} {print}' "$F17/.claude/CLAUDE.md")"
BLOCK_LINES=$(printf '%s\n' "$BLOCK_TEXT" | grep -c .)
[ "$BLOCK_LINES" -le 8 ] && ok "AC17: the new block above '# quetrex-base' is <= 8 lines ($BLOCK_LINES)" \
  || notok "AC17: the new block is $BLOCK_LINES lines, expected <= 8"
printf '%s' "$BLOCK_TEXT" | grep -qE '^[[:space:]]*```' \
  && notok "AC17: the new block contains a fenced-code marker" \
  || ok "AC17: the new block contains 0 fenced-code markers"

OUT17="$(printf '{"hook_event_name":"Stop","cwd":"%s"}' "$F17" \
  | ( cd "$F17" && CLAUDE_PROJECT_DIR="$F17" QUETREX_VERIFY_FULL=1 PATH="$F17/fakebin:$PATH" bash "$VERIFY_HOOK" 2>&1 ) )"
CODE17=$?
for cmd in "npm run check:js" "npm run check:sh" "npm run check:json" "npm test"; do
  n=$(jq -s --arg c "$cmd" '[.[] | select(.cmd==$c)] | length' "$F17/.quetrex/verify-ledger.jsonl" 2>/dev/null)
  [ "$n" = "1" ] && ok "AC17: exactly 1 ledger line for \`$cmd\`" \
    || notok "AC17: expected exactly 1 ledger line for \`$cmd\`, got $n (hook exit $CODE17, out: [$OUT17])"
done
OTHER17=$(jq -s --argjson known 4 '
  ([.[] | .cmd] | unique) as $u | ($u | length)
' "$F17/.quetrex/verify-ledger.jsonl" 2>/dev/null)
[ "$OTHER17" = "4" ] && ok "AC17: the ledger names exactly 4 distinct commands total (0 for anything else)" \
  || notok "AC17: expected exactly 4 distinct commands in the ledger, got $OTHER17"

# =============================================================================
# CORRECTION 2 — the QUETREX_UNLOCK_FLOOR=1 unlock permits the write and
# records it (never silent).
# =============================================================================
REPO_UNLOCK="$TMP/repo-unlock"
mkdir -p "$REPO_UNLOCK/.claude/hooks"
git -C "$REPO_UNLOCK" init -q -b main 2>/dev/null || git -C "$REPO_UNLOCK" init -q 2>/dev/null
git -C "$REPO_UNLOCK" config user.email t@t; git -C "$REPO_UNLOCK" config user.name t
git -C "$REPO_UNLOCK" commit -q --allow-empty -m init

OUT_UNLOCK="$(printf '%s' "$(jq -cn --arg p "$REPO_UNLOCK/.claude/hooks/verify-gate.sh" --arg cwd "$REPO_UNLOCK" \
  '{tool_name:"Write",tool_input:{file_path:$p},cwd:$cwd}')" \
  | CLAUDE_PROJECT_DIR="$REPO_UNLOCK" QUETREX_UNLOCK_FLOOR=1 bash "$GUARD" 2>&1)"

printf '%s' "$OUT_UNLOCK" | grep -q '"permissionDecision":"allow"' \
  && ok "CORRECTION 2: QUETREX_UNLOCK_FLOOR=1 permits the write (permissionDecision:\"allow\")" \
  || notok "CORRECTION 2: QUETREX_UNLOCK_FLOOR=1 did not permit the write [$OUT_UNLOCK]"
printf '%s' "$OUT_UNLOCK" | grep -q '"permissionDecision":"deny"' \
  && notok "CORRECTION 2: the unlocked write was still denied [$OUT_UNLOCK]" \
  || ok "CORRECTION 2: the unlocked write is not denied"
[ -f "$REPO_UNLOCK/.quetrex/protected-files-unlock.log" ] \
  && ok "CORRECTION 2: the unlock is RECORDED in .quetrex/protected-files-unlock.log (never silent)" \
  || notok "CORRECTION 2: no unlock record was written"

# --- unlock does NOT apply without the env var (default stays denied) ------
OUT_STILL_DENIED="$(printf '%s' "$(jq -cn --arg p "$REPO_UNLOCK/.claude/hooks/verify-gate.sh" --arg cwd "$REPO_UNLOCK" \
  '{tool_name:"Write",tool_input:{file_path:$p},cwd:$cwd}')" \
  | CLAUDE_PROJECT_DIR="$REPO_UNLOCK" bash "$GUARD" 2>&1)"
is_deny "$OUT_STILL_DENIED" \
  && ok "CORRECTION 2: without QUETREX_UNLOCK_FLOOR=1, the same write is denied by default" \
  || notok "CORRECTION 2: expected a deny without the unlock env var [$OUT_STILL_DENIED]"

# =============================================================================
# SEC-7 / SEC-4 (security review, 2026-08-21): the write-detection must key
# ONLY on the actual write DESTINATION, never on a protected path appearing
# as a READ argument anywhere else in the same command; and several
# additional write vectors (git checkout/restore, curl -o, patch, inline
# interpreter writes, ./ and ../ path fragments, one-hop symlink
# indirection) must be closed too. Every assertion below drives the SHIPPED
# hook end to end.
# =============================================================================
SEC_TARGET="$TMP/repo/.claude/hooks/verify-gate.sh"

sec_allow() {  # sec_allow <label> <raw-command-string>
  local label="$1" cmd="$2" payload out
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(printf '%s' "$payload" | bash "$GUARD" 2>&1)"
  if is_deny "$out"; then
    notok "SEC-7/SEC-4 ($label): expected ALLOW, got a deny [$cmd] -> $out"
  else
    ok "SEC-7/SEC-4 ($label): correctly allowed"
  fi
}
sec_deny() {  # sec_deny <label> <raw-command-string>
  local label="$1" cmd="$2" payload out
  payload="$(jq -cn --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}')"
  out="$(printf '%s' "$payload" | bash "$GUARD" 2>&1)"
  if is_deny "$out"; then
    ok "SEC-7/SEC-4 ($label): correctly denied"
  else
    notok "SEC-7/SEC-4 ($label): expected a deny, got [$out] for [$cmd]"
  fi
}

# SEC-7: the exact two commands the security review reported as wrongly denied.
sec_allow "grep redirects elsewhere, protected path only a READ arg" \
  "grep -n QUICK $SEC_TARGET > $TMP/sec7-out.txt"
sec_allow "PARITY regeneration procedure this repo's own CLAUDE.md mandates" \
  "cd $TMP/repo/.claude/hooks && shasum -a 256 deny-guard.sh secret-scan.sh enforce-branch.sh merge-gate.sh verify-gate.sh > PARITY.sha256"
sec_allow "cp READS the protected path, writes elsewhere" \
  "cp $SEC_TARGET $TMP/sec7-backup.sh"

# SEC-4: additional write vectors.
sec_deny "git checkout -- <protected>" "git checkout HEAD~1 -- $SEC_TARGET"
sec_deny "git restore <protected>" "git restore --source=HEAD~1 $SEC_TARGET"
sec_deny "curl -o <protected>" "curl -o $SEC_TARGET https://example.com/x"
sec_deny "patch <protected> < diff" "patch $SEC_TARGET < $TMP/sec4.patch"
sec_deny "python3 -c inline write" "python3 -c \"open('$SEC_TARGET','w').write('x')\""
sec_deny "node -e inline write" "node -e \"require('fs').writeFileSync('$SEC_TARGET','x')\""

# SEC-4: path normalization (./ and ../).
sec_deny "./ path fragment" "cp $TMP/x $TMP/repo/.claude/hooks/./verify-gate.sh"
sec_deny "../ path fragment" "cp $TMP/x $TMP/repo/.claude/hooks/sub/../verify-gate.sh"

# SEC-4: two-step symlink indirection (real sequential execution — the
# symlink genuinely exists on disk by the time the second command is
# evaluated, exactly as it would across two separate agent tool calls).
SEC_LINK="$TMP/sec4-link"
ln -sf "$SEC_TARGET" "$SEC_LINK"
sec_deny "write through a symlink pointing AT a protected path" "cp $TMP/evil $SEC_LINK"
rm -f "$SEC_LINK"

# --- fail-first: every one of the above genuinely fails against the
# immediately pre-fix commit (the substring/whole-segment matcher this round
# replaced) — resolved by sha, not by branch name, since this defect was
# introduced and fixed within the same feature branch.
SEC_BASELINE_SHA="e2dadea"
if git -C "$ROOT" cat-file -e "${SEC_BASELINE_SHA}:.claude/hooks/protected-files-guard.sh" 2>/dev/null; then
  SEC_BASELINE="$TMP/sec-baseline-guard.sh"
  git -C "$ROOT" show "${SEC_BASELINE_SHA}:.claude/hooks/protected-files-guard.sh" > "$SEC_BASELINE"
  BASE_PAYLOAD="$(jq -cn --arg c "grep -n QUICK $SEC_TARGET > $TMP/sec7-basecheck.txt" '{tool_name:"Bash",tool_input:{command:$c}}')"
  BASE_OUT="$(printf '%s' "$BASE_PAYLOAD" | bash "$SEC_BASELINE" 2>&1)"
  if is_deny "$BASE_OUT"; then
    ok "SEC-7 FAIL-FIRST: the pre-fix guard (commit ${SEC_BASELINE_SHA}) DID wrongly deny the grep-redirect-elsewhere command — proving this is a genuine, deliberate fix"
  else
    notok "SEC-7 FAIL-FIRST: the pre-fix guard did not deny the grep case either (out: [$BASE_OUT]) — cannot demonstrate the fix is real"
  fi
else
  echo "SKIP: commit ${SEC_BASELINE_SHA} not reachable — SEC-7 fail-first proof could not run"
fi

# =============================================================================
# SEC-13 (security review at 4bd824f, 2026-08-21): the SEC-7 destination-only
# fix opened two vectors it had not existed for. (a) a DIRECTORY destination
# for cp/mv/install/rsync puts the protected basename only in the SOURCE
# token, which destination-only checking deliberately ignores. (b) numbered
# and clobber redirection tokens (1>, 2>, &>, >|, >>, and the exec N> /
# >&N fd-duplication pair) matched neither the bare '>' nor '>>' the scanner
# recognized. Both allowed before this fix; every case below drives the
# SHIPPED hook end to end. The SEC-7 property this must NOT regress -- a
# protected path as a pure READ argument still allows -- is re-asserted at
# the end of this section.
# =============================================================================
# SEC13_DIR MUST be a real ".../hooks" path segment (not merely containing
# the substring "hooks") -- names_protected_path's PROT_PATH_ERE requires
# "hooks" or "scripts" as its OWN path segment, exactly the real vector
# shape (`.claude/hooks/` / plugin `scripts/`), same directory SEC_TARGET
# already lives in.
SEC13_DIR="$(dirname "$SEC_TARGET")"
mkdir -p "$SEC13_DIR"
SEC13_TARGET_NOSLASH="$SEC13_DIR"
SEC13_TARGET_SLASH="$SEC13_DIR/"

# (a) directory-destination form, the exact shape reported: source basename
# is the ONLY place the protected name appears; destination is a directory.
sec_deny "cp SOURCE to directory dest, trailing slash" \
  "cp /tmp/hooks/verify-gate.sh $SEC13_TARGET_SLASH"
sec_deny "cp SOURCE to EXISTING directory dest, no trailing slash" \
  "cp /tmp/hooks/verify-gate.sh $SEC13_TARGET_NOSLASH"
sec_deny "mv SOURCE to directory dest" "mv /tmp/hooks/verify-gate.sh $SEC13_TARGET_SLASH"
sec_deny "install SOURCE to directory dest" "install -m 0755 /tmp/hooks/verify-gate.sh $SEC13_TARGET_SLASH"
sec_deny "rsync SOURCE to directory dest" "rsync -a /tmp/hooks/verify-gate.sh $SEC13_TARGET_SLASH"
sec_allow "cp UNRELATED source basename to directory dest" \
  "cp /tmp/hooks/readme.md $SEC13_TARGET_SLASH"
sec_allow "cp SOURCE to a NON-existent dir with no trailing slash (not a directory form)" \
  "cp /tmp/hooks/verify-gate.sh $TMP/sec13-does-not-exist"

# (b) numbered / clobber redirection tokens.
sec_deny "1> numbered stdout redirect" "cat /tmp/evil 1> $SEC_TARGET"
sec_deny "2> numbered stderr redirect" "cat /tmp/evil 2> $SEC_TARGET"
sec_deny "&> both-streams redirect" "cat /tmp/evil &> $SEC_TARGET"
sec_deny "&>> both-streams append redirect" "cat /tmp/evil &>> $SEC_TARGET"
sec_deny "1>> numbered append redirect" "cat /tmp/evil 1>> $SEC_TARGET"
sec_deny ">| noclobber-override redirect" "cat /tmp/evil >| $SEC_TARGET"
sec_deny "1>| numbered noclobber-override redirect" "cat /tmp/evil 1>| $SEC_TARGET"

# (b) exec N> path / echo x >&N -- the fd-binding pair QA identified as
# sharing the SAME root cause as the bare numbered tokens above.
SEC13_EXEC_CMD="$(printf 'exec 3> %s\necho x >&3' "$SEC_TARGET")"
sec_deny "exec 3> <protected>; echo x >&3 (fd bound to a protected path)" "$SEC13_EXEC_CMD"
SEC13_EXEC_UNRELATED="$(printf 'exec 3> %s/unrelated.txt\necho x >&3' "$TMP")"
sec_allow "exec 3> <unrelated>; echo x >&3 (fd bound to a NON-protected path)" "$SEC13_EXEC_UNRELATED"

# SEC-7 property re-asserted: a protected path as a pure READ argument, with
# the write elsewhere, must still allow after this section's changes.
sec_allow "SEC-7 non-regression: grep reads the protected path, writes elsewhere" \
  "grep -n QUICK $SEC_TARGET > $TMP/sec13-readonly-check.txt"

# --- SEC-13 FAIL-FIRST: every assertion above genuinely fails against the
# immediately pre-fix commit (4bd824f, before this round's directory-
# destination and numbered/clobber-redirection handling landed).
SEC13_BASELINE_SHA="4bd824f"
if git -C "$ROOT" cat-file -e "${SEC13_BASELINE_SHA}:.claude/hooks/protected-files-guard.sh" 2>/dev/null; then
  SEC13_BASELINE="$TMP/sec13-baseline-guard.sh"
  git -C "$ROOT" show "${SEC13_BASELINE_SHA}:.claude/hooks/protected-files-guard.sh" > "$SEC13_BASELINE"
  SEC13_BASE_DIR_PAYLOAD="$(jq -cn --arg c "cp /tmp/hooks/verify-gate.sh $SEC13_TARGET_SLASH" '{tool_name:"Bash",tool_input:{command:$c}}')"
  SEC13_BASE_DIR_OUT="$(printf '%s' "$SEC13_BASE_DIR_PAYLOAD" | bash "$SEC13_BASELINE" 2>&1)"
  SEC13_BASE_1G_PAYLOAD="$(jq -cn --arg c "cat /tmp/evil 1> $SEC_TARGET" '{tool_name:"Bash",tool_input:{command:$c}}')"
  SEC13_BASE_1G_OUT="$(printf '%s' "$SEC13_BASE_1G_PAYLOAD" | bash "$SEC13_BASELINE" 2>&1)"
  if is_deny "$SEC13_BASE_DIR_OUT" || is_deny "$SEC13_BASE_1G_OUT"; then
    notok "SEC-13 FAIL-FIRST: the pre-fix baseline ($SEC13_BASELINE_SHA) unexpectedly already denies (dir: [$SEC13_BASE_DIR_OUT], 1>: [$SEC13_BASE_1G_OUT]) — cannot demonstrate either fix is real"
  else
    ok "SEC-13 FAIL-FIRST: the pre-fix baseline ($SEC13_BASELINE_SHA) WRONGLY ALLOWS both the directory-destination cp and the 1> numbered redirect — proving both closures are genuine, deliberate fixes"
  fi
else
  echo "SKIP: commit ${SEC13_BASELINE_SHA} not reachable — SEC-13 fail-first proof could not run"
fi

# =============================================================================
# AC11 — FAIL-FIRST: protected-files-guard.sh does not exist on the
# pre-change baseline, and NO existing hook on main intercepts this vector.
# =============================================================================
if git -C "$ROOT" show origin/main:.claude/hooks/protected-files-guard.sh >/dev/null 2>&1; then
  notok "AC11 FAIL-FIRST: protected-files-guard.sh unexpectedly EXISTS at origin/main"
elif git -C "$ROOT" show main:.claude/hooks/protected-files-guard.sh >/dev/null 2>&1; then
  notok "AC11 FAIL-FIRST: protected-files-guard.sh unexpectedly EXISTS at main"
else
  ok "AC11 FAIL-FIRST: protected-files-guard.sh does not exist at origin/main or main — this is new machinery"
fi

DENY_GUARD="$ROOT/.claude/hooks/deny-guard.sh"
SECRET_SCAN="$ROOT/.claude/hooks/secret-scan.sh"
BASELINE_HITS=0
PAYLOAD_AC13="$(jq -cn '{tool_name:"Write",tool_input:{file_path:".claude/hooks/verify-gate.sh"}}')"
for existing in "$DENY_GUARD" "$SECRET_SCAN"; do
  [ -f "$existing" ] || continue
  OUT_EXIST="$(printf '%s' "$PAYLOAD_AC13" | bash "$existing" 2>&1)"
  D=$(decision_count "$OUT_EXIST")
  BASELINE_HITS=$((BASELINE_HITS+D))
done
[ "$BASELINE_HITS" -eq 0 ] \
  && ok "AC11 FAIL-FIRST: 0 decisions from any existing main hook (deny-guard.sh, secret-scan.sh) for the AC13 Write-to-floor-script fixture — no pre-change mechanism intercepts this vector" \
  || notok "AC11 FAIL-FIRST: an existing hook already emitted $BASELINE_HITS decision(s) for this fixture — cannot demonstrate this is a new control"

echo
echo "protected-files-guard.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
