#!/usr/bin/env bash
# hypr-dots installer — lays the config symlinks, installs packages, wires the
# per-machine bits, and seeds a starter theme so first boot isn't blank.
#
# safe to re-run: it backs up anything it would overwrite and skips work that's
# already done. nothing here is destructive without asking.
#
#   git clone https://github.com/AidanMercer/hypr-dots ~/dotfiles
#   ~/dotfiles/install.sh
#
# flags:  --no-packages   skip pacman/paru
#         --no-theme      skip seeding a starter theme
#         --no-frostify   skip the (optional) frostify app clone
#         --yes           assume yes to every prompt (unattended)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$HOME/.config/hypr-dots-backup-$(date +%Y%m%d-%H%M%S)"
THEMES_REPO="AidanMercer/themes"        # marketplace source (pinned)
FROSTIFY_REPO="https://github.com/AidanMercer/frostify"
STARTER_THEME="moon"                    # seeded so the desktop looks alive day one

DO_PACKAGES=1 DO_THEME=1 DO_FROSTIFY=1 ASSUME_YES=0
for a in "$@"; do case "$a" in
  --no-packages) DO_PACKAGES=0 ;; --no-theme) DO_THEME=0 ;;
  --no-frostify) DO_FROSTIFY=0 ;; --yes|-y) ASSUME_YES=1 ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//;1d'; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 1 ;;
esac; done

c_ok=$'\e[32m'; c_hi=$'\e[36m'; c_warn=$'\e[33m'; c_dim=$'\e[90m'; c_off=$'\e[0m'
say()  { printf "%s==>%s %s\n" "$c_hi" "$c_off" "$*"; }
ok()   { printf "  %s✓%s %s\n" "$c_ok" "$c_off" "$*"; }
warn() { printf "  %s!%s %s\n" "$c_warn" "$c_off" "$*"; }
skip() { printf "  %s·%s %s\n" "$c_dim" "$c_off" "$*"; }
ask()  { # ask "question" -> returns 0 for yes
  [ "$ASSUME_YES" = 1 ] && return 0
  read -rp "  $1 [y/N] " r; [[ "$r" == [yY]* ]]
}
choose() { # choose "prompt" "opt1" "opt2"... -> sets REPLY to the 1-based pick
  local prompt="$1"; shift
  printf "  %s\n" "$prompt"
  local i=1; for o in "$@"; do printf "    %s%d)%s %s\n" "$c_hi" "$i" "$c_off" "$o"; i=$((i+1)); done
  if [ "$ASSUME_YES" = 1 ]; then REPLY=1; printf "    -> 1 (--yes)\n"; return; fi
  read -rp "  choice [1]: " REPLY; REPLY="${REPLY:-1}"
}

cat <<EOF

${c_hi}hypr-dots installer${c_off}
  Sets up: packages · config symlinks · per-machine files · themes · Frostify.
  ${c_dim}Backs up anything it replaces and asks before each big step. Ctrl-C anytime.${c_off}
EOF

# ── preflight ────────────────────────────────────────────────────────────
say "Preflight"
[ "$(id -u)" -ne 0 ] || { echo "don't run this as root — it installs into your home." >&2; exit 1; }
command -v pacman >/dev/null || { echo "this rice targets Arch (needs pacman)." >&2; exit 1; }
command -v git >/dev/null || { echo "git is required. sudo pacman -S git" >&2; exit 1; }
ok "Arch + git present, running as $USER"

# ── the engine hardcodes ~/dotfiles; make that path resolve wherever we cloned ──
say "Repo location"
if [ "$REPO_DIR" = "$HOME/dotfiles" ]; then
  ok "repo is at ~/dotfiles"
elif [ ! -e "$HOME/dotfiles" ]; then
  ln -s "$REPO_DIR" "$HOME/dotfiles"
  ok "symlinked ~/dotfiles -> $REPO_DIR (configs reference ~/dotfiles by path)"
else
  warn "~/dotfiles exists and isn't this repo. the configs hardcode ~/dotfiles —"
  warn "move this clone to ~/dotfiles (or point ~/dotfiles at it) before using the rice."
fi

# ── packages ─────────────────────────────────────────────────────────────
pkgs_in_section() { # $1 = section tag like [repo]
  sed -n "/^\[$1\]/,/^\[/p" "$REPO_DIR/packages.txt" | grep -vE '^\s*#|^\s*\[|^\s*$'
}
if [ "$DO_PACKAGES" = 1 ]; then
  say "Packages (needs sudo)"
  mapfile -t repo_pkgs < <(pkgs_in_section repo)
  mapfile -t aur_pkgs  < <(pkgs_in_section aur)
  # jq isn't in the run list, but the starter-theme seed below needs it
  [ "$DO_THEME" = 1 ] && repo_pkgs+=(jq)
  if [ "${#repo_pkgs[@]}" -gt 0 ]; then
    say "  repo: ${repo_pkgs[*]}"
    ask "install these with pacman?" && sudo pacman -S --needed "${repo_pkgs[@]}" || skip "skipped repo packages"
  fi
  if ! command -v paru >/dev/null && [ "${#aur_pkgs[@]}" -gt 0 ]; then
    if ask "paru (AUR helper) isn't installed — bootstrap it?"; then
      tmp="$(mktemp -d)"; git clone --depth 1 https://aur.archlinux.org/paru.git "$tmp/paru"
      ( cd "$tmp/paru" && makepkg -si --noconfirm ); rm -rf "$tmp"
      ok "paru installed"
    fi
  fi
  if command -v paru >/dev/null && [ "${#aur_pkgs[@]}" -gt 0 ]; then
    say "  aur: ${aur_pkgs[*]}"
    ask "install these with paru?" && paru -S --needed "${aur_pkgs[@]}" || skip "skipped aur packages"
  fi
