#!/usr/bin/env bash
# test/lib/check-json.sh — JSON.parse every config file the plugin ships.
# Invoked by `npm run check:json`.
#
# Lives in test/lib/, NOT test/, for the same reason as check-sh.sh: it is a
# linter, not a test/run-all.sh unit.
#
# WHY THIS FILE EXISTS (not the original inline `node -e` one-liner, whose
# `for (const f of files) { JSON.parse(...) }` threw and aborted the process
# on the FIRST malformed file): an uncaught throw stops the loop, so a
# second bad file was invisible until the first was fixed — the same
# "fix one, discover more were hidden" defect documented in
# test/run-all.sh's header, just one level down inside a single check
# script instead of across files.
#
# Usage: bash test/lib/check-json.sh [root]
#   root defaults to the repo root, so plain `npm run check:json` checks the
#   real files. A test can instead point it at a fixture directory with its
#   own copies of the same 8 relative paths to prove the collect-everything
#   behavior without ever touching real repo files — see
#   test/check-scripts.test.sh.
set -u
ROOT="${1:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"}"
# See check-sh.sh's identical guard: an unguarded cd on a bad root would
# silently validate the CURRENT directory's files instead of the fixture's.
cd "$ROOT" || { echo "NOT OK - check:json: cannot cd to root: $ROOT" >&2; exit 1; }

node -e '
const fs = require("fs");
const files = [
  "package.json",
  ".claude/settings.json",
  ".claude/templates/verify.json",
  ".quetrex/verify.json",
  ".claude-plugin/plugin.json",
  "hooks/hooks.json",
  "plugins/quetrex-factory/.claude-plugin/plugin.json",
  "plugins/quetrex-factory/hooks/hooks.json",
  "plugins/quetrex-setup/.claude-plugin/plugin.json",
  "plugins/quetrex-setup/hooks/hooks.json",
];
let bad = 0;
for (const f of files) {
  try {
    JSON.parse(fs.readFileSync(f, "utf8"));
  } catch (e) {
    bad++;
    console.log(`NOT OK - ${f}: ${e.message}`);
  }
}
if (bad > 0) {
  console.log(`\ncheck:json: FAILED — ${bad} of ${files.length} file(s) do not parse (see NOT OK lines above)`);
  process.exit(1);
}
console.log(`ok - check:json: ${files.length} JSON files parse`);
'
