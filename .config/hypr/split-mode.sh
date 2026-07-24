#!/usr/bin/env bash
# split-mode.sh — cut one wide monitor into two halves that behave like two monitors.
#
# hyprland can't split an output, and a monitor only ever shows one regular
# workspace, so the right half is a *special* workspace pinned open beside the
# normal one and lopsided gapsout rules keep the two off each other. three things
# have to hold or it falls apart:
#   input:special_fallthrough    focus can leave the special without it hiding
#   misc:close_special_on_empty  the right half survives losing its last window
#   a catch-all `workspace` windowrule — with a special open hyprland routes every
#     new window into it no matter where focus is, so we keep that rule aimed at
#     whichever half is active. zone.sh re-aims it as you move around.
#
# usage: split-mode.sh on|off|toggle | ratio +|-|<0.25-0.75> | status

set -euo pipefail

STATE="${XDG_RUNTIME_DIR:-/tmp}/world80-split"
SPACES=5    # spaces per half
GUTTER=28   # gap either side of the seam, matches gaps_out

# read one field with a fallback, so a missing/mangled state file is harmless
st() {
	local v=""
	[ -s "$STATE" ] && v=$(jq -r "$1 // empty" "$STATE" 2>/dev/null || true)
	[ -n "$v" ] && echo "$v" || echo "$2"
}

# truncate-in-place, never rename: the shell watches this path and a fresh inode
# would drop its watch (same reason the awww cache files are rewritten in place)
save() { # on ratio zone left right seam monitor
	jq -nc --argjson on "$1" --argjson ratio "$2" --arg zone "$3" \
		--argjson left "$4" --argjson right "$5" --argjson seam "$6" \
		--arg monitor "$7" --argjson spaces "$SPACES" \
		'{on:$on,ratio:$ratio,zone:$zone,left:$left,right:$right,seam:$seam,monitor:$monitor,spaces:$spaces}' \
		>"$STATE"
}

focused_mon() { hyprctl monitors -j | jq -c '.[] | select(.focused)'; }

# point the catch-all rule at a half, so the next window opens there
route() { # zone left right
	local target
	if [ "$1" = r ]; then target="special:sp$3"; else target="$2"; fi
	hyprctl keyword windowrule "workspace $target, match:class .*" >/dev/null
}

# lay the two halves out for a given ratio; echoes the seam x (logical px)
apply_rules() { # ratio
	local m lw seam half batch i
	m=$(focused_mon)
	lw=$(jq -r '(.width / .scale) | round' <<<"$m")
	seam=$(jq -rn --argjson lw "$lw" --argjson r "$1" '($lw * $r) | round')
	half=$((GUTTER / 2))

	batch="keyword input:special_fallthrough 1"
	batch+=" ; keyword misc:close_special_on_empty 0"
	batch+=" ; keyword binds:hide_special_on_workspace_change 0"
	batch+=" ; keyword decoration:dim_special 0"
	batch+=" ; keyword workspace r[1-99],gapsout:10 $((lw - seam + half)) 28 28"
	for i in $(seq 1 "$SPACES"); do
		batch+=" ; keyword workspace special:sp$i,gapsout:10 28 28 $((seam + half))"
	done
	hyprctl --batch "$batch" >/dev/null

	echo "$seam"
}

turn_on() {
	local ratio left right zone seam name prev
	ratio=$(st .ratio 0.5)
	right=$(st .right 1)
	name=$(focused_mon | jq -r .name)
	left=$(focused_mon | jq -r '.activeWorkspace.id')
	[ "$left" -ge 1 ] 2>/dev/null || left=1
	prev=$(hyprctl activewindow -j | jq -r '.address // empty')

	seam=$(apply_rules "$ratio")

	# pin the right half open (togglespecialworkspace swaps straight across if a
	# different one is already up)
	if [ "$(focused_mon | jq -r '.specialWorkspace.name')" != "special:sp$right" ]; then
		hyprctl dispatch togglespecialworkspace "sp$right" >/dev/null
	fi

	# showing the special steals focus — hand it back to where the user was
	zone=r
	if [ -n "$prev" ]; then
		hyprctl dispatch focuswindow "address:$prev" >/dev/null
		zone=l
	fi

	save 1 "$ratio" "$zone" "$left" "$right" "$seam" "$name"
	route "$zone" "$left" "$right"
}

turn_off() {
	local left cur a
	left=$(st .left 1)

	# carry the right half's windows back before the rules go away
	for a in $(hyprctl clients -j | jq -r '.[] | select(.workspace.name | startswith("special:sp")) | .address'); do
		hyprctl dispatch movetoworkspacesilent "$left,address:$a" >/dev/null
	done

	cur=$(focused_mon | jq -r '.specialWorkspace.name')
	[ -n "$cur" ] && hyprctl dispatch togglespecialworkspace "${cur#special:}" >/dev/null

	# reload is the only way to drop the catch-all windowrule — there's no API to
	# remove a single rule. monitors.conf/local.conf are sourced from hyprland.conf
	# so the display layout and per-machine env survive it, and nothing here is
	# `exec =` (only exec-once), so nothing gets relaunched.
	hyprctl reload >/dev/null

	save 0 "$(st .ratio 0.5)" l "$left" "$(st .right 1)" 0 ""
}

set_ratio() {
	local cur new seam
	cur=$(st .ratio 0.5)
	case "${1:-}" in
	+) new=$(jq -rn --argjson c "$cur" '[$c + 0.025, 0.75] | min') ;;
	-) new=$(jq -rn --argjson c "$cur" '[$c - 0.025, 0.25] | max') ;;
	*) new=${1:-0.5} ;;
	esac

	if [ "$(st .on 0)" = 1 ]; then
		seam=$(apply_rules "$new")
		save 1 "$new" "$(st .zone l)" "$(st .left 1)" "$(st .right 1)" "$seam" "$(st .monitor "")"
	else
		save 0 "$new" l "$(st .left 1)" "$(st .right 1)" 0 ""
	fi
}

case "${1:-toggle}" in
on) [ "$(st .on 0)" = 1 ] || turn_on ;;
off) [ "$(st .on 0)" = 1 ] && turn_off || true ;;
toggle) [ "$(st .on 0)" = 1 ] && turn_off || turn_on ;;
ratio) set_ratio "${2:-}" ;;
status) [ -s "$STATE" ] && cat "$STATE" || echo '{"on":0}' ;;
*)
	echo "usage: split-mode.sh on|off|toggle | ratio +|-|<0.25-0.75> | status" >&2
	exit 1
	;;
esac
