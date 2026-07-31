# What Quetrex runs on your machine

Quetrex is an enforcement product. It works by installing **hooks** — small bash
scripts Claude Code executes at fixed points in its own loop, before and after
tool calls, with your privileges. That is not a footnote; it is the mechanism.
A plugin's hooks fire on every matching tool call whether or not you read them,
so this page exists so your security reviewer never has to reverse-engineer a
shell script to answer "what does this thing actually do."

Every hook is a plain bash script in `.claude/hooks/`. They are committed, they
are readable, and the table below is the complete list. Nothing is minified,
compiled, or fetched at runtime.

## The one-line answer

**No Quetrex hook opens a network connection, and no Quetrex hook transmits your
code, your commands, your credentials, or any telemetry anywhere.** There is no
Quetrex-operated endpoint for a hook to call. Every hook reads its input from
stdin, consults files inside your own repository, and writes at most into that
repository's `.quetrex/` directory.

Two nuances, stated here rather than left for you to find:

1. `auto-format.sh` shells out to **your project's own formatter**
   (`npx biome format --write`) and only when your project already contains a
   `biome.json`. If your package manager has to resolve that binary it does so
   from your configured registry — the same thing that happens during any local
   build. The hook itself sends nothing.
2. `verify-gate.sh` **executes the commands you listed** in your own
   `.quetrex/verify.json` (typically `tsc`, a linter, a build, your test suite).
   Those commands do whatever they normally do, including reaching the network if
   your build does. Quetrex chooses none of them; you do, and you can read the
   file.

Three hooks from previous releases have been **removed**, and the installer
un-wires them from any machine that still has them:

- `check-quetrex-update.sh` (Stop) called `npm show` to check for a new version.
  It was the only hook that touched the network and the least valuable one, and
  the sentence above is worth more than the feature.
- `security-check.sh` (PreToolUse) was a strictly weaker duplicate of
  `secret-scan.sh`, which ran beside it.
- `enforce-merge-approval.sh` (PreToolUse) returned `ask` on every `gh pr merge`,
  which hangs an unattended run on an approval nobody is present to give. Merge
  authorization is now decided mechanically by `merge-gate.sh` against on-disk,
  commit-pinned evidence.

Removal is not just "we stopped shipping them": `install.js` carries them on an
explicit superseded list, strips their wiring out of your `settings.json`, and
deletes the script — but only where its own manifest proves it wrote that file,
and only after taking a backup. A same-named script it never installed is left
alone.

## The hooks

"Blocks" means the hook can stop an action from happening. Claude Code's contract:
a `PreToolUse` hook blocks by printing a `permissionDecision` JSON object and
exiting 0; a `Stop`/`SubagentStop` hook blocks by printing
`{"decision":"block","reason":...}` and exiting 0. A `PreToolUse` deny fires
**beneath** the permission system, so it still applies under
`--dangerously-skip-permissions`.

