---
description: One-time machine setup for quetrex-base. Configures GitHub auth, git identity, and API keys. Run once per machine — partners run this after installing the npm package.
---

# Quetrex Setup

Sets up your machine to run the quetrex-base pipeline. Run once per machine, not once per project.

## Step 1: GitHub CLI

```bash
gh auth status 2>&1
```

If not authenticated, stop and tell the user:
> "GitHub CLI is not authenticated. Run `gh auth login` in your terminal, choose GitHub.com and HTTPS, then run /quetrex-setup again."

## Step 2: Git Identity

```bash
git config --global user.name
git config --global user.email
```

If either is empty, ask the user for the missing value(s) and set them:

```bash
git config --global user.name "NAME"
git config --global user.email "EMAIL"
```

## Step 3: secrets.env

Check if the global secrets file exists:

```bash
[ -f ~/.claude/secrets.env ] && echo "exists" || echo "missing"
```

If missing, create it:

```bash
cat > ~/.claude/secrets.env << 'EOF'
#!/bin/bash
# quetrex-base secrets — never commit this file
# Add to your shell profile: source ~/.claude/secrets.env
EOF
chmod 600 ~/.claude/secrets.env
```

`chmod 600` makes the file readable only by you — not other users on the machine.

## Step 4: LINEAR_API_KEY

Check which workspaces are already configured:

```bash
grep "LINEAR" ~/.claude/secrets.env 2>/dev/null || echo "none"
```

Display what's configured. Then ask:

> "What Linear workspaces do you need? For each one, I need a name (e.g. 'personal', 'dealerq', 'client-x') and API key from Linear → Settings → API → Personal API Keys.
>
> Start with your primary workspace — you can add more with /secrets add later."

For each workspace the user provides:

- If it's the primary (first) workspace: add as `LINEAR_API_KEY`
- If it's a named workspace: add as `LINEAR_{NAME}_API_KEY` (uppercased)

Write to `~/.claude/secrets.env`:

```bash
# Append primary key
echo '' >> ~/.claude/secrets.env
echo '# Linear: primary workspace' >> ~/.claude/secrets.env
echo 'export LINEAR_API_KEY="VALUE"' >> ~/.claude/secrets.env

# Append named workspace key (if provided)
echo '# Linear: NAME workspace' >> ~/.claude/secrets.env
echo 'export LINEAR_NAME_API_KEY="VALUE"' >> ~/.claude/secrets.env
```

## Step 5: Shell Profile

Check if secrets.env is already sourced:

```bash
grep -l "secrets.env" ~/.zshrc ~/.bashrc ~/.bash_profile ~/.profile 2>/dev/null | head -1
```

If not found in any profile, show the user exactly what to add and where:

> "Add this line to your shell profile. For zsh (macOS default): `~/.zshrc`. For bash: `~/.bashrc`.
>
> ```
> source ~/.claude/secrets.env
> ```
>
> Then run: `source ~/.zshrc` (or open a new terminal)."

If already sourced, confirm and skip.

## Step 6: Confirm

```bash
source ~/.claude/secrets.env 2>/dev/null
echo "LINEAR_API_KEY: ${LINEAR_API_KEY:+set (${#LINEAR_API_KEY} chars)}"
echo "gh: $(gh auth status --active 2>&1 | head -1)"
echo "git name: $(git config --global user.name)"
echo "git email: $(git config --global user.email)"
```

Report clearly what is set and what is missing. If everything is green:

> "quetrex-base setup complete. You're ready to use /issue-prd, /plan-project, and the full pipeline."

## Notes

- LINEAR_API_KEY is your primary workspace default — used unless a project .env overrides it
- Named workspace keys (LINEAR_DEALERQ_API_KEY etc.) are selected by /secrets when working in that project
- Run /secrets to add keys, list what is configured, or switch a project to a named workspace
- This file is read-only to other users (chmod 600) — do not put it in any git repo
