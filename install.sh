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

# ── per-machine hypr conf (untracked; hyprland.conf sources these) ────────
say "Per-machine config"
mon="$REPO_DIR/.config/hypr/monitors.conf"
loc="$REPO_DIR/.config/hypr/local.conf"
if [ ! -e "$mon" ]; then
  printf '# per-machine monitor layout. see `hyprctl monitors`.\nmonitor = , preferred, auto, 1\n' > "$mon"
  ok "wrote a default monitors.conf (edit for your displays)"
else skip "monitors.conf exists"; fi
if [ ! -e "$loc" ]; then
  printf '# per-machine env/overrides, sourced by hyprland.conf.\n# e.g. an AMD laptop needs: env = LIBVA_DRIVER_NAME,radeonsi\n' > "$loc"
  ok "wrote an empty local.conf (per-machine env goes here)"
else skip "local.conf exists"; fi

# ── themes dir + a starter so the desktop isn't blank ─────────────────────
say "Themes"
mkdir -p "$HOME/.config/themes"; ok "~/.config/themes ready (marketplace fills it)"
if [ "$DO_THEME" = 1 ] && [ ! -d "$HOME/.config/themes/$STARTER_THEME" ]; then
  if ask "download the '$STARTER_THEME' starter theme now (~40MB)?"; then
    idx="$(curl -fsSL "https://raw.githubusercontent.com/$THEMES_REPO/master/index.json")"
    commit="$(jq -r '.commit' <<<"$idx")"
    mapfile -t paths < <(jq -r ".themes[]|select(.name==\"$STARTER_THEME\")|.files[].path" <<<"$idx")
    bash "$REPO_DIR/.config/quickshell/scripts/theme-install.sh" \
      "$THEMES_REPO" master "$STARTER_THEME" "$commit" "${paths[@]}" | sed 's/^/    /'
    ok "seeded $STARTER_THEME — open Super+Shift+T to browse, Super+/ → Marketplace for more"
  fi
else
  skip "starter theme skipped"
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
  say "Frostify (optional music overlay, bound to Super+S)"
  if ask "clone frostify to ~/frostify?"; then
    git clone --depth 1 "$FROSTIFY_REPO" "$HOME/frostify" && ok "cloned ~/frostify" \
      || warn "clone failed — set FROSTIFY_REPO at the top of this script if the URL is wrong"
  fi
fi

# ── done ──────────────────────────────────────────────────────────────────
say "Done"
cat <<EOF

  Log out and start Hyprland (from a TTY: \`Hyprland\`, or via your display manager).

  ${c_warn}Worth a look before first boot:${c_off}
   • hyprland.conf line ~38 sets the initial wallpaper to a file that's specific
     to the author (~/Pictures/wallpapers/…). Point it at your starter theme's
     still, e.g.  awww img ~/.config/themes/$STARTER_THEME/wallpaper*.still.png
   • ~/.config/hypr/monitors.conf — set your real display layout.
   • qt6ct.conf references an absolute /home/<author>/… path; update it to yours.

  Keys:  Super+/ this cheatsheet (+ Marketplace tab) · Super+Shift+T themes ·
         Super+R launcher · Super+M control center
$( [ -d "${BACKUP_DIR}" ] && printf "\n  Backed-up originals are in %s\n" "$BACKUP_DIR" )
EOF
