#!/usr/bin/env bash
# test/init-cloud-env.test.sh — cloudEnvironmentId is DERIVED, by ONE shipped
# executable, instead of asked for.
#
# Run: bash test/init-cloud-env.test.sh
#
# WHY. A cloud routine needs an environment_id. Nothing set it, so the FIRST
# /quetrex:task-build on a freshly-bound repo stopped and printed a `node -e`
# one-liner asking the human to open claude.ai, find an env_… id in a URL, and
# paste it back. Every new partner stalled there. Arming a feature belongs in
# init, never in a failure message from the command that needed it.
#
# ONE COPY. The ranking used to be inline python inside init.md's step 3e.
# /quetrex-setup:doctor needed the identical logic for its Cloud-environment
# check, and two copies of a ranking function drift — so it is now
# plugins/quetrex-setup/bin/quetrex-cloud-env, and BOTH commands call it by
# name. This file drives THAT executable (the bytes that actually run) and
# asserts init.md no longer carries its own copy.
#
# THE FIXTURE IS REAL. test/fixtures/remote-triggers.json was captured from an
# actual `RemoteTrigger action:"list"` response (GET /v1/code/triggers, 20
# routines, 2026-08-28), with only the multi-KB prompt bodies removed. AC1 is a
# SHAPE ASSERTION against it: a hand-written fixture proves the fixture, not the
# code, so if the API ever moves environment_id or the repo sources, AC1 fails
# loudly rather than the derivation silently returning nothing.
#
# FAIL-FIRST (baseline pinned to a FIXED SHA, never `main`): against
# 7333ab07abecf95c3e699c528eb0abae79e078a6 there is no
# plugins/quetrex-setup/bin/quetrex-cloud-env at all, and init.md still
# carries the inline `qx_env_candidates()` python — AC0 and AC10 below both
# print NOT OK against that tree.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${QX_CLOUD_ENV_TOOL:-$ROOT/plugins/quetrex-setup/bin/quetrex-cloud-env}"
COMMAND="${QX_INIT_COMMAND:-$ROOT/plugins/quetrex-setup/commands/init.md}"
FIXTURE="$ROOT/test/fixtures/remote-triggers.json"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); printf 'ok - %s\n' "$1"; }
notok() { FAIL=$((FAIL+1)); printf 'NOT OK - %s\n' "$1"; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 unavailable"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node unavailable"; exit 0; }
[ -f "$COMMAND" ]  || { echo "NOT OK - init.md not found at $COMMAND"; exit 1; }
[ -f "$FIXTURE" ]  || { echo "NOT OK - fixture not found at $FIXTURE"; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/init-cloud-env.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- AC0: the shipped executable exists and parses --------------------------
if [ ! -f "$TOOL" ]; then
  notok "AC0: $TOOL does not exist — the derivation has no single shipped home"
  printf '\n%s\n' "init-cloud-env.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi
if ERR="$(bash -n "$TOOL" 2>&1)"; then
  ok "AC0: quetrex-cloud-env exists and parses"
else
  notok "AC0: quetrex-cloud-env is not valid shell: $ERR"
  printf '\n%s\n' "init-cloud-env.test.sh: $PASS passed, $FAIL failed"
  exit 1
fi

# A fixture repo per origin URL: `candidates` reads the origin off the repo
# itself (git remote get-url origin), exactly as init and doctor call it.
repo_for() {  # repo_for <origin-url> -> path
  local d="$WORK/repo-$(printf '%s' "$1" | shasum | cut -c1-10)"
  if [ ! -d "$d" ]; then
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" remote add origin "$1"
  fi
  printf '%s' "$d"
}
cand() {  # cand <origin-url> [json-file] [shell]
  local r; r="$(repo_for "$1")"
  "${3:-bash}" "$TOOL" candidates "$r" < "${2:-$FIXTURE}"
}

# --- AC1: SHAPE ASSERTION on the captured payload ----------------------------
# The two field paths the derivation depends on must still exist in a real
# response. If Anthropic moves either, this fails instead of the derivation
# quietly returning nothing and init falling back to "paste an id".
SHAPE=$(python3 - "$FIXTURE" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
rows = d.get("data") or []
envs = sum(1 for t in rows if ((t.get("job_config") or {}).get("ccr") or {}).get("environment_id"))
urls = sum(1 for t in rows
           if [s for s in ((((t.get("job_config") or {}).get("ccr") or {}).get("session_context") or {}).get("sources") or [])
               if ((s or {}).get("git_repository") or {}).get("url")])
print("%d %d %d" % (len(rows), envs, urls))
PY
)
read -r N_ROWS N_ENV N_URL <<< "$SHAPE"
if [ "${N_ROWS:-0}" -ge 20 ] && [ "${N_ENV:-0}" -ge 10 ] && [ "${N_URL:-0}" -ge 10 ]; then
  ok "AC1 shape: the captured payload still carries job_config.ccr.environment_id ($N_ENV/$N_ROWS) and session_context.sources[].git_repository.url ($N_URL/$N_ROWS)"
else
  notok "AC1 shape: the real-response field paths moved (rows=$N_ROWS env=$N_ENV url=$N_URL) — the derivation would silently find nothing"
fi

# --- AC2: this repo's environments are found, and marked `repo` --------------
OUT=$(cand "https://github.com/Glori-Holdings/quetrex-base")
N=$(printf '%s\n' "$OUT" | grep -c . || true)
REPO_N=$(printf '%s\n' "$OUT" | awk -F'\t' '$2=="repo"' | grep -c . || true)
if [ "$N" -eq 2 ] && [ "$REPO_N" -eq 2 ]; then
  ok "AC2: both environments that have run against quetrex-base are returned and marked 'repo'"
else
  notok "AC2: expected 2 candidates both marked repo, got $N candidates / $REPO_N repo: $(printf '%s' "$OUT" | tr '\n' ' ')"
fi

# --- AC3: distinct environments only, never one row per routine --------------
DUPES=$(printf '%s\n' "$OUT" | awk -F'\t' 'NF{print $1}' | sort | uniq -d | grep -c . || true)
if [ "$DUPES" -eq 0 ]; then
  ok "AC3: environments are de-duplicated — 20 routines collapse to distinct ids"
else
  notok "AC3: $DUPES environment id(s) repeated — the caller would ask about the same environment twice"
fi

# --- AC4: a repo used by exactly one environment resolves UNAMBIGUOUSLY ------
OUT3=$(cand "https://github.com/Glori-Holdings/quetrex-plugins")
ONLY=$(printf '%s\n' "$OUT3" | awk -F'\t' '$2=="repo"{print $1}')
if [ "$(printf '%s\n' "$ONLY" | grep -c .)" -eq 1 ] && [ "$ONLY" = "env_011CUpkAEM4fzsAD6dx1zW3r" ]; then
  ok "AC4: a repo with exactly one environment resolves to it unambiguously (no question asked)"
else
  notok "AC4: expected exactly one 'repo' environment for quetrex-plugins, got: $(printf '%s' "$ONLY" | tr '\n' ' ')"
fi

# --- AC5: repo-first ordering ------------------------------------------------
OUT4=$(cand "https://github.com/Someone-Else/never-seen")
OTHER_N=$(printf '%s\n' "$OUT4" | awk -F'\t' '$2=="other"' | grep -c . || true)
FIRST=$(printf '%s\n' "$OUT3" | head -1 | cut -f2)
if [ "$OTHER_N" -eq 2 ] && [ "$FIRST" = "repo" ]; then
  ok "AC5: an unknown repo still offers the account's 2 environments (as 'other'), and 'repo' sorts first when there is one"
else
  notok "AC5: ordering/fallback wrong — unknown-repo others=$OTHER_N, first row for a known repo='$FIRST'"
fi

# --- AC6: URL normalisation — SSH, .git, and trailing slash all match --------
NORM_OK=1
for U in \
  "git@github.com:Glori-Holdings/quetrex-plugins.git" \
  "https://github.com/Glori-Holdings/quetrex-plugins.git" \
  "https://github.com/Glori-Holdings/quetrex-plugins/" \
  "ssh://git@github.com/Glori-Holdings/quetrex-plugins" \
  "HTTPS://GitHub.com/Glori-Holdings/quetrex-plugins"; do
  G=$(cand "$U" | awk -F'\t' '$2=="repo"{print $1}')
  [ "$G" = "env_011CUpkAEM4fzsAD6dx1zW3r" ] || { NORM_OK=0; notok "AC6: '$U' did not match the https form (got '${G:-none}')"; }
done
[ "$NORM_OK" -eq 1 ] && ok "AC6: SSH, .git, trailing-slash, scheme and case variants of the origin URL all match the recorded https URL"

# --- AC7: the genuinely-new user — empty in, empty out, exit 0, no crash -----
NEW_OK=1
for BAD in '{"data":[]}' '{}' 'not json at all' '' '[]'; do
  printf '%s' "$BAD" > "$WORK/bad.json"
  R=$(cand "https://github.com/x/y" "$WORK/bad.json" 2>&1); RC=$?
  if [ "$RC" -ne 0 ] || [ -n "$R" ]; then
    NEW_OK=0; notok "AC7: input '${BAD:0:20}' gave rc=$RC out='$R' — expected clean empty output, exit 0, so a caller can fall back"
  fi
done
[ "$NEW_OK" -eq 1 ] && ok "AC7: no routines, malformed JSON, a non-object and empty input all yield empty output with exit 0 (init/doctor fall back, never crash)"

# --- AC8: a routine with no environment_id is skipped, not emitted as blank --
python3 - "$FIXTURE" "$WORK/partial.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for t in d["data"]:
    t.setdefault("job_config", {}).setdefault("ccr", {})["environment_id"] = None
json.dump(d, open(sys.argv[2], "w"))
PY
R=$(cand "https://github.com/Glori-Holdings/quetrex-base" "$WORK/partial.json")
if [ -z "$R" ]; then
  ok "AC8: routines carrying no environment_id are skipped entirely — never emitted as an empty candidate"
else
  notok "AC8: a null environment_id produced a candidate row: $(printf '%s' "$R" | tr '\n' ' ')"
fi

# --- AC9: task-build no longer tells the operator to hand-edit the binding ---
TB="${QX_TASK_BUILD_COMMAND:-$ROOT/.claude/commands/task-build.md}"
awk -v name="qx_cloud_env_id" '
  $0 ~ ("quetrex:exec-block " name "([^A-Za-z0-9_]|$)") && $0 !~ ("end quetrex:exec-block") { inb=1 }
  inb { print }
  $0 ~ ("end quetrex:exec-block " name "([^A-Za-z0-9_]|$)") { inb=0 }
' "$TB" > "$WORK/envblock.sh" 2>/dev/null
if [ ! -s "$WORK/envblock.sh" ]; then
  notok "AC9: could not extract qx_cloud_env_id from task-build.md"
elif grep -q 'node -e' "$WORK/envblock.sh"; then
  notok "AC9: the missing-environment message STILL prints a node -e one-liner for the operator to run by hand"
elif grep -q 'quetrex-setup:init' "$WORK/envblock.sh"; then
  ok "AC9: the missing-environment message sends the operator to /quetrex-setup:init and no longer prints a hand-run node -e"
else
  notok "AC9: the missing-environment message does not name /quetrex-setup:init"
fi

# --- AC10: ONE COPY — init.md calls the executable and carries no inline copy -
if grep -q 'job_config.ccr.environment_id' <(awk '/^```bash$/{inb=1;next} /^```$/{inb=0} inb' "$COMMAND") \
   || grep -qE '^[[:space:]]*qx_env_candidates\(\)' "$COMMAND" \
   || grep -q 'python3 -c' "$COMMAND"; then
  notok "AC10: init.md still carries an inline copy of the environment ranking (qx_env_candidates / python3) — two copies drift; the ONE copy is bin/quetrex-cloud-env"
else
  ok "AC10: init.md carries no inline ranking python — one copy, in bin/quetrex-cloud-env"
fi
if grep -q 'quetrex-cloud-env candidates "\$REPO_ROOT"' "$COMMAND" && grep -q 'quetrex-cloud-env set "\$REPO_ROOT"' "$COMMAND"; then
  ok "AC10: init.md step 3e derives with 'quetrex-cloud-env candidates' and writes with 'quetrex-cloud-env set'"
else
  notok "AC10: init.md step 3e does not call quetrex-cloud-env candidates/set by name"
fi
DOCTOR="${QX_DOCTOR_COMMAND:-$ROOT/plugins/quetrex-setup/commands/doctor.md}"
if [ -f "$DOCTOR" ] && grep -q 'quetrex-cloud-env candidates "\$REPO_ROOT"' "$DOCTOR"; then
  ok "AC10: doctor.md's Cloud environment check calls the SAME executable"
else
  notok "AC10: doctor.md does not call quetrex-cloud-env candidates (missing at $DOCTOR, or its own copy)"
fi

# --- AC11: `set` writes the field, preserves the rest, refuses garbage -------
SR="$WORK/set-repo"; mkdir -p "$SR/.quetrex"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({projectCode:"QDM",kanbanUrl:"https://dash.example",branchPrefix:"claude/"},null,2)+"\n")' "$SR/.quetrex/project.json"
SET_OUT="$("$TOOL" set "$SR" env_011CUpkAEM4fzsAD6dx1zW3r 2>&1)"; SET_RC=$?
GOT="$(node -e 'const o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")); process.stdout.write([o.cloudEnvironmentId,o.projectCode,o.kanbanUrl,o.branchPrefix].join("|"))' "$SR/.quetrex/project.json")"
if [ "$SET_RC" -eq 0 ] && [ "$GOT" = "env_011CUpkAEM4fzsAD6dx1zW3r|QDM|https://dash.example|claude/" ] && printf '%s' "$SET_OUT" | grep -q 'cloud environment: env_011CUpkAEM4fzsAD6dx1zW3r'; then
  ok "AC11: set writes cloudEnvironmentId and preserves every other binding field"
