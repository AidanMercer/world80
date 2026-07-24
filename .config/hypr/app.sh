#!/usr/bin/env bash
# app.sh — while split mode is on, bring an already-running app to the half you're
# standing in rather than sending the half off to find it.
#
# The world80 app scripts raise their existing window instead of opening a second
# one (pulse/frostify do it with `hyprctl focuswindow`, cobalt does it itself).
# A half only ever shows one workspace, so raising a window parked elsewhere drags
# your half onto that workspace — press the key on a fresh space and you get
# yanked back. Moving the window to you is the two-monitor behaviour: the app
# arrives on the screen you're looking at.
#
# usage: app.sh <class> <command> [args...]

set -euo pipefail

STATE="${XDG_RUNTIME_DIR:-/tmp}/world80-split"
cls=${1:-}
shift || true

on=0
[ -s "$STATE" ] && on=$(jq -r '.on // 0' "$STATE" 2>/dev/null || echo 0)

if [ "$on" = 1 ] && [ -n "$cls" ]; then
	addr=$(hyprctl clients -j |
		jq -r --arg c "$cls" '[.[] | select(.class == $c)] | sort_by(.focusHistoryID) | .[0].address // empty')

	if [ -n "$addr" ]; then
		if [ "$(jq -r '.zone' "$STATE")" = r ]; then
			tws="special:sp$(jq -r '.right' "$STATE")"
		else
			tws=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .activeWorkspace.name')
		fi

		hyprctl dispatch movetoworkspacesilent "$tws,address:$addr" >/dev/null
		hyprctl dispatch focuswindow "address:$addr" >/dev/null

		# let the half re-tile before reading geometry for the pointer
		sleep 0.12
		c=$(hyprctl activewindow -j |
			jq -r 'if .at then "\(.at[0] + .size[0] / 2 | round) \(.at[1] + .size[1] / 2 | round)" else empty end')
		[ -n "$c" ] && hyprctl dispatch movecursor "$c" >/dev/null
		exit 0
	fi
fi

exec "$@"
