#!/usr/bin/env bash
# test/onboarding-doc.test.sh — the onboarding guide must describe THIS
# product, not the one it replaced.
#
# Run: bash test/onboarding-doc.test.sh
#
# WHY THIS FILE EXISTS. The only prose onboarding artifact anywhere in the
# plugin family shipped from the PUBLIC marketplace repo
# (Glori-Holdings/quetrex-plugins, docs/onboarding/quetrex-onboarding.html)
# and contradicted the current product on every load-bearing point. Verified
# by extracting its text, not by reading around it:
#
#   - its checked-in .claude/settings.json example enabled
#     quetrex-factory@quetrex and quetrex-nextjs@quetrex but NOT
#     quetrex@quetrex, so a reader who copied it got ZERO /quetrex:*
#     commands — no login, no init, no build;
#   - the same snippet's extraKnownMarketplaces entry had no autoUpdate key,
#     which freezes a third-party marketplace catalog so a published fix
#     never reaches anyone (bin/quetrex-arm calls this required, and
#     /quetrex:doctor Check 2 fails a repo for exactly it);
#   - it said the marketplace is private; it is public, deliberately, so a
#     credential-less cloud routine can install the engine;
#   - it taught the retired unprefixed npm-era command names and told the
#     reader no Quetrex update command exists;
#   - and §1/§2/§6 sold bring-your-own compute over Tailscale + ssh to an
#     always-on box: a human sitting at a terminal watching an agent type,
#     which is the exact workflow Quetrex exists to replace.
#
# So the assertions below are not style checks. Each REQUIRED string is a
# load-bearing fact about how work actually moves (routine-fired kanban,
# scope approved from a phone, build on Anthropic's cloud, gated merge,
# manual deploy, booleans-not-pins), and each FORBIDDEN string is a claim
# that was measured to be false or a depiction of the replaced workflow.
#
# EVERY ASSERTION IS PROVEN ABLE TO FAIL. Phase 2 deletes each required
# string from a scratch copy and re-scans; phase 3 injects each forbidden
# string into a scratch copy and re-scans. A phase-1 pass over a document
# nobody proved the scanner could reject would be worthless.
#
# The document lives in THIS repo (the engine repo the `quetrex` plugin
# ships from) because that is where it can be gated. Publishing it to the
# marketplace repo is a separate copy step, exactly like the safety-floor
# scripts republished from here.

set -uo pipefail

TOOLROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$TOOLROOT/docs/onboarding/quetrex-onboarding.html"

FAILED=0
pass() { echo "ok - $1"; }
fail() { echo "NOT OK - $1"; FAILED=$((FAILED + 1)); }

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not installed; onboarding-doc mutation harness needs it"
  exit 0
fi

if [ ! -f "$DOC" ]; then
  fail "onboarding document exists at docs/onboarding/quetrex-onboarding.html"
  echo
  echo "onboarding-doc.test.sh: FAILED — $FAILED assertion(s)"
  exit 1
fi
pass "onboarding document exists at docs/onboarding/quetrex-onboarding.html"

# ---------------------------------------------------------------------------
# The claims. id|string — ids are stable so a mutation can name what it broke.
# ---------------------------------------------------------------------------

# REQUIRED — must be present. These are the current product's load-bearing
# facts; if one is missing the document is teaching a different system.
REQ_ID=(); REQ_STR=()
req() { REQ_ID+=("$1"); REQ_STR+=("$2"); }