else
  skip "package install skipped (--no-packages)"
fi

# ── config symlinks (mirror the by-hand layout; back up anything real) ────
say "Config symlinks"
# tracked .config entries when it's a git checkout; fall back to a plain listing
# for a tarball download (skip the untracked per-machine hypr files handled below)
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  mapfile -t entries < <(git -C "$REPO_DIR" ls-files .config | cut -d/ -f2 | sort -u)
else
  mapfile -t entries < <(cd "$REPO_DIR/.config" && ls -1)
fi
for name in "${entries[@]}"; do
  src="$REPO_DIR/.config/$name"; dst="$HOME/.config/$name"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
    skip "$name (already linked)"; continue
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    mkdir -p "$BACKUP_DIR"; mv "$dst" "$BACKUP_DIR/$name"
    warn "$name existed — backed up to $BACKUP_DIR/$name"
  fi
  mkdir -p "$(dirname "$dst")"; ln -s "$src" "$dst"; ok "$name -> repo"
done

# one config can't use ~ (qt6ct stores an absolute color-scheme path). rewrite
# the author's home to yours in this clone so Qt apps get themed. no-op for the
# author; harmless if the file's already yours.
if [ "$HOME" != "/home/aidan" ]; then
  qtc="$REPO_DIR/.config/qt6ct/qt6ct.conf"
  if [ -f "$qtc" ] && grep -q "/home/aidan" "$qtc"; then
    sed -i "s#/home/aidan#$HOME#g" "$qtc"; ok "qt6ct color path pointed at $HOME"
  fi
fi

# ── per-machine hypr conf (untracked; hyprland.conf sources these) ────────
say "Per-machine config"
mon="$REPO_DIR/.config/hypr/monitors.conf"
loc="$REPO_DIR/.config/hypr/local.conf"
if [ ! -e "$mon" ]; then
  printf '# per-machine monitor layout. see `hyprctl monitors`.\nmonitor = , preferred, auto, 1\n' > "$mon"
  ok "wrote a default monitors.conf (edit for your displays)"
else skip "monitors.conf exists"; fi
# hyprland.conf hardcodes LIBVA_DRIVER_NAME=nvidia (author's desktop). local.conf
# is sourced AFTER it and wins, so we detect the GPU and set the right VAAPI
# driver here — otherwise AMD/Intel video wallpapers fall back to CPU decode.
# This only writes a userspace env var; it does NOT install or touch drivers.
gpu_vendor() {
  local g; g="$(lspci 2>/dev/null | grep -iE 'vga|3d|display' || true)"
  echo "$g" | grep -qi nvidia && { echo nvidia; return; }
  echo "$g" | grep -qiE 'amd|ati|radeon' && { echo amd; return; }
  echo "$g" | grep -qi intel && { echo intel; return; }
  echo unknown
}
if [ ! -e "$loc" ]; then
  v="$(gpu_vendor)"
  case "$v" in
    amd)     libva="radeonsi" ;;
    intel)   libva="iHD" ;;
    nvidia)  libva="nvidia" ;;
    *)       libva="" ;;
  esac
  {
    printf '# per-machine env/overrides, sourced by hyprland.conf (last wins).\n'
    if [ -n "$libva" ]; then
      printf '# detected a %s GPU — VAAPI driver for hardware video decode:\n' "$v"
      printf 'env = LIBVA_DRIVER_NAME,%s\n' "$libva"
    else
      printf '# couldn'"'"'t detect the GPU — set your VAAPI driver by hand:\n'
      printf '#   AMD:  env = LIBVA_DRIVER_NAME,radeonsi\n'
      printf '#   Intel:env = LIBVA_DRIVER_NAME,iHD\n'
      printf '#   (nvidia is already set in hyprland.conf)\n'
    fi
  } > "$loc"
  ok "wrote local.conf (GPU: $v${libva:+, LIBVA_DRIVER_NAME=$libva})"
  case "$v" in
    nvidia) warn "nvidia: make sure nvidia-open-dkms + nvidia-utils are installed (base system)" ;;
    amd)    warn "amd: make sure mesa + vulkan-radeon + libva-mesa-driver are installed (base system)" ;;
    intel)  warn "intel: make sure mesa + vulkan-intel + intel-media-driver are installed (base system)" ;;
  esac
else skip "local.conf exists (left your GPU env alone)"; fi

