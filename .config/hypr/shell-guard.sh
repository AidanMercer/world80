#!/usr/bin/env bash
# world80 shell guard — hyprland fires this once, a few seconds after login.
#
# every keybind except Super+T routes through either quickshell (`qs ipc call …`)
# or an app in ~/dev. so when the shell fails to start there's no bar, no
# notifications, no launcher and no way to ask what went wrong — the desktop just
# looks like the config never loaded, and the only working key is the terminal.
#
# so: if no instance is up by the time the grace period ends, open the one thing
# that still works and explain it there. exec-once children inherit hyprland's
# stdout (tty1), not a log file, so the original error isn't recoverable after
# the fact — the report re-runs `qs` in the foreground to reproduce it live.
#
# read-only until it fires. it never signals or restarts a healthy shell.
set -uo pipefail

# generous on purpose: a cold first boot compiles every qml file in the tree, and
# a false alarm on a working install is worse than a slow one on a broken install.
GRACE=20
REPORT="${XDG_RUNTIME_DIR:-/tmp}/world80-shell-guard.txt"
DOTS="$HOME/dotfiles"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
note() { printf '      \033[90m%s\033[0m\n' "$*"; }

report() {
  printf '\033[1;36mworld80: the shell didn'\''t start\033[0m\n\n'
  cat <<'EOF'
quickshell draws the bar and owns the launcher, control center, clipboard,
notifications, lock screen and the volume/brightness keys. without it every
bind except Super+T (terminal) is a silent no-op — which is why the rest of
the keyboard feels dead. window management (Super+Q, Super+1-5, Super+arrows)
is hyprland's own and should still work.

EOF
  printf '\033[1m── checks ──────────────────────────────────────────────\033[0m\n'

  if command -v qs >/dev/null; then
    ok "quickshell installed — $(qs --version 2>&1 | head -1)"
  else
    bad "quickshell is NOT installed"
    note "sudo pacman -S quickshell"
  fi

  if [ -e "$HOME/.config/quickshell/shell.qml" ]; then
    ok "~/.config/quickshell/shell.qml found"
  else
    bad "~/.config/quickshell/shell.qml is missing — configs were never linked"
    note "run ~/dotfiles/install.sh"
  fi

  # the configs reference ~/dotfiles by absolute path in a dozen or so places
  # (this script included), so a clone parked anywhere else only half-works.
  if [ -f "$DOTS/install.sh" ] && [ -d "$DOTS/.config/quickshell" ]; then
    ok "~/dotfiles resolves to the repo"
  elif [ -e "$DOTS" ]; then
    bad "~/dotfiles exists but isn't world80 — the configs hardcode that path"
    note "move the clone to ~/dotfiles, or point it there: ln -s <clone> ~/dotfiles"
  else
    bad "~/dotfiles doesn't exist — the configs reference it by absolute path"
    note "ln -s <clone> ~/dotfiles"
  fi

  # informational: these are separate repos, absent by design if you declined the
  # installer's prompts. a missing app suite never stops the shell from starting.
  local missing=() app
  for app in mica vellum pulse beryl cobalt tally; do
    [ -x "$HOME/dev/$app/$app.sh" ] || missing+=("$app")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    printf '  \033[33m·\033[0m app suite not installed: %s\n' "${missing[*]}"
    note "Super+E/N/B/K/Escape/D stay dead until you install them:"
    note "~/dotfiles/install.sh --no-packages   ·   or Super+/ → Extensions once the shell is up"
  fi

  printf '\n\033[1m── starting qs here so you can see the error ────────────\033[0m\n'
  cat <<'EOF'
the original startup error went to tty1 rather than a log file, so this re-runs
the shell in the foreground. read the output below.

if the shell DOES come up, it belongs to this terminal — press Super+Shift+R
once to hand it back to the session, then close this window.

EOF
  printf '\033[90m$ qs\033[0m\n'
}

# re-entry: the terminal we spawn runs this same script to print the report, so
# this has to short-circuit before the grace sleep and the liveness check.
if [ "${1:-}" = --report ]; then report; exit 0; fi

sleep "$GRACE"

# a live instance is the only success condition. `qs list` prints one block per
# running instance and nothing at all when there are none.
qs list 2>/dev/null | grep -q '^Instance ' && exit 0

# plain-text copy, no escape codes — pasteable into an issue without a screenshot
report 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' >"$REPORT" 2>/dev/null || true

launch() {
  local term
  for term in kitty foot alacritty wezterm ghostty xterm; do
    command -v "$term" >/dev/null || continue
    case "$term" in
      # hold the window open after qs exits so the error stays readable
      kitty)     kitty --title "world80 shell guard" --hold sh -c "$1" ;;
      foot)      foot  --title "world80 shell guard" --hold sh -c "$1" ;;
      *)         "$term" -e sh -c "$1; exec \$SHELL" ;;
    esac
    return 0
  done
  return 1
}

# print the report inside the terminal, then hand the session off to qs itself so
# its startup error lands in the same window.
launch "'$0' --report; exec qs" || true