| Hook | Event | Matcher | Reads | Can block | Writes | Network |
|---|---|---|---|---|---|---|
| `session-state.sh` | SessionStart | `startup\|resume\|compact` | `.quetrex/{state.json,ESCALATION,verify-attempts,review-verdict.json,plan/*}` and the current branch | no (SessionStart ignores blocking; its stdout is added to context) | nothing | none |
| `workflow-reminder.sh` | UserPromptSubmit | — | nothing (emits a fixed string) | no | nothing | none |
| `deny-guard.sh` | PreToolUse | `Bash` | the command string | **yes** — recursive deletes of `/`, `~`, `.`, `..` or a system directory; `git reset --hard`; `git clean -f`; unconditional force-push | nothing | none |
| `secret-scan.sh` | PreToolUse | `Bash`, `Write\|Edit` | the command string (Bash), the file body being written (Write/Edit) | **yes** — a hardcoded provider key or a high-entropy secret assigned to a secret-named key; and it asks (auto-denied under `dontAsk`) when a secret **file** (`.env`, `id_rsa`, `.npmrc`, `credentials.json`, …) appears in the same command as an egress verb (`curl`, `scp`, `rsync` to a remote, …). The matched token is masked in the refusal; it is never echoed back in full | nothing on disk. On a Bash call carrying a high-confidence provider key it returns `updatedInput` with that token replaced by `__QUETREX_REDACTED_SECRET__`, so the literal secret is not persisted into the transcript. Write/Edit is always a refusal, never a rewrite — a redacted placeholder written into a file would leave the agent believing it holds a working credential | none |
| `enforce-branch.sh` | PreToolUse | `Bash` | the command string, plus `git branch --show-current` in the target directory | **yes** — `git commit` / `git push` while on `main`/`master`. Tag pushes are exempt | nothing | none |
| `merge-gate.sh` | PreToolUse | `Bash` | the command string, `git rev-parse HEAD`, the diff against the default branch, and `.quetrex/{verify.json,verify-ledger.jsonl,review-verdict.json,security-findings.json,ESCALATION,plan/*}` | **yes** — `gh pr merge` or a direct merge/push to the default branch, unless every on-disk gate is green **for the exact commit being merged** | nothing | none |
| `auto-format.sh` | PostToolUse | `Write\|Edit` | the edited file's path | no (PostToolUse runs after the call) | rewrites the edited file, and only when a `biome` config is present | none of its own — see nuance 1 |
| `edit-gate.sh` | PostToolUse | `Write\|Edit` | the edited file's path and the check command resolved from `.quetrex/verify.json` | no — the edit already happened; it exits 2 to feed the type/lint error straight back for a fix | nothing (never `--fix`) | none of its own — it runs your project's checker on one file |
| `verify-gate.sh` | Stop, SubagentStop | — | `.quetrex/verify.json`, else the `## Verification` block of `.claude/CLAUDE.md`, else your `package.json`/`Makefile`/`pyproject.toml`/`go.mod`/`Cargo.toml` | **yes** — refuses to end the turn while your verify chain is red | `.quetrex/verify-ledger.jsonl`, `.quetrex/verify-attempts`, `.quetrex/ESCALATION` | none of its own — see nuance 2 |

`merge-gate.sh` and `verify-gate.sh` are **per-project** gates. They are
deliberately not installed into your user-scope configuration and deliberately
not wired by the plugin, because they execute a command chain read from a
repository file and that should only ever happen in a repository you have opted
in. `/q-init` copies them into the target repo's own `.claude/` and wires them
into that repo's committed `.claude/settings.json`, so they also travel to a
cloud runner, which sees only what is committed.

`/q-init` copies **every** hook it wires — `verify-gate.sh`, `merge-gate.sh`,
`edit-gate.sh`, `secret-scan.sh`, `deny-guard.sh`, `enforce-branch.sh`,
`auto-format.sh`, `session-state.sh` — and commits them alongside the wiring.
That is deliberate and it is checkable: a wired hook whose script is missing
exits 127, and Claude Code treats any exit other than 0 or 2 as non-blocking. A
gate that silently is not there is worse than no gate, so the copy list and the
wiring list are generated from one another. `workflow-reminder.sh` is the single
hook `/q-init` does not deploy — it is a context nudge, not a gate.

## What Quetrex does not do

- No hook calls a Quetrex server, an analytics endpoint, or any third party.
- No hook reads your shell history, your SSH keys, your browser, or anything
  outside the repository you are working in and its `.quetrex/` directory.
- No hook uploads a diff, a file, or a prompt anywhere. Your code reaches
  Anthropic only through Claude Code itself, under your own account and your own
  data-retention settings — Quetrex adds no other destination.
- No hook installs software. `install.js` (the npm package's `postinstall`)
  writes only under `~/.claude/`, and CI installs run with `--ignore-scripts`.

## Permissions Quetrex asks for

The shipped profile sets `defaultMode: "dontAsk"` — only pre-approved tools run,
everything else is auto-denied with no prompt. That is the correct mode for
unattended pipeline runs: nothing hangs waiting for an approval nobody is present
to give, and nothing new is silently allowed. The allow-list is in
`.claude/settings.json`, in plain text, and it is short.

Two pipeline agents (`developer`, `qa`) declare `bypassPermissions` in their
frontmatter because they run inside disposable git worktrees. The `PreToolUse`
hooks above still fire for those agents — a deny runs before the permission
engine, not after it.

## Reporting a vulnerability

Open a private security advisory on the repository, or contact the maintainer
directly. Please do not open a public issue for an unpatched flaw.

## Keeping this page honest

This table is a contract, not documentation. **Adding, removing, or re-wiring a
hook requires updating the row in the same change.** A hook that fires on a
customer's machine without a row here is a defect, and it is reviewable as one.
