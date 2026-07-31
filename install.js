#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

// Files that are never overwritten or pruned — user-owned. The package may
// SEED one when it is absent (see SEED_IF_ABSENT), but an existing copy is
// always left exactly as the user left it.
//
// CLAUDE.md is here because it carries the user's #LESSONS: a full overwrite
// on every `npm i -g` silently destroyed them, and was also the real cause of
// the half-applied command rename recurring on every update.
const PROTECTED = new Set(['secrets.env', 'CLAUDE.md']);

// Protected files the installer WILL write when they do not exist yet, so a
// fresh machine still gets the shipped starting point. secrets.env is
// deliberately NOT here — ensureSecretsEnv() owns it, because it must be
// created with 0600 and must never contain packaged content.
const SEED_IF_ABSENT = new Set(['CLAUDE.md']);

// The package does NOT ship `.claude/CLAUDE.md`: that file in this repo is
// quetrex-base's own PROJECT config ("this repo is the engine"), which would be
// nonsense on a customer's machine. The global starting point is a separate
// template, seeded to ~/.claude/CLAUDE.md only when absent. It is a two-line
// file: an `@quetrex-doctrine.md` import (that file IS replaced every upgrade)
// plus an empty `# LESSONS` the user owns forever.
const GLOBAL_CLAUDE_MD_TEMPLATE = path.join('templates', 'global-CLAUDE.md');

// Merge-target / user-data files that must NEVER be pruned even if a future
// version stops shipping them — pruning settings.json would wipe the user's
// entire global Claude config. (They are still tracked in the manifest.)
const NO_PRUNE = new Set(['settings.json']);

// settings keys whose primitive arrays are UNIONED on merge so package
// additions (new permission entries) reach existing installs. Everything else
// keeps existing-wins, so we never silently mutate other array settings.
const UNION_KEYS = new Set(['allow', 'deny', 'ask']);

// Quetrex-owned GLOBAL hook scripts — the ones wired into the shipped
// settings.json template. Matched by basename so a re-install can APPEND a
// newly-added quetrex hook to an existing settings.json without touching any
// hook entry the user added themselves (a different basename) and without
// duplicating one that's already there.
const GLOBAL_HOOK_SCRIPTS = [
  'deny-guard.sh',
  'secret-scan.sh',
  'enforce-branch.sh',
  'workflow-reminder.sh',
  'auto-format.sh',
  'edit-gate.sh',
  'session-state.sh',
];
const QUETREX_HOOK_BASENAMES = new Set(GLOBAL_HOOK_SCRIPTS);

// Hook scripts that must exist in the global hooks dir but are deliberately
// NOT wired into the global settings.json. q-init (via
// lib/quetrex-install-project-gates.sh) copies them into a project's own
// .claude/hooks and wires them into that repo's COMMITTED settings, which is
// the only channel a cloud routine ever sees. They stay unwired globally
// because verify-gate autodetects a verify chain from any package.json — wired
// globally it would run a stranger repo's chain on every Stop.
const PER_PROJECT_HOOK_SCRIPTS = ['verify-gate.sh', 'merge-gate.sh'];
const PER_PROJECT_HOOK_BASENAMES = new Set(PER_PROJECT_HOOK_SCRIPTS);

// Hooks this package used to ship and has since superseded. Hook reconciliation
// is otherwise purely ADDITIVE by basename, so without this list a removal can
// never reach a machine that already has quetrex installed — which is exactly
// why the drop of these three never landed anywhere. The installer UNWIRES
// these from the merged settings, and prunes the script itself only when a
// prior manifest proves this installer wrote it (manifest stays the sole
// delete authority, and nothing is deleted without a backup).
const SUPERSEDED_HOOK_SCRIPTS = [
  'security-check.sh',          // strictly weaker duplicate of secret-scan.sh
  'enforce-merge-approval.sh',  // superseded by merge-gate.sh; hung unattended runs
  'check-quetrex-update.sh',    // the only hook that made a network call
];
const SUPERSEDED_HOOK_BASENAMES = new Set(SUPERSEDED_HOOK_SCRIPTS);

