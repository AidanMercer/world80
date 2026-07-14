#!/usr/bin/env bash
# ext-install.sh — install/update/remove the world80 app suite (the Extensions
# tab in Super+/). stdout is line-oriented for the shell's SplitParser, same
# idea as theme-install.sh:
#   APP <name> <installed 0|1> <behind> [missing-pkg...]   (status/scan)
#   PROG <n> <total> <step>
#   DEPS <name> <pkg...>
#   DONE <name> | ALLDONE <count> | ERR <message>
#
# actions:
#   scan               installed check only, no network (fast, for the cheat sheet)
#   status             scan + git fetch for behind-counts + missing deps
#   install <app>      clone + set up
#   update <app>       ff-only pull + set up (setup is idempotent — this is how
#                      desktop-entry/portal/dep fixes reach existing installs)
#   update-all         update every installed app
#   remove <app>       refuses if the clone has local changes or unpushed commits
#   setup <app>        just re-run setup
#   deps <app>         interactive dep install (run it in a terminal)
#
# EXT_HOME overrides $HOME so tests can hit a scratch dir.
set -uo pipefail

H="${EXT_HOME:-$HOME}"
APPS_DIR="$H/.local/share/applications"

# name|dest|github repo|pacman deps|aur deps
table() { cat <<EOF
mica|$H/dev/mica|AidanMercer/mica|pyside6 ffmpeg ripgrep poppler|xdg-desktop-portal-termfilechooser
vellum|$H/dev/vellum|AidanMercer/vellum|pyside6 python-markdown python-pygments|
pulse|$H/dev/pulse|AidanMercer/pulse|pyside6|
beryl|$H/dev/beryl|AidanMercer/beryl|pyside6 qt6-webengine python-adblock|
frostify|$H/frostify|AidanMercer/frostify|pyside6|python-spotipy
EOF
}
field() { table | grep "^$1|" | cut -d'|' -f"$2"; }

missing_deps() { # every table dep pacman doesn't have, space-separated
  # shellcheck disable=SC2046
  pacman -T $(field "$1" 4) $(field "$1" 5) 2>/dev/null | tr '\n' ' ' | sed 's/ $//'
}

write_desktop() { # repo's .desktop with Exec pointed at the real clone; frostify ships none
  local app="$1" dest; dest="$(field "$app" 2)"
  mkdir -p "$APPS_DIR"
  if [ -f "$dest/$app.desktop" ]; then
    sed -E "s#^Exec=[^ ]*/$app\.sh#Exec=$dest/$app.sh#" "$dest/$app.desktop" > "$APPS_DIR/$app.desktop"
  else
    cat > "$APPS_DIR/$app.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$app
Comment=Frosted Spotify client that follows the rice theme
Exec=$dest/$app.sh
Icon=multimedia-player
Terminal=false
Categories=AudioVideo;Audio;Player;
StartupWMClass=$app
EOF
  fi
  update-desktop-database "$APPS_DIR" 2>/dev/null || true
}

setup_one() { # everything past the clone/pull; idempotent, needs no root
  local app="$1" dest; dest="$(field "$app" 2)"
  chmod +x "$dest/$app.sh" 2>/dev/null || true
  write_desktop "$app"
  if [ "$app" = mica ] && [ -f "$dest/portal/setup.sh" ]; then
    # wires mica in as the system file picker; exits 1 cleanly if the
    # termfilechooser backend isn't installed — the DEPS line covers that
    bash "$dest/portal/setup.sh" >/dev/null 2>&1 || true
  fi
  local miss; miss="$(missing_deps "$app")"
  [ -n "$miss" ] && echo "DEPS $app $miss"
  return 0
}

app_status() { # $1=app $2=with-network
  local app="$1" dest up n miss; dest="$(field "$app" 2)"
  if [ ! -d "$dest/.git" ]; then echo "APP $app 0 0"; return; fi
  n=0
  if [ "$2" = 1 ]; then
    timeout 10 git -C "$dest" fetch --quiet 2>/dev/null
    up="$(git -C "$dest" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")"
    [ -n "$up" ] && n="$(git -C "$dest" rev-list --count "HEAD..$up" 2>/dev/null || echo 0)"
  fi
  miss="$(missing_deps "$app")"
  echo "APP $app 1 $n${miss:+ $miss}"
}

