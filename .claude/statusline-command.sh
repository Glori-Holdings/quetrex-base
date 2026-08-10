#!/bin/bash

# Claude Code Status Bar — Minimal, color-coded segments
# Designed for warm dark theme with true-color ANSI
# Target render: <50ms (no network calls, single jq, cached git)

# --- 1. Read JSON from stdin, extract ALL fields in one jq call ---
input=$(cat)
eval "$(echo "$input" | jq -r '
  "cwd=" + (.workspace.current_dir // "" | @sh) + "\n" +
  "project_dir=" + (.workspace.project_dir // "" | @sh) + "\n" +
  "model=" + (.model.display_name // "" | @sh) + "\n" +
  "version=" + (.version // "" | @sh) + "\n" +
  "used_pct=" + (.context_window.used_percentage // 0 | tostring | @sh)
')"

# Default used_pct to 0 if empty or non-numeric
[[ "$used_pct" =~ ^[0-9]+$ ]] || used_pct=0

# --- 2. Abbreviate path ---
home_dir="$HOME"
if [ -n "$project_dir" ] && [ "$project_dir" != "null" ] && [ "$project_dir" != "$home_dir" ]; then
  proj_base=$(basename "$project_dir")
  if [ "$cwd" = "$project_dir" ] || [ -z "$cwd" ] || [ "$cwd" = "null" ]; then
    display_path="~/${proj_base}"
  else
    rel_path="${cwd#"$project_dir"}"
    display_path="~/${proj_base}${rel_path}"
  fi
elif [ -n "$cwd" ] && [ "$cwd" != "null" ] && [ "$cwd" != "$home_dir" ]; then
  display_path="${cwd/#$home_dir/\~}"
else
  display_path="~"
fi

# --- 3. Get git branch (cached, 5s TTL) ---
git_cache="/tmp/claude-statusline-git-cache"
git_dir="${project_dir:-$cwd}"
branch=""

if [ -n "$git_dir" ] && [ "$git_dir" != "null" ]; then
  cache_valid=0
  if [ -f "$git_cache" ]; then
    if stat -c %Y "$git_cache" >/dev/null 2>&1; then
      cache_mtime=$(stat -c %Y "$git_cache")
    else
      cache_mtime=$(stat -f %m "$git_cache")
    fi
    cache_age=$(( $(date +%s) - cache_mtime ))
    cached_dir=$(head -1 "$git_cache" 2>/dev/null)
    if [ "$cache_age" -le 5 ] && [ "$cached_dir" = "$git_dir" ]; then
      cache_valid=1
      branch=$(tail -1 "$git_cache" 2>/dev/null)
    fi
  fi

  if [ "$cache_valid" -eq 0 ]; then
    branch=$(git -C "$git_dir" --no-optional-locks branch --show-current 2>/dev/null || echo "")
    printf '%s\n%s\n' "$git_dir" "$branch" > "$git_cache" 2>/dev/null
  fi
fi

# --- 4. Determine context threshold color + indicator ---
if [ "$used_pct" -ge 90 ]; then
  bar_r=239; bar_g=83; bar_b=80
  indicator=" new session recommended"
elif [ "$used_pct" -ge 75 ]; then
  bar_r=230; bar_g=74; bar_b=25
  indicator=" consider new session"
elif [ "$used_pct" -ge 60 ]; then
  bar_r=217; bar_g=119; bar_b=87
  indicator=" compacting"
elif [ "$used_pct" -ge 50 ]; then
  bar_r=255; bar_g=183; bar_b=77
  indicator=" compact soon"
else
  bar_r=129; bar_g=199; bar_b=132
  indicator=""
fi

# --- 4.5. Quetrex engine version ---
# Quetrex pins no version anywhere: a pinned enabledPlugins entry makes the
# plugin count as DISABLED for dependency resolution and the whole /quetrex:*
# command layer stops loading. Config therefore carries no version, and this
# status bar is the ONLY place the running engine is ever named — read at
# runtime, never hardcoded and never baked in from plugin.json.
#
# quetrex-version exits non-zero when no engine is installed. In that case the
# Quetrex half is omitted ENTIRELY: a status script must never surface a
# "command not found", an interpreter error, or a half-rendered placeholder,
# because the operator reads that as a failed build when nothing failed.
#
# The call is BOUNDED. quetrex-version is a third-party process from here: a
# different release train, possibly a wrapper, possibly wedged on a stale lock
# or a dead mount. Unbounded, a hung engine freezes the whole status bar for as
# long as it hangs (a 3s stub measured a 3.2s render against this file's <50ms
# target). `timeout`/`gtimeout` are coreutils and are NOT present on a stock
# macOS, so the bound is built from `read -t` on a pipe instead — no extra
# dependency, and no measurable cost on the fast path.
#
# The subshell prints the EXIT STATUS first and the output second, because both
# matter and a plain pipe would throw the status away: an engine that prints a
# usable version and then exits non-zero is reporting that the number is not
# trustworthy, so that case must fail closed exactly like a crash. Reading a
# single line also gives the "first line only" trim for free — stray banner
# output can never break line 1.
#
# bash 3.2 (stock macOS) rejects a fractional `read -t`, so the bound is one
# whole second there and a few hundred ms on bash 4+. Either way it is bounded.
if [ "${BASH_VERSINFO[0]:-3}" -ge 4 ]; then _qx_timeout=0.4; else _qx_timeout=1; fi
quetrex_v=""
_qv=""
_qrc=1
exec 3< <( _o="$(quetrex-version --plain 2>/dev/null)"; _r=$?; printf '%s\n%s\n' "$_r" "$_o" )
if IFS= read -t "$_qx_timeout" -r _qrc <&3; then
  IFS= read -t "$_qx_timeout" -r _qv <&3 || _qv=""
else
  _qrc=1   # timed out — treat a wedged engine exactly like a missing one
fi
exec 3<&-

if [ "$_qrc" = "0" ]; then
  # Anything that is not a bare 1-, 2- or 3-component numeric version is
  # treated as no answer at all rather than rendered verbatim.
  if [[ "$_qv" =~ ^[0-9]+(\.[0-9]+)?(\.[0-9]+)?$ ]]; then
    # ALWAYS three components. A bare "2.4" reads as a truncated version,
    # which is exactly the confusion this segment exists to remove.
    case "$_qv" in
      *.*.*) quetrex_v="$_qv"       ;;
      *.*)   quetrex_v="${_qv}.0"   ;;
      *)     quetrex_v="${_qv}.0.0" ;;
    esac
  fi
fi

# --- 5. Terminal width ---
term_width=${COLUMNS:-$(tput cols 2>/dev/null || echo 80)}

# --- 6. Print Line 1: icon+path  icon+branch  icon+model  right-aligned-version ---
c_path="\033[38;2;217;119;87m"
c_branch="\033[38;2;77;182;172m"
c_model="\033[38;2;120;113;108m"
c_version="\033[38;2;68;64;60m"
c_quetrex="\033[38;2;212;175;55m"
c_quetrex_v="\033[38;2;168;162;158m"
c_reset="\033[0m"

icon_dir="📂"
icon_model="🤖"

seg_path="${icon_dir} ${display_path}"
seg_branch=""
[ -n "$branch" ] && seg_branch="${branch}"
seg_model="${icon_model} ${model}"
seg_version=""
[ -n "$version" ] && [ "$version" != "null" ] && seg_version="v${version}"

emoji_extra=1
plain_left="${seg_path}"
[ -n "$seg_branch" ] && plain_left="${plain_left}   ${seg_branch}"
plain_left="${plain_left}   ${seg_model}"
emoji_extra=$((emoji_extra + 1))
plain_len=$(( ${#plain_left} + emoji_extra ))

colored_left="${c_reset}${icon_dir} ${c_path}${display_path}${c_reset}"
[ -n "$seg_branch" ] && colored_left="${colored_left}   ${c_branch}${branch}${c_reset}"
colored_left="${colored_left}   ${c_reset}${icon_model} ${c_model}${model}${c_reset}"

# Right-aligned group: the gold word "Quetrex", its version one shade lighter
# and subordinate, then Claude Code's OWN version last in the existing dim
# tone, two spaces after the Quetrex group. Either half may be absent; the gap
# is measured from plain_right, which carries no escapes, because counting
# ANSI would shove the whole group ~45 columns left.
#
# seg_version is STDIN-SUPPLIED (the .version field of the status JSON) and so
# is kept out of every %b argument and passed on its own %s, exactly as it was
# before the Quetrex group existed. %b interprets backslash escapes, and a
# `\c` in a %b argument terminates printf's output outright — it would swallow
# line 1's newline and weld the context bar onto line 1, breaking the two-line
# invariant this file guarantees. right_prefix therefore carries only our OWN
# colour literals plus quetrex_v, which the numeric guard above has already
# proven contains nothing but digits and dots.
plain_right=""
right_prefix=""
if [ -n "$quetrex_v" ]; then
  plain_right="Quetrex ${quetrex_v}"
  right_prefix="${c_quetrex}Quetrex ${c_quetrex_v}${quetrex_v}${c_reset}"
fi
if [ -n "$seg_version" ]; then
  if [ -n "$plain_right" ]; then
    plain_right="${plain_right}  ${seg_version}"
    right_prefix="${right_prefix}  ${c_version}"
  else
    plain_right="${seg_version}"
    right_prefix="${c_version}"
  fi
fi

if [ -n "$plain_right" ]; then
  gap=$(( term_width - plain_len - ${#plain_right} ))
  [ "$gap" -lt 1 ] && gap=1
  padding=$(printf '%*s' "$gap" '')
  printf "%b%s%b%s%b\n" "$colored_left" "$padding" "$right_prefix" "$seg_version" "$c_reset"
else
  printf "%b\n" "$colored_left"
fi

# --- 7. Print Line 2: colored bar + percentage + compact indicator ---
pct_label=" ${used_pct}%"
indicator_len=0
[ -n "$indicator" ] && indicator_len=${#indicator}
label_len=$(( ${#pct_label} + indicator_len ))

bar_width=$(( term_width - label_len ))
[ "$bar_width" -lt 10 ] && bar_width=10

filled=$(( used_pct * bar_width / 100 ))
empty=$(( bar_width - filled ))

bar_filled=""
bar_empty=""
for ((i=0; i<filled; i++)); do bar_filled+="▰"; done
for ((i=0; i<empty; i++)); do bar_empty+="▱"; done

c_empty="\033[38;2;68;64;60m"
c_bar="\033[38;2;${bar_r};${bar_g};${bar_b}m"

printf "%b%s%b%s%b%s%b%s%b\n" \
  "$c_bar" "$bar_filled" \
  "$c_empty" "$bar_empty" \
  "$c_bar" "$pct_label" \
  "$c_bar" "$indicator" \
  "$c_reset"