// The wiring the global settings.json must actually have after a merge.
// assertHooksInstalled checks REACHABILITY here, not just that bytes landed on
// disk: a hook script that no settings file references is not enforcement.
const EXPECTED_GLOBAL_WIRING = {
  SessionStart: ['session-state.sh'],
  UserPromptSubmit: ['workflow-reminder.sh'],
  PreToolUse: ['deny-guard.sh', 'secret-scan.sh', 'enforce-branch.sh'],
  PostToolUse: ['auto-format.sh', 'edit-gate.sh'],
};

// Largest hook timeout the installer will accept, in SECONDS. The field is
// seconds, not milliseconds: a 5000 here is 83 minutes of a stalled session.
// verify-gate.sh derives its whole fail-closed budget from this number, so a
// wrong value is not cosmetic.
const MAX_HOOK_TIMEOUT_SECONDS = 900;

// The timeout, in seconds, this package ships for each of its own hooks. Used
// to REPAIR an existing install whose entries carry millisecond-scale values
// (5000 / 10000 / 3000 shipped for a long time). Only quetrex-owned basenames
// are ever rewritten; a hook the user added is theirs.
const SHIPPED_HOOK_TIMEOUTS = {
  'merge-gate.sh': 60,
  'verify-gate.sh': 900,
};
const DEFAULT_HOOK_TIMEOUT_SECONDS = 30;

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
// `command` string. Handles both the legacy `bash ~/.claude/hooks/x.sh` form
// and the project-relative `bash "${CLAUDE_PROJECT_DIR:-.}/.claude/hooks/x.sh"`
// form, whose trailing quote must not defeat the match. Returns null if the
// entry has no recognizable `.sh` command.
function hookBasename(entry) {
  const cmd = entry && typeof entry.command === 'string' ? entry.command : '';
  const m = cmd.match(/([^/\s"']+\.sh)["']?\s*$/);
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

/**
 * Remove every hook entry whose basename `shouldRemove(basename)` accepts, from
 * every event and matcher-group of a `hooks` settings object. A group whose
 * hooks array is emptied by the removal is dropped; an event whose groups are
 * all dropped is dropped. Anything with an unexpected shape is passed through
 * untouched — this only ever deletes entries it positively recognizes.
 *
 * @returns {{ hooks: object, removed: string[] }} removed basenames, in order.
 */
function stripHookEntries(hooksSetting, shouldRemove) {
  const removed = [];
  if (!isPlainObject(hooksSetting)) return { hooks: hooksSetting, removed };
  const out = {};
  for (const event of Object.keys(hooksSetting)) {
    const groups = hooksSetting[event];
    if (!Array.isArray(groups)) { out[event] = groups; continue; }
    const keptGroups = [];
    for (const g of groups) {
      if (!isPlainObject(g) || !Array.isArray(g.hooks)) { keptGroups.push(g); continue; }
      const before = g.hooks.length;
      const hooks = g.hooks.filter((h) => {
        const base = hookBasename(h);
        if (base && shouldRemove(base)) { removed.push(base); return false; }
        return true;
      });
      if (before > 0 && hooks.length === 0) continue; // emptied by removal — drop the group
      keptGroups.push({ ...g, hooks });
    }
    if (groups.length > 0 && keptGroups.length === 0) continue; // emptied — drop the event
    out[event] = keptGroups;
  }
  return { hooks: out, removed };
}

// Every hook basename this package has ever owned. Only these are ever
// rewritten in a user's settings.
function isQuetrexOwnedBasename(base) {
  return QUETREX_HOOK_BASENAMES.has(base)
    || PER_PROJECT_HOOK_BASENAMES.has(base)
    || SUPERSEDED_HOOK_BASENAMES.has(base);
}

/**
 * Repair millisecond-scale timeouts on quetrex-owned hook entries in place.
 * The field is SECONDS; the values this package shipped for a long time (5000,
 * 10000, 3000) mean 83 minutes, ~3 hours, 50 minutes of a stalled session, and
 * hook merging is additive-by-basename so an existing entry is otherwise never
 * revisited. User-authored hooks are left exactly alone.
 *
 * @returns {string[]} basenames whose timeout was rewritten.
 */
function normalizeHookTimeouts(hooksSetting) {
  const fixed = [];
  if (!isPlainObject(hooksSetting)) return fixed;
  for (const groups of Object.values(hooksSetting)) {
    if (!Array.isArray(groups)) continue;
    for (const g of groups) {
      if (!isPlainObject(g) || !Array.isArray(g.hooks)) continue;
      for (const h of g.hooks) {
        const base = hookBasename(h);
        if (!base || !isQuetrexOwnedBasename(base)) continue;
        const t = h.timeout;
        const bad = t !== undefined
          && (typeof t !== 'number' || !Number.isFinite(t) || t <= 0 || t > MAX_HOOK_TIMEOUT_SECONDS);
        if (!bad) continue;
        h.timeout = SHIPPED_HOOK_TIMEOUTS[base] || DEFAULT_HOOK_TIMEOUT_SECONDS;
        fixed.push(base);
      }
    }
  }
  return fixed;
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
 *          Superseded hook basenames unwired from the merged settings are
 *          reported through `log`, and are observable in the written file.
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

  const unwired = [];
  const mergeSettings = (srcPath, destPath, relPosix) => {
    const incoming = JSON.parse(fs.readFileSync(srcPath, 'utf8'));

    // The committed settings.json is BOTH this repo's project config and the
    // global template. The per-project gates (verify-gate / merge-gate) belong
    // to the first role only — strip them before they reach ~/.claude, or every
    // session in every unrelated repo would run a Stop gate that autodetects
    // that repo's verify chain.
    if (isPlainObject(incoming.hooks)) {
      incoming.hooks = stripHookEntries(
        incoming.hooks,
        (base) => PER_PROJECT_HOOK_BASENAMES.has(base),
      ).hooks;
    }

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

    const merged = deepMerge(existing, incoming);

    // Removal half of the reconciliation. Hook merging is additive by
    // basename, so a superseded hook can only ever leave an existing install
    // through an explicit, declared unwire. Timeout repair is the same shape of
    // problem: an existing entry is otherwise never revisited.
    let retimed = [];
    if (isPlainObject(merged.hooks)) {
      const stripped = stripHookEntries(
        merged.hooks,
        (base) => SUPERSEDED_HOOK_BASENAMES.has(base),
      );
      if (stripped.removed.length) merged.hooks = stripped.hooks;
      retimed = normalizeHookTimeouts(merged.hooks);
      if (stripped.removed.length || retimed.length) {
        // Back up the settings we are about to rewrite, so an unwire or a
        // retime is as recoverable as a prune.
        if (fs.existsSync(destPath)) backup(destPath, relPosix);
        for (const base of stripped.removed) unwired.push(base);
      }
    }

    writeFresh(destPath, JSON.stringify(merged, null, 2) + '\n');
    for (const base of retimed) {
      log(`  repaired timeout (the field is SECONDS, not milliseconds): ${base}`);
    }
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
      const rel = path.join(relDir, entry.name);
      const relPosix = toPosix(rel);
      const srcPath = path.join(srcRoot, rel);
      const destPath = path.join(destRoot, rel);

      if (PROTECTED.has(entry.name)) {
        // User-owned. Seed it only if it is absent; never overwrite, and never
        // back it up-and-replace — the user's copy is the authority.
        if (!SEED_IF_ABSENT.has(entry.name)) continue;
        if (fs.existsSync(destPath)) {
          log(`  kept (user-owned, not overwritten): ${relPosix}`);
        } else {
          writeFresh(destPath, fs.readFileSync(srcPath));
          log(`  seeded: ${relPosix}`);
        }
        copied.push(relPosix); // owned by this version; PROTECTED blocks pruning
        continue;
      }

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

  // --- Seed the global CLAUDE.md from its template, if still absent ---------
  // The walk cannot do this: the package deliberately does not ship a file
  // named `CLAUDE.md`, so SEED_IF_ABSENT never sees one. Without this block a
  // FRESH install ends up with no ~/.claude/CLAUDE.md at all — no doctrine
  // import, no #LESSONS anchor. It is written once and then behaves exactly
  // like any PROTECTED file: never overwritten, never pruned.
  const globalClaudeMd = path.join(destRoot, 'CLAUDE.md');
  if (!fs.existsSync(globalClaudeMd)) {
    const tplPath = path.join(srcRoot, GLOBAL_CLAUDE_MD_TEMPLATE);
    if (fs.existsSync(tplPath)) {
      writeFresh(globalClaudeMd, fs.readFileSync(tplPath));
      copied.push('CLAUDE.md');
      log('  seeded: CLAUDE.md (from templates/global-CLAUDE.md)');
    }
  } else if (!copied.includes('CLAUDE.md')) {
    copied.push('CLAUDE.md');
    log('  kept (user-owned, not overwritten): CLAUDE.md');
  }

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
  let prevFiles = [];
  if (fs.existsSync(manifestPath)) {
    try { prevFiles = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).files || []; } catch {}
    for (const rel of prevFiles) removeManagedFile(rel);
  }

  // Superseded hook scripts, explicitly. The manifest diff above already
  // removes them once the package stops shipping them; this pass makes the
  // intent declared rather than incidental, and is still gated on the prior
  // manifest so the installer never deletes a file it cannot prove it wrote.
  const prevSet = new Set(prevFiles);
  for (const base of SUPERSEDED_HOOK_SCRIPTS) {
    const relPosix = `hooks/${base}`;
    if (prevSet.has(relPosix)) removeManagedFile(relPosix);
  }

  // --- Record the manifest for next time -----------------------------------
  fs.writeFileSync(
    manifestPath,
    JSON.stringify({ version: 1, files: [...copiedSet].sort() }, null, 2) + '\n',
  );

  for (const rel of copied) log(`  copied: ${rel}`);
  for (const rel of pruned) log(`  pruned: ${rel}`);
  for (const base of unwired) log(`  unwired (superseded): ${base}`);
  if (pruned.length) log(`  (backups saved under ${BACKUP_DIR}/${stamp})`);

  return { copied: [...copiedSet], pruned };
}

/**
 * Collect every wired hook basename from a settings object, grouped by event.
 * @returns {Map<string, Array<{ basename: string, timeout: * }>>}
 */
function wiredHooksByEvent(settings) {
  const byEvent = new Map();
  const hooks = settings && settings.hooks;
  if (!isPlainObject(hooks)) return byEvent;
  for (const event of Object.keys(hooks)) {
    const groups = hooks[event];
    if (!Array.isArray(groups)) continue;
    const found = [];
    for (const g of groups) {
      if (!isPlainObject(g) || !Array.isArray(g.hooks)) continue;
      for (const h of g.hooks) {
        const basename = hookBasename(h);
        if (basename) found.push({ basename, timeout: h && h.timeout });
      }
    }
    byEvent.set(event, found);
  }
  return byEvent;
}

/**
 * Post-install assertion: the enforcement channel must be REACHABLE, not just
 * copied bytes.
 *
 * Checks, in order:
 *  1. every global hook script landed in the dest hooks dir and is executable;
 *  2. the per-project gate scripts are present (q-init copies them into each
 *     project);
 *  3. the merged settings.json re-parses as valid JSON;
 *  4. every global hook is actually WIRED under its expected event — the check
 *     that "copied bytes" never made. A hook no settings file references is
 *     not enforcement, and its absence is silent: a missing hook command exits
 *     127, and anything other than 0 or 2 is non-blocking;
 *  5. the deliberate opposite invariant for the two per-project gates: present
 *     on disk, NOT wired globally;
 *  6. no superseded hook is still wired;
 *  7. every wired timeout is a sane number of SECONDS (<= 900). verify-gate
 *     derives its fail-closed budget from this value.
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
  let settings = null;
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    problems.push(`settings.json does not re-parse as valid JSON: ${e.message}`);
  }

  if (settings) {
    const byEvent = wiredHooksByEvent(settings);
    const allWired = [];
    for (const entries of byEvent.values()) allWired.push(...entries);
    const wiredNames = new Set(allWired.map((e) => e.basename));

    // 4. every expected hook reachable from its event
    for (const [event, expected] of Object.entries(EXPECTED_GLOBAL_WIRING)) {
      const present = new Set((byEvent.get(event) || []).map((e) => e.basename));
      for (const name of expected) {
        if (!present.has(name)) {
          problems.push(
            `hooks/${name} is installed but NOT wired under settings.json hooks.${event} — ` +
            'an unreferenced hook never runs and fails silently',
          );
        }
      }
    }

    // 5. per-project gates: present on disk, deliberately unwired globally
    for (const name of PER_PROJECT_HOOK_SCRIPTS) {
      if (wiredNames.has(name)) {
        problems.push(
          `hooks/${name} is wired in the GLOBAL settings.json — it must not be. ` +
          'It is a per-project gate: remove it from ~/.claude/settings.json and let ' +
          '/q-init wire it into each repo\'s own committed .claude/settings.json.',
        );
      }
    }

    // 6. superseded hooks must be gone
    for (const name of SUPERSEDED_HOOK_SCRIPTS) {
      if (wiredNames.has(name)) {
        problems.push(`superseded hook still wired in settings.json: ${name}`);
      }
    }

    // 7. timeouts are seconds, and sane. Only quetrex-owned hooks are a
    //    failure — the installer repairs those, so a bad one here means the
    //    repair did not work. A user's own hook only earns a warning.
    for (const { basename, timeout } of allWired) {
      if (timeout === undefined) continue;
      const bad = typeof timeout !== 'number' || !Number.isFinite(timeout) || timeout <= 0;
      const tooLong = !bad && timeout > MAX_HOOK_TIMEOUT_SECONDS;
      if (!bad && !tooLong) continue;
      const detail = bad
        ? `has a non-numeric timeout: ${JSON.stringify(timeout)}`
        : `timeout is ${timeout}s (> ${MAX_HOOK_TIMEOUT_SECONDS}s) — the field is SECONDS, not ` +
          `milliseconds; a hung hook would stall the session for ${Math.round(timeout / 60)} minutes`;
      if (isQuetrexOwnedBasename(basename)) {
        problems.push(`hook ${basename} ${detail}`);
      } else {
        log(`quetrex/base: WARNING — your own hook ${basename} ${detail}`);
      }
    }
  }

  if (problems.length) {
    log('quetrex/base: INSTALL FAILED — the enforcement channel is broken:');
    for (const p of problems) log(`  - ${p}`);
    log('  Fix the issue(s) above and re-run the install; a partially-wired enforcement channel is not shipped.');
    return false;
  }
  return true;
}

/**
 * Visible notice (never fatal): a repo that has been bound to a Quetrex
 * project (.quetrex/) but has no repo-local gate wiring is unprotected in
 * exactly the place it matters — a cloud routine only ever sees what is
 * committed, never the operator's ~/.claude.
 *
 * @returns {boolean} true iff a notice was emitted.
 */
function noticeProjectGateWiring(projectRoot, log = console.log) {
  if (!projectRoot || !fs.existsSync(path.join(projectRoot, '.quetrex'))) return false;

  const settingsPath = path.join(projectRoot, '.claude', 'settings.json');
  let wired = new Set();
  try {
    const settings = JSON.parse(fs.readFileSync(settingsPath, 'utf8'));
    for (const entries of wiredHooksByEvent(settings).values()) {
      for (const e of entries) wired.add(e.basename);
    }
  } catch {
    wired = new Set();
  }

  const missing = PER_PROJECT_HOOK_SCRIPTS.filter((n) => !wired.has(n));
  if (missing.length === 0) return false;

  log('');
  log(`quetrex/base: NOTICE — ${projectRoot} is bound to a Quetrex project but its`);
  log(`  committed .claude/settings.json does not wire: ${missing.join(', ')}`);
  log('  Nothing gates this repo\'s builds, locally or in a cloud routine. Run /q-init');
  log('  (or .claude/lib/quetrex-install-project-gates.sh <repo-root>) to deploy the gates.');
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
  noticeProjectGateWiring(process.cwd());
  console.log('quetrex/base: done. Restart Claude Code to load new agents and skills.');
}

module.exports = {
  install,
  ensureSecretsEnv,
  assertHooksInstalled,
  noticeProjectGateWiring,
  wiredHooksByEvent,
  stripHookEntries,
  normalizeHookTimeouts,
  hookBasename,
  deepMerge,
  unionArrays,
  isPrimitiveArray,
  GLOBAL_HOOK_SCRIPTS,
  PER_PROJECT_HOOK_SCRIPTS,
  SUPERSEDED_HOOK_SCRIPTS,
  EXPECTED_GLOBAL_WIRING,
  MAX_HOOK_TIMEOUT_SECONDS,
};
