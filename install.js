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

// Quetrex-owned GLOBAL hook scripts (wired into the shipped settings.json
// template). Matched by basename so a re-install can APPEND a newly-added
// quetrex hook to an existing settings.json without touching any hook entry
// the user added themselves (a different basename) and without duplicating
// one that's already there. verify-gate.sh / merge-gate.sh are deliberately
// excluded — those are PER-PROJECT gates installed by quetrex-init, never
// wired into the global settings.
const GLOBAL_HOOK_SCRIPTS = [
  'deny-guard.sh',
  'secret-scan.sh',
  'enforce-branch.sh',
  'workflow-reminder.sh',
  'auto-format.sh',
  'check-quetrex-update.sh',
];
const QUETREX_HOOK_BASENAMES = new Set(GLOBAL_HOOK_SCRIPTS);

// Hook scripts that must exist in the global hooks dir but are NOT wired into
// the global settings.json — quetrex-init copies them into a project's own
// .claude/hooks to power the per-project verify-gate / merge-gate chain.
const PER_PROJECT_HOOK_SCRIPTS = ['verify-gate.sh', 'merge-gate.sh'];

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

// Extract the script basename (e.g. "deny-guard.sh") from a hook entry's
// `command` string (e.g. "bash ~/.claude/hooks/deny-guard.sh"). Returns null
// if the entry has no recognizable `.sh` command.
function hookBasename(entry) {
  const cmd = entry && typeof entry.command === 'string' ? entry.command : '';
  const m = cmd.match(/([^/\s]+\.sh)\s*$/);
  return m ? m[1] : null;
}

function isQuetrexHookEntry(entry) {
  const base = hookBasename(entry);
  return base !== null && QUETREX_HOOK_BASENAMES.has(base);
}

// Reconcile one matcher-group's `hooks` array: APPEND any incoming
// quetrex-owned hook entry whose basename isn't already present; never touch,
// remove, reorder, or duplicate an existing entry (quetrex or user-authored).
function mergeHookEntries(existingHooks, incomingHooks) {
  const out = existingHooks.slice();
  const existingBasenames = new Set(existingHooks.map(hookBasename).filter(Boolean));
  for (const entry of incomingHooks) {
    if (!isQuetrexHookEntry(entry)) continue; // only quetrex-owned hooks are reconciled
    const base = hookBasename(entry);
    if (existingBasenames.has(base)) continue; // already present — never duplicate
    out.push(entry);
    existingBasenames.add(base);
  }
  return out;
}

// Shallow-clone a matcher-group, preserving its `hooks` array (or its absence)
// so an object that never had a `hooks` key doesn't gain one with value
// undefined (which would make it structurally different from the original).
function cloneHookGroup(g) {
  if (!('hooks' in g)) return { ...g };
  return { ...g, hooks: Array.isArray(g.hooks) ? g.hooks.slice() : g.hooks };
}

// Merge one event's array of matcher-groups (e.g. hooks.PreToolUse). Groups
// are matched by their `matcher` field (two groups with no `matcher` at all
// are treated as the same group, e.g. UserPromptSubmit/Stop). A group with no
// existing counterpart is appended wholesale (in order); a matched group has
// its `hooks` array reconciled via mergeHookEntries.
function mergeHookGroups(existingGroups, incomingGroups) {
  const out = existingGroups.map(cloneHookGroup);
  for (const incomingGroup of incomingGroups) {
    const match = out.find((g) => (g.matcher || undefined) === (incomingGroup.matcher || undefined));
    if (!match) {
      out.push(cloneHookGroup(incomingGroup));
      continue;
    }
    if (Array.isArray(match.hooks) && Array.isArray(incomingGroup.hooks)) {
      match.hooks = mergeHookEntries(match.hooks, incomingGroup.hooks);
    }
    // else: shape mismatch — leave the existing group untouched.
  }
  return out;
}

// Merge the whole `hooks` settings key, event-by-event. An event missing from
// the existing settings is taken wholesale from incoming; an event present in
// both is reconciled group-by-group so newly-added quetrex hooks reach an
// existing install without clobbering the user's own hook entries.
function mergeHooksSetting(existingHooks, incomingHooks) {
  const result = { ...existingHooks };
  for (const event of Object.keys(incomingHooks)) {
    if (Array.isArray(result[event]) && Array.isArray(incomingHooks[event])) {
      result[event] = mergeHookGroups(result[event], incomingHooks[event]);
    } else if (!(event in result)) {
      result[event] = incomingHooks[event];
    }
    // else: existing non-array value for this event wins (unexpected shape).
  }
  return result;
}

function deepMerge(target, source) {
  const result = { ...target };
  for (const key of Object.keys(source)) {
    if (key in result) {
      if (key === 'hooks' && isPlainObject(result[key]) && isPlainObject(source[key])) {
        result[key] = mergeHooksSetting(result[key], source[key]);
      } else if (isPlainObject(result[key]) && isPlainObject(source[key])) {
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
        // Hook scripts are invoked as `bash <path>` but must still be
        // executable in their own right — writeFileSync does not preserve
        // (or require) the source file's mode bits, so force it here rather
        // than depend on every hook script in the source tree being +x.
        if (relPosix.startsWith('hooks/') && relPosix.endsWith('.sh')) {
          try { fs.chmodSync(destPath, 0o755); } catch {}
        }
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

/**
 * Post-install assertion: the enforcement channel must be real, not just
 * copied bytes. Verifies every global hook script (the ones wired into
 * settings.json) landed in the dest hooks dir and is executable, that the
 * per-project gate scripts (verify-gate.sh / merge-gate.sh — copied by
 * quetrex-init into each project, never wired globally) are present, and
 * that the merged settings.json still re-parses as valid JSON. A broken
 * enforcement channel must fail the install loudly, never ship silently.
 *
 * @returns {boolean} true iff everything checks out.
 */
function assertHooksInstalled(destRoot, log = console.log) {
  const hooksDir = path.join(destRoot, 'hooks');
  const problems = [];

  const checkScript = (name, requireExecutable) => {
    const p = path.join(hooksDir, name);
    const st = lstatSafe(p);
    if (!st || !st.isFile()) {
      problems.push(`missing hook script: hooks/${name}`);
      return;
    }
    if (requireExecutable) {
      try {
        fs.accessSync(p, fs.constants.X_OK);
      } catch {
        problems.push(`hook script is not executable: hooks/${name} (chmod +x it in the source tree)`);
      }
    }
  };

  for (const name of GLOBAL_HOOK_SCRIPTS) checkScript(name, true);
  for (const name of PER_PROJECT_HOOK_SCRIPTS) checkScript(name, false);

  const settingsPath = path.join(destRoot, 'settings.json');
  try {
    JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    problems.push(`settings.json does not re-parse as valid JSON: ${e.message}`);
  }

  if (problems.length) {
    log('quetrex/base: INSTALL FAILED — the enforcement channel is broken:');
    for (const p of problems) log(`  - ${p}`);
    log('  Fix the issue(s) above and re-run the install; a partially-wired enforcement channel is not shipped.');
    return false;
  }
  return true;
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
  if (!assertHooksInstalled(destRoot)) {
    process.exit(1);
  }
  console.log('quetrex/base: done. Restart Claude Code to load new agents and skills.');
}

module.exports = {
  install,
  ensureSecretsEnv,
  assertHooksInstalled,
  deepMerge,
  unionArrays,
  isPrimitiveArray,
};