# The product model itself.
req "model-routine-fired"   "routine-fired kanban"
req "model-phone-approval"  "approve the scope from your phone"
req "model-cloud-build"     "the build runs on Anthropic's cloud"
req "model-compute-locked"  "Compute runs only on Anthropic servers"
req "model-manual-deploy"   "manual deploy"
# The single worst error the old document made, named and negated.
req "model-no-watching"     "You do not sit and watch an agent type."
# Arming — a reader must be able to get a working command layer.
req "arm-login"             "/quetrex:login"
req "arm-init"              "/quetrex:init"
req "arm-scoped"            "unarmed repo has no gates at all"
req "arm-plugin-commands"   "\"quetrex@quetrex\": true"
req "arm-plugin-engine"     "\"quetrex-factory@quetrex\": true"
req "arm-autoupdate"        "\"autoUpdate\": true"
req "arm-no-pins"           "Never pin a version"
req "arm-marketplace-repo"  "Glori-Holdings/quetrex-plugins"
req "arm-marketplace-open"  "The marketplace is public"
# The commands that exist today, namespaced.
req "cmd-task-new"          "/quetrex:task-new"
req "cmd-task-refine"       "/quetrex:task-refine"
req "cmd-task-build"        "/quetrex:task-build"
req "cmd-task-rework"       "/quetrex:task-rework"
req "cmd-merge"             "/quetrex:merge"
req "cmd-deploy"            "/quetrex:deploy"
req "cmd-task-complete"     "/quetrex:task-complete"
req "cmd-update"            "/quetrex:update"
req "cmd-doctor"            "/quetrex:doctor"
# The build transport and the evidence a merge is gated on.
req "build-spec-branch"     "quetrex-spec/"
req "gate-merge-manual"     "Merging is not automatic."
req "gate-ledger"           "verify-ledger.jsonl"
req "gate-qa"               "qa-report.json"
req "gate-review"           "review-verdict.json"
req "gate-security"         "security-findings.json"
req "gate-head-pin"         "gates-head"

# FORBIDDEN — must be absent. Each was measured false, retired, or is a
# depiction of the workflow Quetrex replaces.
FORB_ID=(); FORB_STR=()
forb() { FORB_ID+=("$1"); FORB_STR+=("$2"); }

# Bring-your-own-compute over a mesh network to a box you keep awake.
forb "no-tailscale"         "Tailscale"
forb "no-tailnet"           "tailnet"
forb "no-ssh-box"           "ssh studio"
forb "no-mosh"              "mosh studio"
forb "no-byo-compute"       "bring-your-own"
forb "no-always-on"         "always-on machine"
# Claims measured false.
forb "no-private-market"    "The marketplace is private"
forb "no-auto-merge"        "Merge is automatic"
# Retired npm-era command names the doctrine says are stale leftovers.
forb "no-npm-setup"         "/quetrex-setup"
forb "no-npm-init"          "/quetrex-init"
forb "no-npm-task-new"      "/quetrex-task-new"
forb "no-npm-task-build"    "/quetrex-task-build"
forb "no-npm-task-merge"    "/quetrex-task-merge"
forb "no-npm-update"        "/quetrex-update"

# ---------------------------------------------------------------------------
# norm <file> — the document as a READER sees it: tags dropped, entities
# resolved, whitespace collapsed.
#
# WHY NOT grep THE RAW HTML. Measured on the document this replaces: the
# sentence "The marketplace is <strong>private</strong>" is a false claim a
# reader absolutely does read, and a raw `grep -F "The marketplace is private"`
# sails straight past it because a tag sits in the middle. Matching rendered
# text means a forbidden claim cannot be smuggled back in by wrapping one of
# its words in <em>.
# ---------------------------------------------------------------------------
norm() {
  node -e '
    const fs = require("fs");
    let t = fs.readFileSync(process.argv[1], "utf8");
    t = t.replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, " ");
    t = t.replace(/<[^>]+>/g, " ");
    t = t.replace(/&quot;/g, "\"").replace(/&lt;/g, "<").replace(/&gt;/g, ">")
         .replace(/&nbsp;/g, " ").replace(/&rarr;/g, "->").replace(/&rsquo;/g, "’")
         .replace(/&amp;/g, "&");
    t = t.replace(/\s+/g, " ").trim();
    process.stdout.write(t);
  ' "$1"
}

# ---------------------------------------------------------------------------
# scan_doc <file> — print one line per violated claim. Silent = clean.
#
# Matching is `case`, not a `grep` pipeline, on purpose: under
# `set -o pipefail`, `producer | grep -q pat` reports the PIPELINE as failed
# whenever grep short-circuits and SIGPIPEs the producer, so every check but
# the last silently inverted. That bug was observed in this very file.
# ---------------------------------------------------------------------------
scan_doc() {
  local f="$1" txt i
  txt="$(norm "$f")"
  for i in "${!REQ_ID[@]}"; do
    case "$txt" in
      *"${REQ_STR[$i]}"*) ;;
      *) echo "MISSING:${REQ_ID[$i]}" ;;
    esac
  done
  for i in "${!FORB_ID[@]}"; do
    case "$txt" in
      *"${FORB_STR[$i]}"*) echo "PRESENT:${FORB_ID[$i]}" ;;
    esac
  done
  return 0
}

