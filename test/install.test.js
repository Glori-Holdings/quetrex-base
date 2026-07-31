'use strict';

// Framework-free functional test for install.js. Run: `npm test`.
// Exercises the merge + prune + wiring + safety behaviors against throwaway
// temp directories, plus a set of assertions against the repo's OWN committed
// .claude/settings.json — the file that is simultaneously this repo's project
// config and the global template shipped to every customer.

const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const {
  install,
  assertHooksInstalled,
  noticeProjectGateWiring,
  wiredHooksByEvent,
  deepMerge,
  unionArrays,
  GLOBAL_HOOK_SCRIPTS,
  PER_PROJECT_HOOK_SCRIPTS,
  SUPERSEDED_HOOK_SCRIPTS,
  EXPECTED_GLOBAL_WIRING,
} = require('../install.js');

let passed = 0;
function check(name, fn) {
  fn();
  passed++;
  console.log(`  ok - ${name}`);
}
const mkdtemp = (prefix) => fs.mkdtempSync(path.join(os.tmpdir(), prefix));
function write(root, rel, content) {
  const p = path.join(root, rel.split('/').join(path.sep));
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, content);
}
const read = (root, rel) => fs.readFileSync(path.join(root, rel.split('/').join(path.sep)), 'utf8');
const readJson = (root, rel) => JSON.parse(read(root, rel));
const exists = (root, rel) => fs.existsSync(path.join(root, rel.split('/').join(path.sep)));
const silent = () => {};

const REPO_ROOT = path.join(__dirname, '..');

// Every basename wired anywhere in a settings object.
function wiredBasenames(settings) {
  const out = new Set();
  for (const entries of wiredHooksByEvent(settings).values()) {
    for (const e of entries) out.add(e.basename);
  }
  return out;
}

// Every hook `command` string in a settings object.
function hookCommands(settings) {
  const out = [];
  for (const groups of Object.values((settings && settings.hooks) || {})) {
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      for (const h of (g && g.hooks) || []) {
        if (h && typeof h.command === 'string') out.push(h.command);
      }
    }
  }
  return out;
}

const hookEntry = (name, timeout) => ({
  type: 'command',
  command: `bash "\${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/${name}"`,
  timeout,
});

// A destination that looks like a correct global install: every hook script on
// disk and executable, and settings wiring exactly what is expected.
function makeInstalledDest(settings) {
  const dest = mkdtemp('qx-assert-');
  fs.mkdirSync(path.join(dest, 'hooks'), { recursive: true });
  for (const n of [...GLOBAL_HOOK_SCRIPTS, ...PER_PROJECT_HOOK_SCRIPTS]) {
    const p = path.join(dest, 'hooks', n);
    fs.writeFileSync(p, '#!/usr/bin/env bash\nexit 0\n');
    fs.chmodSync(p, 0o755);
  }
  fs.writeFileSync(path.join(dest, 'settings.json'), JSON.stringify(settings, null, 2));
  return dest;
}

function goodGlobalSettings() {
  const hooks = {};
  for (const [event, names] of Object.entries(EXPECTED_GLOBAL_WIRING)) {
    hooks[event] = [{ hooks: names.map((n) => hookEntry(n, 30)) }];
  }
  return { hooks };
}

// --- unit: merge -----------------------------------------------------------
check('unionArrays dedups and preserves order', () => {
  assert.deepStrictEqual(unionArrays(['a', 'b'], ['b', 'c']), ['a', 'b', 'c']);
});

check('deepMerge unions permission allow-lists; user scalar wins', () => {
  const merged = deepMerge(
    { permissions: { allow: ['Bash(git push:*)'], defaultMode: 'dontAsk' } },
    { permissions: { allow: ['Bash(git push:*)', 'Bash(cargo:*)'], defaultMode: 'auto' } },
  );
  assert.deepStrictEqual(merged.permissions.allow, ['Bash(git push:*)', 'Bash(cargo:*)']);
  assert.strictEqual(merged.permissions.defaultMode, 'dontAsk');
});

