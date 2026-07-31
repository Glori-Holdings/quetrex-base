# quetrex-base capability inventory (evidence-grounded)

Repo: `/Users/barnent1/Projects/quetrex-base` · branch `refactor/q-command-prefix` · npm `quetrex-base@2.0.1`.
Produced by reading every file under `.claude/` plus README.md, install.js, package.json, test/, docs/, `.quetrex/`.

## THE FRAMING FACT

Three layers must not be conflated:

| Layer | Location | Actually executes? |
|---|---|---|
| Scripts/agents shipped in this repo | `<repo>/.claude/**` | Only if wired into a settings.json somewhere |
| This repo's project settings | `.claude/settings.json` | Yes, for sessions in this repo |
| Operator's global install | `~/.claude/**` (written by `install.js`) | Yes, globally |

`.claude/settings.json:41-99` wires **6** hooks, all pointing at `~/.claude/hooks/*` — not at this repo's own `.claude/hooks/`. The two flagship gates, `verify-gate.sh` and `merge-gate.sh`, are **wired nowhere** (verified: the global `~/.claude/settings.json` wires deny-guard, enforce-branch, enforce-merge-approval, secret-scan, security-check, auto-format, workflow-reminder, check-quetrex-update — no verify-gate, no merge-gate). `install.js:39-41` says this is deliberate: they are "PER-PROJECT gates installed by q-init, never wired into the global settings." **quetrex-base has never run `/q-init` on itself**, so its own most sophisticated enforcement is inert here.

Worse: the global install wires `enforce-merge-approval.sh`, whose own header (`.claude/hooks/enforce-merge-approval.sh:2-14`) declares it **superseded** by `merge-gate.sh`. The live merge policy is the old "always prompt a human" one while all docs describe the artifact-gated model.

## 1. Steering / long sessions

Three independent bounds:
- **Verify self-heal bound** — `verify-gate.sh:62` `MAX_ATTEMPTS="${QUETREX_VERIFY_MAX:-3}"`; counter `.quetrex/verify-attempts` (`:88`), incremented `:324-328`; at cap writes `.quetrex/ESCALATION` and blocks once more ordering the agent to stop self-healing (`:345-347`).
- **Review rework bound** — `reviewer.md:131` (`ESCALATE_HUMAN if escalation_present or review_iter >= 3`), counter `.quetrex/state.json .review_iter`, incremented on every REWORK (`reviewer.md:195-205`).
- **Wall-clock budget** — `verify-gate.sh:101-116`: `QUETREX_VERIFY_BUDGET` default 840s (Stop) / 540s (SubagentStop), under the external hook timeout; per-command `timeout`/`gtimeout` with a background-SIGKILL watchdog (`:247-268`). Budget exhaustion is **RED, not skipped** (`:275-289`) — fail-closed on timeout.

**Escalation-on-uncertainty is a first-class verdict.** `reviewer.md:140-144` lists four uncertainty conditions forcing `ESCALATE_HUMAN`, including "the native `/review` or `/security-review` errored or could not run on a non-trivial change." `reviewer.md:129`: "When genuinely torn between AUTO_MERGE and anything else, you do **not** AUTO_MERGE."

**Context isolation as anti-anchoring** in three agents: `reviewer.md:32` ("deliberately NOT given the developer's or QA's reasoning transcript… it is an anchoring trap"), `qa.md:33`, `security-reviewer.md:117`. `architect.md:11-12` states the inverse: "Downstream agents are context-blind… If a fact is not in the artifact, it does not exist for them."

**No-stops steering** — `.claude/CLAUDE.md:59-69` "Pipeline Mode — No Stops", exactly three permitted pause reasons. Reinforced `architect.md:38,139`.

**Not present:** no plan mode / ExitPlanMode usage, no compaction or context-window management guidance, no session-resume/`--continue` handling, no `maxTurns` anywhere except `git-workflow.md:8` (`maxTurns: 30`).

## 2. CLAUDE.md

Only `.claude/CLAUDE.md` (project scope) in the repo. A near-identical `~/.claude/CLAUDE.md` (user scope) **still uses the old `/quetrex-*` names** — the `/q-*` rename landed in the project file but not the global one.