else
  notok "AC11: set rc=$SET_RC got='$GOT' out='$SET_OUT'"
fi
BEFORE="$(cat "$SR/.quetrex/project.json")"
if "$TOOL" set "$SR" 'not-an-id;rm -rf /' >/dev/null 2>&1; then
  notok "AC11: set accepted a non-env_ id"
elif [ "$(cat "$SR/.quetrex/project.json")" = "$BEFORE" ]; then
  ok "AC11: set refuses an id that is not env_<alnum> and leaves the binding untouched"
else
  notok "AC11: set refused the bad id but still changed the binding"
fi
NB="$WORK/no-binding"; mkdir -p "$NB"
if "$TOOL" set "$NB" env_abc >/dev/null 2>&1 || [ -e "$NB/.quetrex/project.json" ]; then
  notok "AC11: set created a binding where none existed — init owns creation"
else
  ok "AC11: set refuses to create a binding (no .quetrex/project.json → error, nothing written)"
fi

# --- AC12: identical output under zsh (the operator's shell) -----------------
if command -v zsh >/dev/null 2>&1; then
  Z="$(cand "https://github.com/Glori-Holdings/quetrex-plugins" "$FIXTURE" zsh)"
  if [ "$Z" = "$OUT3" ]; then
    ok "AC12: candidates prints byte-identical rows under zsh and bash"
  else
    notok "AC12: zsh output differs from bash: $(printf '%s' "$Z" | tr '\n' '|')"
  fi
else
  ok "AC12: zsh not present, skipped"
fi

printf '\n%s\n' "init-cloud-env.test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
