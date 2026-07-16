#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

// Files that are never copied, overwritten, or pruned — user-owned.
const PROTECTED = new Set(['secrets.env']);

// Merge-target / user-data files that must NEVER be pruned even if a future
// version stops shipping them — pruning settings.json would wipe the user's
// entire global Claude config. (They are still tracked in the manifest.)
const NO_PRUNE = new Set(['settings.json']);

// settings keys whose primitive arrays are UNIONED on merge so package
// additions (new permission entries) reach existing installs. Everything else
// keeps existing-wins, so we never silently mutate other array settings.
const UNION_KEYS = new Set(['allow', 'deny', 'ask']);

// Bookkeeping files the installer writes into the destination.
const MANIFEST = '.quetrex-manifest.json'; // the set of files this version ships
const BACKUP_DIR = '.quetrex-backups';     // timestamped copies of anything replaced/removed

// Retired base artifacts — commands and skills that a PRIOR version of THIS
// package shipped and the current version no longer does. Derived from git
// history: (every command/skill file ever committed) minus (what HEAD ships).
// Unlike the manifest-diff prune above (which only removes what a prior install
// recorded on THIS machine), this is a curated, explicit, auditable list that
// is actively removed from every destination even when this machine's manifest
// never mentioned it, so all machines converge onto the lean current base.
// Files unrelated to base (a user's own commands, artifacts from other tools)
// are intentionally NOT listed and are never touched. If the package ever
// reintroduces one of these names, the legacy-removal pass below skips it
// automatically (see copiedSet check). Removals are backed up first.
const LEGACY_REMOVE = [
  // Command files (once shipped, now dropped)
  'commands/add-runner-project.md',
  'commands/auto-pilot.md',
  'commands/complete.md',
  'commands/create-prd.md',
  'commands/create-rules.md',
  'commands/deploy-setup.md',
  'commands/execute.md',
  'commands/issue-prd.md',
  'commands/issue-rework.md',
  'commands/map-states.md',
  'commands/new-video.md',
  'commands/plan-feature.md',
  'commands/plan-project.md',
  'commands/prime.md',
  'commands/project-setup.md',
  'commands/quetrex-docs.md',
  'commands/quetrex-setup.md',
  'commands/runner.md',
  'commands/secrets.md',
  'commands/update-rules.md',
  // Skill directories (once shipped, now dropped)
  'skills/agent-browser',
  'skills/deploy',
  'skills/domain-capture',
  'skills/e2e-test',
  'skills/issue-requeue',
  'skills/merge-issue',
  'skills/paperclip',
  'skills/paperclip-create-agent',
  'skills/paperclip-create-plugin',
  'skills/para-memory-files',
  'skills/quetrex',
  'skills/quetrex-create-agent',
  'skills/quetrex-create-plugin',
  'skills/story-builder',
];

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// True for an array whose every element is a primitive. We only union these;
// arrays of objects (e.g. hook definitions) are left to existing-wins so a
// user's customizations are never silently duplicated.
function isPrimitiveArray(a) {
  return Array.isArray(a) && a.every((x) => x === null || typeof x !== 'object');
}

// Union two primitive arrays: existing first, then incoming entries not present.
function unionArrays(existing, incoming) {
  const out = existing.slice();
  const seen = new Set(existing.map((x) => JSON.stringify(x)));
  for (const x of incoming) {
    const k = JSON.stringify(x);
    if (!seen.has(k)) { out.push(x); seen.add(k); }
  }
  return out;
}

function deepMerge(target, source) {
  const result = { ...target };
  for (const key of Object.keys(source)) {
    if (key in result) {
      if (isPlainObject(result[key]) && isPlainObject(source[key])) {
        result[key] = deepMerge(result[key], source[key]);
      } else if (UNION_KEYS.has(key) && isPrimitiveArray(result[key]) && isPrimitiveArray(source[key])) {
        result[key] = unionArrays(result[key], source[key]);
      }
      // else: existing value wins — never clobber a user scalar, object array,
      // or a non-permission array.
    } else {
      result[key] = source[key];
    }
  }
  return result;
}

const lstatSafe = (p) => { try { return fs.lstatSync(p); } catch { return null; } };

// True iff resolved `targetAbs` is inside `baseAbs` (defends the prune/backup
// paths against a corrupt or hand-edited manifest containing "../" entries).
function within(baseAbs, targetAbs) {
  const b = path.resolve(baseAbs) + path.sep;
  const t = path.resolve(targetAbs);
  return t === path.resolve(baseAbs) || (t + path.sep).startsWith(b);
}

