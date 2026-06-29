---
description: Check for and apply updates to Glori Builder. Shows current vs latest version and updates if behind.
---

# Quetrex Update

## Step 1: Check Installed Version

```bash
npm list -g quetrex-base --depth=0 --json 2>/dev/null
```

Extract the installed version from the JSON output.

If `quetrex-base` is not found in the output, tell the user: "Glori Builder does not appear to be installed globally. Install it with: `npm install -g quetrex-base`" and stop.

## Step 2: Check Latest Version

```bash
npm show quetrex-base version 2>/dev/null
```

## Step 3: Compare

If installed == latest:
> "You're on the latest version of Glori Builder (v{version}). Nothing to do."

Clear the flag file if it exists: `rm -f ~/.claude/.quetrex-update-available`

Stop.

If installed != latest, display:
> "Glori Builder update available
> Installed: v{installed}
> Latest:    v{latest}
>
> This will update all agents, skills, and commands in ~/.claude/.
> Your settings.json permissions and custom project files will not be overwritten.
> Update now?"

Wait for confirmation before proceeding.

## Step 4: Apply Update

```bash
npm install -g quetrex-base@latest
```

The postinstall script runs automatically and copies all updated files to `~/.claude/`.

## Step 5: Confirm

```bash
rm -f ~/.claude/.quetrex-update-available
npm list -g quetrex-base --depth=0
```

Report:
> "Updated to v{latest}. Restart Claude Code to load new agents and skills."
