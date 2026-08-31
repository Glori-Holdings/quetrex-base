#!/usr/bin/env bash
# plugin-version-not-behind.test.sh — "with each fix, make sure the plugin is
# updated, including the version, so we don't end up with missing parts."
#
# THE MECHANISM THIS CLOSES. The marketplace manifest lives in a DIFFERENT repo
# (Glori-Holdings/quetrex-plugins) and carries its OWN `version` per plugin,
# pulling source out of this repo by `git-subdir`. `claude plugin update` reads
# the MARKETPLACE number, not this repo's plugin.json. So:
#
#   * bump plugin.json here and forget the marketplace -> the fix is merged, the
#     source is right, and NOBODY EVER RECEIVES IT. Silent, and invisible from
#     inside this repo.
#   * edit a plugin without bumping at all -> the marketplace serves new code
#     under an old number; a machine that already has that number never updates.
#
# Both happened: quetrex-setup sat at 1.0.1 in this repo while 1.0.2 was the
# published version — the two drifted in BOTH directions at once.
#
# ASSERTION 1 (offline, always runs): a plugin whose shipped files changed
# against origin/main must also change its version.
# ASSERTION 2 (network, skips cleanly when offline): this repo's version must
# never be BEHIND the published one. Ahead is fine — that is an unpublished
# fix waiting for scripts/publish-marketplace.sh. Behind means source and
# marketplace have diverged and someone is shipping blind.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0; FAIL=0
ok()    { PASS=$((PASS+1)); echo "ok - $1"; }
notok() { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
skip()  { PASS=$((PASS+1)); echo "ok - $1 (SKIPPED)"; }

MARKET_URL="https://raw.githubusercontent.com/Glori-Holdings/quetrex-plugins/main/.claude-plugin/marketplace.json"

# name|version|manifest-path|shipped-root  for every plugin this repo owns
plugins() {
  printf '%s\n' "$ROOT/.claude-plugin/plugin.json"
  find "$ROOT/plugins" -mindepth 3 -maxdepth 3 -path '*/.claude-plugin/plugin.json' 2>/dev/null | sort
}

ver_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("version",""))' "$1" 2>/dev/null; }
name_of() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("name",""))' "$1" 2>/dev/null; }

# semver compare: prints -1 / 0 / 1 for $1 vs $2
vcmp() {
  python3 - "$1" "$2" <<'PY'
import sys
def parse(v):
    return tuple(int(x) for x in v.split("-")[0].split(".")[:3])
a,b = parse(sys.argv[1]), parse(sys.argv[2])
print(-1 if a<b else (0 if a==b else 1))
PY
}

# --- ASSERTION 1: shipped files changed -> version changed -------------------
BASE="${QX_VERSION_BASE:-origin/main}"
if ! git -C "$ROOT" rev-parse --verify -q "$BASE" >/dev/null; then
  skip "no $BASE to diff against; bump-on-change check"
else
  while IFS= read -r manifest; do
    [ -f "$manifest" ] || continue
    pname="$(name_of "$manifest")"
    pdir="$(cd "$(dirname "$(dirname "$manifest")")" && pwd)"
    rel="${pdir#"$ROOT"/}"; [ "$pdir" = "$ROOT" ] && rel="."

    if [ "$rel" = "." ]; then
      # the root `quetrex` plugin ships .claude/commands + .claude/hooks + .claude/lib
      changed="$(git -C "$ROOT" diff --name-only "$BASE"...HEAD -- .claude/commands .claude/hooks .claude/lib .claude-plugin 2>/dev/null)"
    else
      changed="$(git -C "$ROOT" diff --name-only "$BASE"...HEAD -- "$rel" 2>/dev/null)"
    fi
    [ -n "$changed" ] || continue

    # did the version line itself move?
    vdiff="$(git -C "$ROOT" diff -U0 "$BASE"...HEAD -- "${manifest#"$ROOT"/}" 2>/dev/null | grep -E '^\+.*"version"' || true)"
    if [ -n "$vdiff" ]; then
      ok "$pname: shipped files changed AND the version was bumped to $(ver_of "$manifest")"
    else
      notok "$pname: shipped files changed against $BASE but plugin.json version is still $(ver_of "$manifest") — bump it, or the marketplace serves new code under an old number and installed machines never update. Changed: $(printf '%s' "$changed" | tr '\n' ' ')"
    fi
  done <<EOF
$(plugins)
EOF
  [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ] && ok "no shipped plugin files changed against $BASE"
fi

# --- ASSERTION 2: never BEHIND the published marketplace ---------------------
if ! MANIFEST="$(curl -fsS --max-time 10 "$MARKET_URL" 2>/dev/null)"; then
  skip "marketplace unreachable; published-version parity"
else
  while IFS= read -r manifest; do
    [ -f "$manifest" ] || continue
    pname="$(name_of "$manifest")"; local_v="$(ver_of "$manifest")"
    pub_v="$(printf '%s' "$MANIFEST" | python3 -c '
import json,sys
d=json.load(sys.stdin); n=sys.argv[1]
p=next((x for x in d.get("plugins",[]) if x.get("name")==n), None)
print(p.get("version","") if p else "")' "$pname" 2>/dev/null)"

    if [ -z "$pub_v" ]; then
      ok "$pname: not published in the marketplace yet — nothing to drift from"
      continue
    fi
    case "$(vcmp "$local_v" "$pub_v")" in
      -1) notok "$pname: this repo is BEHIND the marketplace (source $local_v < published $pub_v) — source and marketplace have diverged; whoever published $pub_v did not land it here." ;;
       0) ok "$pname: source $local_v == published $pub_v" ;;
       1) ok "$pname: source $local_v is ahead of published $pub_v — run scripts/publish-marketplace.sh after this merges" ;;
    esac
  done <<EOF
$(plugins)
EOF
fi

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then
  echo "plugin-version-not-behind.test.sh: all checks passed"
else
  echo "plugin-version-not-behind.test.sh: FAILURES above"
fi
exit "$FAIL"
