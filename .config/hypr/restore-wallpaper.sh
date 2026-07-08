#!/usr/bin/env sh
# awww starts with no wallpaper each session, so restore one on login:
#   1. the last theme the switcher applied (persisted), else
#   2. any installed theme's still (so a fresh install still shows something),
#      extracting a frame from an mp4 theme if its still isn't cached yet.
# the theme switcher writes the "last applied" path to the cache file below.
set -u
last="${XDG_CACHE_HOME:-$HOME/.cache}/world80/last-wallpaper"
pick=""

if [ -f "$last" ]; then
  p=$(cat "$last" 2>/dev/null)
  [ -n "$p" ] && [ -f "$p" ] && pick="$p"
fi

if [ -z "$pick" ]; then
  pick=$(ls "$HOME"/.config/themes/*/wallpaper*.still.png 2>/dev/null | sort | head -1)
fi
if [ -z "$pick" ]; then
  pick=$(ls "$HOME"/.config/themes/*/wallpaper*.jpg "$HOME"/.config/themes/*/wallpaper*.png 2>/dev/null | sort | head -1)
fi
if [ -z "$pick" ]; then
  mp4=$(ls "$HOME"/.config/themes/*/wallpaper*.mp4 2>/dev/null | sort | head -1)
  if [ -n "$mp4" ] && command -v ffmpeg >/dev/null 2>&1; then
    s="${mp4%.mp4}.still.png"
    [ -f "$s" ] || ffmpeg -y -v error -i "$mp4" -frames:v 1 "$s" </dev/null 2>/dev/null
    [ -f "$s" ] && pick="$s"
  fi
fi

[ -n "$pick" ] && exec awww img --transition-type fade --transition-duration 0.7 "$pick"