// Reject any relative path that is absolute or escapes its root.
function isSafeRel(relPosix) {
  if (!relPosix || path.isAbsolute(relPosix)) return false;
  return !relPosix.split('/').some((seg) => seg === '..' || seg === '');
}

/**
 * Copy the package's .claude tree into destRoot, then prune files a PRIOR
 * install of this package recorded but this version no longer ships — backing
 * each up first. The manifest is the only prune authority: the installer never
 * deletes a file it cannot prove it wrote on this machine. Separately, also
 * removes the curated LEGACY_REMOVE list (retired old-system artifacts) —
 * backing each up first — regardless of manifest history. Pure of global
 * state so it can be unit-tested against temp directories.
 *
 * @returns {{ copied: string[], pruned: string[], removed: string[] }} POSIX relative paths.
 */
function install(srcRoot, destRoot, opts = {}) {
  const log = opts.log || console.log;
  const stamp = opts.stamp || new Date().toISOString().replace(/[:.]/g, '-');

  if (!fs.existsSync(srcRoot)) {
    log('quetrex/base: no .claude directory found, skipping install');
    return { copied: [], pruned: [], removed: [] };
  }

  const toPosix = (p) => p.split(path.sep).join('/');
  const backupRoot = path.join(destRoot, BACKUP_DIR, stamp);
  const backup = (absPath, relPosix) => {
    const target = path.join(backupRoot, relPosix.split('/').join(path.sep));
    if (!within(backupRoot, target)) return false;
    fs.mkdirSync(path.dirname(target), { recursive: true });
    fs.copyFileSync(absPath, target);
    return true;
  };

  const writeFresh = (destPath, data) => {
    // Never write THROUGH a symlink at destPath (would clobber an unrelated
    // target the user linked to). Replace the link with a regular file.
    const st = lstatSafe(destPath);
    if (st && st.isSymbolicLink()) fs.unlinkSync(destPath);
    fs.writeFileSync(destPath, data);
  };

  const mergeSettings = (srcPath, destPath, relPosix) => {
    const incoming = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
    let existing = {};
    if (fs.existsSync(destPath)) {
      const raw = fs.readFileSync(destPath, 'utf8');
      try {
        existing = JSON.parse(raw);
      } catch {
        // The user's settings.json is unreadable. Do NOT silently replace it
        // with package defaults — back it up first so nothing is lost.
        backup(destPath, relPosix);
        log(`  WARNING: ${relPosix} was not valid JSON; backed it up before writing merged defaults`);
      }
    }
    writeFresh(destPath, JSON.stringify(deepMerge(existing, incoming), null, 2) + '\n');
    log(`  merged: ${relPosix}`);
  };

  // --- Copy ----------------------------------------------------------------
  const copied = []; // POSIX relative paths this version owns
  const walk = (relDir) => {
    const srcDir = path.join(srcRoot, relDir);
    const destDir = path.join(destRoot, relDir);
    if (!fs.existsSync(destDir)) fs.mkdirSync(destDir, { recursive: true });
    for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
      if (entry.isDirectory()) { walk(path.join(relDir, entry.name)); continue; }
      if (PROTECTED.has(entry.name)) continue;
      const rel = path.join(relDir, entry.name);
      const relPosix = toPosix(rel);
      const srcPath = path.join(srcRoot, rel);
      const destPath = path.join(destRoot, rel);
      if (entry.name === 'settings.json') {
        mergeSettings(srcPath, destPath, relPosix);
      } else {
        writeFresh(destPath, fs.readFileSync(srcPath));
      }
      copied.push(relPosix);
    }
  };
  walk('');

  const copiedSet = new Set(copied);

  // --- Prune (with backup) — manifest diff is the sole authority ------------
  const pruned = [];
  const removeManagedFile = (relPosix) => {
    if (copiedSet.has(relPosix)) return;                 // still shipped — keep
    if (!isSafeRel(relPosix)) return;                    // reject "../" / absolute
    if (PROTECTED.has(path.basename(relPosix))) return;
    if (NO_PRUNE.has(path.basename(relPosix))) return;   // never prune user config
    const abs = path.join(destRoot, relPosix.split('/').join(path.sep));
    if (!within(destRoot, abs)) return;                  // containment
    const st = lstatSafe(abs);
    if (!st || !st.isFile() || st.isSymbolicLink()) return; // only real files
    if (!backup(abs, relPosix)) return;                  // never delete without a backup
    fs.rmSync(abs);
    pruned.push(relPosix);
  };

  const manifestPath = path.join(destRoot, MANIFEST);
  if (fs.existsSync(manifestPath)) {
    let prev = [];
    try { prev = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).files || []; } catch {}
    for (const rel of prev) removeManagedFile(rel);
  }

  // --- Legacy removal (explicit, curated — not manifest-gated) --------------
  // Recursively back up every real file under `absDir`, preserving its
  // relative path under `relDirPosix`, then remove the directory. Symlinked
  // entries are skipped (never backed up or followed), mirroring the prune
  // real-file-only rule.
  const backupAndRemoveDir = (absDir, relDirPosix) => {
    const walkDir = (curAbs, curRelPosix) => {
      for (const entry of fs.readdirSync(curAbs, { withFileTypes: true })) {
        const entryAbs = path.join(curAbs, entry.name);
        const entryRelPosix = `${curRelPosix}/${entry.name}`;
        if (entry.isSymbolicLink()) continue;               // never follow/back up a link
        if (entry.isDirectory()) { walkDir(entryAbs, entryRelPosix); continue; }
        if (entry.isFile()) backup(entryAbs, entryRelPosix);
      }
    };
    walkDir(absDir, relDirPosix);
    fs.rmSync(absDir, { recursive: true, force: true });
  };

  const removed = [];
  for (const relPosix of LEGACY_REMOVE) {
    if (copiedSet.has(relPosix)) continue;                  // this version ships it — keep
    if ([...copiedSet].some((c) => c.startsWith(`${relPosix}/`))) continue; // dir still shipped
    if (!isSafeRel(relPosix)) continue;                      // reject "../" / absolute
    if (PROTECTED.has(path.basename(relPosix))) continue;
    if (NO_PRUNE.has(path.basename(relPosix))) continue;
    const abs = path.join(destRoot, relPosix.split('/').join(path.sep));
    if (!within(destRoot, abs)) continue;                     // containment
    const st = lstatSafe(abs);
    if (!st) continue;                                        // doesn't exist
    if (st.isSymbolicLink()) continue;                         // never remove/back up through a link
    if (st.isFile()) {
      if (!backup(abs, relPosix)) continue;                    // never delete without a backup
      fs.rmSync(abs);
      removed.push(relPosix);
    } else if (st.isDirectory()) {
      backupAndRemoveDir(abs, relPosix);
      removed.push(relPosix);
    }
  }

  // --- Record the manifest for next time -----------------------------------
  fs.writeFileSync(
    manifestPath,
    JSON.stringify({ version: 1, files: [...copiedSet].sort() }, null, 2) + '\n',
  );

  for (const rel of copied) log(`  copied: ${rel}`);
  for (const rel of pruned) log(`  pruned: ${rel}`);
  for (const rel of removed) log(`  removed (legacy): ${rel}`);
  if (pruned.length || removed.length) log(`  (backups saved under ${BACKUP_DIR}/${stamp})`);

  return { copied: [...copiedSet], pruned, removed };
}

function ensureSecretsEnv(destRoot, log = console.log) {
  const secretsPath = path.join(destRoot, 'secrets.env');
  if (!fs.existsSync(secretsPath)) {
    fs.writeFileSync(secretsPath, [
      '#!/bin/bash',
      '# quetrex-base secrets — never commit this file',
      '# Add to your shell profile (~/.zshrc or ~/.bashrc):',
      '#   source ~/.claude/secrets.env',
      '#',
      '# Add your API keys below as KEY=value lines.',
      '',
    ].join('\n'));
    try { fs.chmodSync(secretsPath, 0o600); } catch {}
    log('  created: ~/.claude/secrets.env (add your API keys, then source it from your shell profile)');
  }
}

if (require.main === module) {
  const srcRoot = path.join(__dirname, '.claude');
  const destRoot = path.join(os.homedir(), '.claude');
  console.log('quetrex/base: installing Claude Code configuration...');
  install(srcRoot, destRoot);
  ensureSecretsEnv(destRoot);
  console.log('quetrex/base: done. Restart Claude Code to load new agents and skills.');
}

module.exports = { install, ensureSecretsEnv, deepMerge, unionArrays, isPrimitiveArray, LEGACY_REMOVE };
