# Anthropic "Claude Code in Action" — full course capture

Source: https://anthropic.skilljar.com/claude-code-in-action/ (read 2026-07-29, authenticated).
All 9 lessons captured verbatim-in-substance below. The Course Quiz (11 questions) contains no teaching content.

---

## L1 — Steering Long Sessions (`/486901`)

Thesis: long tasks (hours, dozens of files) need two habits — **scope before Claude starts, steer while it runs**.

**Scope first with plan mode.** Claude researches read-only and hands back a plan. *Actually read it, don't skim.* Iterating on a plan is much faster than letting Claude run and cleaning up after.

**Steering levers while running:**

- **`/compact`** — summarizes conversation, uses the summary as new context, deletes old messages. Risk: something important gets dropped and Claude drifts. **Never run bare `/compact`** — append instructions that shape what the summary keeps, e.g. `/compact Focus on the --version flag implementation`. "That's your steering wheel for context."
- **Rewind** — every user prompt creates a checkpoint. **Double-tap Escape on an empty prompt** to open the menu. Five options:
  - Restore code and conversation
  - Restore conversation only
  - Restore code only
  - **Summarize from here** — compress everything *after* the checkpoint (good for killing a side conversation)
  - **Summarize up to here** — compress everything *before* the checkpoint (good for compressing a long setup phase while keeping implementation intact)

**Autonomy levers:**

- **`/goal`** — sets a *completion condition*. Claude keeps working across turns until a fast evaluator confirms the conditions are met; it won't stop the first time it thinks it's done. Example: `/goal all tests in src/billing pass, and the type checker reports zero errors`. Cancel with `/goal clear`. **Hard constraint: the evaluator only reads the transcript**, so the condition must be checkable from output Claude actually produces (e.g. test-run results).
- **`/loop`** — runs a prompt on an interval between turns, fixed or self-paced. Use to poll something external (CI run, deploy) and act when state changes. Stop with Escape.

**Parallel work with worktrees.** "You don't want two steering wheels in one car." Each session gets its own independent file tree; agents can't clobber each other. **A clean worktree is automatically removed when the session exits.** A **`.worktreeinclude`** file at repo root lists *git-ignored* files to copy into each worktree (env files, local config you need everywhere but won't commit).

---

## L2 — A CLAUDE.md That Follows (`/486929`)

Thesis: **CLAUDE.md is not enforced configuration — it is guidance.** Every line competes with every other line for attention. The longer the file, the more it competes with itself and the less reliably any single rule is followed. The goal is not to write down everything; it's to keep the file tight.

**First ask whether CLAUDE.md is the right surface at all.** Example: "never push to main" in CLAUDE.md is a hope. That is a hard line and **belongs in a PreToolUse hook**, which is code that runs and can actually block. "Move your hard rules to hooks and let CLAUDE.md handle the softer conventions."

**Four locations, all loaded together at launch, nothing dropped, they stack:**

1. **Managed policy** — org-level, platform-team controlled, **cannot be excluded**.
2. **User** — personal preferences following you across every project on the machine.
3. **Project** — shared with the team, checked into the repo.
4. **Local** — git-ignored, personal notes for one repository only. Called out as easy to overlook but very handy — e.g. architectural decisions you want held during your own refactor without affecting the team.

**Imports.** Break a long project file with path-to-file import syntax:

```
@.claude/conventions/code-style.md
@.claude/conventions/testing.md
@.claude/conventions/workflow.md
```

**Critical caveat:** imports are expanded inline at launch. They help you *organize*; they **do not reduce the context Claude reads**. "Use imports to organize, not to shrink the load."

**Phrasing rules that make rules stick:**

- **Be specific and checkable.** Vague: "Follow best practices for API routes." Specific: "Put new API routes in `src/api/handlers`, one per file." If you can't check whether it was followed, neither can Claude.
- **Name the replacement, don't just ban.** Open: "Don't use default exports." Closed: "Use named exports, not default exports."
- **Emphasis is a budget.** "IMPORTANT"/"YOU MUST" raise priority only *relative to quieter text around them*. If every rule shouts, nothing stands out. Spend it on the two or three rules that really hurt when broken.

**Keep the file under revision.** When Claude does the wrong thing, treat it as a **bug report against CLAUDE.md**, not something to fix by hand. You can say "add that to the CLAUDE.md file" and Claude writes the rule.

