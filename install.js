#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const os = require('os');

const src = path.join(__dirname, '.claude');
const dest = path.join(os.homedir(), '.claude');

// Files that are never copied or overwritten — user-owned
const PROTECTED = new Set(['secrets.env']);

function copyDir(srcDir, destDir) {
  if (!fs.existsSync(destDir)) {
    fs.mkdirSync(destDir, { recursive: true });
  }
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const srcPath = path.join(srcDir, entry.name);
    const destPath = path.join(destDir, entry.name);
    if (entry.isDirectory()) {
      copyDir(srcPath, destPath);
    } else {
      copyFile(srcPath, destPath);
    }
  }
}

function copyFile(srcPath, destPath) {
  const name = path.basename(srcPath);

  if (PROTECTED.has(name)) {
    return; // Never touch user secrets
  }

  if (name === 'settings.json') {
    mergeSettings(srcPath, destPath);
    return;
  }

  fs.copyFileSync(srcPath, destPath);
  console.log(`  copied: ${destPath.replace(os.homedir(), '~')}`);
}

function mergeSettings(srcPath, destPath) {
  const incoming = JSON.parse(fs.readFileSync(srcPath, 'utf8'));
  let existing = {};
  if (fs.existsSync(destPath)) {
    try { existing = JSON.parse(fs.readFileSync(destPath, 'utf8')); } catch {}
  }
  const merged = deepMerge(existing, incoming);
  fs.writeFileSync(destPath, JSON.stringify(merged, null, 2) + '\n');
  console.log(`  merged: ${destPath.replace(os.homedir(), '~')}`);
}

function deepMerge(target, source) {
  const result = { ...target };
  for (const key of Object.keys(source)) {
    if (key in result) {
      if (isPlainObject(result[key]) && isPlainObject(source[key])) {
        result[key] = deepMerge(result[key], source[key]);
      }
      // existing scalar value wins — never overwrite
    } else {
      result[key] = source[key];
    }
  }
  return result;
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function ensureSecretsEnv() {
  const secretsPath = path.join(dest, 'secrets.env');
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
    try {
      fs.chmodSync(secretsPath, 0o600);
    } catch {}
    console.log('  created: ~/.claude/secrets.env (add your API keys, then source it from your shell profile)');
  }
}

if (!fs.existsSync(src)) {
  console.log('quetrex/base: no .claude directory found, skipping install');
  process.exit(0);
}

console.log('quetrex/base: installing Claude Code configuration...');
copyDir(src, dest);
ensureSecretsEnv();
console.log('quetrex/base: done. Restart Claude Code to load new agents and skills.');