check('deepMerge does NOT union a non-permission primitive array (existing wins)', () => {
  const merged = deepMerge({ keywords: ['a'] }, { keywords: ['a', 'b'] });
  assert.deepStrictEqual(merged.keywords, ['a']);
});

check('deepMerge leaves object-arrays (hooks) to existing-wins', () => {
  const merged = deepMerge(
    { hooks: { PreToolUse: [{ matcher: 'Bash', v: 1 }] } },
    { hooks: { PreToolUse: [{ matcher: 'Bash', v: 2 }] } },
  );
  assert.deepStrictEqual(merged.hooks.PreToolUse, [{ matcher: 'Bash', v: 1 }]);
});

// --- functional: install() -------------------------------------------------
check('fresh install copies tree and writes a manifest', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'commands/q-init.md', '# init');
  write(src, 'agents/qa.md', '# qa');
  const res = install(src, dest, { log: silent, stamp: 'T1' });
  assert.ok(exists(dest, 'commands/q-init.md') && exists(dest, 'agents/qa.md'));
  const manifest = JSON.parse(read(dest, '.quetrex-manifest.json'));
  assert.deepStrictEqual(manifest.files, ['agents/qa.md', 'commands/q-init.md']);
  assert.strictEqual(res.pruned.length, 0);
});

check('manifest diff prunes a dropped file and backs it up', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'commands/a.md', 'A'); write(src, 'commands/b.md', 'B');
  install(src, dest, { log: silent, stamp: 'V1' });
  fs.rmSync(path.join(src, 'commands', 'b.md'));           // v2 drops b.md
  const res = install(src, dest, { log: silent, stamp: 'V2' });
  assert.ok(!exists(dest, 'commands/b.md'), 'dropped file pruned');
  assert.ok(res.pruned.includes('commands/b.md'));
  assert.ok(exists(dest, 'commands/a.md'), 'kept file survives');
  assert.strictEqual(read(dest, '.quetrex-backups/V2/commands/b.md'), 'B', 'backed up');
});

check('a file NOT in any prior manifest is never pruned (no RETIRED blind delete)', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'commands/q-init.md', '# init');
  // User authored their own command; quetrex never installed it here.
  write(dest, 'commands/prime.md', 'my personal prime command');
  install(src, dest, { log: silent, stamp: 'U1' });
  assert.ok(exists(dest, 'commands/prime.md'), 'user file untouched — installer only prunes what it recorded shipping');
  assert.strictEqual(read(dest, 'commands/prime.md'), 'my personal prime command');
});

check('settings.json is never pruned even if the package stops shipping it', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({ a: 1 }));
  install(src, dest, { log: silent, stamp: 'P1' });      // v1 ships settings.json
  fs.rmSync(path.join(src, 'settings.json'));             // v2 drops it
  install(src, dest, { log: silent, stamp: 'P2' });
  assert.ok(exists(dest, 'settings.json'), 'user global config never pruned');
});

check('a "../" manifest entry cannot delete files outside the dest', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  const outside = mkdtemp('qx-out-');
  write(outside, 'important.txt', 'do not delete');
  write(src, 'commands/x.md', 'x');
  // Forge a malicious prior manifest.
  const rel = path.relative(dest, path.join(outside, 'important.txt')).split(path.sep).join('/');
  write(dest, '.quetrex-manifest.json', JSON.stringify({ version: 1, files: [rel] }));
  install(src, dest, { log: silent, stamp: 'TR1' });
  assert.ok(exists(outside, 'important.txt'), 'path traversal rejected — outside file survives');
});