Bottom line: treat CLAUDE.md like production code — **if you can't justify a line, delete it.**

---

## L3 — Verification Skills (`/486930`)

Thesis: **if there's one skill worth building first, it's a verification skill.**

**Why.** Normally checking Claude's work depends on *you remembering to ask*. Skip it once and bad code ships. A verification skill removes that dependency: the change matches the skill's description, so **the skill fires on its own**. Then it:

1. Runs the test suite.
2. Reads the diff.
3. **Checks that no test was weakened just to make things pass.**
4. Reports pass or fail, **with the evidence attached**.

Emphasis on step 3: "It's not enough to run the tests and see green. A test can be quietly loosened so it passes no matter what." And: **"Done isn't 'the code looks right' from reading the diff alone. Done is the gates being run and observed, with the results stated explicitly."**

**Rule of thumb: if you've typed the same multi-step instruction twice, that's a skill.** Same shape carries a release checklist, a migration recipe, a pre-PR check.

**A skill folder holds more than instructions** — this is what makes skills powerful for verification:

- **`reference.md`** next to the skill for detailed material, linked from `skill.md`. Claude reads it only when it needs that depth; the main file stays short.
- **Scripts in the folder.** **Claude executes them rather than loading their contents into context.** So a skill can carry its own tooling — e.g. a `check.sh` that runs all the gates.

Takeaway: keep `skill.md` lean; push heavy material and executable scripts into side files.

**Which instruction surface owns which rule:**

| Rule type | Surface |
|---|---|
| Conventions that apply all the time (naming, where files go) | CLAUDE.md |
| Procedures + reference material tied to a kind of task | Skill |
| A rule Claude **must not be able to skip** | **Hook** — code that actually runs, not instructions Claude follows |

Only skill *descriptions* load into context until a skill is needed, "so there's no cost to packaging every procedure you repeat." Check it into `.claude/skills` and the whole team inherits the same move.

---

## L4 — Permission Modes (`/486932`)

**Six modes:**

| Mode | Behavior |
|---|---|
| **Manual** | Reads only, without prompting. Everything else asks first. |
| **Accept edits** | Reads, file edits, and common filesystem bash commands without asking. For iterating on code you review after the fact. |
| **Plan** | Reads only. Researches and proposes without editing. |
| **Auto** | Accepts everything, with **a separate classifier model reviewing each action before it runs**. |
| **Don't ask** | **Only pre-approved tools are allowed. Everything else is auto-denied with no prompt.** |
| **Bypass permissions** | Skips all checks; equivalent to `--dangerously-skip-permissions`. **Only run inside an isolated container or VM.** |

**shift-tab** cycles the everyday four: manual → accept edits → plan → auto. The status bar always shows the current mode.

**How auto mode works.** A separate classifier reviews each action before execution. **The classifier guards *intent*** — it watches for moves that escalate beyond what you asked. Designed to block: production deploys and migrations; force pushing; piping downloaded code straight into a shell; sending sensitive data to external endpoints; destroying files that exist for the session. Waves through: local edits in your project, installing deps from your lock file, read-only requests, pushing to your own branch.

**What the classifier can't do — the key point.** "The classifier checks intent, not correctness. It won't catch whether the code actually works. If you ask Claude to refactor authentication and it writes broken authentication, the classifier waves it through, **because broken isn't dangerous.**"

**Therefore: pair auto mode with a Stop hook that runs your tests.**
- Auto mode watches **what Claude is trying to do, while it runs** (intent, before each action).
- The Stop hook confirms **the code actually runs, once Claude finishes** (correctness, after).

Auto mode's guardrails are still evolving — check docs for current block/allow lists.

**Don't ask is the mode for unattended runs**: CI pipelines, scheduled jobs, overnight batches. Only pre-approved tools allowed; anything else auto-denied with no prompt, so **the pipeline keeps moving instead of hanging on an approval no one is there to give.**

---

## L5 — Hooks (`/486933`)

Thesis: CLAUDE.md is a request, not a guarantee. **A hook is deterministic code at a fixed point in the loop — it turns "Claude usually listens" into "Claude can't skip it."**

**Claude Code fires around 30 hook events.** The ones worth knowing:

