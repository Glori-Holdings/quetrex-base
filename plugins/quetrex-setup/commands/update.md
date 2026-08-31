---
description: Update the Quetrex engine on this machine and report the running version. No version pins — the engine auto-updates and the version is surfaced in the status bar. Usage: /quetrex-setup:update
argument-hint: ""
---

# Quetrex Update

Pull the latest Quetrex engine into this machine's plugin cache and report what
is now running.

**There are no version pins, and this command must never create one.** That is
not a style preference, it is the fix for a total outage:

- A pinned `enabledPlugins` entry — `"quetrex-factory@quetrex": ["1.2.1"]`, array
  or bare string — makes the plugin count as **disabled** for dependency
  resolution. The `quetrex` command layer then fails to load and **no
  `/quetrex:*` command exists at all** in that repo. Measured across four
  checkouts: pin absent → enabled; pin `true` → enabled; pin `["1.2.1"]`, the
  exact installed version → *failed to load*; pin `["1.1.0"]` → *failed to load*.
  The repos with the "correct" concrete pin were precisely the broken ones.
- Pinning also broke updating itself: a pin naming a version a machine does not
  have, or a stale pin nobody remembers to bump, silently strands the whole team
  on an old engine while every repo *looks* configured.

So the engine tracks the marketplace automatically via
`extraKnownMarketplaces.quetrex.autoUpdate`, both plugins are enabled with a
plain `true`, and **the running version is surfaced in the status bar** rather
than pinned in config. This command needs no PR and changes no committed file.

---

## 1. Update this machine's plugin cache

All three plugins, engine first, this one (quetrex-setup) last so the command finishes
running the version it started with, never a half-swapped one mid-execution:

```bash
claude plugin update quetrex-factory@quetrex || echo "quetrex-factory: no update applied (already latest, or not installed from this marketplace)"
claude plugin update quetrex@quetrex          || echo "quetrex: no update applied (already latest, or not installed from this marketplace)"
claude plugin update quetrex-setup@quetrex    || echo "quetrex-setup: no update applied (already latest, or not installed from this marketplace)"
```

A non-zero exit is not fatal — it usually means the plugin is already latest.

---

## 2. Report what is running, and what is published

The authoritative "latest" is the marketplace manifest on GitHub raw. Offline is
not fatal here: with no pins there is nothing to write, so an unreachable
marketplace only means the comparison is skipped.

**Never `read ... < <(...)`.** `read` returns NON-ZERO when the final line has no
trailing newline, so a `|| { fatal }` guard fires on SUCCESS. That defect made
this command and `/quetrex-setup:login` fail 100% of the time. Capture, check, then
let `node` do the parsing and the comparison — never shell word splitting.

```bash
RUNNING="$(quetrex-version --plain 2>/dev/null || echo "unknown")"
echo "Running: quetrex $RUNNING"

MARKET_URL="https://raw.githubusercontent.com/Glori-Holdings/quetrex-plugins/main/.claude-plugin/marketplace.json"
if MANIFEST="$(curl -fsS --max-time 10 "$MARKET_URL" 2>/dev/null)"; then
  # The whole comparison happens INSIDE node, so nothing depends on shell word
  # splitting. `set -- $VERSIONS` was the bug: zsh does NOT word-split an
  # unquoted parameter (SH_WORD_SPLIT is off by default), so $1 became the
  # entire "quetrex factory setup" string — the "Published:" line misprinted and
  # the equality test then falsely reported a newer engine on a machine already
  # on the latest. Shipped blocks run in the operator's shell, which is zsh on
  # macOS; never rely on bash-only splitting in one.
  REPORT="$(printf '%s' "$MANIFEST" | node -e '
    let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
      let o; try{o=JSON.parse(s)}catch{process.exit(1)}
      const v=n=>{const p=(o.plugins||[]).find(x=>x&&x.name===n);return p&&p.version?String(p.version):""};
      const q=v("quetrex"), f=v("quetrex-factory"), st=v("quetrex-setup");
      if(!q||!f){process.exit(1)}
      const running=process.argv[1];
      process.stdout.write(
        "Published: quetrex "+q+", quetrex-factory "+f+", quetrex-setup "+(st||"?")+"\n"+
        (running===q
          ? "This machine is on the latest engine.\n"
          : "A newer engine is published \u2014 restart Claude Code to finish applying the update.\n"));
    })' "$RUNNING")" || REPORT=""
  if [ -n "$REPORT" ]; then
    printf '%s' "$REPORT"
  else
    echo "Could not read the marketplace manifest; skipping the comparison."
  fi
else
  echo "Marketplace unreachable; skipping the comparison (nothing is pinned, so nothing is stale in config)."
fi
```

---

## 3. Repair a legacy pin if this repo still carries one

A repo armed by an older engine may still hold a version pin, and while it does,
**no `/quetrex:*` command loads there**. Detect it and say how to clear it:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
PINNED="$(node -e '
  let o={}; try{o=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))}catch{}
  const e=o.enabledPlugins||{};
  const bad=Object.keys(e).filter(function(k){return /^quetrex(-[a-z0-9]+)?@quetrex$/.test(k) && e[k]!==true && e[k]!==false});
  process.stdout.write(bad.join(","));
' "$REPO_ROOT/.claude/settings.json" 2>/dev/null)"

if [ -n "$PINNED" ]; then
  echo "This repo pins: $PINNED — while a pin is present the quetrex command layer does not load here."
  echo "Fix: run /quetrex-setup:init (arming rewrites any pin to true), or set those entries to true in .claude/settings.json."
else
  echo "No version pins in this repo — the engine auto-updates."
fi
```

Confirm with `claude plugin list`: `quetrex@quetrex` must read **enabled**, not
*failed to load*.

---

## 4. Report

- **Local cache** — what `claude plugin update` bumped, or already-latest.
- **Running / published** — the two versions, and whether a restart is needed.
- **Pins** — none (expected), or the legacy pin found and how to clear it.
- **Where the version lives** — the status bar (`Quetrex vX.Y.Z`), never a pin.

---

## Error-handling rules

- **Never write a version pin.** Not an array, not a string. A pin disables the
  command layer.
- Never `read ... < <(...)`: `read` exits non-zero without a trailing newline and
  a fatal guard then fires on success.
- Offline is not fatal — with nothing pinned there is nothing to write.
- Build all JSON with `node` / `JSON.stringify`; never `echo`/`sed` into settings.
