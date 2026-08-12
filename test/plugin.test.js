'use strict';

// Framework-free structure test for the `quetrex` Claude Code plugin.
// Run: `npm test` (test/run-all.sh runs this file, then every test/*.sh
// file, unconditionally — see that script's header for why).
//
// This replaced test/install.test.js, which validated the retired npm
// installer (install.js). Quetrex is no longer an npm package that seeds
// ~/.claude — it is a plugin the user enables. So the invariant that matters
// is no longer "the installer wired ~/.claude correctly" but "the committed
// plugin tree IS a correct plugin": the manifest is well-formed, every command
// is de-prefixed to the plugin namespace, the plugin's own hooks resolve from
// ${CLAUDE_PLUGIN_ROOT} and do NOT re-register the engine guards that
// quetrex-factory owns, no command sources a lib from ~/.claude, and not one
// legacy /q-<cmd> reference survives anywhere in the tree.

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { execFileSync } = require('child_process');

const REPO_ROOT = path.join(__dirname, '..');
const readJson = (rel) => JSON.parse(fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8'));
const exists = (rel) => fs.existsSync(path.join(REPO_ROOT, rel));
const read = (rel) => fs.readFileSync(path.join(REPO_ROOT, rel), 'utf8');

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}

// Every hook `command` string in a hooks-shaped object.
function hookCommands(obj) {
  const out = [];
  for (const groups of Object.values((obj && obj.hooks) || {})) {
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      for (const h of (g && g.hooks) || []) {
        if (h && typeof h.command === 'string') out.push(h.command);
      }
    }
  }
  return out;
}
// Trailing `.sh` basename from a hook command (tolerates a closing quote).
function hookBasename(cmd) {
  const m = cmd.match(/([^/\s"']+\.sh)["']?\s*$/);
  return m ? m[1] : null;
}

// Run `git grep` over the working tree and return matched lines (empty when
// there are no matches). git grep exits 1 on "no match" — that is success here,
// not an error.
function gitGrep(pattern, pathspecs) {
  const args = ['grep', '-I', '--no-color', '-E', pattern, '--', ...pathspecs];
  try {
    const out = execFileSync('git', args, { cwd: REPO_ROOT, encoding: 'utf8' });
    return out.split('\n').filter(Boolean);
  } catch (e) {
    if (e.status === 1) return []; // no matches
    throw e;
  }
}

// The nine legacy command verbs, assembled from fragments so this test file
// never itself contains a literal `/q-<verb>` that its own repo-wide sweep
// assertion would flag as a false positive.
const VERBS = ['init', 'login', 'task-new', 'task-refine', 'task-build',
  'task-rework', 'task-complete', 'task-merge', 'deploy'];
const LEGACY_CMD_RE = '/' + 'q-' + '(' + VERBS.join('|') + ')';

// The de-prefixed core command set (the eight files renamed from q-*.md). New
// capabilities (update.md, doctor.md) are added by other workstreams and are
// intentionally NOT required here — the invariant this test owns is that the
// core eight are de-prefixed and that ZERO q-*.md files remain.
const CORE_COMMANDS = ['deploy', 'init', 'login', 'task-build',
  'task-complete', 'task-new', 'task-refine', 'task-rework'].map((n) => `${n}.md`);

// Guards that quetrex-factory owns; quetrex must NOT re-register them (enabling
// quetrex depends_on quetrex-factory, so a copy here would double-register).
const ENGINE_GUARDS = ['deny-guard.sh', 'secret-scan.sh', 'enforce-branch.sh', 'auto-format.sh'];
// The command-layer hooks unique to quetrex, which it keeps registering.
// quetrex-update-check.sh is the one hook the command-layer plugin legitimately
// owns: a non-blocking SessionStart nudge that a newer engine version exists.
const KEPT_HOOKS = ['session-state.sh', 'edit-gate.sh', 'quetrex-update-check.sh'];

// --- 0. THIS REPO IS THE PLUGIN -------------------------------------------
// Everything at this repo root is shipped to every consumer of the `quetrex`
// plugin, so a project-level config file here is not local — it is broadcast.
//
// That is not hypothetical. Versions 2.0.3 and 2.0.4 shipped a root
// `.mcp.json` registering a `quetrex-kanban` http broker at
// `<kanban>/api/mcp`, an endpoint that was never built. Because it travelled
// INSIDE the plugin package, every repo with the plugin enabled tried to
// connect it — regardless of whether that repo had an `.mcp.json` of its own.
// Deleting the per-repo copies did not stop it; only removing it from the
// shipped package did. The failure surfaced to operators as "the plugins
// cannot connect to the dash" and cost a full debugging cycle.
//
// So this is a packaging guard, not a style rule: no MCP server may be
// declared by anything this repo ships until the endpoint behind it exists and
// answers an MCP `initialize`.
check('the plugin package ships no .mcp.json (it would broadcast to every consumer)', () => {
  assert.ok(
    !exists('.mcp.json'),
    'a root .mcp.json is shipped inside the plugin and registers an MCP server for EVERY repo that enables it — '
      + 'this is exactly how the dead <kanban>/api/mcp broker reached every armed repo in 2.0.3/2.0.4. '
      + 'Do not re-add it until the endpoint exists and answers an MCP initialize.',
  );
});

check('no shipped file declares an mcpServers block', () => {
  const hits = gitGrep('mcpServers', [
    ':(exclude)test/**',
    ':(exclude).claude/commands/**',
    ':(exclude)bin/quetrex-arm',
  ]);
  assert.deepStrictEqual(
    hits, [],
    'mcpServers is declared in a shipped file: ' + hits.join(', ')
      + '. Only the arming tool (which REMOVES the dead broker), its tests, and the command docs '
      + 'that explain the removal may mention it.',
  );
});

// --- 0b. COMMANDS MUST ACTUALLY RUN ---------------------------------------
// Every defect that reached an operator in this engine so far shared one shape:
// a code path that had never once been EXECUTED. The suite checked what files
// SAID ("does init.md contain the right sentence") and never what they DID, so
// the first human to walk a path was the one who found it broken.
//
// The worst instance: /quetrex:login and /quetrex:update both used
//     read -r A B < <(node -e '... process.stdout.write(a+" "+b) ...')
//         || { echo "unreadable"; exit 1; }
// `read` returns NON-ZERO when the final line has no trailing newline. The
// values land in the variables correctly and the guard fires anyway — so both
// commands failed 100% of the time, on healthy input. /quetrex:login is the
// FIRST command a teammate runs on a new machine, so onboarding was impossible.
//
// These two checks are cheap and they close that class permanently.
check('no shipped command reads from a process substitution (read returns non-zero without a trailing newline)', () => {
  const hits = gitGrep('read -r .*< <', [':(exclude)test/**']);   // no parens: git grep would read them as a group
  assert.deepStrictEqual(
    hits, [],
    'a shipped file uses `read ... < <(...)`: ' + hits.join(', ')
      + '. `read` exits NON-ZERO when the last line lacks a trailing newline, so any `|| { fatal }` '
      + 'guard fires on SUCCESS and the command aborts with a bogus error. Capture into a variable, '
      + 'check it, then split with `set --`.',
  );
});

check('every bash block embedded in every command is syntactically valid', () => {
  const dir = path.join(REPO_ROOT, '.claude/commands');
  const failures = [];
  let blocks = 0;
  for (const file of fs.readdirSync(dir).filter((x) => x.endsWith('.md'))) {
    const src = fs.readFileSync(path.join(dir, file), 'utf8');
    [...src.matchAll(/```bash\n([\s\S]*?)```/g)].forEach((m, i) => {
      blocks++;
      const tmp = path.join(require('os').tmpdir(), 'qx-block-' + process.pid + '-' + blocks + '.sh');
      fs.writeFileSync(tmp, m[1]);
      try {
        execFileSync('bash', ['-n', tmp], { stdio: 'pipe' });
      } catch (e) {
        failures.push(file + ' block#' + (i + 1) + ': ' + String(e.stderr || '').trim().split('\n')[0]);
      } finally {
        try { fs.unlinkSync(tmp); } catch {}
      }
    });
  }
  assert.ok(blocks > 50, 'expected to find the command bash blocks, found only ' + blocks);
  assert.deepStrictEqual(failures, [], 'bash syntax errors in shipped command blocks:\n  ' + failures.join('\n  '));
});

// --- 0c. THE MERGE PATH MUST STAY CONNECTED -------------------------------
// The build runs in an Anthropic cloud sandbox, and `.quetrex/*` is git-ignored, so every
// gate artifact it produces (ledger, verdict, security findings) stays in that sandbox. The
// operator's merge-gate.sh then finds no verdict and denies the merge. That is why merging
// was always done by hand on GitHub, and why the post-merge bookkeeping — status -> merged,
// branch and worktree teardown — never ran and tasks stranded in in_progress.
//
// Two halves fix it and BOTH must stay present: the cloud routine PUBLISHES its evidence to
// a gates branch, and /quetrex:merge FETCHES it, proves it is pinned to the PR head, and
// merges through the same gate. Delete either half and merging silently breaks again with no
// error anywhere — so each half is asserted here.
check('the cloud routine publishes its gate artifacts (the transport half)', () => {
  const routine = read('.claude/lib/cloud-build-routine.md');
  assert.match(routine, /-gates/, 'the routine must push a gates branch — without it no evidence reaches the operator');
  assert.match(routine, /gates-head/, 'the routine must record the head sha the artifacts describe, so staleness is detectable');
  for (const artifact of ['verify-ledger.jsonl', 'review-verdict.json']) {
    assert.ok(routine.includes(artifact), `the routine must publish ${artifact}`);
  }
  assert.match(routine, /git add -f/, 'the artifacts are git-ignored, so publishing them requires add -f');
});

check('/quetrex:merge exists, verifies the pin, and offers no bypass', () => {
  assert.ok(exists('.claude/commands/merge.md'), '.claude/commands/merge.md must ship — it is the only merge path');
  const m = read('.claude/commands/merge.md');
  assert.match(m, /^---\ndescription: /, 'merge.md needs command frontmatter to be discoverable');
  assert.match(m, /-gates/, 'merge.md must fetch the gates branch');
  assert.match(m, /GATES_SHA.*PR_SHA|PR_SHA.*GATES_SHA/s, 'merge.md must compare the evidence sha to the PR head sha');
  assert.match(m, /merge-gate/, 'merge.md must defer the decision to merge-gate.sh, not re-implement it');
  assert.match(m, /task-status "\$TASK" merged/, 'merge.md must move the task to merged — the bookkeeping that never ran');
  assert.match(m, /worktree remove/, 'merge.md must tear down the task worktree');
  // The whole point is that it cannot be forced. These are the escape hatches that would
  // turn the gate back into decoration.
  assert.ok(!/--admin/.test(m), 'merge.md must not use gh --admin, which bypasses branch protection');
  // Narrowly: a FORCED MERGE or a FORCED PUSH would defeat the gate. `worktree remove --force`
  // is ordinary teardown and must stay allowed — an over-broad rule here fails on its own
  // cleanup code, which is exactly what happened when this test was first written.
  assert.ok(!/pr merge[^\n]*--force/.test(m), 'merge.md must not force a merge');
  assert.ok(!/push[^\n]*(--force|\s-f\b)/.test(m), 'merge.md must not force-push');
});

check('task-build no longer claims there is no merge command', () => {
  const tb = read('.claude/commands/task-build.md');
  assert.ok(
    !/no \`\/quetrex:task-merge\` command/.test(tb),
    'task-build.md still says no merge command exists — it now does, and telling the user otherwise '
      + 'sends them back to merging by hand, which skips every post-merge step',
  );
  assert.match(tb, /\/quetrex:merge/, 'task-build.md must point at /quetrex:merge as the terminus follow-up');
});

// --- 0d. THE BRANCH PREFIX RULE, STATED CORRECTLY -------------------------
// claude/ is not a style choice and not cargo cult: the routines documentation says pushes to
// claude/-prefixed branches "are always accepted", while any other branch is rejected if it is
// protected, already has someone else's open PR, or carries someone else's commits — the last
// of which rules out shared feature/* branches. Our prose used to give a fabricated reason
// ("blocked until a repo admin allows that prefix"), which is how the rule got questioned as
// cargo cult and nearly removed.
check('no shipped file still prescribes a feature/ branch prefix', () => {
  const offenders = [];
  for (const rel of ['.claude/agents/developer.md', '.claude/lib/cloud-build-routine.md',
                     '.claude/skills/quetrex-pipeline/SKILL.md']) {
    const body = read(rel);
    // A prescription looks like `feature/<...>` or `feature/` as the stated prefix. Prose
    // EXPLAINING why shared feature/* branches fail is allowed and desirable.
    for (const line of body.split('\n')) {
      if (!/feature\//.test(line)) continue;
      if (/rules out|rejected|someone else|why|not allowed|fails/i.test(line)) continue;
      offenders.push(rel + ': ' + line.trim().slice(0, 100));
    }
  }
  assert.deepStrictEqual(offenders, [], 'these still prescribe feature/ as the branch prefix:\n  ' + offenders.join('\n  '));
});

// INVERTED, deliberately, and recorded rather than quietly deleted. This assertion used to
// REQUIRE that init present the Claude GitHub App as required/outstanding. That behavior was
// removed on the operator's call, so the assertion now pins the opposite. Two reasons, both
// measured in the field:
//
//   1. The model cannot run `/install-github-app` — it is a native interactive command driving
//      a GitHub OAuth flow in the operator's own browser. init asked "Run it?", the operator
//      answered yes, and NOTHING happened while the summary read as handled.
//   2. That install flow then asks whether to set up GitHub Actions workflows, and yes there
//      creates a third execution location — a runner with no Claude login, demanding its own
//      ANTHROPIC_API_KEY. This project already deleted exactly that workflow once. A prompt
//      whose wrong answer breaks the architecture should not be asked at all.
//
// Quetrex's gates run inside the cloud routine and publish to <prefix><TASK>-gates, which is
// what merge-gate.sh reads. GitHub-side review is additive, and the app without workflows
// delivers none of it anyway.
check('init does NOT ask about the Claude GitHub App, and records why', () => {
  const init = read('.claude/commands/init.md');
  assert.ok(
    !/run `?\/install-github-app`?\?/i.test(init),
    'init must never ask "Run /install-github-app?" — it cannot run it, so a yes produces nothing while reading as done',
  );
  // Scan the WHOLE file. This used to read only init.split('## 4h.')[0], which blinded it to
  // the back half — and that is exactly where the miss lived: the step-7 summary still listed
  // "GitHub app — installed already / offered and accepted / offered and declined", the very
  // line whose "read as handled" was the reported defect.
  assert.ok(
    !/GitHub app\b[^\n]*offered/i.test(init),
    'the step-7 summary must not report a GitHub App interaction — none can occur',
  );
  assert.ok(
    !/\bREQUIRED\b[^\n]{0,80}GitHub App|GitHub App[^\n]{0,80}\bREQUIRED\b/i.test(init),
    'init must not present the App as required — the pipeline does not use it',
  );
  assert.match(init, /^## 4g\. \(removed\)/m,
    'the removal must be recorded in place, so the next person does not add the check back as a convenience');
  assert.match(init, /third execution location/,
    'the removal notice must name the real hazard: a runner with no Claude login demanding its own API key');
});

// --- 1. plugin.json manifest -----------------------------------------------
check('.claude-plugin/plugin.json parses and carries the v2 identity', () => {
  const p = readJson('.claude-plugin/plugin.json');
  assert.strictEqual(p.name, 'quetrex', 'plugin name is the slash-command namespace — must be "quetrex"');
  // Asserted against package.json rather than a hardcoded literal: the two
  // files are the same release and MUST agree (the marketplace publishes from
  // plugin.json, the update-check nudge compares against it), and a literal
  // here meant every version bump broke this test for no signal.
  const pkg = readJson('package.json');
  assert.match(p.version, /^2\.\d+\.\d+$/, 'plugin version must be a concrete 2.x.y — the v2 identity');
  assert.strictEqual(p.version, pkg.version, 'plugin.json and package.json must declare the same version');
  assert.strictEqual(p.displayName, 'Quetrex');
});

// REPLACED, deliberately. This used to REQUIRE `dependencies: ["quetrex-factory"]`.
// That declaration is what turned a version-pinned engine into a hard failure:
// `claude plugin list` reported
//   quetrex@quetrex  ✘ failed to load
//   Error: Dependency "quetrex-factory@quetrex" is disabled
// even while the factory itself showed ✔ enabled, because a pinned entry does not
// count as enabled for dependency resolution. So NO /quetrex:* command existed in
// any armed repo. Verified: deleting the field loads cleanly even with a pin
// present. The engine is still installed by the marketplace; /quetrex:doctor
// reports it if it is missing. The inverted assertion lives in section 5b.
check('plugin.json still declares the paths and identity the marketplace needs', () => {
  const p = readJson('.claude-plugin/plugin.json');
  assert.strictEqual(p.name, 'quetrex');
  assert.ok(Array.isArray(p.agents) && p.agents.length > 0, 'the engine agents must still be declared');
});

check('plugin.json declares custom paths that keep content under .claude/', () => {
  const p = readJson('.claude-plugin/plugin.json');
  assert.deepStrictEqual(p.commands, ['./.claude/commands/']);
  assert.deepStrictEqual(p.skills, ['./.claude/skills/']);
  // hooks must NOT be declared: the standard hooks/hooks.json auto-loads, so
  // declaring it makes Claude Code double-load it ("Duplicate hooks file
  // detected") and the plugin errors on install. Confirmed by live install test.
  assert.strictEqual(p.hooks, undefined,
    'do NOT declare hooks in plugin.json — hooks/hooks.json auto-loads; declaring it duplicates');
  assert.ok(exists('hooks/hooks.json'),
    'hooks/hooks.json must exist at the plugin root so it auto-loads');
  // `agents` MUST be individual .md FILE paths — the Claude Code plugin validator
  // rejects a directory for `agents` (unlike commands/skills, which take a dir).
  // Derive from the real dir so adding/removing an agent without updating the
  // manifest fails here — and so the "directory" regression can never come back.
  const agentFiles = fs.readdirSync(path.join(REPO_ROOT, '.claude/agents'))
    .filter((f) => f.endsWith('.md'))
    .map((f) => `./.claude/agents/${f}`)
    .sort();
  assert.ok(Array.isArray(p.agents) && p.agents.length > 0, 'agents must be a non-empty array');
  assert.ok(p.agents.every((a) => a.endsWith('.md')),
    'agents must be individual .md file paths, not a directory (the plugin validator rejects a dir)');
  assert.deepStrictEqual([...p.agents].sort(), agentFiles,
    'every .claude/agents/*.md file must be declared in plugin.json agents (and vice-versa)');
});

// --- 2. commands are de-prefixed to the plugin namespace -------------------
check('no q-*.md command file survives the rename', () => {
  const files = fs.readdirSync(path.join(REPO_ROOT, '.claude', 'commands'));
  const legacy = files.filter((f) => /^q-.*\.md$/.test(f));
  assert.deepStrictEqual(legacy, [],
    'a q-*.md file becomes /quetrex:q-* — command files must be de-prefixed');
});

check('the de-prefixed core command set is present', () => {
  for (const f of CORE_COMMANDS) {
    assert.ok(exists(`.claude/commands/${f}`), `missing de-prefixed command: .claude/commands/${f}`);
  }
});

// --- 3. the plugin's own hooks ---------------------------------------------
check('hooks/hooks.json parses and every command resolves from the plugin root', () => {
  const h = readJson('hooks/hooks.json');
  const cmds = hookCommands(h);
  assert.ok(cmds.length > 0, 'hooks.json registers at least one hook');
  for (const cmd of cmds) {
    assert.ok(cmd.includes('${CLAUDE_PLUGIN_ROOT}/'),
      `plugin hook command must resolve from \${CLAUDE_PLUGIN_ROOT}: ${cmd}`);
    assert.ok(!cmd.includes('${CLAUDE_PROJECT_DIR}'),
      `a plugin hook registration must not use \${CLAUDE_PROJECT_DIR} (that is for scripts locating the user repo): ${cmd}`);
    const rel = cmd.match(/\$\{CLAUDE_PLUGIN_ROOT\}\/([^"']+\.sh)/);
    assert.ok(rel, `plugin hook command has no .sh target: ${cmd}`);
    assert.ok(exists(rel[1]),
      `plugin wires ${rel[1]}, which does not exist — the hook would exit 127 on every matching tool call`);
  }
});

check('hooks.json registers ONLY the command-layer hooks, never the engine guards', () => {
  const h = readJson('hooks/hooks.json');
  const wired = new Set(hookCommands(h).map(hookBasename).filter(Boolean));
  for (const g of ENGINE_GUARDS) {
    assert.ok(!wired.has(g),
      `${g} is owned by quetrex-factory — quetrex must not re-register it (double-registration when both plugins are enabled)`);
  }
  for (const k of KEPT_HOOKS) {
    assert.ok(wired.has(k), `${k} is unique to the command layer and must stay registered by quetrex`);
  }
  assert.deepStrictEqual([...wired].sort(), [...KEPT_HOOKS].sort(),
    'hooks.json must wire exactly the kept command-layer hooks and nothing else');
});

// --- 4. no command sources a lib the way the retired installer required ----
check('no command sources a lib from ~/.claude (the plugin ships bin/quetrex-api on PATH)', () => {
  const dir = path.join(REPO_ROOT, '.claude', 'commands');
  for (const f of fs.readdirSync(dir)) {
    const body = read(`.claude/commands/${f}`);
    assert.ok(!/source\s+~\/\.claude\/lib/.test(body),
      `${f} still sources a lib from ~/.claude — a plugin never seeds that path; call the bin/quetrex-api tool by name`);
    assert.ok(!body.includes('${CLAUDE_PLUGIN_ROOT}'),
      `${f} references \${CLAUDE_PLUGIN_ROOT}, which is UNSET in slash-command bash — call the bundled quetrex-api tool by name instead`);
  }
});

// --- 4b. zero references to the retired per-project gate installer, in ANY
// invocation form (not just `source`) — a `bash ~/.claude/lib/...` call or a
// bare mention is just as broken in a fresh clone as `source` was.
check('no command invokes or references ~/.claude/lib in any form (the per-project gate-copy is retired)', () => {
  const dir = path.join(REPO_ROOT, '.claude', 'commands');
  for (const f of fs.readdirSync(dir)) {
    const body = read(`.claude/commands/${f}`);
    assert.ok(!/bash\s+~\/\.claude\/lib/.test(body),
      `${f} still invokes a lib via bash ~/.claude/lib — the per-project gate-copy is retired; the quetrex-factory plugin pin delivers the guards instead`);
    assert.ok(!/~\/\.claude\/lib/.test(body),
      `${f} still references ~/.claude/lib in some form — a plugin never seeds that path, and the per-project gate-copy it used to run is retired`);
  }
});

// --- 5. not one legacy /q-<cmd> reference survives, anywhere ----------------
check('zero /q-<cmd> command references remain repo-wide', () => {
  const hits = gitGrep(LEGACY_CMD_RE, ['.', ':(exclude).quetrex-backups', ':(exclude).quetrex/plan']);
  assert.deepStrictEqual(hits, [],
    'every legacy command reference must be rewritten to /quetrex:*:\n' + hits.join('\n'));
});

// --- 5b. a BROAD /q-<anything> scan across .claude/ — the specific-verb
// regex above only matches the exact known verbs (init, login, task-new, …)
// and a glob-style reference like `/q-task-*` slips past it untouched
// because "task-*" is not one of the enumerated verbs. This assertion
// catches any `/q-<lowercase-letters>` reference anywhere under .claude/,
// verb list or not, so that class of miss cannot recur.
check('zero broad /q-<anything> command references remain under .claude/ (catches glob forms like /q-task-*)', () => {
  const BROAD_LEGACY_RE = '/' + 'q-[a-z]';
  const hits = gitGrep(BROAD_LEGACY_RE, ['.claude', ':(exclude).quetrex-backups', ':(exclude).quetrex/plan']);
  assert.deepStrictEqual(hits, [],
    'every legacy /q-<verb> reference under .claude/ (including glob-style mentions like /q-task-*) must be rewritten to /quetrex:*:\n' + hits.join('\n'));
});

// --- 5b. NO VERSION PINS, ANYWHERE ----------------------------------------
// A pinned enabledPlugins entry makes the plugin count as DISABLED for
// dependency resolution, so the entire /quetrex:* command layer FAILED TO LOAD
// in every armed repo. Measured across four checkouts with `claude plugin list`:
//
//   pin absent            -> quetrex@quetrex ✔ enabled
//   pin true              -> quetrex@quetrex ✔ enabled
//   pin ["1.2.1"]         -> quetrex@quetrex ✘ failed to load   (exact installed version!)
//   pin ["1.1.0"]         -> quetrex@quetrex ✘ failed to load
//
// The repos carrying the "correct" concrete pin were precisely the broken ones,
// and the one that worked did so only because its pin was the floating boolean
// the old doctrine called wrong. Pinning also broke updating: a stale pin, or one
// naming a version a machine does not have, strands the team while every repo
// looks configured.
//
// So: booleans only, auto-update via extraKnownMarketplaces, and the running
// version is surfaced in the status bar (bin/quetrex-version) instead of frozen
// into config. These tests previously ENFORCED the array pin; they now forbid it.
const PIN_KEYS = ['quetrex@quetrex', 'quetrex-factory@quetrex'];
const isVersionPin = (v) => Array.isArray(v) || typeof v === 'string';

check('committed enabledPlugins uses booleans only — never a version pin', () => {
  const entries = Object.entries(readJson('.claude/settings.json').enabledPlugins || {});
  assert.ok(entries.length > 0, '.claude/settings.json must still enable the engine');
  for (const key of PIN_KEYS) {
    const value = Object.fromEntries(entries)[key];
    assert.strictEqual(
      value, true,
      `enabledPlugins["${key}"] = ${JSON.stringify(value)} — it must be exactly true. `
        + 'A version pin (array or string) makes the plugin count as disabled for dependency '
        + 'resolution and NO /quetrex:* command loads in this repo.',
    );
  }
});

check('no shipped writer emits a version pin for either quetrex plugin', () => {
  const isComment = (line) => /^\s*(#|\/\/)/.test(line);
  const rowText = (row) => row.slice(row.indexOf(':') + 1);
  const offenders = [];
  for (const key of PIN_KEYS) {
    const hits = gitGrep('enabledPlugins\\["' + key + '"\\][[:space:]]*=', [':!test/'])
      .filter((row) => !isComment(rowText(row)));
    for (const row of hits) {
      const rhs = rowText(row).split('=').slice(1).join('=');
      // A pin is an array literal or a quoted string on the right-hand side.
      if (/\[|"\d|'\d/.test(rhs)) offenders.push(row.trim());
    }
  }
  assert.deepStrictEqual(
    offenders, [],
    'a shipped file assigns a VERSION PIN to a quetrex plugin:\n  ' + offenders.join('\n  ')
      + '\nAssign true instead — a pin disables the command layer.',
  );
});

check('bin/quetrex-arm still enables both plugins, with true', () => {
  const body = read('bin/quetrex-arm');
  for (const key of PIN_KEYS) {
    const re = new RegExp('enabledPlugins\\["' + key.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '"\\]\\s*=\\s*true');
    assert.ok(re.test(body), `bin/quetrex-arm must set enabledPlugins["${key}"] = true`);
  }
});

check('the plugin declares no hard dependency (it made a pinned engine fatal)', () => {
  const m = readJson('.claude-plugin/plugin.json');
  assert.ok(
    m.dependencies === undefined,
    'plugin.json must not declare "dependencies": with it, a version-pinned quetrex-factory '
      + 'resolved as disabled and the whole command layer failed to load with '
      + '"Dependency \"quetrex-factory@quetrex\" is disabled". Verified: removing the field '
      + 'loads cleanly even with a pin present.',
  );
});

check('the version reporter used by the status bar ships and is executable', () => {
  assert.ok(exists('bin/quetrex-version'), 'bin/quetrex-version must ship — it is where the version is surfaced now');
  const st = fs.statSync(path.join(REPO_ROOT, 'bin/quetrex-version'));
  assert.ok((st.mode & 0o111) !== 0, 'bin/quetrex-version must be executable');
  const out = execFileSync('bash', [path.join(REPO_ROOT, 'bin/quetrex-version'), '--plain'], { encoding: 'utf8' }).trim();
  assert.match(out, /^\d+\.\d+\.\d+$/, 'quetrex-version --plain must print a bare semver, got: ' + out);
  const pretty = execFileSync('bash', [path.join(REPO_ROOT, 'bin/quetrex-version')], { encoding: 'utf8' }).trim();
  assert.match(pretty, /^Quetrex v\d+\.\d+\.\d+$/, 'quetrex-version must print "Quetrex vX.Y.Z", got: ' + pretty);
});

// --- 5bb. one branch-prefix default, and it is claude/ ---------------------
// `claude/` is the only prefix an Anthropic cloud routine can push to without a
// repo admin loosening the branch restriction, so it is the default everywhere
// and /quetrex:init does not ask. Two competing defaults in the same system is
// the confusion this replaced — assert there is exactly one.
check('every branch-prefix fallback defaults to claude/, never feature/', () => {
  const stale = gitGrep('(branchPrefix *\\|\\| *"feature/"|BRANCH_PREFIX="feature/"|echo .feature/.)', [':!test/']);
  assert.deepStrictEqual(stale, [],
    'a feature/ branch-prefix fallback survives — there must be exactly one default (claude/):\n' + stale.join('\n'));
});

check('init.md sets the branch prefix without prompting for it', () => {
  const body = read('.claude/commands/init.md');
  assert.ok(/BRANCH_PREFIX="claude\/"/.test(body),
    'init.md must default BRANCH_PREFIX to claude/');
  assert.ok(/do NOT ask the user|Do not prompt for this/i.test(body),
    'init.md must state that the branch prefix is not a question — it was a prompt users could not answer');
});

// --- 5c. the file-edit grant stays scoped and enforceable ------------------
// defaultMode "dontAsk" makes permissions.allow the COMPLETE grant set, so a
// bare "Edit"/"Write" grants every path on the machine with no prompt. And
// Claude Code consults Edit(path)/Read(path) rules ONLY — a Write(path) rule is
// accepted, never enforced, and warns at startup. Both mistakes look correct in
// review, so assert against both, here and in the need[] array /quetrex:init
// unions into every customer repo.
const BARE_EDIT_GRANTS = ['Write', 'Edit', 'NotebookEdit', 'MultiEdit'];
check('the file-edit permission grant is path-scoped and uses an enforceable Edit() rule', () => {
  const allow = readJson('.claude/settings.json').permissions.allow;
  for (const bare of BARE_EDIT_GRANTS) {
    assert.ok(!allow.includes(bare),
      `permissions.allow contains bare "${bare}" — under dontAsk that grants every path on the machine; use Edit(/**)`);
  }
  const unenforceable = allow.filter((r) => /^(Write|NotebookEdit|MultiEdit|Glob)\(/.test(r));
  assert.deepStrictEqual(unenforceable, [],
    'these rules are accepted but never consulted (only Edit(path)/Read(path) are): ' + unenforceable.join(', '));
  assert.ok(allow.includes('Edit(/**)'),
    'the pipeline needs a project-scoped file-edit grant: Edit(/**)');
});

check('init.md seeds customer repos with the same scoped, enforceable grant', () => {
  const body = read('.claude/commands/init.md');
  const need = body.match(/const need\s*=\s*\[[\s\S]*?\]/);
  assert.ok(need, 'init.md must still declare the need[] permission array');
  const entries = [...need[0].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
  for (const bare of BARE_EDIT_GRANTS) {
    assert.ok(!entries.includes(bare),
      `init.md need[] unions bare "${bare}" into every adopted repo — use Edit(/**)`);
  }
  const unenforceable = entries.filter((r) => /^(Write|NotebookEdit|MultiEdit|Glob)\(/.test(r));
  assert.deepStrictEqual(unenforceable, [],
    'init.md need[] contains rules Claude Code never consults: ' + unenforceable.join(', '));
  assert.ok(entries.includes('Edit(/**)'), 'init.md need[] must grant Edit(/**)');
});

// A merge that resolves badly can leave a VCS conflict marker in a committed
// file. Everything under .claude/commands/ is a prompt Claude Code loads at
// runtime, so a stray marker ships to every consumer of the plugin — and the
// rest of the verify chain stays green with one present. Sweep for all three
// marker forms across every tracked file.
check('no merge-conflict marker survives in any tracked file', () => {
  const markers = gitGrep('^(<<<<<<< |=======$|>>>>>>> )', ['.']);
  assert.deepStrictEqual(markers, [],
    'unresolved merge-conflict markers are committed:\n' + markers.join('\n'));
});

// --- 6. the npm installer is fully retired ---------------------------------
check('install.js is deleted', () => {
  assert.ok(!exists('install.js'), 'install.js is retired — the plugin does not seed ~/.claude');
});

check('package.json has no publish/install machinery, keeps the dev/verify scripts', () => {
  const pkg = readJson('package.json');
  assert.ok(!pkg.scripts || !pkg.scripts.postinstall, 'no postinstall — nothing to install');
  assert.ok(!('publishConfig' in pkg), 'no publishConfig — the package is not published');
  assert.ok(!('files' in pkg), 'no "files" allowlist — there is no tarball to ship');
  for (const s of ['check:js', 'check:sh', 'check:json', 'test']) {
    assert.ok(pkg.scripts && pkg.scripts[s], `dev script missing: ${s}`);
  }
  assert.ok(!pkg.scripts['check:js'].includes('install.js'),
    'check:js must not reference the deleted install.js');
});

check('no test file requires the retired install.js', () => {
  // Needles assembled from fragments so THIS file never itself contains the
  // literal it forbids (which would make the check match itself).
  const mod = '../inst' + 'all.js';
  const needles = ["require('" + mod + "')", 'require("' + mod + '")'];
  const dir = __dirname;
  for (const f of fs.readdirSync(dir)) {
    if (!f.endsWith('.js')) continue;
    const body = fs.readFileSync(path.join(dir, f), 'utf8');
    for (const n of needles) {
      assert.ok(!body.includes(n), `${f} still requires the retired installer`);
    }
  }
});

console.log(`\n${passed} passed`);
