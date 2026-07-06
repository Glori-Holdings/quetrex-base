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
 * deletes a file it cannot prove it wrote on this machine. Pure of global state
 * so it can be unit-tested against temp directories.
 *
 * @returns {{ copied: string[], pruned: string[] }} POSIX relative paths.
 */
function install(srcRoot, destRoot, opts = {}) {
  const log = opts.log || console.log;
  const stamp = opts.stamp || new Date().toISOString().replace(/[:.]/g, '-');

  if (!fs.existsSync(srcRoot)) {
    log('quetrex/base: no .claude directory found, skipping install');
    return { copied: [], pruned: [] };
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

  // --- Record the manifest for next time -----------------------------------
  fs.writeFileSync(
    manifestPath,
    JSON.stringify({ version: 1, files: [...copiedSet].sort() }, null, 2) + '\n',
  );

  for (const rel of copied) log(`  copied: ${rel}`);
  for (const rel of pruned) log(`  pruned: ${rel}`);
  if (pruned.length) log(`  (backups saved under ${BACKUP_DIR}/${stamp})`);

  return { copied: [...copiedSet], pruned };
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

module.exports = { install, ensureSecretsEnv, deepMerge, unionArrays, isPrimitiveArray };
