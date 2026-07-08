#!/usr/bin/env bash
# theme-install.sh — download one marketplace theme from raw.githubusercontent
# into ~/.config/themes/<name>/. the repo-relative file paths (from the
# catalog's index.json, so no GitHub API and no rate limits) are the trailing
# args, after the four fixed ones.
#
# args:  <repo> <branch> <name> <commit> <path>...
# stdout, one line per event, for the Super+/ Marketplace SplitParser:
#   PROG <done> <total> <relpath>
#   DONE <targetdir>
#   ERR  <message>
#
# THEME_DEST overrides the install root (used by tests to hit a scratch dir).
set -uo pipefail

repo="${1:?repo}"; branch="${2:?branch}"; name="${3:?name}"; commit="${4:?commit}"
shift 4
files=("$@")
base="https://raw.githubusercontent.com/$repo/$branch"
dest_root="${THEME_DEST:-$HOME/.config/themes}"
UA="hypr-marketplace (https://github.com/AidanMercer/world80)"

# never let a crafted catalog name escape the themes dir
case "$name" in */*|.*|"") echo "ERR bad theme name"; exit 1 ;; esac

total="${#files[@]}"
[ "$total" -gt 0 ] || { echo "ERR empty file list"; exit 1; }

work="$HOME/.cache/hypr-marketplace/dl/$name.$$"
rm -rf "$work"; mkdir -p "$work"
trap 'rm -rf "$work"' EXIT

n=0
for path in "${files[@]}"; do
  case "$path" in "$name"/*) ;; *) echo "ERR path outside theme: $path"; exit 1 ;; esac
  rel="${path#"$name"/}"
  out="$work/$rel"
  mkdir -p "$(dirname "$out")"
  if ! curl -fsSL --retry 2 -m 90 -A "$UA" -o "$out" "$base/$path"; then
    echo "ERR download failed: $path"; exit 1
  fi
  n=$((n + 1))
  echo "PROG $n $total $rel"
done

# swap into place via a rename (same filesystem under $HOME), so a failed
# download never leaves a half-written theme the shell would try to load
mkdir -p "$dest_root"
incoming="$dest_root/.$name.incoming.$$"
rm -rf "$incoming"
mv "$work" "$incoming"
printf '%s\n' "$commit" > "$incoming/.mkt-version"
rm -rf "$dest_root/$name"
mv "$incoming" "$dest_root/$name"
echo "DONE $dest_root/$name"
