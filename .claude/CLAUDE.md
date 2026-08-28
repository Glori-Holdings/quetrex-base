PROTECTED (HOOKFIX G5): the safety floor — deny-guard.sh, secret-scan.sh,
enforce-branch.sh, merge-gate.sh, verify-gate.sh, verify-gate-quick-chain.sh,
qx-verify-baseline.sh —
lives in exactly ONE place: plugins/quetrex-factory/scripts/ (the one-copy
rule). Changing one requires explicit operator approval
(QUETREX_UNLOCK_FLOOR=1). verify-gate.sh's quick-chain-on-Stop behavior must
never be reverted.

# quetrex-base

This repo IS the Quetrex engine — the hooks, agents, commands and installer that other repos run. Work here edits enforcement machinery, not application code.

- Hook scripts live in `.claude/hooks/`, agent contracts in `plugins/quetrex-factory/agents/` (the one-copy location — none remain under `.claude/agents/`), slash commands in `.claude/commands/`, shared shell in `.claude/lib/`.
- This repo ships as the `quetrex` Claude Code plugin. A plugin hook command must resolve via `${CLAUDE_PLUGIN_ROOT}`: write `bash "${CLAUDE_PLUGIN_ROOT}/.claude/hooks/<name>.sh"`, NEVER `~/.claude/...` — a plugin only ever sees what it ships. (`${CLAUDE_PROJECT_DIR}` still appears *inside* hook scripts to target the user's repo; that is not the registration layer.)
- **A change to a hook's blocking behavior ships in the same commit as a test under `test/` that proves both the new block and the new allow.**
- Generic pipeline doctrine (agent roles, branch rules, permission model) lives in the on-demand `.claude/skills/quetrex-pipeline/` skill — nothing loads it globally. Keep THIS file to what is true of THIS repo only.

# Learning

When I correct you or you catch yourself making a mistake, before continuing, add the lesson as a one-line rule under #LESSONS so it never happens again.

# LESSONS
- A PreToolUse hook's `permissionDecision:"ask"` only actually prompts in `default` mode — it is AUTO-ALLOWED under `bypassPermissions`, `acceptEdits`, `dontAsk`, `auto`, `plan`, and when `permission_mode` is absent (measured 2026-08-27/28). Never let a guard DEPEND on `ask`, and gate it with an ALLOWLIST (`= "default"`), never a denylist against `bypassPermissions`.
- The human channel in `transcript_path` is `origin.kind == "human"` — NOT string `message.content`. Measured: 667 of 1366 string-content `type=="user"` rows are agent-reachable (SendMessage peer rows, task-notification summaries, agent-invoked SlashCommands), and one was replayed to rewrite the verify chain. Do NOT key on `promptSource=="typed"` either: `queued` and `suggestion_accepted` are also genuinely human. Absent origin fails CLOSED.


- A hook must NEVER surface a raw interpreter stack trace to the operator — it reads as "the build failed" even when nothing failed and nothing was gated. Print one labelled line: what command ran, which checkout/branch it ran in, and whether it blocks. Never execute a verify chain into a throw when a required env name is simply unset; say it was skipped and why.

- Customer-facing explainers must show the real machinery (agents' specializations, the architect's PRD-decomposition that kills drift/hallucination, hooks, skills, exact commands), grounded in the actual source files — never shallow marketing gloss, and structured so the reader never hits a boring paragraph before the substance lands.
- Before explaining or depicting how Quetrex works for the user, re-ground in the CURRENT product model from memory: it is a routine-fired kanban (plan → tap Approve on scope from the phone → automated build → review → auto-merge → manual deploy; needs_human→SMS), where the board is watch-plus-gate-taps. NEVER depict the old "run a terminal command and watch the AI type" model — that is exactly what Quetrex replaces.

## Verification

```
npm run check:js
npm run check:sh
npm run check:json
npm test
```

## Quetrex

This is a Quetrex project (code `QUE`) — features go through `/quetrex:task-build`, and the guarded pipeline (architect → developers → QA → reviewer → git-workflow) carries each task to a reviewed, merged PR.