# has <violation-line> <scan-output>  — exact-line membership, no pipeline.
has() {
  local needle="$1" hay="$2"
  case "$hay" in
    "$needle") return 0 ;;
    "$needle"*$'\n'*) return 0 ;;
    *$'\n'"$needle") return 0 ;;
    *$'\n'"$needle"$'\n'*) return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# PHASE 1 — the real document is clean, claim by claim.
# ---------------------------------------------------------------------------
DOCTXT="$(norm "$DOC")"
VIOLATIONS="$(scan_doc "$DOC")"

for i in "${!REQ_ID[@]}"; do
  case "$DOCTXT" in
    *"${REQ_STR[$i]}"*) pass "doc states [${REQ_ID[$i]}]: ${REQ_STR[$i]}" ;;
    *) fail "doc states [${REQ_ID[$i]}]: ${REQ_STR[$i]}" ;;
  esac
done

for i in "${!FORB_ID[@]}"; do
  case "$DOCTXT" in
    *"${FORB_STR[$i]}"*) fail "doc is free of [${FORB_ID[$i]}]: ${FORB_STR[$i]}" ;;
    *) pass "doc is free of [${FORB_ID[$i]}]: ${FORB_STR[$i]}" ;;
  esac
done

if [ -z "$VIOLATIONS" ]; then
  pass "scan_doc reports zero violations against the shipped document"
else
  fail "scan_doc reports zero violations against the shipped document (got: $(echo "$VIOLATIONS" | tr '\n' ' '))"
fi

# ---------------------------------------------------------------------------
# PHASE 2 + 3 — prove every assertion can fail.
#
# A green phase 1 over a scanner that cannot say no proves nothing. Mutate a
# scratch copy per claim and require the scanner to catch exactly that claim.
# ---------------------------------------------------------------------------
TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT

# mutate <src> <dst> <mode:strip|inject> <string>
#   strip  — remove EVERY occurrence (a claim stated twice must not survive
#            one deletion, or the assertion is weaker than it looks)
#   inject — append the string as VISIBLE prose. Not an HTML comment: the
#            scanner reads rendered text, so a comment would be stripped and
#            the "can it fail" check would pass for the wrong reason.
mutate() {
  node -e '
    const fs = require("fs");
    const [src, dst, mode, s] = process.argv.slice(1);
    let t = fs.readFileSync(src, "utf8");
    if (mode === "strip") {
      t = t.split(s).join("");
      if (t.indexOf(s) !== -1) { process.exit(3); }
    } else {
      t += "\n<p>" + s + "</p>\n";
    }
    fs.writeFileSync(dst, t);
  ' "$1" "$2" "$3" "$4"
}

for i in "${!REQ_ID[@]}"; do
  id="${REQ_ID[$i]}"; s="${REQ_STR[$i]}"
  m="$TMPDIR_T/strip.html"
  if ! mutate "$DOC" "$m" strip "$s"; then
    fail "mutation harness could strip [$id]"
    continue
  fi
  if has "MISSING:$id" "$(scan_doc "$m")"; then
    pass "assertion [$id] can fail — deleting the claim is caught"
  else
    fail "assertion [$id] can fail — deleting the claim is caught"
  fi
done

for i in "${!FORB_ID[@]}"; do
  id="${FORB_ID[$i]}"; s="${FORB_STR[$i]}"
  m="$TMPDIR_T/inject.html"
  if ! mutate "$DOC" "$m" inject "$s"; then
    fail "mutation harness could inject [$id]"
    continue
  fi
  if has "PRESENT:$id" "$(scan_doc "$m")"; then
    pass "assertion [$id] can fail — reintroducing the claim is caught"
  else
    fail "assertion [$id] can fail — reintroducing the claim is caught"
  fi
done

