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

Add any API keys you need with `/secrets add KEY` (global) or `/secrets add KEY --project`.

## Step 4: Shell Profile

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

## Step 5: direnv (recommended)

direnv automatically loads a project's `.env` file when you enter its directory. This means database URLs, project API keys, and other credentials are available to Claude's commands without any manual setup or per-command sourcing.

Check if direnv is installed:

```bash
which direnv 2>/dev/null && direnv version || echo "not installed"
```

If not installed, recommend it:

> "direnv is not installed. It's strongly recommended — without it, database commands and other project-specific credentials may fail silently.
>
> Install:
> - macOS: `brew install direnv`
> - Linux / Windows WSL: `sudo apt install direnv` or `curl -sfL https://direnv.net/install.sh | bash`
>
> After installing, add the hook to your shell profile:
> - zsh: `echo 'eval "$(direnv hook zsh)"' >> ~/.zshrc`
> - bash: `echo 'eval "$(direnv hook bash)"' >> ~/.bashrc`
>
> Then: `source ~/.zshrc` and run /quetrex-setup again."

If installed, check if the hook is in the shell profile:

```bash
grep -l "direnv hook" ~/.zshrc ~/.bashrc ~/.bash_profile 2>/dev/null | head -1
```

If the hook is missing, show the user the command to add it. If already configured, confirm and continue.

**How direnv works with projects:** When a project has a `.env` file and an `.envrc` file containing `dotenv`, direnv auto-exports those vars whenever you `cd` into the directory. Claude's bash commands inherit them — no manual sourcing needed. The `/project-setup` command creates the `.envrc` file.

## Step 6: Confirm

```bash
source ~/.claude/secrets.env 2>/dev/null
echo "gh auth        : $(gh auth status --active 2>&1 | head -1)"
echo "git name       : $(git config --global user.name)"
echo "git email      : $(git config --global user.email)"
echo "direnv         : $(which direnv 2>/dev/null && direnv version || echo 'not installed')"
```

Report clearly what is set and what is missing. If everything is green:

> "quetrex-base setup complete. You're ready to plan work and run the full pipeline."

## Notes

- Add API keys with /secrets — global keys are defaults, project .env keys override per project
- Run /secrets to add keys or list what is configured
- secrets.env is read-only to other users (chmod 600) — do not put it in any git repo
