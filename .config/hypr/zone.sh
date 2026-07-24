#!/usr/bin/env bash
# zone.sh — the window keys, made half-aware while split mode is on. With it off
# these fall straight through to the stock dispatchers, so one set of binds covers
# both states.
#
# The two halves are two different workspaces (left = a regular one, right =
# special:spN), which is why crossing the seam takes focuswindow rather than
# movefocus: movefocus can't see out of the workspace it's standing in.
#
# usage: zone.sh focus l|r|u|d
#        zone.sh move  l|r|u|d
#        zone.sh space <n>
#        zone.sh step  +1|-1 [move]
#        zone.sh fullscreen

set -euo pipefail

STATE="${XDG_RUNTIME_DIR:-/tmp}/world80-split"
HERE="$(cd "$(dirname "$0")" && pwd)"

cmd=${1:-}
arg=${2:-}
extra=${3:-}

on=0
[ -s "$STATE" ] && on=$(jq -r '.on // 0' "$STATE" 2>/dev/null || echo 0)

# Carry the pointer to whatever just took focus. Window borders are off and the
# opacity difference between active and inactive is slight, so without this
# there's nothing telling you which zone your next keystroke lands in.
warp() { # optional "x y" fallback for when the target is empty
	local w cx cy
	w=$(hyprctl activewindow -j)
	cx=$(jq -r 'if .at then (.at[0] + .size[0] / 2 | round) else empty end' <<<"$w")
	cy=$(jq -r 'if .at then (.at[1] + .size[1] / 2 | round) else empty end' <<<"$w")
	if [ -n "$cx" ] && [ -n "$cy" ]; then
		hyprctl dispatch movecursor "$cx $cy" >/dev/null
	elif [ -n "${1:-}" ]; then
		hyprctl dispatch movecursor "$1" >/dev/null
	fi
}

if [ "$on" != 1 ]; then
	case "$cmd" in
	focus)
		hyprctl dispatch movefocus "$arg" >/dev/null
		warp
		;;
	move)
		case "$arg" in
		l | r) hyprctl dispatch movewindow "mon:$arg" >/dev/null ;;
		*) hyprctl dispatch movewindow "$arg" >/dev/null ;;
		esac
		;;
	space) hyprctl dispatch workspace "$arg" >/dev/null ;;
	step) "$HERE/workspace-deep.sh" "$arg" "$extra" ;;
	fullscreen) hyprctl dispatch fullscreen 0 >/dev/null ;;
	esac
	exit 0
fi

zone=$(jq -r '.zone' "$STATE")
left=$(jq -r '.left' "$STATE")
right=$(jq -r '.right' "$STATE")
spaces=$(jq -r '.spaces' "$STATE")
rws="special:sp$right"

# rewrite one field in place — see the note in split-mode.sh about the inode
poke() {
	jq -c "$1" "$STATE" >"$STATE.tmp" && cat "$STATE.tmp" >"$STATE"
	rm -f "$STATE.tmp"
}

aim() { # zone leftws rightIdx — where the next window should open
	local target
	if [ "$1" = r ]; then target="special:sp$3"; else target="$2"; fi
	hyprctl keyword windowrule "workspace $target, match:class .*" >/dev/null
}

enter() { # l|r — make that half the active one
	poke ".zone = \"$1\""
	aim "$1" "$left" "$right"
}

# put focus in a workspace whether or not it has windows in it. switching a
# half's space leaves focus behind on the workspace that just went off screen,
# so every switch has to land somewhere deliberately.
land() { # workspace name
	local a
	a=$(hyprctl clients -j |
		jq -r --arg ws "$1" '[.[] | select(.workspace.name == $ws)] | sort_by(.focusHistoryID) | .[0].address // empty')
	if [ -n "$a" ]; then
		hyprctl dispatch focuswindow "address:$a" >/dev/null
	else
		hyprctl dispatch focusworkspaceoncurrentmonitor "$1" >/dev/null
	fi
}

# the regular workspace the left half is showing — the monitor is the authority,
# the state file only remembers it
lws() { hyprctl monitors -j | jq -r '.[] | select(.focused) | .activeWorkspace.name'; }

# middle of a half, for warping into one that has no windows to aim at
half_centre() { # l|r -> "x y"
	local m lw lh seam
	m=$(hyprctl monitors -j | jq -c '.[] | select(.focused)')
	lw=$(jq -r '(.width / .scale) | round' <<<"$m")
	lh=$(jq -r '(.height / .scale) | round' <<<"$m")
	seam=$(jq -r '.seam' "$STATE")
	if [ "$1" = r ]; then
		echo "$((seam + (lw - seam) / 2)) $((lh / 2))"
	else
		echo "$((seam / 2)) $((lh / 2))"
	fi
}