# ---------------------------------------------------------------------------
# The settings snippet must be a valid, copy-pasteable settings.json AND must
# carry no version pin. A pinned entry (array or string) makes the plugin count
# as DISABLED for dependency resolution, which is what took the entire
# /quetrex:* command layer down in every armed repo. Parse the snippet the doc
# actually ships rather than trusting the prose next to it.
# ---------------------------------------------------------------------------
SNIPPET="$TMPDIR_T/snippet.json"
node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  // Every <pre><code> block whose text parses as JSON and declares
  // enabledPlugins is a settings example a reader will copy.
  const blocks = [...html.matchAll(/<pre><code>([\s\S]*?)<\/code><\/pre>/g)]
    .map(m => m[1]
      .replace(/&quot;/g, "\"").replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">").replace(/&amp;/g, "&"));
  const found = [];
  for (const b of blocks) {
    let o; try { o = JSON.parse(b); } catch { continue; }
    if (o && o.enabledPlugins) found.push(b);
  }
  if (found.length !== 1) {
    console.error("expected exactly 1 settings example, found " + found.length);
    process.exit(1);
  }
  fs.writeFileSync(process.argv[2], found[0]);
' "$DOC" "$SNIPPET"
if [ -s "$SNIPPET" ]; then
  pass "doc ships exactly one settings.json example and it parses as JSON"

  if node -e '
    const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const p = o.enabledPlugins || {};
    if (p["quetrex@quetrex"] !== true) process.exit(1);
    if (p["quetrex-factory@quetrex"] !== true) process.exit(1);
    for (const k of Object.keys(p)) {
      if (Array.isArray(p[k]) || typeof p[k] === "string") process.exit(1);
    }
    const m = ((o.extraKnownMarketplaces || {}).quetrex) || {};
    if (m.autoUpdate !== true) process.exit(1);
    if (!m.source || m.source.repo !== "Glori-Holdings/quetrex-plugins") process.exit(1);
  ' "$SNIPPET"; then
    pass "settings example enables both plugins as booleans with autoUpdate and no version pin"
  else
    fail "settings example enables both plugins as booleans with autoUpdate and no version pin"
  fi

  # Prove that check can fail: the exact shape the old document shipped —
  # engine only, no command layer, no autoUpdate — must be rejected.
  cat > "$TMPDIR_T/old-shape.json" <<'OLDEOF'
{
  "extraKnownMarketplaces": {
    "quetrex": { "source": { "source": "github", "repo": "Glori-Holdings/quetrex-plugins" } }
  },
  "enabledPlugins": {
    "quetrex-factory@quetrex": true,
    "quetrex-nextjs@quetrex": true
  }
}
OLDEOF
  if node -e '
    const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const p = o.enabledPlugins || {};
    if (p["quetrex@quetrex"] !== true) process.exit(1);
    if (p["quetrex-factory@quetrex"] !== true) process.exit(1);
    for (const k of Object.keys(p)) {
      if (Array.isArray(p[k]) || typeof p[k] === "string") process.exit(1);
    }
    const m = ((o.extraKnownMarketplaces || {}).quetrex) || {};
    if (m.autoUpdate !== true) process.exit(1);
    if (!m.source || m.source.repo !== "Glori-Holdings/quetrex-plugins") process.exit(1);
  ' "$TMPDIR_T/old-shape.json" 2>/dev/null; then
    fail "settings check rejects the retired example (engine only, no autoUpdate)"
  else
    pass "settings check rejects the retired example (engine only, no autoUpdate)"
  fi

  # And a version pin must be rejected even when everything else is right.
  node -e '
    const fs = require("fs");
    const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    o.enabledPlugins["quetrex-factory@quetrex"] = ["1.5.1"];
    fs.writeFileSync(process.argv[2], JSON.stringify(o));
  ' "$SNIPPET" "$TMPDIR_T/pinned.json"
  if node -e '
    const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    const p = o.enabledPlugins || {};
    if (p["quetrex@quetrex"] !== true) process.exit(1);
    if (p["quetrex-factory@quetrex"] !== true) process.exit(1);
    for (const k of Object.keys(p)) {
      if (Array.isArray(p[k]) || typeof p[k] === "string") process.exit(1);
    }
  ' "$TMPDIR_T/pinned.json" 2>/dev/null; then
    fail "settings check rejects a version-pinned enabledPlugins entry"
  else
    pass "settings check rejects a version-pinned enabledPlugins entry"
  fi
else
  fail "doc ships exactly one settings.json example and it parses as JSON"
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "onboarding-doc.test.sh: FAILED — $FAILED assertion(s)"
  exit 1
fi
echo "onboarding-doc.test.sh: all assertions passed"
