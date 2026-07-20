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

# carry over anything the catalog doesn't ship — local-only wallpapers (moon's
# gitignored 176MB wallpaper2.mp4), extracted stills, hand edits. incoming sits
# on the same fs as the theme dir, so these are renames, not copies.
old="$dest_root/$name"
if [ -d "$old" ]; then
  while IFS= read -r -d '' f; do
    rel="${f#"$old"/}"
    [ -e "$incoming/$rel" ] && continue
    # a still whose video just got redownloaded is stale — let ffmpeg regrow it
    case "$rel" in *.still.png) [ -e "$incoming/${rel%.still.png}.mp4" ] && continue ;; esac
    mkdir -p "$(dirname "$incoming/$rel")"
    mv "$f" "$incoming/$rel" 2>/dev/null || cp -a "$f" "$incoming/$rel"
  done < <(find "$old" \( -type f -o -type l \) -print0)
fi
rm -rf "$old"
mv "$incoming" "$old"

# stills for any video that arrived without one
if command -v ffmpeg >/dev/null; then
  for v in "$dest_root/$name"/wallpaper*.mp4; do
    [ -e "$v" ] || continue
    s="${v%.mp4}.still.png"
    [ -f "$s" ] || ffmpeg -y -v error -i "$v" -frames:v 1 "$s" </dev/null || true
  done
fi
echo "DONE $dest_root/$name"
