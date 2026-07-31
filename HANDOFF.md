# Handoff — what cannot be done inside this repository

Everything in the fix program that could be closed with a file change has been.
This page is the remainder: work that requires an account, an admin right, or a
different repository. Each item states **what it unblocks** and **what to do**,
so none of it has to be rediscovered.

Ordered by what the product is blocked on, not by effort.

---

## 1. Create the build routine and its HTTP POST endpoint

**Unblocks:** the product itself. Quetrex is sold as a routine-fired kanban —
scope is approved from a phone and the build runs with nobody at a terminal.
Today every entry point is a human typing a slash command, and the approval gate
in `/q-task-build` is a conversational turn in a session that has to stay alive
across the wait. A routine is the only documented mechanism that starts a run on
Anthropic's infrastructure with no terminal.

**Do:**

1. Create the routine — either at `claude.ai/code/routines` (name, instructions,
   repository, trigger) or with `/schedule` from inside Claude Code.
2. Give it the **HTTP POST** trigger, not only a cron schedule. A recurring
   schedule runs at most hourly; 60-minute latency breaks the product promise.
   Keep an hourly cron as *reconciliation* for dropped POSTs, never as the
   primary path.
3. Its instruction is the post-approval half of `/q-task-build`: take the task
   id, run the pipeline from architect to PR.
4. Record the endpoint URL in each project's `.quetrex/project.json` so the
   kanban knows where to fire.
5. Pass `--max-turns` on the routine so an unattended run is bounded.

**Note:** routines are a research preview; behavior and limits move.

---

## 2. Kanban: add the `scope_approved` transition and the outbound POST

**Unblocks:** item 1 having something to fire it. Repository:
**quetrex-kanban**, not this one. `quetrex-api.sh` here is entirely outbound
(terminal → kanban); nothing fires inbound.

**Do:** add the `scope_approved` status transition to the board, and on entering
it, POST to the project's routine endpoint (from
`.quetrex/project.json`) with the task id. That single edge is what turns
"tap Approve on your phone" into a running build.

---

## 3. Loosen the branch restriction, per repository

**Unblocks:** the pipeline having a terminus under a routine. Each routine run
starts from a fresh clone of the default branch and **can only push to
`claude/`-prefixed branches** unless loosened per repo. Every branch Quetrex
creates is `feature/*`. `git-workflow`'s `git push -u origin "$BRANCH"` fails, so
there is no PR and the run ends nowhere. `/q-init`'s own
`feature/q-init-adopt` push breaks the same way.

**Do this in the right order.** The restriction is currently the only real
guardrail keeping an autonomous run off `main`. Confirm `merge-gate.sh` is wired
and passing in the target repo **first**, then loosen the branch prefix for that
repo in its routine settings.

**The fallback is now built**, so this is a preference rather than a blocker:
`.quetrex/project.json` carries a `branchPrefix` field (`/q-init` chooses and
records it, and backfills already-linked repos), and `q-task-build`,
`q-task-rework` and `dev-pipeline.md` construct every branch from it —
`feature/` is nowhere hardcoded. Set it to `claude/` on any repo you would
rather not loosen and the pipeline works unchanged.

**Untested — do not assume:** whether `gh pr merge` is affected. That is an API
merge under the token's permissions, not a push.

---

## 4. Install the GitHub app and set the API key secret

**Unblocks:** `.github/workflows/claude-review.yml`, which cannot start without
it. That workflow is what makes it structurally impossible for the agent
deciding the merge verdict to also be the agent reporting whether independent
review ran — the exact self-exemption that shipped an `AUTO_MERGE` over 18 files
with `"nativeReview": "not_run_no_pr"`.

**Do:** run `/install-github-app` from inside Claude Code (needs repo admin). It
walks through installing the app and setting the `ANTHROPIC_API_KEY` secret. Then
open a throwaway PR and confirm the **review gate** check appears and that its
conclusion tracks the verdict.

---

## 5. Turn on branch protection for `main`

**Unblocks:** the gates being gates. `main` is currently unprotected, so a red
check is advisory and a merge can route around every artifact the pipeline
produces.

**Do:** Settings → Branches → protect `main`, and mark these as **required
status checks**:

- `verify chain` (from `.github/workflows/verify.yml`)
- `review gate` (from `.github/workflows/claude-review.yml`)

Also require a PR before merging, and allow squash merges only.

---

## 6. Publish the plugin to the private marketplace

**Unblocks:** distribution without copy-paste drift between machines. The
manifest is committed at `.claude-plugin/plugin.json`, name **`q`** (commands
namespace as `/q:task-build`, `/q:init`).