check('copy replaces a dest symlink instead of writing through it', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  const elsewhere = mkdtemp('qx-elsewhere-');
  write(elsewhere, 'real.md', 'user real file');
  write(src, 'commands/q-init.md', 'package content');
  fs.mkdirSync(path.join(dest, 'commands'), { recursive: true });
  fs.symlinkSync(path.join(elsewhere, 'real.md'), path.join(dest, 'commands', 'q-init.md'));
  install(src, dest, { log: silent, stamp: 'SL1' });
  assert.strictEqual(read(elsewhere, 'real.md'), 'user real file', 'symlink target NOT clobbered');
  assert.strictEqual(read(dest, 'commands/q-init.md'), 'package content', 'link replaced by fresh file');
  assert.ok(!fs.lstatSync(path.join(dest, 'commands', 'q-init.md')).isSymbolicLink());
});

check('malformed dest settings.json is backed up before merged defaults are written', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({ permissions: { defaultMode: 'auto' } }));
  write(dest, 'settings.json', '{ "permissions": { "defaultMode": "dontAsk" } } // trailing junk');
  install(src, dest, { log: silent, stamp: 'MB1' });
  assert.ok(exists(dest, '.quetrex-backups/MB1/settings.json'), 'unreadable settings backed up');
  assert.ok(read(dest, '.quetrex-backups/MB1/settings.json').includes('dontAsk'));
});

check('secrets.env is never copied, overwritten, or pruned', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'secrets.env', 'PACKAGE_SHOULD_NOT_SHIP_THIS');
  write(dest, 'secrets.env', 'MY_REAL_SECRET=abc');
  install(src, dest, { log: silent, stamp: 'S1' });
  assert.strictEqual(read(dest, 'secrets.env'), 'MY_REAL_SECRET=abc');
});

check('missing source dir is a no-op, not a crash', () => {
  const dest = mkdtemp('qx-dst-');
  assert.deepStrictEqual(
    install(path.join(dest, 'nope'), dest, { log: silent, stamp: 'N1' }),
    { copied: [], pruned: [] },
  );
});

// --- CLAUDE.md is user-owned (#8) ------------------------------------------
check('an existing global CLAUDE.md with custom content survives an install', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'CLAUDE.md', '# Quetrex Base\n\n# LESSONS\n\n(Place Lessons Here)\n');
  const mine = '# Quetrex Base\n\n# LESSONS\n\n- never guess at an API\n- re-ground in the product model\n';
  write(dest, 'CLAUDE.md', mine);
  install(src, dest, { log: silent, stamp: 'C1' });
  assert.strictEqual(read(dest, 'CLAUDE.md'), mine, '#LESSONS must survive every update');
  // Re-installing must not erode it either.
  install(src, dest, { log: silent, stamp: 'C2' });
  assert.strictEqual(read(dest, 'CLAUDE.md'), mine);
});

check('CLAUDE.md is seeded when absent, and never pruned afterwards', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'CLAUDE.md', 'shipped doctrine');
  install(src, dest, { log: silent, stamp: 'C3' });
  assert.strictEqual(read(dest, 'CLAUDE.md'), 'shipped doctrine', 'seeded on a fresh machine');
  write(dest, 'CLAUDE.md', 'shipped doctrine\n\n- my lesson\n');
  fs.rmSync(path.join(src, 'CLAUDE.md'));                 // a later version drops it
  const res = install(src, dest, { log: silent, stamp: 'C4' });
  assert.ok(!res.pruned.includes('CLAUDE.md'), 'user-owned files are never pruned');
  assert.ok(read(dest, 'CLAUDE.md').includes('my lesson'));
});