# ── themes: a plain dir the marketplace fills, plus an optional first batch ─
say "Themes"
mkdir -p "$HOME/.config/themes"; ok "~/.config/themes ready"

# the shell layers every theme over themes/default/config.toml, so that base
# always has to exist. it isn't a marketplace theme (no wallpaper) — just the
# palette floor — so seed its couple of files directly.
if [ ! -f "$HOME/.config/themes/default/config.toml" ]; then
  mkdir -p "$HOME/.config/themes/default"; base_ok=1
  for f in config.toml frostify.qml; do
    curl -fsSL "https://raw.githubusercontent.com/$THEMES_REPO/master/default/$f" \
      -o "$HOME/.config/themes/default/$f" 2>/dev/null || base_ok=0
  done
  [ "$base_ok" = 1 ] && ok "installed the base 'default' theme (palette floor)" \
    || warn "couldn't fetch the default base — check your connection and re-run"
else skip "default base theme present"; fi

THEME_IDX="" THEME_COMMIT=""
theme_catalog() { # fetch index.json once; needs jq + curl
  [ -n "$THEME_IDX" ] && return 0
  command -v jq >/dev/null || { command -v pacman >/dev/null && ask "themes need jq — install it?" && sudo pacman -S --needed jq; }
  command -v jq >/dev/null || { warn "jq missing — skipping; use the Marketplace tab in-session instead"; return 1; }
  THEME_IDX="$(curl -fsSL "https://raw.githubusercontent.com/$THEMES_REPO/master/index.json")" || { warn "couldn't reach the theme store"; return 1; }
  THEME_COMMIT="$(jq -r '.commit' <<<"$THEME_IDX")"
}
install_theme() { # $1 = name
  local name="$1" paths
  [ -d "$HOME/.config/themes/$name" ] && { skip "$name (already installed)"; return 0; }
  mapfile -t paths < <(jq -r ".themes[]|select(.name==\"$1\")|.files[].path" <<<"$THEME_IDX")
  [ "${#paths[@]}" -gt 0 ] || { warn "no theme named '$name' in the catalog"; return 1; }
  printf "  downloading %s…\n" "$name"
  bash "$REPO_DIR/.config/quickshell/scripts/theme-install.sh" \
    "$THEMES_REPO" master "$name" "$THEME_COMMIT" "${paths[@]}" >/dev/null \
    && ok "$name installed" || warn "$name failed"
}

if [ "$DO_THEME" = 1 ]; then
  choose "How many themes to download now? (the rest are one click away in Super+/ → Marketplace)" \
    "just a starter ($STARTER_THEME, ~40MB)" \
    "all themes (~240MB)" \
    "let me pick" \
    "none — I'll grab them from the Marketplace later"
  case "$REPLY" in
    1) theme_catalog && install_theme "$STARTER_THEME" ;;
    2) if theme_catalog; then
         for t in $(jq -r '.themes[].name' <<<"$THEME_IDX"); do install_theme "$t"; done
       fi ;;
    3) if theme_catalog; then
         echo "  available:"
         jq -r '.themes[] | "    \(.name)  ·  \((.bytes/1048576)|floor)MB  ·  \(.tagline)"' <<<"$THEME_IDX"
         read -rp "  names to install (space-separated): " picks
         for t in $picks; do install_theme "$t"; done
       fi ;;
    *) skip "no themes seeded — open Super+/ → Marketplace anytime" ;;
  esac
else
  skip "themes skipped (--no-theme)"
fi

# ── services ──────────────────────────────────────────────────────────────
say "Services"
if ask "enable NetworkManager + bluetooth (system) and wireplumber (user)?"; then
  sudo systemctl enable --now NetworkManager.service bluetooth.service || warn "system services: check manually"
  systemctl --user enable --now wireplumber.service || warn "wireplumber: check manually"
  ok "services enabled"
else skip "services left alone"; fi

# ── frostify (optional, separate app that fills the frostify.qml slot) ────
if [ "$DO_FROSTIFY" = 1 ] && [ ! -d "$HOME/frostify" ]; then
  say "Frostify (optional)"
  echo "  A full-screen now-playing overlay — album art, playlists, and playback"
  echo "  controls — that follows Spotify/MPRIS and matches your active theme (Super+S)."
  if ask "install Frostify to ~/frostify?"; then
    git clone --depth 1 "$FROSTIFY_REPO" "$HOME/frostify" && ok "cloned ~/frostify" \
      || warn "clone failed — set FROSTIFY_REPO at the top of this script if the URL is wrong"
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────
say "Done"
cat <<EOF

  Log out and start Hyprland (from a TTY: \`Hyprland\`, or via your display manager).

  ${c_dim}Set your display layout in ~/.config/hypr/monitors.conf if the default
  (auto, 1x scale) isn't right. The wallpaper restores to your last-applied
  theme on login (or a starter one if you seeded any).${c_off}

  Keys:  Super+/ this cheatsheet (+ Marketplace tab) · Super+Shift+T themes ·
         Super+R launcher · Super+M control center
$( [ -d "${BACKUP_DIR}" ] && printf "\n  Backed-up originals are in %s\n" "$BACKUP_DIR" )
EOF
