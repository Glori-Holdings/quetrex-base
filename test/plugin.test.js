'use strict';

// Framework-free structure test for the `quetrex` Claude Code plugin.
// Run: `npm test` (this file, then bash test/merge-gate.test.sh).
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

// --- 1. plugin.json manifest -----------------------------------------------
check('.claude-plugin/plugin.json parses and carries the v2 identity', () => {
  const p = readJson('.claude-plugin/plugin.json');
  assert.strictEqual(p.name, 'quetrex', 'plugin name is the slash-command namespace — must be "quetrex"');
  assert.strictEqual(p.version, '2.0.3');
  assert.strictEqual(p.displayName, 'Quetrex');
});

check('plugin.json depends on quetrex-factory (the build engine)', () => {
  const p = readJson('.claude-plugin/plugin.json');
  assert.ok(Array.isArray(p.dependencies), 'dependencies must be an array');
  assert.ok(p.dependencies.includes('quetrex-factory'),
    'quetrex installs the engine automatically — quetrex-factory must be a declared dependency');
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

// --- 5b. the engine pin is a shape Claude Code actually accepts -------------
// Claude Code's settings schema is:
//   enabledPlugins: record<string, string[] | boolean | undefined>
// A bare version STRING (`"quetrex-factory@quetrex": "1.0.0"`) fails validation
// with `Invalid input`, and the entry is dropped — the repo silently loses its
// engine pin while looking pinned. The array form is the documented "extended
// format with version constraints", and Claude Code treats an array value as
// enabled (`value === true || Array.isArray(value)`).
const FACTORY_PIN_KEY = 'quetrex-factory@quetrex';
const isValidEnabledPluginsValue = (v) =>
  typeof v === 'boolean' ||
  (Array.isArray(v) && v.length > 0 && v.every((r) => typeof r === 'string' && r.length > 0));

check('the enabledPlugins validator rejects a bare version string and accepts the array pin', () => {
  // The exact shape that shipped broken — this is the regression this test owns.
  assert.ok(!isValidEnabledPluginsValue('1.0.0'),
    'a bare version string must be rejected — Claude Code reports it as Invalid input');
  assert.ok(!isValidEnabledPluginsValue([]), 'an empty array pins nothing');
  assert.ok(!isValidEnabledPluginsValue(null), 'null is not a valid enabledPlugins value');
  // The shapes the schema does accept.
  assert.ok(isValidEnabledPluginsValue(true), 'true (unversioned enable) is valid');
  assert.ok(isValidEnabledPluginsValue(false), 'false (explicit disable) is valid');
  assert.ok(isValidEnabledPluginsValue(['1.0.0']), 'a one-element semver array is the concrete pin');
});

check('committed .claude/settings.json enabledPlugins values all satisfy the schema', () => {
  const entries = Object.entries(readJson('.claude/settings.json').enabledPlugins || {});
  assert.ok(entries.length > 0, '.claude/settings.json must pin the engine for teammates and cloud routines');
  for (const [key, value] of entries) {
    assert.ok(isValidEnabledPluginsValue(value),
      `enabledPlugins["${key}"] = ${JSON.stringify(value)} is not a boolean or a non-empty string array`);
  }
  const pin = Object.fromEntries(entries)[FACTORY_PIN_KEY];
  assert.ok(Array.isArray(pin),
    `${FACTORY_PIN_KEY} must be a concrete array pin, not ${JSON.stringify(pin)} — cloud routines need an exact engine`);
});

// Every place that WRITES the pin. bin/quetrex-arm is the deterministic arming
// executable /quetrex:init shells out to; update.md carries the bump snippet.
// Discovered by repo-wide grep rather than hardcoded, so a new writer added
// elsewhere cannot reintroduce the bare-string form unnoticed.
check('every pin writer emits the array form, never a bare version string', () => {
  const ASSIGN_RE = new RegExp('enabledPlugins\\["' + FACTORY_PIN_KEY + '"\\]\\s*=\\s*[^;\\n]+', 'g');
  // Drop comment lines (`#` in shell, `//` in the embedded node programs) — a
  // doc comment describing the pin must not satisfy "this file writes the pin",
  // or deleting the real write would still pass.
  const isComment = (line) => /^\s*(#|\/\/)/.test(line);
  // gitGrep does NOT pass -n, so each row is `path:content` — split on the FIRST
  // colon only. (Slicing at a later colon silently disables the comment filter.)
  const rowPath = (row) => row.slice(0, row.indexOf(':'));
  const rowText = (row) => row.slice(row.indexOf(':') + 1);
  const hits = gitGrep('enabledPlugins\\["' + FACTORY_PIN_KEY + '"\\][[:space:]]*=', [':!test/'])
    .filter((row) => !isComment(rowText(row)));
  const unique = [...new Set(hits.map(rowPath))];
  assert.ok(unique.length > 0, 'the repo must still write the engine pin somewhere');
  assert.ok(unique.includes('bin/quetrex-arm'),
    'bin/quetrex-arm is the deterministic arming writer — it must still write the pin');
  for (const rel of unique) {
    const body = read(rel);
    const assignments = (body.match(ASSIGN_RE) || [])
      .filter((a) => !isComment(a));
    assert.ok(assignments.length > 0, `${rel} must still write the ${FACTORY_PIN_KEY} pin`);
    for (const a of assignments) {
      const rhs = a.slice(a.indexOf('=') + 1).trim();
      assert.ok(rhs.startsWith('['),
        `${rel} assigns a non-array pin (${rhs}) — a bare version string fails settings validation`);
    }
  }
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
