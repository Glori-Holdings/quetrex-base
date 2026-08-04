---
description: Update the Quetrex engine — bump the pinned quetrex and quetrex-factory plugin versions to the latest published, commit the changed pin, and open a PR so the whole team moves together. Usage: /quetrex:update
argument-hint: ""
---

# Quetrex Update

Bump this repo onto the latest published Quetrex engine and make the move
**team-consistent and reviewable**. A pinned plugin gets no native update
notification, and updating one machine's local plugin cache does nothing for
your teammates or for cloud routines — the pin that everyone (and every routine)
actually reads lives in the repo's committed `.claude/settings.json`
`enabledPlugins`. So this command does two things:

1. Runs `claude plugin update` for both Quetrex plugins so THIS machine pulls
   the latest into its plugin cache.
2. Writes the new concrete `quetrex-factory@quetrex` version into the repo's
   committed `enabledPlugins` pin and opens a PR — the durable, reviewable
   record that moves the team and the routines forward together.

Never bump the pin silently or on `main`: the whole point is a reviewed change
everyone adopts at once.

---

## 1. Update this machine's plugin cache

Bump the pinned versions in the local plugin install to latest. Both plugins,
in dependency order (the engine first, then the command layer that depends on
it):

```bash
claude plugin update quetrex-factory@quetrex || echo "quetrex-factory: no update applied (already latest, or not installed from this marketplace)"
claude plugin update quetrex@quetrex          || echo "quetrex: no update applied (already latest, or not installed from this marketplace)"
```

A non-zero exit here is not fatal — it usually just means the plugin is already
at latest. Report what happened and continue to the pin update, which is the
part that reaches the team.

---

## 2. Resolve the latest published versions

The authoritative "latest" is the marketplace manifest on GitHub raw (there is
no version-check API). Fetch it and read both versions. Offline is fatal for
THIS command (unlike the passive SessionStart check) — you cannot pin to a
version you could not confirm:

```bash
MARKET_URL="https://raw.githubusercontent.com/Glori-Holdings/quetrex-plugins/main/.claude-plugin/marketplace.json"
MANIFEST="$(curl -fsS --max-time 10 "$MARKET_URL")" || { echo "Could not fetch the Quetrex marketplace — check your connection and re-run /quetrex:update." >&2; exit 1; }

read -r LATEST_QUETREX LATEST_FACTORY < <(printf '%s' "$MANIFEST" | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o; try{o=JSON.parse(s)}catch{process.exit(1)}
    const v=n=>{const p=(o.plugins||[]).find(x=>x&&x.name===n);return p&&p.version?String(p.version):""};
    const q=v("quetrex"), f=v("quetrex-factory");
    if(!q||!f){process.exit(1)}
    process.stdout.write(q+" "+f);
  })') || { echo "The marketplace manifest was unreadable — contact your administrator." >&2; exit 1; }

echo "Latest published: quetrex $LATEST_QUETREX, quetrex-factory $LATEST_FACTORY"
```

---

## 3. Write the committed pin (the team-consistent part)

Update `$REPO_ROOT/.claude/settings.json` `enabledPlugins` so it reads:

- `"quetrex@quetrex": true` — the command layer is enabled (a plain `true`; the
  command surface is not version-gated per repo).
- `"quetrex-factory@quetrex": "<LATEST_FACTORY>"` — a **concrete version pin**,
  never a floating `true`. This is the number cloud routines and teammates read.

Merge, never clobber — preserve every other `enabledPlugins` entry and every
other settings key. Only write when the pin actually changed:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
node -e '
  const fs=require("fs"), path=require("path");
  const [file, latestFactory] = process.argv.slice(1);
  let o={}; try{o=JSON.parse(fs.readFileSync(file,"utf8"))}catch{}
  o.enabledPlugins = o.enabledPlugins || {};
  const before = JSON.stringify(o.enabledPlugins);
  o.enabledPlugins["quetrex@quetrex"] = true;
  o.enabledPlugins["quetrex-factory@quetrex"] = latestFactory;   // concrete pin
  if (JSON.stringify(o.enabledPlugins) === before) { console.log("PIN_UNCHANGED"); process.exit(0); }
  fs.mkdirSync(path.dirname(file), {recursive:true});
  fs.writeFileSync(file, JSON.stringify(o, null, 2) + "\n");
  console.log("PIN_UPDATED");
' "$REPO_ROOT/.claude/settings.json" "$LATEST_FACTORY"
```

If it prints `PIN_UNCHANGED`, the repo is already on the latest engine — tell the
user *"Already on the latest Quetrex engine (quetrex-factory $LATEST_FACTORY)."*
and stop without opening a PR.

---

## 4. Commit the pin and open a PR

Only when the pin changed. Follow the `worktree-workflow` conventions and use
`git -C "$REPO_ROOT"` so the enforce-branch hook sees the branch instead of
blocking on `main`. Never commit the pin bump straight to `main`:

```bash
BRANCH="chore/quetrex-engine-$LATEST_FACTORY"
git -C "$REPO_ROOT" checkout -b "$BRANCH" 2>/dev/null || git -C "$REPO_ROOT" checkout "$BRANCH"
git -C "$REPO_ROOT" add .claude/settings.json

if git -C "$REPO_ROOT" diff --cached --quiet; then
  echo "Nothing staged — pin already committed."
else
  git -C "$REPO_ROOT" commit -m "chore: bump Quetrex engine to quetrex-factory $LATEST_FACTORY

Pin the committed enabledPlugins to the latest published engine so the whole
team and every cloud routine move onto it together. Reviewed, not silent." >/dev/null

  if git -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1 && command -v gh >/dev/null 2>&1; then
    git -C "$REPO_ROOT" push -u origin "$BRANCH" >/dev/null 2>&1
    PR_URL="$(gh pr create --repo "$(git -C "$REPO_ROOT" remote get-url origin)" \
      --head "$BRANCH" \
      --title "chore: bump Quetrex engine to quetrex-factory $LATEST_FACTORY" \
      --body "Bumps the committed \`enabledPlugins\` pin to the latest published Quetrex engine (\`quetrex-factory@quetrex\` → \`$LATEST_FACTORY\`) so teammates and cloud routines all adopt it together. Merge to roll the whole repo forward." 2>/dev/null)"
    [ -n "$PR_URL" ] && echo "Opened PR: $PR_URL" || echo "Committed on $BRANCH, but PR creation failed — open one manually."
  else
    echo "Committed locally on $BRANCH; no remote (or gh unavailable), so no PR was opened."
  fi
fi
```

---

## 5. Report

- **Local cache** — whether `claude plugin update` bumped quetrex / quetrex-factory
  on this machine, or they were already latest.
- **Latest published** — the versions read from the marketplace.
- **Committed pin** — updated to `quetrex-factory <LATEST_FACTORY>` (with the PR
  URL), or *"already on the latest engine"* if nothing changed.
- **Next step** — merge the PR to move the team; a `/quetrex:doctor` run after
  merge confirms every repo is on the pinned version.

---

## Error-handling rules

- The marketplace fetch is REQUIRED here (unlike the passive SessionStart nudge):
  never pin to a version you could not confirm from the manifest.
- The `quetrex-factory` pin is always a **concrete version string**, never a
  floating `true` — routines and teammates must all resolve the exact same engine.
- Never commit the pin bump to `main`; always a branch + PR so the move is
  reviewed and adopted team-wide at once.
- Build all JSON with `node` / `JSON.stringify`; never hand-edit settings with
  `echo`/`sed`.