install_one() {
  local app="$1" dest url; dest="$(field "$app" 2)"
  [ -n "$dest" ] || { echo "ERR unknown extension: $app"; exit 1; }
  url="https://github.com/$(field "$app" 3)"
  echo "PROG 1 3 download"
  if [ ! -d "$dest/.git" ]; then
    mkdir -p "$(dirname "$dest")"
    git clone --depth 1 "$url" "$dest" >/dev/null 2>&1 \
      || { echo "ERR $app: clone failed — check your connection"; exit 1; }
  fi
  echo "PROG 2 3 set up"
  setup_one "$app"
  echo "PROG 3 3 done"
  echo "DONE $app"
}

update_one() {
  local app="$1" dest; dest="$(field "$app" 2)"
  [ -d "$dest/.git" ] || { echo "ERR $app isn't installed"; return 1; }
  echo "PROG 1 3 pull"
  if [ -z "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
    # ff-only so a diverged clone fails safe instead of merging
    git -C "$dest" pull --ff-only --quiet 2>/dev/null \
      || { echo "ERR $app: pull failed (diverged clone?)"; return 1; }
  fi  # dirty tree: leave the work alone, but still refresh the setup below
  echo "PROG 2 3 set up"
  setup_one "$app"
  echo "PROG 3 3 done"
  echo "DONE $app"
}

remove_one() {
  local app="$1" dest ahead; dest="$(field "$app" 2)"
  case "$app" in *[!a-z]*|"") echo "ERR bad extension name"; exit 1 ;; esac
  [ -n "$dest" ] || { echo "ERR unknown extension: $app"; exit 1; }
  if [ -d "$dest/.git" ]; then
    # never eat work: a dirty tree or unpushed commits block the remove
    if [ -n "$(git -C "$dest" status --porcelain 2>/dev/null)" ]; then
      echo "ERR $app has local changes — remove ~/${dest#"$H"/} by hand"; return 1
    fi
    ahead="$(git -C "$dest" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ]; then
      echo "ERR $app has unpushed commits — remove ~/${dest#"$H"/} by hand"; return 1
    fi
  fi
  if [ "$app" = mica ] && [ -f "$dest/portal/setup.sh" ]; then
    bash "$dest/portal/setup.sh" --revert >/dev/null 2>&1 || true
  fi
  rm -rf "$dest"
  rm -f "$APPS_DIR/$app.desktop"
  echo "DONE $app"
}

deps_interactive() { # run in a terminal — pacman wants a tty for sudo
  local app="$1" miss repo_miss="" aur_miss="" p
  miss="$(missing_deps "$app")"
  [ -z "$miss" ] && { echo "nothing missing for $app"; return 0; }
  for p in $miss; do
    if grep -qw "$p" <<<"$(field "$app" 5)"; then aur_miss="$aur_miss $p"; else repo_miss="$repo_miss $p"; fi
  done
  # shellcheck disable=SC2086
  [ -n "$repo_miss" ] && sudo pacman -S --needed $repo_miss
  if [ -n "$aur_miss" ]; then
    # shellcheck disable=SC2086
    if command -v paru >/dev/null; then paru -S --needed $aur_miss
    else echo "paru isn't installed — AUR deps skipped:$aur_miss"; fi
  fi
  setup_one "$app"   # finish what the missing packages blocked (mica's portal)
}

act="${1:-}"
case "$act" in
  scan)       for a in $(table | cut -d'|' -f1); do app_status "$a" 0; done ;;
  status)     for a in $(table | cut -d'|' -f1); do app_status "$a" 1; done ;;
  install)    install_one "${2:?app}" ;;
  update)     update_one "${2:?app}" ;;
  update-all) n=0
              for a in $(table | cut -d'|' -f1); do
                [ -d "$(field "$a" 2)/.git" ] || continue
                update_one "$a" && n=$((n+1))
              done
              echo "ALLDONE $n" ;;
  remove)     remove_one "${2:?app}" ;;
  setup)      setup_one "${2:?app}"; echo "DONE ${2}" ;;
  deps)       deps_interactive "${2:?app}" ;;
  *)          echo "ERR usage: ext-install.sh scan|status|install|update|update-all|remove|setup|deps [app]"; exit 1 ;;
esac