- **PreToolUse** — before a tool call. **"This is your enforcement primitive."** The one that can stop something before it happens.
- **PostToolUse** — after a *successful* tool call. Usually auto-formatting / auto-lint.
- **Stop** — when Claude wants to end its turn. **You can refuse and say "no, you're not done yet."** Matching **SubagentStop** for sub-agent completion.
- **PreCompact / PostCompact** — before and after compaction.
- **InstructionsLoaded** — when a CLAUDE.md or rule file loads. **Handy for auditing what actually made it into context.**
- **SessionStart** — at session start, primes the environment. Use the `startup` source for fresh starts only.

**Gotcha called out explicitly:** to re-inject context after compaction, **do not use PostCompact — use SessionStart with the `compact` matcher.** That's the one whose output actually gets back into the conversation.

**PreToolUse JSON contract** — print JSON and **exit zero**. Key field `permissionDecision`:

- `allow` — let the call through
- `deny` — stop the call
- `ask` — hand back to the user
- (`defer` — technically a fourth value, only for non-interactive `-p` runs where a calling process pauses the tool and resumes later. Rarely used.)

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "...",
    "updatedInput": { "command": "..." }
  }
}
```

**`updatedInput` — the lesser-known, more interesting move.** Instead of blocking, **rewrite the call**. That's how you redact a secret out of a bash command *and still let it run*. **Catch: `updatedInput` replaces the whole input object**, so echo back the fields you aren't changing or you lose them.

**Exit codes, for hooks that don't return JSON:**

- **`0`** — success. If stdout is JSON, Claude parses it. Plain text is ignored on most events, **but on SessionStart, UserPromptSubmit, and UserPromptExpansion, plain text gets added to context** (this is what makes a state-preserver hook work).
- **`2`** — **blocking error. stderr is fed back to Claude as context.** This is the blocking exit code almost everywhere.
- **Anything else** — non-blocking; stderr logged, Claude carries on.
- **The trap: exit code `1` does NOT block.** "It feels like an error, but Claude runs the command anyway. If you meant to stop something, exit 2, not 1."

More wrinkles: **exit 2 can block Stop**, which is how you tell Claude it's not done. **PostToolUse fires after the tool already ran**, so blocking there is too late to stop the call (it can still feed text back). A few events **ignore blocking entirely** — Notification, SessionStart.

**Worked example — redact instead of block.** PreToolUse on Bash; matcher picks the tool, an optional `if` clause narrows to a specific command. Obvious move is `deny`. The better move is `updatedInput`: the hook spots an `sk_live_` pattern and swaps it for a placeholder before the command executes. **The command still ran, the work still got done, the secret never made it through.**

**Preserving state across a compact.** A SessionStart hook with the `compact` matcher runs right after compaction; have it print a short summary of files you've been working on so Claude picks up where it left off instead of starting cold.

Wrap-up: "Reach past auto-formatting: guard tools with PreToolUse, gate the turn with Stop, and preserve state across a compact."

---

## L6 — Routines and Headless (`/486935`)

Framing: **a spectrum.** One end = routines on Anthropic's managed infrastructure (build nothing). Other end = headless mode / Agent SDK, run from your own code (full control).

### Routines

A routine bundles **a prompt + the repository it works on + any connectors it needs**, and runs that bundle in the cloud when triggered. **Infrastructure is Anthropic's** — no machine of yours staying on overnight, no workflow file to maintain.

**Triggers:**
- A **cron schedule** (e.g. every morning at 9am)
- **An HTTP POST to its API endpoint**, so your own code can kick it off
- **A GitHub event**, like a new pull request landing

Good fits: morning dependency audit, PR triager firing on new PRs, daily Sentry-ticket scan for urgency.

**Two ways to create one:**
- Web at **`claude.ai/code/routines`** — name, instructions, repository, trigger.
- From inside Claude Code: **`/schedule`** with plain language, e.g. `/schedule daily dependency audit at 9am`.

**Three limits to know before relying on routines:**
1. **Research preview** — behavior and limits will keep moving.
2. **A recurring schedule runs at most hourly.** Need more frequent? Routines aren't the tool.
3. **Each run starts from a fresh clone of your default branch and can only push to `claude/`-prefixed branches** unless loosened per repo. "This is the guardrail that keeps an autonomous run from rewriting main."

### Headless mode

**`-p` / `--print`** — one-shot, no interactive UI, reads stdin and writes stdout, pipes like any shell tool: `claude -p "summarize the changes in this diff"`.

**Important:** **`-p` skips auto-discovery of hooks, skills, plugins, MCP servers, and the CLAUDE.md file.** You get Claude plus explicitly-allowed tools and nothing the local environment happens to load. Upside: much faster startup.

**Structured output** — pair a JSON schema with the JSON output format; Claude constrains output to match. The object lands in the **`structured_output`** field:

```bash
claude -p "Extract the exported function names from src/core/style.js" \
  --output-format json \
  --json-schema '{"type":"object","properties":{"functions":{"type":"array","items":{"type":"string"}}},"required":["functions"]}' \
  | jq '.structured_output.functions'
