'use strict';

// Framework-free functional test for install.js. Run: `npm test`.
// Exercises the merge + prune + safety behaviors against throwaway temp dirs.

const fs = require('fs');
const os = require('os');
const path = require('path');
const assert = require('assert');

const { install, deepMerge, unionArrays, LEGACY_REMOVE } = require('../install.js');

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
const exists = (root, rel) => fs.existsSync(path.join(root, rel.split('/').join(path.sep)));
const silent = () => {};

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
  write(src, 'commands/quetrex-init.md', '# init');
  write(src, 'agents/qa.md', '# qa');
  const res = install(src, dest, { log: silent, stamp: 'T1' });
  assert.ok(exists(dest, 'commands/quetrex-init.md') && exists(dest, 'agents/qa.md'));
  const manifest = JSON.parse(read(dest, '.quetrex-manifest.json'));
  assert.deepStrictEqual(manifest.files, ['agents/qa.md', 'commands/quetrex-init.md']);
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
  write(src, 'commands/quetrex-init.md', '# init');
  // User authored their own command; quetrex never installed it here.
  // (Must be a non-legacy name — legacy names are actively removed below.)
  write(dest, 'commands/my-custom.md', 'my personal custom command');
  install(src, dest, { log: silent, stamp: 'U1' });
  assert.ok(exists(dest, 'commands/my-custom.md'), 'user file untouched — installer only prunes what it recorded shipping');
  assert.strictEqual(read(dest, 'commands/my-custom.md'), 'my personal custom command');
});

// --- functional: legacy removal --------------------------------------------
check('a legacy command file present in dest but not shipped is removed and backed up', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'commands/quetrex-init.md', '# init');
  write(dest, 'commands/runner.md', 'old runner command');
  assert.ok(LEGACY_REMOVE.includes('commands/runner.md'), 'sanity: runner.md is on the legacy list');
  const res = install(src, dest, { log: silent, stamp: 'L1' });
  assert.ok(!exists(dest, 'commands/runner.md'), 'legacy file removed');
  assert.ok(res.removed.includes('commands/runner.md'));
  assert.strictEqual(read(dest, '.quetrex-backups/L1/commands/runner.md'), 'old runner command', 'backed up before removal');
});

check('a legacy skill directory present in dest is removed recursively and backed up', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  write(src, 'commands/quetrex-init.md', '# init');
  write(dest, 'skills/merge-issue/SKILL.md', 'old merge-issue skill');
  write(dest, 'skills/merge-issue/nested/extra.md', 'nested file');
  assert.ok(LEGACY_REMOVE.includes('skills/merge-issue'), 'sanity: merge-issue is on the legacy list');
  const res = install(src, dest, { log: silent, stamp: 'L2' });
  assert.ok(!exists(dest, 'skills/merge-issue'), 'legacy skill directory removed');
  assert.ok(res.removed.includes('skills/merge-issue'));
  assert.strictEqual(
    read(dest, '.quetrex-backups/L2/skills/merge-issue/SKILL.md'),
    'old merge-issue skill',
    'top-level file backed up',
  );
  assert.strictEqual(
    read(dest, '.quetrex-backups/L2/skills/merge-issue/nested/extra.md'),
    'nested file',
    'nested file backed up',
  );
});

check('a legacy name still shipped by the current package is protected, not removed', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  // secrets.md is on the legacy list, but this (hypothetical future) version
  // still ships it — the legacy-removal pass must defer to copiedSet.
  write(src, 'commands/secrets.md', '# secrets, still shipped');
  const res = install(src, dest, { log: silent, stamp: 'L3' });
  assert.ok(exists(dest, 'commands/secrets.md'), 'still-shipped legacy name survives');
  assert.strictEqual(read(dest, 'commands/secrets.md'), '# secrets, still shipped');
  assert.ok(!res.removed.includes('commands/secrets.md'), 'not reported as removed');
});

check('a legacy file that is a symlink in dest is skipped, not removed or backed up', () => {
  const src = mkdtemp('qx-src-'); const dest = mkdtemp('qx-dst-');
  const elsewhere = mkdtemp('qx-elsewhere-');
  write(src, 'commands/quetrex-init.md', '# init');
  write(elsewhere, 'real.md', 'user real file, linked as legacy name');
  fs.mkdirSync(path.join(dest, 'commands'), { recursive: true });
  fs.symlinkSync(path.join(elsewhere, 'real.md'), path.join(dest, 'commands', 'runner.md'));
  const res = install(src, dest, { log: silent, stamp: 'L4' });
  assert.ok(fs.lstatSync(path.join(dest, 'commands', 'runner.md')).isSymbolicLink(), 'symlink left untouched');
  assert.ok(!res.removed.includes('commands/runner.md'), 'symlinked legacy path not reported removed');
  assert.strictEqual(read(elsewhere, 'real.md'), 'user real file, linked as legacy name', 'link target untouched');
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
  write(src, 'commands/quetrex-init.md', 'package content');
  fs.mkdirSync(path.join(dest, 'commands'), { recursive: true });
  fs.symlinkSync(path.join(elsewhere, 'real.md'), path.join(dest, 'commands', 'quetrex-init.md'));
  install(src, dest, { log: silent, stamp: 'SL1' });
  assert.strictEqual(read(elsewhere, 'real.md'), 'user real file', 'symlink target NOT clobbered');
  assert.strictEqual(read(dest, 'commands/quetrex-init.md'), 'package content', 'link replaced by fresh file');
  assert.ok(!fs.lstatSync(path.join(dest, 'commands', 'quetrex-init.md')).isSymbolicLink());
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
    { copied: [], pruned: [], removed: [] },
  );
});

console.log(`\n${passed} passed`);
