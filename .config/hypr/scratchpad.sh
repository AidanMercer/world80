#!/usr/bin/env bash
# scratchpad.sh — a floating overlay you can throw windows into and pull back
# out (Hyprland's `special:scratchpad` workspace).
#
# The scratchpad slides over whatever workspace you're on — the desktop behind
# it dims and frosts — and everything in it floats. Hide it and the windows
# stay alive, exactly where you left them; show it again from any workspace or
# monitor and they're back.
#
#   scratchpad.sh toggle           show / hide it on the focused monitor
#   scratchpad.sh send [WINDOW]    put the window in the scratchpad: floated,
#                                  sized to 60×65% of the screen, cascaded so
#                                  it doesn't land exactly on the last one.
#                                  If it's already in there, drop it back onto
#                                  the current workspace instead (still
#                                  floating — Super+F re-tiles it).
#                                  WINDOW defaults to the active window;
#                                  address:0x…, pid:N and class:foo also work.
#
# Why a script and not `movetoworkspace special:scratchpad` alone: that would
# carry a TILED window in, and the `float` windowrule is static — it only fires
# when a window is first created. So we float + size + place it ourselves, by
# address, which also means the window never has to be focused (headless tests).
#
# Env, for headless tests only:
#   SCRATCHPAD_SILENT=1     don't follow the window (no focus, no special toggle)
#   SCRATCHPAD_OUT_WS=<id>  workspace to drop it on instead of the focused one

set -u
SPECIAL="special:scratchpad"
STEP=36     # cascade offset between successive windows, px
SLOTS=6     # cascade wraps after this many
FRAC_W=0.60 # size of a window that arrives tiled, as a fraction of the
FRAC_H=0.65 # usable screen (minus the bar)

cmd="${1:-toggle}"
sel="${2:-}"

case "$cmd" in
  toggle)
    exec hyprctl dispatch togglespecialworkspace scratchpad
    ;;
  send) ;;
  *)
    echo "usage: scratchpad.sh toggle | send [address:0x…|pid:N|class:foo]" >&2
    exit 2
    ;;
esac

# ---- resolve the window -------------------------------------------------
if [[ -z "$sel" ]]; then
    win=$(hyprctl activewindow -j)
else
    key=${sel%%:*}; val=${sel#*:}
    case "$key" in
      address) f='.address == $v' ;;
      pid)     f='(.pid|tostring) == $v' ;;
      class)   f='.class == $v' ;;
      *) echo "scratchpad.sh: unknown selector '$sel'" >&2; exit 2 ;;
    esac
    win=$(hyprctl clients -j | jq -c --arg v "$val" "first(.[] | select($f)) // {}")
fi

addr=$(jq -r '.address // ""' <<<"$win")
[[ "$addr" == 0x* ]] || exit 0            # nothing focused — nothing to send

ws=$(jq -r '.workspace.name' <<<"$win")
mon_id=$(jq -r '.monitor' <<<"$win")
floating=$(jq -r '.floating' <<<"$win")

if [[ -n "${SCRATCHPAD_SILENT:-}" ]]; then
    move=movetoworkspacesilent
else
    move=movetoworkspace
fi

# ---- already in the scratchpad: drop it back onto the current workspace -----
if [[ "$ws" == "$SPECIAL" ]]; then
    mons=$(hyprctl monitors -j)
    dest=${SCRATCHPAD_OUT_WS:-$(jq '.[] | select(.focused) | .activeWorkspace.id' <<<"$mons")}
    hyprctl dispatch "$move" "$dest,address:$addr" >/dev/null
    # the (now possibly empty) overlay is still up over the workspace we just
    # dropped onto — close it so the window is actually reachable
    if [[ -z "${SCRATCHPAD_SILENT:-}" ]]; then
        shown=$(hyprctl monitors -j | jq -r '.[] | select(.focused) | .specialWorkspace.name')
        [[ "$shown" == "$SPECIAL" ]] && hyprctl dispatch togglespecialworkspace scratchpad >/dev/null
    fi
    exit 0
fi

# ---- send it in ------------------------------------------------------------
batch="dispatch setfloating address:$addr"

# A window that arrives tiled gets a sane floating size and a cascaded spot.
# One that was already floating was placed on purpose — lift it as it is.
if [[ "$floating" != "true" ]]; then
    # usable area of the window's monitor, in logical px: position is already
    # logical, size is physical (÷ scale), reserved = [left, top, right, bottom]
    read -r ax ay aw ah < <(hyprctl monitors -j | jq -r --argjson id "$mon_id" '
        .[] | select(.id == $id)
        | (.reserved) as $r
        | "\(.x + $r[0]) \(.y + $r[1]) \(((.width  / .scale) | floor) - $r[0] - $r[2]) \(((.height / .scale) | floor) - $r[1] - $r[3])"')
    [[ -n "${aw:-}" ]] || { hyprctl dispatch "$move" "$SPECIAL,address:$addr" >/dev/null; exit 0; }

    n=$(hyprctl clients -j | jq --arg s "$SPECIAL" --argjson m "$mon_id" --arg a "$addr" \
        '[.[] | select(.workspace.name == $s and .monitor == $m and .address != $a)] | length')
    slot=$(( n % SLOTS ))

    w=$(awk -v a="$aw" -v f="$FRAC_W" 'BEGIN { printf "%d", a * f }')
    h=$(awk -v a="$ah" -v f="$FRAC_H" 'BEGIN { printf "%d", a * f }')
    # centered, then walked down-right one STEP per window already in there,
    # starting a little up-left so a full cascade straddles the centre
    x=$(( ax + (aw - w) / 2 + (slot - SLOTS / 2) * STEP ))
    y=$(( ay + (ah - h) / 2 + (slot - SLOTS / 2) * STEP ))
    # keep it on screen
    (( x < ax )) && x=$ax; (( x + w > ax + aw )) && x=$(( ax + aw - w ))
    (( y < ay )) && y=$ay; (( y + h > ay + ah )) && y=$(( ay + ah - h ))

    batch+=" ; dispatch resizewindowpixel exact $w $h,address:$addr"
    batch+=" ; dispatch movewindowpixel exact $x $y,address:$addr"
fi

batch+=" ; dispatch $move $SPECIAL,address:$addr"
hyprctl --batch "$batch" >/dev/null