```

**Multi-step automation with sessions** — capture the session ID from JSON output and resume later:

```bash
claude --resume "$(jq -r .session_id /tmp/plan.json)"
```

One script kicks off the work, another resumes it with full context (first pass produces a plan, second carries it out).

**Deterministic runs for CI** — **`--bare`** gives deterministic mode. Right choice inside a pipeline when you want repeatable, predictable output rather than anything that varies run to run.

### Agent SDK

Library embedding Claude Code inside your own TypeScript or Python app. Both expose a `query` function and the same primitives as the CLI: `allowedTools`, a system prompt, a permission mode. Iterate over streamed messages.

**Decision guide:** Routines are the default for repeat work → headless `-p` when the job needs your pipeline → `--bare` when CI needs identical results every run → Agent SDK when the work belongs inside your own product. "Start with routines. Drop down the spectrum only when the job actually needs the extra control."

---

## L7 — GitHub Actions and Code Review (`/486936`)

Two distinct tools for PR work.

### Managed path: Code Review

Anthropic-hosted service reviewing PRs through the Claude GitHub app. Nothing to build or host. An **org admin** enables it from **Claude Code admin settings → Code review section → Configure**, installs the Claude GitHub app, picks repos, and chooses timing:

- Once when a PR opens
- On every push to the PR
- Only when someone comments **`@claude review`**

Review agents **analyze the diff against your full codebase, not just the changed lines in isolation**, then post findings as **inline comments on specific lines, tagged by severity, with a summary table in the check run**. It **deduplicates and ranks** findings so you read a handful of real issues instead of a wall of nitpicks.

**Boundaries:**
- **It never approves or blocks the PR.** The judgment call stays with a human.
- **There is no managed autofix.** Findings only.
- **Research preview, available on team and enterprise plans.**

Applying a finding is a **local** move: **`/code-review`** reviews a diff and **`--fix`** applies findings to your working tree. Flow: Claude finds it in the PR → you pull down and fix locally.

### DIY path: the GitHub Action

For when the job goes **beyond review** — implementing changes from a comment, scheduled reports, any custom CI. Runs on PR comments, scheduled jobs, and any GitHub event.

Setup starts inside Claude Code: **`/install-github-app`** (needs repo admin). It walks you through installing the GitHub app and setting the Anthropic API key secret.

Action is **`anthropics/claude-code-action@v1`**. Inputs:

- `anthropic_api_key` — optional
- `github_token` — defaults to `secrets.GITHUB_TOKEN`
- `trigger_phrase` — what it listens for in comments; defaults to `@claude`
- `use_bedrock` / `use_vertex`
- `prompt` — the instruction for the run
- `claude_args` — a string of CLI arguments passed straight through to Claude Code

Workflow at `.github/workflows/claude.yaml`:

```yaml
- uses: anthropics/claude-code-action@v1
  with:
    anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    trigger_phrase: "@claude"
    prompt: "Your instructions here"
    claude_args: "--max-turns 5 --model claude-sonnet-5"