Contents: orchestrator role + "never write application code yourself" (`:3-4`); `# Learning`/`# LESSONS` protocol with 2 lessons (`:6-13`); scripted Welcome Message with exact-string requirement + skip conditions (`:15-24`); command table (`:26-38`); pipeline diagram (`:40-52`); Workflow Rules (`:54-63`); Pipeline Mode (`:65-75`); Stack/Verification delegation (`:77-80`); Preferences (`:82-88`); "For Teammates" (`:90-96`).

Strong on imperative voice and specificity: `:60` "Max 3 QA failures before escalating"; `:88` gives an exact command form `FLY_API_TOKEN="$TOK" fly <cmd> --app <app>` **plus the reason** the ambient login fails. Scoping delegated: `:77-79` says stack and verification live in the *project* CLAUDE.md, and `q-init.md:231-312` (step 4b) is the machinery guaranteeing a `## Verification` section exists for QA.

**Two staleness defects inside CLAUDE.md:** `:36` and `:50` advertise `/q-task-merge`, but no `.claude/commands/q-task-merge.md` exists (8 command files, none for merge). `README.md:63` repeats it while `README.md:6` simultaneously says "there is no `/q-task-merge`."

Also `.claude/team-protocol.md` (not referenced from settings): file-ownership-first rules, 3–5 teammates, TaskList monitoring, "no two teammates edit the same file" (`:14`).

## 3. Skills

Three skills, all shipped by npm (`package.json:28-30`).

| Skill | Frontmatter | Verification skill? | Invocation |
|---|---|---|---|
| `qa-verify` | `name`, `description` only — **no `allowed-tools`** (`skills/qa-verify/SKILL.md:1-9`) | **Yes** — pure pre-merge checklist | Model-invoked on description match; body says "Invoke as `/qa-verify`" (`:13`) |
| `worktree-workflow` | `allowed-tools: Bash, Read` (`:4`) | No — procedural | Model-invoked; referenced from `.claude/CLAUDE.md:62`, `dev-pipeline.md:46`, `q-init.md:489` |
| `tab-control` | `allowed-tools: Bash, AskUserQuestion, Read, Write`, **`disable-model-invocation: true`** (`:6`) | No — cosmetic (WezTerm tab) | User-only, `/tab-control` |

`qa-verify` has 12 numbered checks — typecheck/lint/build/tests (`:28-59`), **unfiltered** repo-wide grep for rename/removal proof (`:70-78`, "No file-type filters"), filename search (`:88-92`), branch-name search (`:100-102`), secret scan (`:112-118`), no-`any` (`:126-128`), feature-branch check, conventional commits, and a requirement that **raw terminal output** go in the PR body (`:150-159`, "Paste the raw output — do not paraphrase it. Zero-result output is valid proof"). Origin (`:15-20`) is a real incident: agents marking rename tasks done while references survived in shell/config files invisible to filtered search.

Caveats: `qa-verify` **hardcodes `pnpm`/`biome`** (`:31,:37,:49,:55`) despite `qa.md:56` forbidding exactly that ("Never hardcode a stack"); and it references `scripts/qa-verify.sh` (`:165`) **which does not exist**.

`security-reviewer.md:6` declares `skills: security-review` — not in this repo; resolves to the built-in `/security-review`.

## 4. Permission modes