check('a fresh install seeds ~/.claude/CLAUDE.md from the shipped template', () => {
  // The package does not ship a file named CLAUDE.md (this repo's own
  // .claude/CLAUDE.md is repo-specific), so the SEED_IF_ABSENT walk never fires
  // for it. Without the explicit template seed a fresh machine gets no global
  // CLAUDE.md at all — no doctrine import and nowhere for #LESSONS to live.
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'quetrex-doctrine.md', '# doctrine');
  write(src, 'templates/global-CLAUDE.md', '@quetrex-doctrine.md\n\n# LESSONS\n');
  install(src, dest, { log: silent, stamp: 'G1' });
  const seeded = read(dest, 'CLAUDE.md');
  assert.ok(seeded.includes('@quetrex-doctrine.md'), 'seeded CLAUDE.md must import the doctrine');
  assert.ok(seeded.includes('# LESSONS'), 'seeded CLAUDE.md must anchor #LESSONS');
  assert.ok(exists(dest, 'quetrex-doctrine.md'), 'the doctrine file itself must be installed');

  // Second install: the user's edits survive, and the file is never pruned.
  write(dest, 'CLAUDE.md', '@quetrex-doctrine.md\n\n# LESSONS\n- my lesson\n');
  const res = install(src, dest, { log: silent, stamp: 'G2' });
  assert.ok(read(dest, 'CLAUDE.md').includes('my lesson'), 'an existing CLAUDE.md is never overwritten');
  assert.ok(!res.pruned.includes('CLAUDE.md'), 'CLAUDE.md is never pruned');
});

check('the shipped package actually contains the files install.js seeds from', () => {
  const files = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'package.json'), 'utf8')).files || [];
  const shipped = (rel) => files.some((f) => rel === f || rel.startsWith(f));
  for (const rel of ['.claude/templates/global-CLAUDE.md', '.claude/quetrex-doctrine.md']) {
    assert.ok(exists(REPO_ROOT, rel), `${rel} must exist`);
    assert.ok(shipped(rel), `${rel} exists but package.json "files" does not ship it — the seed is dead code in the published tarball`);
  }
});

// --- per-project gates never reach the global settings (#2 / #7) -----------
check('the per-project gates are stripped from the GLOBAL settings merge', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({
    hooks: {
      Stop: [{ hooks: [hookEntry('verify-gate.sh', 900)] }],
      SubagentStop: [{ hooks: [hookEntry('verify-gate.sh', 600)] }],
      PreToolUse: [{ matcher: 'Bash', hooks: [hookEntry('deny-guard.sh', 30), hookEntry('merge-gate.sh', 60)] }],
    },
  }));
  install(src, dest, { log: silent, stamp: 'G1' });
  const merged = readJson(dest, 'settings.json');
  const wired = wiredBasenames(merged);
  assert.ok(!wired.has('verify-gate.sh'), 'verify-gate is a per-project gate, never global');
  assert.ok(!wired.has('merge-gate.sh'), 'merge-gate is a per-project gate, never global');
  assert.ok(wired.has('deny-guard.sh'), 'global guards still wired');
  assert.ok(!('Stop' in merged.hooks), 'an event emptied by the strip is dropped, not left hollow');
});

// --- removal path for superseded hooks (#3 / #3b) --------------------------
check('a superseded basename is unwired from an existing settings.json', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({
    hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [hookEntry('deny-guard.sh', 30)] }] },
  }));
  // A machine that installed an older quetrex: superseded hooks still wired.
  write(dest, 'settings.json', JSON.stringify({
    hooks: {
      Stop: [{ hooks: [hookEntry('check-quetrex-update.sh', 30)] }],
      PreToolUse: [{
        matcher: 'Bash',
        hooks: [
          hookEntry('security-check.sh', 30),
          hookEntry('enforce-merge-approval.sh', 30),
          { type: 'command', command: 'bash ~/my-own-hook.sh', timeout: 5 },
        ],
      }],
    },
  }));
  install(src, dest, { log: silent, stamp: 'X1' });
  const merged = readJson(dest, 'settings.json');
  const wired = wiredBasenames(merged);
  for (const name of SUPERSEDED_HOOK_SCRIPTS) {
    assert.ok(!wired.has(name), `${name} must be unwired — additive merge alone can never remove it`);
  }
  assert.ok(wired.has('my-own-hook.sh'), "the user's own hook is untouched");
  assert.ok(wired.has('deny-guard.sh'), 'current quetrex hooks still land');
  assert.ok(!('Stop' in merged.hooks), 'event emptied by the unwire is dropped');
  assert.ok(exists(dest, '.quetrex-backups/X1/settings.json'), 'an unwire is backed up like a prune');
});