# which half holds the focused window, or "" if focus got stranded on a
# workspace that isn't on screen
half_of() { # workspace name of the focused window
	if [ "$1" = "$rws" ]; then
		echo r
	elif [ -n "$1" ] && [ "$1" = "$(lws)" ]; then
		echo l
	else
		echo ""
	fi
}

case "$cmd" in
focus)
	case "$arg" in
	u | d)
		hyprctl dispatch movefocus "$arg" >/dev/null
		warp
		exit 0
		;;
	esac

	act=$(hyprctl activewindow -j)
	aws=$(jq -r '.workspace.name // empty' <<<"$act")
	here=$(half_of "$aws")

	if [ -z "$here" ]; then
		# nothing focused on screen — just land in the half being asked for
		if [ "$arg" = r ]; then land "$rws"; else land "$(lws)"; fi
		enter "$arg"
		warp "$(half_centre "$arg")"
		exit 0
	fi

	# is there another window further along in this half? if so it's an ordinary
	# movefocus; if not we've reached the half's edge and step across the seam,
	# exactly like walking off the side of a real monitor
	cx=$(jq -r '.at[0] + .size[0] / 2' <<<"$act")
	if [ "$arg" = l ]; then op="<"; else op=">"; fi
	n=$(hyprctl clients -j |
		jq --arg ws "$aws" --argjson cx "$cx" \
			"[.[] | select(.workspace.name == \$ws) | select((.at[0] + .size[0] / 2) $op \$cx)] | length")

	if [ "${n:-0}" -gt 0 ]; then
		hyprctl dispatch movefocus "$arg" >/dev/null
		warp
	elif [ "$arg" != "$here" ]; then
		if [ "$arg" = r ]; then land "$rws"; else land "$(lws)"; fi
		enter "$arg"
		warp "$(half_centre "$arg")"
	fi
	;;

move)
	case "$arg" in
	u | d)
		hyprctl dispatch movewindow "$arg" >/dev/null
		exit 0
		;;
	esac

	act=$(hyprctl activewindow -j)
	a=$(jq -r '.address // empty' <<<"$act")
	[ -z "$a" ] && exit 0
	here=$(half_of "$(jq -r '.workspace.name // empty' <<<"$act")")

	if [ "$arg" = "$here" ]; then
		hyprctl dispatch movewindow "$arg" >/dev/null # rearrange inside the half
	else
		if [ "$arg" = r ]; then tws="$rws"; else tws="$(lws)"; fi
		hyprctl dispatch movetoworkspacesilent "$tws,address:$a" >/dev/null
		hyprctl dispatch focuswindow "address:$a" >/dev/null
		enter "$arg"
	fi
	warp
	;;

space)
	[ "$arg" -ge 1 ] 2>/dev/null || exit 0
	if [ "$zone" = r ]; then
		[ "$arg" -le "$spaces" ] || exit 0
		if [ "$arg" != "$right" ]; then
			hyprctl dispatch togglespecialworkspace "sp$arg" >/dev/null
			right=$arg
			rws="special:sp$arg"
			poke ".right = $arg"
		fi
		land "$rws"
	else
		hyprctl dispatch workspace "$arg" >/dev/null
		left=$arg
		poke ".left = $arg"
		land "$arg"
	fi
	aim "$zone" "$left" "$right"
	warp "$(half_centre "$zone")"
	;;

step)
	d=1
	[[ "$arg" == -* ]] && d=-1
	if [ "$zone" = r ]; then
		n=$(((right - 1 + d + spaces) % spaces + 1))
		if [ "$extra" = move ]; then
			a=$(hyprctl activewindow -j | jq -r '.address // empty')
			[ -n "$a" ] && hyprctl dispatch movetoworkspacesilent "special:sp$n,address:$a" >/dev/null
		fi
		hyprctl dispatch togglespecialworkspace "sp$n" >/dev/null
		right=$n
		rws="special:sp$n"
		poke ".right = $n"
		land "$rws"
	else
		"$HERE/workspace-deep.sh" "$arg" "$extra"
		left=$(lws)
		poke ".left = $left"
		land "$left"
	fi
	aim "$zone" "$left" "$right"
	warp "$(half_centre "$zone")"
	;;

fullscreen)
	# maximise inside the half rather than over the whole panel — the same thing
	# fullscreen does on one monitor of a two-monitor desk
	hyprctl dispatch fullscreen 1 >/dev/null
	;;
esac
