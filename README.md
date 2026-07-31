# Quetrex Base

Claude Code configuration for development teams: specialized agents, committed
hooks, and kanban-wired commands that carry a task from written scope to a
reviewed, merged PR — with the gates enforced by code rather than by asking
Claude nicely.

> **Current model.** The pipeline engine ships as the **`q`** plugin (plus
> per-stack packs) from the private marketplace
> **`Glori-Holdings/quetrex-plugins`**, installed through Claude Code's native
> plugin system. Two consequences that supersede older docs anywhere in this repo:
>
> - **Merge is gated by artifact, not by a prompt.** A separate review agent
>   writes `AUTO_MERGE` / `REWORK` / `ESCALATE_HUMAN`, and `merge-gate.sh` allows
>   the merge only when every gate is green **for the exact commit being merged**.
>   There is no merge command. Only **production deploy** is a manual human step.
> - **Update with the native `/plugin update`.** There is no Quetrex update
>   command, and no hook checks for one.

**What runs on your machine, and what it can block, is documented hook by hook in
[SECURITY.md](SECURITY.md).** No Quetrex hook makes a network call.

## Install

```bash
npm install -g quetrex-base
```

Or install directly from GitHub (works with private repos — requires GitHub access):

```bash
npm install -g github:Barnhardt-Enterprises-Inc/quetrex-base
```

## First time on a new machine

```bash
/q-login
```

Logs in to the Quetrex kanban via browser device-flow and stores a per-user API token.

## First time on a new project

```bash
/q-init
```

Links the repo to a Quetrex project, writes its verify chain to
`.quetrex/verify.json`, and installs the per-project build gates into the repo's
**committed** `.claude/` — which is what makes them fire in a cloud runner, since
a cloud runner only ever sees what is committed.

## Planning work

```bash
/q-task-new         # Create a Backlog task on the kanban
/q-task-refine      # Refine a task into a clear, buildable spec
```

## The pipeline

```
architect → developer(s) → QA → reviewer → git-workflow → PR
```

Each stage is a specialized agent. The architect decomposes the spec into a plan
with a strict file-ownership map. Developers work in parallel worktrees on
disjoint files. QA proves green with **actual exit codes**, never by reading
output for the word "passed". The reviewer runs in fresh context on the finished
change and decides the merge verdict mechanically. git-workflow opens the squash
PR.

Two gates stand underneath all of it and are not skippable by an agent:
`verify-gate.sh` refuses to end a turn while the verify chain is red, and
`merge-gate.sh` refuses a merge whose evidence is missing, red, or pinned to an
older commit.

## Commands

| Command | What it does |
|---|---|
| `/q-login` | One-time machine login to the Quetrex kanban |
| `/q-init` | Link a repo to a Quetrex project; install its verify chain and build gates |
| `/q-task-new` | Create a Backlog task on the kanban |
| `/q-task-refine` | Refine a task into a buildable spec |
| `/q-task-build` | Vet, classify, and build a task end to end |
| `/q-task-rework` | Re-plan and re-run a failed task |
| `/q-task-complete` | Mark a deployed task Complete |
| `/q-deploy` | Deploy the project's app from vault secrets |

Installed as the `q` plugin, these namespace as `/q:task-build`, `/q:init`, and
so on.

## Permission model

The shipped profile is **`dontAsk`**: only pre-approved tools run, everything
else is auto-denied with no prompt. That is the mode built for unattended runs —
the pipeline keeps moving instead of hanging on an approval nobody is there to
give, and nothing new is silently permitted. The allow-list lives in
`.claude/settings.json`.

The `PreToolUse` hooks sit **beneath** the permission system: a deny fires before
the permission engine, so it holds even for pipeline agents that run with
`bypassPermissions` inside a disposable worktree.

## Updates

```bash
/plugin update
```

Native Claude Code plugin update. For the npm distribution, re-run the install
command above.

## Requirements

- Node.js 18+
- Claude Code
- GitHub CLI (`gh auth login`)
- `jq` (the gates are jq-mandatory and fail closed without it)