check('a superseded hook script recorded in a prior manifest is pruned and backed up', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({ hooks: {} }));
  write(dest, 'hooks/check-quetrex-update.sh', '#!/usr/bin/env bash\nnpm show quetrex-base\n');
  write(dest, '.quetrex-manifest.json', JSON.stringify({
    version: 1, files: ['hooks/check-quetrex-update.sh'],
  }));
  const res = install(src, dest, { log: silent, stamp: 'X2' });
  assert.ok(!exists(dest, 'hooks/check-quetrex-update.sh'), 'superseded script removed');
  assert.ok(res.pruned.includes('hooks/check-quetrex-update.sh'));
  assert.ok(read(dest, '.quetrex-backups/X2/hooks/check-quetrex-update.sh').includes('npm show'));
});

check('a superseded script this installer never recorded writing is NOT deleted', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({ hooks: {} }));
  // No prior manifest — the installer cannot prove it wrote this file.
  write(dest, 'hooks/security-check.sh', 'user-authored, same name by coincidence');
  install(src, dest, { log: silent, stamp: 'X3' });
  assert.ok(exists(dest, 'hooks/security-check.sh'), 'manifest remains the sole delete authority');
});

// --- millisecond-scale timeouts on an existing install (#11) ---------------
check('an upgrade repairs millisecond-scale timeouts on quetrex hooks only', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'settings.json', JSON.stringify({
    hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [hookEntry('deny-guard.sh', 30)] }] },
  }));
  // A machine carrying the values this package actually shipped: 5000 / 10000.
  write(dest, 'settings.json', JSON.stringify({
    hooks: {
      PreToolUse: [{
        matcher: 'Bash',
        hooks: [
          { type: 'command', command: 'bash ~/.claude/hooks/deny-guard.sh', timeout: 5000 },
          { type: 'command', command: 'bash ~/.claude/hooks/my-own-hook.sh', timeout: 4000 },
        ],
      }],
      PostToolUse: [{
        matcher: 'Write|Edit',
        hooks: [{ type: 'command', command: 'bash ~/.claude/hooks/auto-format.sh', timeout: 10000 }],
      }],
    },
  }));
  const lines = [];
  install(src, dest, { log: (m) => lines.push(m), stamp: 'MS1' });
  const merged = readJson(dest, 'settings.json');
  const byEvent = wiredHooksByEvent(merged);
  const t = (event, name) => (byEvent.get(event) || []).find((e) => e.basename === name).timeout;
  assert.strictEqual(t('PreToolUse', 'deny-guard.sh'), 30, '83 minutes is not a guard timeout');
  assert.strictEqual(t('PostToolUse', 'auto-format.sh'), 30);
  assert.strictEqual(t('PreToolUse', 'my-own-hook.sh'), 4000, "the user's own hook is never rewritten");
  assert.ok(lines.some((l) => l.includes('SECONDS')));
  assert.ok(exists(dest, '.quetrex-backups/MS1/settings.json'), 'a retime is backed up like a prune');
});

// --- the wiring assertion (#7 / #11) ---------------------------------------
check('assertHooksInstalled passes on a correctly wired install', () => {
  const dest = makeInstalledDest(goodGlobalSettings());
  assert.strictEqual(assertHooksInstalled(dest, silent), true);
});

check('assertHooksInstalled FAILS when a hook is present on disk but unwired', () => {
  const settings = goodGlobalSettings();
  // Drop deny-guard from the wiring; the script stays on disk and executable.
  settings.hooks.PreToolUse[0].hooks = settings.hooks.PreToolUse[0].hooks
    .filter((h) => !h.command.includes('deny-guard.sh'));
  const dest = makeInstalledDest(settings);
  const lines = [];
  assert.strictEqual(assertHooksInstalled(dest, (m) => lines.push(m)), false);
  assert.ok(lines.some((l) => l.includes('deny-guard.sh') && l.includes('NOT wired')));
});

