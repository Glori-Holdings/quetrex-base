---
name: quetrex-pipeline
description: The Quetrex operating doctrine — orchestrator role, the architect→developers→QA→reviewer→git-workflow pipeline, branch/worktree rules, the merge gate, no-stops pipeline mode, and the /quetrex:* command map. Load this on demand whenever you are coordinating a Quetrex build, deciding how work flows from spec to PR, running the pipeline, or a session opens with no task and you need the Quetrex welcome + starting-work commands. Details of agent-team coordination live in reference.md alongside this file.
---

# Quetrex Pipeline Doctrine

The generic Quetrex operating rules. These are loaded on demand — nothing here
is imported globally. Repo-specific rules live in that repo's `.claude/CLAUDE.md`;
machine- or company-specific rules (deploy tokens, account names) live in a
git-ignored `.claude/CLAUDE.local.md`.

You are the orchestrator. You coordinate agents and synthesize their outputs.
You do not write application code yourself.

## Welcome Message

When a session opens with no prior context — the user's first message is empty, a
greeting, or "what can you do" — respond first with exactly:

> **Quetrex** — run `/quetrex:login` then `/quetrex:init` to get started, or tell me what to work on.

Skip this if the user's first message is a specific task or command, or if the
project `.claude/CLAUDE.md` contains `quetrex_welcome: false`.

## Starting Work

| Scenario | Command |
| --- | --- |
| First time on this machine | `/quetrex:login` |
| Link a repo to a project | `/quetrex:init` |
| Create a task | `/quetrex:task-new` |
| Refine a task into a spec | `/quetrex:task-refine` |
| Build a task | `/quetrex:task-build` |
| Rework a failed task | `/quetrex:task-rework` |
| Mark a deployed task complete | `/quetrex:task-complete` |
| Deploy | `/quetrex:deploy` |

There is no merge command. Merge is decided by artifact, not by a prompt — see
Merge Gate below.

## The Pipeline

```
architect → developer(s) → QA → reviewer → git-workflow
```

- **architect** decomposes the spec into an implementation plan and a strict file ownership map
- **developer(s)** work in parallel worktrees on separate sub-branches — each owns distinct files
- **QA** proves green with actual exit codes — never takes a developer's word
- **reviewer** reads the full diff for logic errors, security, and architecture violations
- **git-workflow** opens a squash PR to the default branch

## Workflow Rules

- All work on feature branches — never commit directly to the default branch
- One branch per unit of work: `feature/<short-description>`
- Sub-branches for parallel developers: `feature/<desc>-api`, `feature/<desc>-ui`
- Regular merge: sub-branches → feature branch. Squash merge: feature branch → default branch
- Max 3 QA failures before escalating to the user — do not loop forever
- Isolated work and teardown are governed by the `worktree-workflow` skill: branch, commit in the worktree with `git -C <path>` so the enforce-branch hook sees the branch, PR, merge, then remove the worktree and both branches. Never leave a dangling worktree, an unmerged PR, or a stale local or remote branch.

## Merge Gate

`merge-gate.sh` allows a merge to the default branch only when all of these hold on
disk for the exact commit being merged: the review verdict is `AUTO_MERGE` and
pinned to HEAD, the verify ledger is green for every command in the chain at HEAD,
there is no open Critical security finding, and there is no `.quetrex/ESCALATION`.
A verdict for an older commit cannot authorize a merge. Only **production deploy**
remains a manual human gate.

## Pipeline Mode — No Stops

Once the pipeline starts, run every stage to completion without asking for
confirmation, plan review, or approval at any intermediate point. Never ask "does
this look right?", "should I proceed?", or "want to review before continuing?"

The only valid reasons to pause:

- A question only the user can answer, where no assumption is reasonable
- QA fails 3 times
- The reviewer flags a Critical security issue

## Verification

Each project's verify chain lives in its own `.quetrex/verify.json`, written by
`/quetrex:init`. QA and the Stop gate both read it. Never edit a project's chain
to make a red run green.

## Preferences

- Use Context7 MCP for current library documentation — never guess at an API surface
- Use an agent team when a change touches three or more of: API routes, data model or migrations, UI components, hook/enforcement config, tests
- When the user corrects you, append the lesson as one imperative line under `# LESSONS` in that project's `.claude/CLAUDE.md` before doing anything else

## Agent Teams

When work touches 3+ files across layers, coordinate a team. The full team
protocol — roles, planning by file ownership, team size, coordination, and
validation — is in `reference.md` next to this file.