```

Same action works for a cron daily rollup; add `workflow_dispatch` to kick off manually from the Actions tab.

**Tuning with `claude_args`:**
- **`--max-turns 5`** — hard cap on the agent loop so it can't run forever.
- **Permission mode** — for an unattended job, one that won't stop and ask, since no one is there to answer.
- **Allowed tools** — exactly what it needs and nothing more; for a report, read-only.

**Guidance:** managed Code Review for PR reviews + `/code-review --fix` locally. Reach for the action "the moment you need Claude to actually *do* something in CI, not just comment on it."

---

## L8 — Trust It: Verifying Unsupervised Runs (`/486938`)

Core principle: **verify in proportion to how much rope you gave the run. "The less you watched, the more you verify."**

**Keep unattended runs in auto mode, not bypass permissions.** In auto mode the classifier still reviews each action for danger — a safety net worth keeping. **But be clear about what it doesn't do: the classifier never judges whether the code is correct, only whether an action is dangerous.** So your verification bar stays exactly where it was.

**Start with the diff, not the summary.**
1. Run **`/code-review`** to walk the changes and flag issues.
2. Then put your own eyes on **`git diff`**.

**The trap:** "a tidy summary that reads perfectly fine, while the actual diff touched a file you honestly didn't expect it to touch. The summary won't tell you that. The diff will." Read the files that were part of the plan first, **then look for anything outside it. A clean write-up is not proof of clean code.**

**Turn tests into a gate, not a promise.** The real gate is whether tests passed **and whether Claude actually ran them or only claimed it did**. Don't leave that to trust — wire it as a hook:

- **A Stop hook that runs your tests and refuses to end the turn on failure.**
- **A PostToolUse hook that lints and type checks after every edit.**

**The key detail is the exit code: a hook that exits `2` feeds the failure straight back to Claude**, which reads it and fixes it without you asking. And **the check fires on every run whether or not you remember to ask.**

**Get a cold second opinion.** Open a **fresh session or sub-agent** to review the changed code **with no memory of how the code was built**. "Because it has no stake in the approach, it catches the things the original run talked itself past. A second reviewer with fresh eyes finds what the author rationalized away."

**Putting it together:**
- Read the diff yourself.
- Turn the tests into a hook that gates the turn.
- **Verify headless runs by their JSON result and exit code.**
- Get a cold second opinion on anything that matters.

---

## L9 — Plugins (`/486939`)

Problem: you build a great `.claude` directory and then everyone copies and pastes files between machines and hopes they stay in sync. **A plugin is how Claude Code packages a setup and moves it from one person to the next.**

**What a plugin is.** One installable unit bundling skills, subagents, hooks, and MCP server configs, **plus the longer tail: language server protocol servers, background monitors, themes, and a slice of `settings.json`.** One version, one install.

**Installing:**
- By name in a session: **`/plugin install org-name@plugin-name`**, then **`/reload-plugins`** to apply.
- For a team, add a **private marketplace** once: **`/plugin marketplace add your-org/claude-plugins`**. Every install after resolves through it — **centralized discovery, version tracking, and updates in one place.** Browse from the **Discover tab**.

**Read before you install — the part that matters most.** "A plugin runs code on your machine, with your privileges. Its hooks fire on every matching tool call. So if you install a plugin for its skills, **you also get its PreToolUse and Stop hooks whether you read them or not.**" A community plugin could ship a Stop hook calling a network endpoint every time and nothing in your config would warn you.

Claude Code shows what it will install and **estimates the context cost**, with a plain warning that Anthropic doesn't control third-party plugin contents. Two sourcing facts: **the in-app submission form posts to the community marketplace after Anthropic's automated review; the official marketplace is curated on a separate track.** **"Reviewed isn't the same as trusted."**

**Components run alongside yours, they don't overwrite:**
- **Hooks stack.** A plugin's PreToolUse and your own both fire on every tool call. Neither replaces the other. "This is exactly why you read the details first."
- **Skills, agents, and commands are namespaced under the plugin name**, so they never clash.
- A plugin can ship a `settings.json` but **Claude Code honors just two keys from it: the agent and subagent status line keys.** **The `agent` key promotes one of the plugin's subagents to the main thread — along with its system prompt, tool restrictions, and model.** So enabling a plugin can change how Claude Code behaves by default.
- Manage/uninstall and see everything a plugin added from the **plugin panel**.

**Packaging your own.** No restructuring needed — a plugin uses the same `.claude` shape you already use:
- One folder per skill
- One markdown file per subagent under `agents`
- **`hooks/hooks.json` and `.mcp.json` at the plugin root**

Claude Code discovers components **by directory convention**.

**Manifest** at **`.claude-plugin/plugin.json`** — optional:

```json
{
  "name": "svg-splitter-review",
  "version": "0.1.0",
  "description": "Reviews the SVG Splitter repo",
  "author": { "name": "Lewis Menelaws" }
}
```

- **`name` is the only required field.** It **namespaces skills as `company-name:skill-name`**, preventing collisions.
- **Version it like any other dependency** — that's what makes updates and version tracking work across the team.

Two rules: **read before you install**; **package your `.claude` the moment it works.**
