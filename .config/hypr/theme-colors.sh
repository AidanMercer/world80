#!/usr/bin/env bash
# Per-theme app colors. Reads the active theme's config.toml palette and writes
# color configs for kitty, fuzzel and hyprlock, then live-reloads kitty. Hooked
# from the quickshell theme switcher (on apply) and hyprland exec-once (login).
# A wallpaper that isn't a themed folder just gets a neutral dark fallback.

set -u
out="$HOME/.cache/theme"
mkdir -p "$out"

# theme dir: explicit arg, else the folder holding the active wallpaper. awww may
# not have painted yet at login, so give it a few tries before falling back.
dir="${1:-}"
if [ -z "$dir" ]; then
    for _ in $(seq 1 8); do
        wall=$(awww query 2>/dev/null | grep -oP 'image: \K.*' | head -1)
        [ -n "${wall:-}" ] && break
        sleep 1.2
    done
    [ -n "${wall:-}" ] && dir=$(dirname "$wall")
fi
cfg="$dir/config.toml"

# read a "#rrggbb" value for KEY out of config.toml, bare 6-hex; DEFAULT if absent
get() {
    local val=""
    [ -f "$cfg" ] && val=$(grep -ioP "^\s*$1\s*=\s*[\"']?#\K[0-9a-fA-F]{6}" "$cfg" | head -1)
    printf '%s' "${val:-$2}"
}

# neutral dark fallback (tokyo-night-ish); themes override via config.toml
bg=$(get bg 11121a)
fg=$(get fg c8ccd8)
accent=$(get accent 7aa2f7)
accent2=$(get accent2 7dcfff)
accent3=$(get accent3 bb9af7)
warn=$(get accent_warn e0af68)
dim=$(get accent_dim 3b3f51)
green=$(get hue_green 9ece6a)
blue=$(get hue_blue 7aa2f7)

cat >"$out/kitty.conf" <<EOF
background #$bg
foreground #$fg
cursor #$accent
cursor_text_color #$bg
selection_background #$dim
selection_foreground #$fg
url_color #$accent2

color0 #$bg
color8 #$dim
color1 #$accent3
color9 #$accent3
color2 #$green
color10 #$green
color3 #$accent
color11 #$warn
color4 #$blue
color12 #$blue
color5 #$accent3
color13 #$accent3
color6 #$accent2
color14 #$accent2
color7 #$fg
color15 #$fg

active_tab_background #$accent
active_tab_foreground #$bg
inactive_tab_background #$dim
inactive_tab_foreground #$fg
active_border_color #$accent
inactive_border_color #$dim
EOF

mkdir -p "$HOME/.config/fuzzel"
cat >"$HOME/.config/fuzzel/fuzzel.ini" <<EOF
[main]
font=Noto Sans Mono:size=12
prompt=>
lines=10
width=36
horizontal-pad=20
vertical-pad=16
inner-pad=10

[colors]
background=${bg}f2
text=${fg}ff
prompt=${accent2}ff
input=${fg}ff
match=${accent}ff
# translucent row tint + normal fg so the selected row stays readable on
# light palettes too (opaque dim + bg text only worked on dark themes)
selection=${dim}55
selection-text=${fg}ff
selection-match=${accent}ff
border=${accent}ff

[border]
width=2
radius=14
EOF

# hyprlang variables consumed by hyprlock.conf (escaped \$ so the heredoc keeps
# the literal name while the hex values expand)
cat >"$out/hypr-colors.conf" <<EOF
\$lock_fg = rgba(${fg}ff)
\$lock_dim = rgba(${dim}ff)
\$lock_accent = rgba(${accent}ff)
\$lock_cyan = rgba(${accent2}ff)
\$lock_magenta = rgba(${accent3}ff)
\$lock_fail = rgba(${accent3}ff)
\$lock_bg = rgba(${bg}ee)
EOF

# bare hexes for non-templated consumers (the lavat fish wrapper tints from these)
printf '%s' "$accent" >"$out/accent"
printf '%s' "$dim" >"$out/accent_dim"

# kitty reloads its config (includes and all) on SIGUSR1
pkill -USR1 -x kitty 2>/dev/null || true
