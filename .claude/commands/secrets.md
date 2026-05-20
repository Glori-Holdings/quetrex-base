---
description: Manage API keys for quetrex-base. Add, list, or remove keys from the global secrets file or the current project. Usage: /secrets add KEY [--project], /secrets list, /secrets remove KEY [--project]
argument-hint: add KEY [--project] | list | remove KEY [--project]
---

# Secrets Manager

Manages API keys in `~/.claude/secrets.env` (global) or the current project's `.env` (project-level override).

Parse the command from `$ARGUMENTS`:
- `add KEY_NAME [--project]`
- `list`
- `remove KEY_NAME [--project]`

If `$ARGUMENTS` is empty or unrecognised, show usage and stop.

---

## add KEY_NAME [--project]

**Global** (`add LINEAR_API_KEY`): writes to `~/.claude/secrets.env`
**Project** (`add LINEAR_API_KEY --project`): writes to `.env` in the current directory

### Global add

1. Confirm `~/.claude/secrets.env` exists. If not: "Run /quetrex-setup first."
2. Ask: "Value for KEY_NAME?"
3. Check if the key already exists:
   ```bash
   grep -q "^export KEY_NAME=" ~/.claude/secrets.env && echo "exists" || echo "new"
   ```
4. If exists: update the line using sed.
5. If new: append to file.
6. Confirm: "KEY_NAME added to ~/.claude/secrets.env. Run `source ~/.claude/secrets.env` to load it in your current terminal."

**Format in secrets.env:**
```bash
export KEY_NAME="value"
```

### Project add

1. Confirm we are inside a git repo:
   ```bash
   git rev-parse --git-dir 2>/dev/null
   ```
   If not: "Not inside a git repo. Run this from your project directory."

2. Check `.gitignore` for `.env`:
   ```bash
   grep -q "^\.env$\|^\.env " .gitignore 2>/dev/null && echo "ignored" || echo "not ignored"
   ```
   If `.env` is not gitignored, warn: "⚠ .env is not in .gitignore. Adding it now to prevent accidental commits."
   ```bash
   echo '.env' >> .gitignore
   ```

3. Ask: "Value for KEY_NAME?"

4. Check if `.env` exists and if the key is already there:
   ```bash
   [ -f .env ] && grep -q "^KEY_NAME=" .env && echo "exists" || echo "new"
   ```

5. If exists: update in place with sed.
6. If new: append to `.env`.

7. Confirm: "KEY_NAME added to .env (project-level). This overrides the global value when working in this project."

**Format in project .env:**
```bash
KEY_NAME=value
```
Note: no `export` prefix — standard dotenv format.

---

## list

Show all configured keys from both sources. Never show values — names only.

```bash
echo "=== Global (~/.claude/secrets.env) ===" 
grep "^export " ~/.claude/secrets.env 2>/dev/null | sed 's/^export //' | cut -d= -f1 | sort

echo ""
echo "=== Project (.env) ==="
[ -f .env ] && grep -v "^#" .env | grep "=" | cut -d= -f1 | sort || echo "(no project .env found)"
```

Display the output cleanly. If a key appears in both: note "project overrides global" next to the project entry.

---

## remove KEY_NAME [--project]

**Global**: removes the line from `~/.claude/secrets.env`
**Project**: removes the line from `.env`

1. Confirm the key exists in the target file.
2. If not found: "KEY_NAME not found in [file]. Nothing to remove."
3. If found: confirm with user before deleting.
4. Remove the line:
   ```bash
   # Global (macOS sed requires -i '')
   sed -i '' "/^export KEY_NAME=/d" ~/.claude/secrets.env

   # Project
   sed -i '' "/^KEY_NAME=/d" .env
   ```
5. Confirm: "KEY_NAME removed from [file]."

---

## Notes

- Global keys are your defaults across all projects — set once, work everywhere
- Project `.env` keys override the global for that project only — use for different Linear workspaces, project-specific services, etc.
- Never store secrets in code, CLAUDE.md, or any file that gets committed
- All commands that need LINEAR_API_KEY read `$LINEAR_API_KEY` from the environment — the layered system (shell sources secrets.env, project .env overrides) handles the rest
- On a new machine: run /quetrex-setup to create secrets.env and configure your primary keys
- On a new project with a different Linear workspace: run `/secrets add LINEAR_API_KEY --project`