check('assertHooksInstalled FAILS when a per-project gate is wired globally', () => {
  const settings = goodGlobalSettings();
  settings.hooks.Stop = [{ hooks: [hookEntry('verify-gate.sh', 900)] }];
  const dest = makeInstalledDest(settings);
  assert.strictEqual(assertHooksInstalled(dest, silent), false);
});

check('assertHooksInstalled FAILS when a superseded hook is still wired', () => {
  const settings = goodGlobalSettings();
  settings.hooks.PreToolUse[0].hooks.push(hookEntry('security-check.sh', 30));
  const dest = makeInstalledDest(settings);
  assert.strictEqual(assertHooksInstalled(dest, silent), false);
});

check('assertHooksInstalled FAILS a millisecond-scale timeout', () => {
  const settings = goodGlobalSettings();
  settings.hooks.PreToolUse[0].hooks[0].timeout = 5000; // 83 minutes as seconds
  const dest = makeInstalledDest(settings);
  const lines = [];
  assert.strictEqual(assertHooksInstalled(dest, (m) => lines.push(m)), false);
  assert.ok(lines.some((l) => l.includes('SECONDS')));
});

check('assertHooksInstalled FAILS when a hook script is missing from disk', () => {
  const dest = makeInstalledDest(goodGlobalSettings());
  fs.rmSync(path.join(dest, 'hooks', 'secret-scan.sh'));
  assert.strictEqual(assertHooksInstalled(dest, silent), false);
});

check('noticeProjectGateWiring warns for a .quetrex repo with no repo-local gates', () => {
  const repo = mkdtemp('qx-proj-');
  fs.mkdirSync(path.join(repo, '.quetrex'), { recursive: true });
  write(repo, '.claude/settings.json', JSON.stringify({
    hooks: { PreToolUse: [{ matcher: 'Bash', hooks: [hookEntry('deny-guard.sh', 30)] }] },
  }));
  const lines = [];
  assert.strictEqual(noticeProjectGateWiring(repo, (m) => lines.push(m)), true);
  assert.ok(lines.some((l) => l.includes('verify-gate.sh') && l.includes('merge-gate.sh')));

  write(repo, '.claude/settings.json', JSON.stringify({
    hooks: {
      Stop: [{ hooks: [hookEntry('verify-gate.sh', 900)] }],
      PreToolUse: [{ matcher: 'Bash', hooks: [hookEntry('merge-gate.sh', 60)] }],
    },
  }));
  assert.strictEqual(noticeProjectGateWiring(repo, silent), false, 'silent once the gates are wired');
});

check('a repo with no .quetrex/ gets no gate notice', () => {
  const repo = mkdtemp('qx-plain-');
  assert.strictEqual(noticeProjectGateWiring(repo, silent), false);
});

// --- the repo's OWN committed settings.json --------------------------------
// This file is both quetrex-base's project config and the global template.
// A cloud routine only ever sees what is committed — never ~/.claude.
const committed = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, '.claude', 'settings.json'), 'utf8'));

check('no committed hook command resolves through ~/.claude', () => {
  // statusLine is deliberately exempt: it is a cosmetic, global-only asset
  // that q-init does not deploy per project. Enforcement is what must travel.
  const offenders = hookCommands(committed).filter((c) => c.includes('~/.claude') || c.includes('$HOME/.claude'));
  assert.deepStrictEqual(
    offenders, [],
    'a hook command pointing at ~/.claude exits 127 in a fresh clone, and anything other than exit 0 or 2 is NON-blocking — enforcement fails open, silently',
  );
});

