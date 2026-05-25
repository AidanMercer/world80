#!/usr/bin/env bash
# workspace-deep.sh — step the FOCUSED monitor through its own stack of
# workspaces, skipping any workspace that currently belongs to another monitor.
#
# Plain `workspace +1` walks the global workspace numbers, so with several
# monitors each parked on 1, 2, 3… "next" just jumps onto a neighbour's
# workspace. Here we skip every workspace owned by a different monitor and land
# on the next one that is either already ours or doesn't exist yet (a fresh
# empty workspace opens on the focused monitor). That gives each monitor an
# independent depth to scroll through.
#
# Usage:
#   workspace-deep.sh +1        # switch deeper / next
#   workspace-deep.sh -1        # switch shallower / previous
#   workspace-deep.sh +1 move   # carry the active window deeper (focus follows)
#   workspace-deep.sh -1 move   # carry the active window shallower

case "${1:-+1}" in
  -*) step=-1 ;;
  *)  step=1  ;;
esac

# "move" carries the focused window along; anything else just switches view.
if [[ "${2:-}" == move ]]; then
    action="movetoworkspace"
else
    action="workspace"
fi

mon=$(hyprctl monitors -j)
ws=$(hyprctl workspaces -j)

# Focused monitor's id and the workspace it's currently showing.
fid=$(jq '.[] | select(.focused) | .id'                 <<<"$mon")
cur=$(jq '.[] | select(.focused) | .activeWorkspace.id' <<<"$mon")

# Workspace ids that live on a DIFFERENT monitor — these are the ones to skip.
blocked=$(jq -r --argjson f "$fid" '.[] | select(.monitorID != $f) | .id' <<<"$ws")

is_blocked() {
    local id
    for id in $blocked; do [[ "$id" == "$1" ]] && return 0; done
    return 1
}

# Walk in the requested direction until we hit a workspace that isn't owned by
# another monitor. Stop at the bottom (id 1) when going shallower.
cand=$((cur + step))
while (( cand >= 1 )) && is_blocked "$cand"; do
    cand=$((cand + step))
done

(( cand >= 1 )) && hyprctl dispatch "$action" "$cand"
