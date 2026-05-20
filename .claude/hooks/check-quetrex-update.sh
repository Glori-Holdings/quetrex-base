#!/bin/bash
# Daily background check for Glori Builder updates.
# Runs on session Stop. Fast exit if checked within 24 hours.

TIMESTAMP_FILE="$HOME/.claude/.quetrex-last-check"
FLAG_FILE="$HOME/.claude/.quetrex-update-available"

# Fast path: skip if checked within the last 24 hours
if [ -f "$TIMESTAMP_FILE" ]; then
  LAST=$(cat "$TIMESTAMP_FILE" 2>/dev/null)
  NOW=$(date +%s)
  if [ -n "$LAST" ] && [ $(( NOW - LAST )) -lt 86400 ]; then
    exit 0
  fi
fi

# Update timestamp immediately so concurrent sessions don't double-check
date +%s > "$TIMESTAMP_FILE"

# Run the npm check in the background so it doesn't delay session exit
(
  INSTALLED=$(npm list -g glori-builder --depth=0 --json 2>/dev/null \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('dependencies',{}).get('glori-builder',{}).get('version',''))" 2>/dev/null)

  LATEST=$(npm show glori-builder version 2>/dev/null)

  if [ -n "$INSTALLED" ] && [ -n "$LATEST" ] && [ "$INSTALLED" != "$LATEST" ]; then
    echo "$LATEST" > "$FLAG_FILE"
  else
    rm -f "$FLAG_FILE"
  fi
) &

exit 0