**Project `.claude/settings.json`:** `permissions.defaultMode: "dontAsk"` (`:33`); `allow` 11 entries + `WebSearch` (`:7-20`): `Bash(npx biome:*)`, `npm run:*`, `npx playwright:*`, `npx stryker:*`, `npx knip:*`, `git checkout:*`, `git merge:*`, `git push:*`, `git worktree:*`, `gh pr:*`, `gh run:*`; `deny` 10 (`:21-32`): `rm -rf /`, `/*`, `~`, `~/`, `.`, `git reset --hard*`, `git checkout -- .`, `git clean -f*`, `git push --force:*`, `git push -f:*`; `"skipDangerousModePermissionPrompt": true` (`:107`). Env: `ENABLE_TOOL_SEARCH`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` (`:2-5`); `teammateMode: "auto"`, `voiceEnabled`, `remoteControlAtStartup: false` (`:108-110`).

**`.claude/settings.local.json`** — 2 entries: cross-repo `Read(//Users/barnent1/Projects/quetrex-kanban/**)` and one fully-specified build command with placeholder env values (`:3-6`).

**Per-agent permission modes:**
- `developer.md:7` `permissionMode: bypassPermissions` + `isolation: worktree` (`:8`)
- `qa.md:7` `permissionMode: bypassPermissions`
- `git-workflow.md:7` `permissionMode: acceptEdits`
- `database-architect.md` — **deliberately none**: "You have **no permission bypass**: every command you run — including destructive DDL — passes through the deny-guard and secret-scan hooks exactly like every other agent" (`:13`)
- `reviewer.md:5` / `security-reviewer.md:5` use `disallowedTools` (`Write, Edit` / `Edit`) rather than a mode

Those bypass grants are why the hooks are written as they are: `deny-guard.sh:3-6`, `secret-scan.sh:12-13`, `merge-gate.sh:44-46` all note a PreToolUse `permissionDecision:"deny"` runs *before* the permission engine and fires even under `bypassPermissions` / `--dangerously-skip-permissions`.

Drift: `README.md:8` says "The team runs **`auto` permission mode**, not `--dangerously-skip-permissions`" — global settings do use `auto`, but this repo's committed settings say `dontAsk`.

## 5. Hooks

| Script | Event / matcher | Contract | Enforces | Wired here? |
|---|---|---|---|---|
| `deny-guard.sh` | PreToolUse / Bash | `permissionDecision:"deny"`, exit 0 (`:12-16`) | **Real gate.** Recursive `rm` on root/home/current/parent/system dirs (`:22-33`); `reset --hard`, `clean -f`, force-push (`:36-40`) | Yes (`settings.json:53`) |
| `secret-scan.sh` | PreToolUse / Bash **and** Write\|Edit | deny, exit 0 (`:41-45`) | **Real gate.** Tier A ~22 provider-prefix regexes (AWS/Stripe/Anthropic/GitHub/Fly/JWT/DB-URI-with-password) (`:50-74`); Tier B Shannon entropy >4.0 over ≥20-char token next to a secret keyword (`:86-104`); masks the hit (`:35-39`) | Yes (`:58`, `:73`) |
| `enforce-branch.sh` | PreToolUse / Bash | deny, exit 0 (`:61`) | **Real gate.** Blocks `git commit`/`push` when branch resolves to main/master; tag pushes exempt (`:26-33`); resolves branch via `git -C` > `cd &&` > session cwd > `$PWD` (`:37-58`) | Yes (`:63`) |
| `workflow-reminder.sh` | UserPromptSubmit | stdout → context | **Advisory only.** Header concedes "A hook can only NUDGE… it cannot strictly force a tool choice" (`:8-10`) | Yes (`:41`) |
| `auto-format.sh` | PostToolUse / Write\|Edit | exit 0 | Advisory. Biome format if a `biome.json` found walking up (`:13-25`) | Yes (`:85`) |
| `check-quetrex-update.sh` | Stop | exit 0 | Advisory. 24h-throttled background npm version check → flag file (`:5-32`) | Yes (`:96`) |
| **`verify-gate.sh`** | Stop + SubagentStop | `{"decision":"block","reason":...}` **printed on exit 0** — header notes exit-non-zero *discards* the JSON (`:55-58`) | **The core gate — NOT WIRED** | **No** |
| **`merge-gate.sh`** | PreToolUse / Bash | deny, exit 0 (`:40-46`) | **The merge boundary — NOT WIRED** | **No** |
| `enforce-merge-approval.sh` | PreToolUse / Bash | `permissionDecision:"ask"` (`:29-33`) | Superseded per its own header (`:2-14`); forces interactive prompt on `gh pr merge`, push-to-main, merge-while-on-main | Not in repo settings — **IS wired globally**, so this is the merge policy that actually runs |
| `security-check.sh` | PreToolUse / Write\|Edit | deny, exit 0 (`:35`) | Strictly weaker predecessor of `secret-scan.sh` (11 patterns, no entropy tier, no Bash matcher) | Not in repo settings — **wired globally** |

**`verify-gate.sh`** (348 lines). Chain precedence: `.quetrex/verify.json .verify[]` → `.claude/CLAUDE.md ## Verification` fenced block via awk state machine (`:170-183`) → autodetect package.json/Makefile/pyproject/go.mod/Cargo (`:190-221`); no chain ⇒ exit 0 (`:223-226`). SubagentStop may use `.verifyQuick[]` (`:150-156`). Header enumerates four explicitly-closed fail-open holes (`:16-37`): no fast-skip on clean tree, no exit-127/ENOENT "environment error" laundering, no fail-open when `jq` is missing (`block()` has manual sed-escaping fallback, `:127-137`), no fail-open on hook timeout. Every run appends `{ts,cmd,cwd,sha,exit,tail}` to `.quetrex/verify-ledger.jsonl` (`:298-302`), `sha` pinning to the exact commit (`:92-95`).

**`merge-gate.sh`** (370 lines). Detects three merge vectors: `gh pr merge`, `git push` targeting main/master (including from a feature branch — the case `enforce-branch` misses), `git merge` while *on* main (`:94-126`); tag pushes exempt (`:83-88`). Scoped to repos having `.quetrex/` (`:143`). Four gates: (1) no `ESCALATION` (`:177-181`); (2) verdict `AUTO_MERGE` **and** `.sha == HEAD` (`:186-227`), legacy `BLOCK`/`APPROVE`/`ESCALATE` handled defensively (`:197-218`); (3) ledger green **and** commit-pinned — every chain command's most-recent line must be `exit 0` AND `sha == HEAD` (`:249-274`); (4) security findings — no open Critical, pinned to HEAD, and **required-but-missing is a failure**, where the requirement is computed from the *actual diff* not the plan flag: a 30-term sensitive-path regex (`:310`) plus a sensitive-added-code regex (`:320`), so "a plan that simply omits the flag cannot ship sensitive code unreviewed" (`:285-287`). Fail-closed if `jq` absent (`:163-165`) or ledger unparseable (`:267-270`).

**Test coverage exists for exactly one hook:** `test/merge-gate.test.sh` builds a throwaway fixture repo and asserts 4 cases against the real script (`:100-157`). It is **not** in `npm test` (`package.json:7` runs only `test/install.test.js`).

## 6. Automation

**Thinnest area.** No headless invocation anywhere: zero occurrences of `claude -p`, `--print`, cron, or any scheduler across `.claude/`, `install.js`, `README.md`, `test/`.

Aspirational only:
- "Anthropic cloud routine" is the stated *rationale* for committing gates per-project — `quetrex-install-project-gates.sh:10-12` and `q-init.md:384-389`: "any **Anthropic cloud routine** only ever sees what is **committed to this repo**… Without this step the gates would silently no-op in the cloud." Nothing in the repo *creates* such a routine.
- `.claude/CLAUDE.md:13` describes the product as "a routine-fired kanban" — no code behind it here.
- Backgrounding is delegated to the **Workflow tool**, named as the execution substrate (`dev-pipeline.md:9,41-43`; `q-task-build.md:19-21,196-198`; `q-task-rework.md:156`) but not defined or configured. The "terminal stays free" claim rests on it.
- Long-poll orchestration exists as *prose*: the epic DAG dispatcher in `q-task-build.md:179-224` specifies a ready-set computation, concurrency cap 3–5, `qx_is_unblocked` polling (`quetrex-api.sh:289-303`), and a fixpoint termination argument (`:217-224`) — but runs in-session, model-driven, not scheduled.

## 7. GitHub Actions / code review

**No `.github/` directory exists.** Git history shows `.github/workflows/quality-gate.yml` was deliberately deleted in `03444c7` ("chore: remove dead files… (#58)"). No CI, no required status check, no PR automation.

`worktree-workflow/SKILL.md:73-86` documents how to *add* branch protection with a required `qa` context via `gh api -X PUT …/branches/main/protection`, including the gotcha that you must PUT the full protection object — manual, not applied, and free personal private repos get HTTP 403.

**Native review commands are used, but only from inside an agent.** `reviewer.md:4` declares the `SlashCommand` tool; `:65-72` mandates: always run `/security-review` on the branch; run `/review <PR_NUM>` when a PR exists. Output is evidence, not verdict — `:72`: "A native tool that **errors or cannot run** on a non-trivial change is itself a reason to lean toward ESCALATE_HUMAN"; findings must be independently reproduced before being labeled CONFIRMED (`:99`). Verdict records both as `inputs.nativeReview` / `inputs.nativeSecurityReview` (`:176-177`).

Ground truth from the live artifact `.quetrex/review-verdict.json:14-15`: `"nativeReview": "not_run_no_pr"`, `"nativeSecurityReview": "not_available_in_env"` — on the most recent real run **neither native review executed**, and the verdict was still `AUTO_MERGE`.

## 8. Verifying unsupervised runs

Design intent: **a chain of custody built from on-disk artifacts, never chat prose.**

| Artifact | Written by | Read by |
|---|---|---|
| `verify.json` | `q-init` step 4d from `templates/verify.json` | qa, developer, verify-gate, merge-gate, architect |
| `verify-ledger.jsonl` | `verify-gate.sh:298-302`, `qa.md:77-80`, `git-workflow.md:152-155` | merge-gate GATE 3, git-workflow Gate 2 |
| `plan/<TASK>.json` | architect (its only write, `architect.md:44`) | developer, qa, reviewer, security-reviewer, merge-gate |
| `security-findings.json` | security-reviewer (its only write, `:62`) | merge-gate GATE 4, git-workflow Gate 3, reviewer |
| `review-verdict.json` | reviewer via `jq` (`:156-180`) | merge-gate GATE 2, git-workflow Gate 4 |
| `state.json` (`.review_iter`) | reviewer (`:195-205`), git-workflow on refusal (`:210-215`) | reviewer, merge-gate |
| `ESCALATION` | verify-gate at cap (`:345`), reviewer at cap (`:200-205`) | merge-gate GATE 1, git-workflow Gate 1 |
| `verify-attempts` | verify-gate (`:328`) | verify-gate |

**Exit codes as the only truth** — `qa.md:15`: "A command that prints 'All tests passed' and exits `1` is a FAIL." The `run()` helper (`qa.md:65-83`) captures `$?` immediately and appends a sha-pinned ledger line. `qa.md:18` forbids escape hatches by name: no editing tsconfig/lint rules/CI/the verify chain, no `.skip`/`.only`/`xit`, no `@ts-ignore`/`eslint-disable`/`# noqa`/`--passWithNoTests`/`--no-verify`, no glob narrowing.

**Anti-vacuous-suite guard** (`qa.md:106-112`) — every changed production unit needs ≥1 non-trivial assertion that actually calls it; snapshot-only, fully-mocked-unit, and `expect(true).toBe(true)` don't count; a file coverage says is exercised but whose assertions are all trivial is treated as UNCOVERED and FAILs. Plus **changed-file** coverage at default 80% (`qa.md:93`), optional mutation testing (`:94`), and a mandatory **runtime/E2E smoke** — "A change that builds and unit-tests green but crashes on first real invocation is a FAIL" (`:95`).

**Mandatory coverage-gap disclosure** — `qa.md:19` makes "state what you did NOT verify" cardinal rule #5; both verdict templates end with `NOT VERIFIED:` (`:138`, `:149`).

**Double independent re-verification.** `qa.md:114-116`: "you cannot end green by asserting green — the hook checks the exit codes independently." Then `git-workflow.md:121-171` (§2a) re-runs the *full* chain after its own commit, because HEAD just moved AND because the main-agent Stop hook resolves ROOT to `CLAUDE_PROJECT_DIR` (the main checkout) rather than the worktree merge-gate will read. That bug is documented at `git-workflow.md:130-136` and regression-tested at `test/merge-gate.test.sh:143-157`.

**Stale-green is the threat model everything is organized around.** Three pins: ledger `sha` == HEAD (`merge-gate.sh:232-238`), verdict `sha` == HEAD (`:225-227`), findings `head_sha` == HEAD (`:348-350`). `verify-gate.sh:17-21` refuses any fast-skip: "A clean working tree does NOT let a prior green stand in for the current state."

**Caveats.** `.quetrex/` is **neither gitignored nor tracked** (`git ls-files .quetrex` empty; `git status` shows `?? .quetrex/`), so the audit trail is purely local and vanishes on clone. This repo has **no `.quetrex/verify.json`** (only `review-verdict.json`). And `git-workflow.md:91` still gates on `VERDICT = "APPROVE"` — a string the reviewer never emits and that `merge-gate.sh:209-213` treats as ESCALATE_HUMAN. The two terminal gates disagree on the contract.

## 9. Plugins

**No plugin packaging in this repo.** No `.claude-plugin/`, no `plugin.json`, no marketplace manifest.

Distribution is a **global-config-overwriting npm package**: `package.json:6` `postinstall: node install.js`; installed via `npm install -g quetrex-base` or `npm install -g github:Barnhardt-Enterprises-Inc/quetrex-base` (`README.md:14-22`). `package.json:23-37` whitelists 12 paths — it ships `.claude/settings.json` and `.claude/CLAUDE.md`, i.e. the package writes the user's **global** config.

`install.js`: copies `.claude/**` → `~/.claude/**` (`:370-374`), chmod 755 on `hooks/*.sh` (`:256-258`); `settings.json` **deep-merged, never clobbered** (`:217-233`), existing scalars win, only `allow`/`deny`/`ask` primitive arrays unioned (`:19`, `:153-155`), hook object-arrays reconciled **by script basename** (`:86-97`, `:112-126`); **manifest-based pruning** via `.quetrex-manifest.json` as sole delete authority — "the installer never deletes a file it cannot prove it wrote on this machine" (`:186-187`), every prune backed up to `.quetrex-backups/<stamp>/` (`:278`); `secrets.env` protected (`:9`); `settings.json` never pruned (`:14`); path-traversal rejection (`:169-179`); symlinks replaced rather than written through (`:209-215`). **Post-install enforcement assertion** (`:314-351`): every global hook must exist *and* be executable, `verify-gate.sh`/`merge-gate.sh` must be present, settings.json must re-parse — else `process.exit(1)` with "INSTALL FAILED — the enforcement channel is broken."

`test/install.test.js` covers 11 of these including path-traversal and symlink cases (`:99-122`).

**Per-project** distribution is `.claude/lib/quetrex-install-project-gates.sh` (242 lines), invoked from `q-init.md:397`. It copies 5 hooks + 7 agents from `~/.claude` into the target repo's own `.claude/`, then wires them into that repo's **committed** `settings.json` via a temp Node script (`:120-218`) with idempotent basename-matched insertion (`:162-196`), using `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/<x>.sh"` so paths resolve in a fresh clone (`:152-160`). It wires the timeouts the verify-gate budget assumes: Stop 900s, SubagentStop 600s, merge-gate 60s (`:199-206`).

`README.md:5-10` announces the successor: the engine now ships as a **`quetrex-factory` plugin** from the private marketplace `Glori-Holdings/quetrex-plugins` via Claude Code's native plugin system, updated with `/plugin update`. **None of that is in this repo** — this repo is "the kanban-integration command layer during the transition."

## 10. Subagents

| Agent | Model / effort | Tools | Mode / isolation | Role |
|---|---|---|---|---|
| **architect** | opus / high | Read, Grep, Glob, **Write** | — | Writes exactly one artifact: `.quetrex/plan/<TASK>.json` |
| **developer** | sonnet / high | Read, Write, Edit, Bash, Grep, Glob | `bypassPermissions`, `isolation: worktree` | Implements ONE workstream, owned files only |
| **database-architect** | opus / high | Read, Write, Edit, Bash, Grep, Glob | `isolation: worktree`, **no bypass** | Migrations only, when `db_migration:true` |
| **qa** | sonnet / high | Read, Write, Edit, Bash, Grep, Glob | `bypassPermissions` | Green-proof gate; Write/Edit *only* for tests |
| **security-reviewer** | opus / **xhigh** | Read, Grep, Glob, Bash; `disallowedTools: Edit`; `skills: security-review` | — | 9-category OWASP audit → `security-findings.json` |
| **reviewer** | opus / **xhigh** | Read, Grep, Glob, Bash, **SlashCommand**; `disallowedTools: Write, Edit` | — | 3-way merge verdict → `review-verdict.json` |
| **git-workflow** | sonnet / medium | **Bash, Read** only | `acceptEdits`, `maxTurns: 30` | Artifact gate → commit → push → open PR |

Tool allowlists are used as behavioral guarantees and each agent says why: `architect.md:135` "You have no Edit tool and must not attempt code changes via Write"; `reviewer.md:19` "`Write`/`Edit` are denied so you cannot 'fix and hide' a defect" (it writes its three control artifacts through Bash/`jq`, with an explicit ban on `sed -i`/redirect/heredoc into source); `security-reviewer.md:112` "Bash is for read-only inspection only"; `qa.md:99` "You have Write/Edit for ONE purpose: adding and hardening tests."

Depth worth noting: `architect.md:103-118` ownership must be a "total, disjoint function over touched files", acceptance criteria need a numeric `measure` with "fast"/"correct"/"robust"/"secure"/"properly"/"handles errors gracefully" **banned as the substance of a measure** (`:110`); `security_review_required` is advisory-**up** only (`:113`); one valid early exit `needs_clarity` (`:121-129`). `developer.md:36-46` fail-first: write the test, *watch it fail for the right reason*, implement, re-run; `:32-34` touching another workstream's file is forbidden even when it seems necessary; `:61` Context7 MCP required before writing against any external API. `security-reviewer.md:41-49` nine categories with CWE/OWASP ids, BOLA/IDOR "highest yield, look here first"; `:96` a `critical` finding **must** be `CONFIRMED`. `reviewer.md:80-91` read every changed file in full, grep callers/callees, "build the breaking case… name the exact input"; `:99` "cry wolf and you get ignored; rubber-stamp and you ship bugs." `git-workflow.md:12` "You trust exactly one thing: the on-disk artifacts"; `:119` if a hook blocks the commit, no `--no-verify`, no editing hooks.

**A parallel, contradictory pipeline description exists.** `.claude/lib/dev-pipeline.md` declares itself the "single canonical definition" (`:3-5`), is referenced by `q-task-build.md:104` and `q-task-rework.md:145`, but disagrees with the agent files on three points: architect writes `.issue/architecture-decision.md` (`:56`) vs `.quetrex/plan/<TASK>.json`; git-workflow is **haiku** (`:85`) vs sonnet; review is REJECT→inner-loop (`:76-78`) vs the 3-way verdict.

## CLAIMED-BUT-NOT-WIRED

1. **`verify-gate.sh` and `merge-gate.sh` are wired in no settings file** — not this repo's, not the global one.
2. **The global install wires the superseded hooks** — `enforce-merge-approval.sh` and `security-check.sh` run; their replacements do not.
3. **`/q-task-merge` does not exist** as a command file but is advertised in `.claude/CLAUDE.md:36,50`, `README.md:63`, `git-workflow.md:14,179,199`, `dev-pipeline.md:94,106`, and inside `merge-gate.sh` deny messages.
4. **`git-workflow` gates on `APPROVE`** (`:91`) — a verdict the reviewer never emits.
5. **`security-reviewer.md:62` names the wrong consumer** — says `enforce-merge-approval.sh` parses `security-findings.json`; that hook never reads it.
6. **No `.quetrex/verify.json` in this repo.**
7. **No CI** — workflow deleted; main not branch-protected; `merge-gate.test.sh` not in `npm test`.
8. **The Workflow tool** — stated execution substrate for every background pipeline run — is not defined or available in this repo.
9. **`.quetrex/` is untracked**, so the audit trail does not survive a clone.
10. **`~/.claude/CLAUDE.md` still uses old `/quetrex-*` names** — the rename is half-applied across scopes.
