#!/usr/bin/env bash
# world80 uninstaller — reverses install.sh. Removes the config symlinks it
# created and, on request, the extras (themes, Frostify, caches, packages).
#
# Safe by default: it only unlinks symlinks that point into THIS repo, never
# touches real files, and asks before anything that holds data you might want.
# It does NOT delete the repo clone itself.
#
#   ~/dotfiles/uninstall.sh
#
# flags:  --purge   assume yes to the optional removals (themes, frostify,
#                    caches, the ~/dotfiles symlink) — but NOT packages
#         --yes     assume yes to every prompt (implies --purge; still asks
#                    nothing, but package removal stays behind its own guard)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PURGE=0 ASSUME_YES=0
for a in "$@"; do case "$a" in
  --purge) PURGE=1 ;; --yes|-y) ASSUME_YES=1; PURGE=1 ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//;1d'; exit 0 ;;
  *) echo "unknown flag: $a" >&2; exit 1 ;;
esac; done

c_ok=$'\e[32m'; c_hi=$'\e[36m'; c_warn=$'\e[33m'; c_dim=$'\e[90m'; c_off=$'\e[0m'
say()  { printf "%s==>%s %s\n" "$c_hi" "$c_off" "$*"; }
ok()   { printf "  %s✓%s %s\n" "$c_ok" "$c_off" "$*"; }
warn() { printf "  %s!%s %s\n" "$c_warn" "$c_off" "$*"; }
skip() { printf "  %s·%s %s\n" "$c_dim" "$c_off" "$*"; }
ask()  { [ "$ASSUME_YES" = 1 ] && return 0; read -rp "  $1 [y/N] " r; [[ "$r" == [yY]* ]]; }
# for the optional-but-safe removals: yes under --purge, else prompt
askp() { [ "$PURGE" = 1 ] && return 0; ask "$1"; }

cat <<EOF

${c_hi}world80 uninstaller${c_off}
  Unlinks the configs and (on request) removes themes, Frostify, and caches.
  ${c_dim}Only touches symlinks pointing into this repo. Leaves the repo clone in place.${c_off}
EOF
ask "continue?" || { echo "  aborted."; exit 0; }

# ── config symlinks (only the ones that point back into this repo) ────────
say "Config symlinks"
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  mapfile -t entries < <(git -C "$REPO_DIR" ls-files .config | cut -d/ -f2 | sort -u)
else
  mapfile -t entries < <(cd "$REPO_DIR/.config" && ls -1)
fi
for name in "${entries[@]}"; do
  dst="$HOME/.config/$name"
  if [ -L "$dst" ] && [[ "$(readlink -f "$dst")" == "$REPO_DIR"/* ]]; then
    rm "$dst"; ok "unlinked $name"
  else
    skip "$name (not our symlink — left alone)"
  fi
done

# ── restore the newest backup install.sh made, if any ─────────────────────
newest_backup="$(ls -1d "$HOME"/.config/world80-backup-* 2>/dev/null | sort | tail -1 || true)"
if [ -n "$newest_backup" ]; then
  say "Backups"
  if askp "restore your pre-install configs from $newest_backup?"; then
    for f in "$newest_backup"/*; do
      [ -e "$f" ] || continue
      n="$(basename "$f")"
      [ -e "$HOME/.config/$n" ] && { warn "$n already present — left backup in place"; continue; }
      mv "$f" "$HOME/.config/$n"; ok "restored $n"
    done
    rmdir "$newest_backup" 2>/dev/null || true
  else
    skip "backups kept at $newest_backup"
  fi
fi

# ── themes (downloaded via the marketplace — user data, off by default) ───
say "Themes"
if [ -d "$HOME/.config/themes" ]; then
  if askp "remove ~/.config/themes and everything you downloaded there?"; then
    rm -rf "$HOME/.config/themes"; ok "removed ~/.config/themes"
  else skip "kept ~/.config/themes"; fi
else skip "no ~/.config/themes"; fi

# ── per-machine hypr conf + caches ────────────────────────────────────────
say "Caches + per-machine files"
for d in "$HOME/.cache/world80" "$HOME/.cache/hypr-marketplace"; do
  [ -e "$d" ] && { rm -rf "$d"; ok "removed $d"; }
done
skip "left ~/.config/hypr/{monitors,local}.conf in the repo (delete by hand if you want)"

# ── frostify ──────────────────────────────────────────────────────────────
if [ -d "$HOME/frostify" ]; then
  say "Frostify"
  if askp "remove ~/frostify?"; then rm -rf "$HOME/frostify"; ok "removed ~/frostify"
  else skip "kept ~/frostify"; fi
fi

# ── the ~/dotfiles convenience symlink (only if install.sh made it) ───────
if [ -L "$HOME/dotfiles" ] && [ "$(readlink -f "$HOME/dotfiles")" = "$REPO_DIR" ] && [ "$REPO_DIR" != "$HOME/dotfiles" ]; then
  say "~/dotfiles symlink"
  if askp "remove the ~/dotfiles -> $REPO_DIR symlink?"; then rm "$HOME/dotfiles"; ok "removed"
  else skip "kept"; fi
fi

# ── packages (opt-in, its own guard — pacman -Rns can pull shared deps) ───
say "Packages"
warn "removing rice packages can also remove things you use elsewhere (Qt, pipewire, …)."
if ask "review + remove the packages from packages.txt now? (you'll confirm in pacman)"; then
  mapfile -t pk < <(sed -n '/^\[repo\]/,$p' "$REPO_DIR/packages.txt" | grep -vE '^\s*#|^\s*\[|^\s*$')
  printf "  would remove: %s\n" "${pk[*]}"
  sudo pacman -Rns "${pk[@]}" || warn "pacman declined / some packages weren't installed — that's fine"
else
  skip "packages left installed"
fi

say "Done"
cat <<EOF

  world80 is unlinked. The repo clone is still at $REPO_DIR — delete it with
  \`rm -rf "$REPO_DIR"\` if you're done with it.
$( [ -n "$newest_backup" ] && [ -d "$newest_backup" ] && printf "  Your original configs are still backed up in %s\n" "$newest_backup" )
EOF
