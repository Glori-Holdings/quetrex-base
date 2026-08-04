# qa-verify — per-check rationale

Read this when a check fires and you need to know *why* it exists before deciding what
to do about it. `SKILL.md` tells you how to run the script; this file explains each
verdict. Every design choice below exists because the naive version of the check
already failed in practice.

---

## 1. Chain resolution — the precedence, and why nothing is hardcoded

```
.quetrex/verify.json           ->  authoritative, machine-readable
.claude/CLAUDE.md "## Verification"  ->  human-declared fallback
manifest autodetect            ->  INFERRED, always reported as a WARN
```

This is the same precedence the `qa` agent uses, deliberately: the skill and the agent
must never disagree about what "green" means for a repo.

**Why no hardcoded stack.** A skill fires on its own. An earlier version of this file
ran `pnpm run typecheck`, `npx biome check .`, `pnpm run build`, `pnpm test`. In a
Python or Rust partner repo that is four `command not found` failures — which then drop
the agent into a "fix the issue immediately" protocol against a repo that was never
broken. The JS package manager is now read off the lockfile (`pnpm-lock.yaml`,
`yarn.lock`, `bun.lock*`, else npm), never assumed.

**Why "no chain resolvable" is exit `2`, not a pass.** If nothing declares what green
means, nothing can be proven. Exiting `0` there would be a silent fail-open — precisely
the failure mode this skill exists to remove. Declare a chain instead:

```json
{ "verify": ["<lint cmd>", "<typecheck cmd>", "<build cmd>", "<test cmd>"] }
```

**Why the CLAUDE.md extractor toggles the fence before matching headings.** A `#`
comment *inside* a fenced block otherwise matches the heading rule first and silently
truncates the chain at that line — proving a subset green and reporting it as green.
The extractor also accepts backticked list items, which is how `/quetrex:init` writes the
section.

## 2. Chain execution — exit codes are the only truth

- The verdict of a command is the integer in `$?`. Never a word found in its stdout.
  A command that prints `All tests passed` and exits `1` is a FAIL.
- **No env-error laundering.** Exit `127`, "command not found", ENOENT — all RED. This
  is the single most common way a real gate degrades into a no-op: the tool is missing,
  the command "fails harmlessly", and the run is called green. Missing tooling is a
  *setup* failure to report, not a *code* failure to self-heal against.
- Every command runs under `timeout`/`gtimeout` when available (default 600s, `--timeout`
  to change). A timeout is RED, never "inconclusive" — a hung build must not pass.
- The whole chain runs even after the first red, so the report is the full picture
  rather than the first failure.

## 3. Anti-weakening — the check the old checklist did not have

Running the suite and seeing green proves nothing on its own: a test can be quietly
loosened so it passes no matter what. This check reads the diff and refuses that.

It compares test files against the base commit and fails on any of these appearing in
an **added** line:

`.skip(` · `.only(` · `fdescribe(` · `fit(` · `xit(` · `xdescribe(` · `.todo(` ·
`@ts-ignore` · `@ts-nocheck` · `@ts-expect-error` · `eslint-disable` · `biome-ignore` ·
`type: ignore` · `noqa` · `passWithNoTests` · `--no-verify` · `pytest.mark.skip` ·
`pytest.mark.xfail` · `unittest.skip` · `#[ignore]` · `t.Skip(` · `.Ignore(` ·
a bare `assert True` · `expect(true).toBe(true)`

Adjacent signals, reported as WARN rather than FAIL because both have legitimate uses:

- **assertion lines deleted** from a test file,
- **test files deleted** outright,
- **the verification config itself changed** by this diff (`.quetrex/verify.json`,
  `tsconfig*.json`, eslint/biome/ruff/mypy/pytest/golangci/clippy config, jest/vitest
  config, `.claude/CLAUDE.md`). Changing the definition of green inside the change
  being proved green is not forbidden, but it must be justified out loud.

A WARN also fires when files changed and **no test file was touched at all** — the
quiet version of the same problem.

This logic previously lived only in the `qa` agent, reachable only by running the whole
pipeline. It is in the script so that it cannot be skipped by anyone taking the short
path.

## 4. Secrets — position without content

The check reports `file:line` and the *kind* of secret (`api_key`, `token`, …) with the
value replaced by `****(masked, N chars on line)`. It never prints the matched text.

- **Why masked.** An earlier version grepped for `api_key|secret|password|token` with no
  exclusions and printed whole matching lines. The command-string secret scanner does
  not inspect *output*, so those lines sailed through the gate and landed in context.
  A check that leaks the secret it is looking for is worse than no check.
- **Why `.env*` files are excluded from the content scan.** They are supposed to contain
  secrets; grepping them is guaranteed to dump them. Instead they are **asserted**: every
  `.env*` on disk (except `*.example` / `*.sample` / `*.template`) must be untracked in
  git **and** matched by `.gitignore`. Either violation is a FAIL. That is the property
  that actually matters.
- **Why the pattern requires an assignment and a long value.** A keyword alone matches
  prose, type names, and lockfile digests. Requiring `keyword <:|=> <16+ chars>` keeps
  the noise out. False positives erode trust in a gate until people stop reading it.
- Lockfiles, vendored trees, build output, `*.example`, this skill's own files, and
  `README`/`SECURITY`/`CHANGELOG` are excluded from the scan.

## 5. TypeScript checks are conditional

The `any` check runs **only** when the repo actually has TypeScript (`tsconfig.json`, or
tracked `.ts`/`.tsx` files), and then only against **added lines in changed files** — not
the whole repo. Scanning the whole repo in an adopted codebase produces a wall of
pre-existing hits that has nothing to do with the change under review. In a Python or Go
repo the check reports `SKIP`, not four failures.

## 6. Rename / removal proof (`--term`)

**No file-type filters, by design.** The original failure this skill was written for was
an agent declaring a rename complete while references survived in `.sh`, `.yml`, `.toml`,
Dockerfiles, Makefiles and directory *names* — all invisible to a `--include="*.ts"`
search. The scan walks tracked plus untracked-not-ignored files, then filenames, then
branch names. Content and filename hits are FAIL; branch-name hits are WARN.

## 7. The annotation contract

Any FAILing line may be exempted by putting

```
qa-verify: allow <reason>
```

on **that same line**. The reason is not optional and is not for the script — it is for
the reviewer. Rules:

- Annotate the narrowest possible line; never a whole file or block.
- An annotation without a reason, or with a reason that does not survive review, is a
  defect in its own right.
- An annotation is not a substitute for the PR body. Say it in both places.
- Never annotate a check to get past a red build under time pressure. That is the exact
  behaviour the anti-weakening check exists to catch, and the reviewer reads the diff.

## 8. What this script deliberately does not do

It prints these as `NOT VERIFIED` on every run, because a report that omits its own
coverage gaps is an incomplete report:

- acceptance criteria from the plan artifact — mechanics are not intent,
- runtime / end-to-end behaviour,
- conventional-commit format and the PR body,
- the contents of `.env*` files — never read, on purpose,
- anything skipped because no base commit or no `--term` was resolvable.

State them. "I ran the script and it passed" is not the report; the summary block plus
the NOT VERIFIED block is.