check('every committed hook command is project-relative and its script is committed', () => {
  for (const cmd of hookCommands(committed)) {
    assert.ok(
      cmd.includes('${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/'),
      `hook command is not project-relative: ${cmd}`,
    );
    const m = cmd.match(/([^/\s"']+\.sh)["']?\s*$/);
    assert.ok(m, `hook command has no .sh target: ${cmd}`);
    assert.ok(
      exists(REPO_ROOT, `.claude/hooks/${m[1]}`),
      `wired but not committed: .claude/hooks/${m[1]} — the wiring assertion exists so this can never ship`,
    );
  }
});

check('committed settings wire the flagship gates at their load-bearing timeouts', () => {
  const byEvent = wiredHooksByEvent(committed);
  const find = (event, name) => (byEvent.get(event) || []).find((e) => e.basename === name);

  const stop = find('Stop', 'verify-gate.sh');
  assert.ok(stop, 'Stop must run verify-gate.sh');
  assert.strictEqual(stop.timeout, 900);

  const sub = find('SubagentStop', 'verify-gate.sh');
  assert.ok(sub, 'SubagentStop must run verify-gate.sh — parallel worktree developers finish there');
  assert.strictEqual(sub.timeout, 600);

  const merge = find('PreToolUse', 'merge-gate.sh');
  assert.ok(merge, 'merge-gate.sh must be in the PreToolUse/Bash group');
  assert.strictEqual(merge.timeout, 60);

  assert.ok(find('PostToolUse', 'edit-gate.sh'), 'PostToolUse Write|Edit must run edit-gate.sh');
  assert.ok(find('SessionStart', 'session-state.sh'), 'SessionStart must run session-state.sh');
});

check('the SessionStart matcher covers both the startup and compact sources', () => {
  const groups = committed.hooks.SessionStart || [];
  const g = groups.find((x) => (x.hooks || []).some((h) => h.command.includes('session-state.sh')));
  assert.ok(g, 'session-state.sh must be wired under SessionStart');
  assert.ok(/startup/.test(g.matcher) && /compact/.test(g.matcher),
    'compact is the only source whose hook output reaches the conversation after a compaction');
});

check('no committed hook timeout is millisecond-scale', () => {
  for (const [, entries] of wiredHooksByEvent(committed)) {
    for (const { basename, timeout } of entries) {
      if (timeout === undefined) continue;
      assert.strictEqual(typeof timeout, 'number', `${basename} timeout must be a number`);
      assert.ok(timeout > 0 && timeout <= 900,
        `${basename} timeout ${timeout} is not a sane number of SECONDS (verify-gate derives its fail-closed budget from it)`);
    }
  }
});

check('no superseded hook is wired in the committed settings', () => {
  const wired = wiredBasenames(committed);
  for (const name of SUPERSEDED_HOOK_SCRIPTS) {
    assert.ok(!wired.has(name), `${name} is superseded and must not be wired`);
    assert.ok(!exists(REPO_ROOT, `.claude/hooks/${name}`), `${name} must be deleted from the repo`);
  }
});

check('every hook script on disk is wired, or is on the stated exemption list', () => {
  // A script nobody runs is dead weight; worse, it reads as enforcement that
  // is not enforcing. Anything added to .claude/hooks/ must be wired here or
  // consciously named below with the reason.
  const EXEMPT = new Set([]); // none today — add with a comment stating why
  const wired = wiredBasenames(committed);
  const onDisk = fs.readdirSync(path.join(REPO_ROOT, '.claude', 'hooks')).filter((f) => f.endsWith('.sh'));
  const orphans = onDisk.filter((f) => !wired.has(f) && !EXEMPT.has(f));
  assert.deepStrictEqual(orphans, [], 'unwired hook script(s) on disk');
});

// --- channel parity: committed settings / q-init installer / plugin ---------
// The gates travel through three channels and a hook is only enforcement in the
// channel that wires it. These lock the two ways that silently breaks: a hook
// wired in one channel and not the other, and a wiring whose script is absent
// (exit 127, which Claude Code treats as NON-blocking — a silent fail-open).
const gatesInstaller = fs.readFileSync(
  path.join(REPO_ROOT, '.claude', 'lib', 'quetrex-install-project-gates.sh'), 'utf8');

// Deliberate, stated divergences. Each must carry its reason here.
const PROJECT_CHANNEL_EXEMPT = new Set([
  // A fixed orchestration nudge, not a gate. The operator has it at user scope;
  // a per-project copy injects the identical paragraph twice per prompt.
  'workflow-reminder.sh',
]);
const PLUGIN_CHANNEL_EXEMPT = new Set([
  // Per-project by design: both execute a command chain read from a repository
  // file, which must stay opt-in per repo. A plugin installs per USER.
  'verify-gate.sh',
  'merge-gate.sh',
]);

check('the q-init gates installer wires every hook the committed settings wire', () => {
  for (const name of wiredBasenames(committed)) {
    if (PROJECT_CHANNEL_EXEMPT.has(name)) continue;
    assert.ok(
      gatesInstaller.includes(`hookEntry("${name}"`),
      `${name} is wired in the committed settings but not by quetrex-install-project-gates.sh — the gate would not travel to a customer repo or a cloud routine`,
    );
  }
});

check('the gates installer copies every script it wires', () => {
  const m = gatesInstaller.match(/^GATE_SCRIPTS="([^"]*)"/m);
  assert.ok(m, 'GATE_SCRIPTS list not found');
  const copied = new Set(m[1].split(/\s+/).filter(Boolean));
  for (const name of gatesInstaller.match(/hookEntry\("([^"]+\.sh)"/g).map((s) => s.slice(11, -1))) {
    assert.ok(copied.has(name),
      `${name} is wired into a customer repo but never copied there — a wired hook whose script is missing exits 127, and any exit other than 0 or 2 is non-blocking`);
  }
  for (const name of copied) {
    assert.ok(exists(REPO_ROOT, `.claude/hooks/${name}`), `GATE_SCRIPTS names a script that does not exist: ${name}`);
  }
});

check('q-init stages every hook the gates installer deploys', () => {
  const qinit = fs.readFileSync(path.join(REPO_ROOT, '.claude', 'commands', 'q-init.md'), 'utf8');
  const m = gatesInstaller.match(/^GATE_SCRIPTS="([^"]*)"/m);
  for (const name of m[1].split(/\s+/).filter(Boolean)) {
    assert.ok(qinit.includes(`.claude/hooks/${name}`),
      `${name} is deployed by the installer but q-init never stages it — a cloud routine clones the repo and finds the wiring without the script`);
  }
});

check('the plugin channel wires the same hooks, from the plugin root, and they exist', () => {
  const plugin = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, 'hooks', 'hooks.json'), 'utf8'));
  const pluginWired = wiredBasenames(plugin);
  for (const cmd of hookCommands(plugin)) {
    assert.ok(cmd.includes('${CLAUDE_PLUGIN_ROOT}/'),
      `plugin hook command must resolve from the plugin root: ${cmd}`);
    const rel = cmd.match(/\$\{CLAUDE_PLUGIN_ROOT\}\/([^"']+\.sh)/);
    assert.ok(rel, `plugin hook command has no .sh target: ${cmd}`);
    assert.ok(exists(REPO_ROOT, rel[1]),
      `plugin wires ${rel[1]}, which does not exist at the plugin root — the hook would exit 127 on every matching tool call`);
  }
  for (const name of wiredBasenames(committed)) {
    if (PLUGIN_CHANNEL_EXEMPT.has(name)) continue;
    assert.ok(pluginWired.has(name), `${name} is wired in the committed settings but not by the plugin`);
  }
  for (const name of PLUGIN_CHANNEL_EXEMPT) {
    assert.ok(!pluginWired.has(name), `${name} is per-project and must NOT be wired by the plugin`);
  }
});

console.log(`\n${passed} passed`);