**Do:** add the plugin to the marketplace repo
`Glori-Holdings/quetrex-plugins`; partners then run
`/plugin marketplace add Glori-Holdings/quetrex-plugins` once, and
`/plugin install Glori-Holdings@q` plus `/reload-plugins` thereafter. Version it
like any dependency — that is what makes update tracking work.

**On licensing:** a git-sourced private marketplace's access control is only the
git repo's, no stronger than the current `npm install -g github:` path, and
neither claws back files a customer already has. The enforceable boundary is the
**kanban API token**: with no token every `q-task-*` command is inert markdown.
Put the seat check and expiry at token issuance, server-side, and use the
marketplace only for discovery and versioning.

---

## Plugin packaging notes

Three things about plugins that are easy to get wrong and expensive to discover
late:

**A plugin's `settings.json` is honored for only two keys** — the agent and
subagent status-line keys. So `permissions.allow` **cannot travel in the
plugin**. That matters concretely: `git-workflow` runs in `acceptEdits`, and its
job is `git push` and `gh pr create`, neither of which counts as a common
filesystem bash command. Those run silently today only because
`Bash(git push:*)` and `Bash(gh pr:*)` are allow-listed. Ship the allow-list
through **`/q-init`** into the customer's own project settings, or the terminal
stage of an unattended run hangs.

**Keep `quetrex-install-project-gates.sh`.** A plugin installs **per user**, so
it replaces the *global* channel only. A cloud routine clones the repo and sees
nothing but what is committed — no plugin, no `~/.claude`. Delete the
per-project installer and every routine loses all enforcement, silently. The
plugin and the installer cover different machines; neither is redundant.

**`hooks/hooks.json` now points at `${CLAUDE_PLUGIN_ROOT}/.claude/hooks/<name>.sh`
— the real location — rather than `${CLAUDE_PLUGIN_ROOT}/hooks/`, where no script
has ever existed.** Every plugin-side hook path used to resolve to nothing, which
exits 127 — **and anything other than exit 0 or 2 is non-blocking**, so the
enforcement layer failed open with no error. A test now asserts that every path
in `hooks/hooks.json` resolves to a file that exists, so no packaging step is
needed and this cannot silently regress. Still verify after packaging that a hook
actually fires before shipping a version.

**Unresolved, and it needs a person:** plugin discovery of `agents/`, `commands/`
and `skills/`. Claude Code looks for those at the plugin root; this repo keeps
them under `.claude/`. `hooks/hooks.json` is the one component that reads its
target path from a file we control, which is why it could be fixed here. Confirm
against the current plugin schema whether `plugin.json` accepts explicit path
fields for the other three, and if it does not, the packaging step has to place
or symlink them at the root. **Do not publish a version until you have installed
it and confirmed `/q:init` appears.**

**What the plugin channel deliberately omits:** `verify-gate.sh` and
`merge-gate.sh` are not wired in `hooks/hooks.json`. They execute a command chain
read from a repository file, which should only ever happen in a repo the user has
opted into. They travel per project via `/q-init`, which also makes them
committed — and therefore visible to a cloud runner. This is intentional; do not
"fix" it by adding them to the plugin.

**Keep `SECURITY.md` in step.** The plugin panel shows a reviewer the hook count
before they read a word of marketing. Every hook wired in `hooks/hooks.json` or
in `.claude/settings.json` must have a row in `SECURITY.md`, in the same change.

---

## Repository follow-ups that belong to a person, not a file

- **`~/.claude/CLAUDE.md` is no longer shipped by `package.json` — CLOSED.** The
  generic doctrine lives in `.claude/quetrex-doctrine.md` (user scope), the
  project file is cut to what is true of this repo, and `install.js` now seeds
  `~/.claude/CLAUDE.md` from `.claude/templates/global-CLAUDE.md` **only when
  absent** (an `@quetrex-doctrine.md` import plus an empty `# LESSONS`).
  `CLAUDE.md` is in `PROTECTED`, so an existing copy is never overwritten and
  never pruned. Two tests cover it, including one asserting `package.json`'s
  `files` actually ships the template — otherwise the seed is dead code in the
  published tarball, which is exactly how this broke the first time.
- **`.claude/templates/` is now in `package.json`'s `files` list**, and was not
  before. `quetrex-install-project-gates.sh` resolves its seed chain from
  `~/.claude/templates/verify.json` and `fail`s hard when that file is absent —
  so on any machine that installed only from npm, `/q-init` could not have
  reached the point of writing a verify chain. Worth a one-time check on an
  existing install: if `~/.claude/templates/verify.json` is missing, re-install.
- **Machine- and company-specific rules** (the Fly.io per-company token rule, in
  particular) were removed from the committed `CLAUDE.md` — they were being
  shipped to strangers. They belong in a git-ignored `.claude/CLAUDE.local.md`,
  which the `.gitignore` now covers.
