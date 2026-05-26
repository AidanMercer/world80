#!/bin/sh
# Toggle the active window between tiled and floating. When it lands FLOATING,
# shrink it to half the monitor and center it. When it goes back to tiled, do
# nothing else (resizing/centering a tiled window would disturb the layout).
#
# Why a script and not a `size`/`center` windowrule: in Hyprland those are
# "static" rules applied only when a window is first created. They never fire
# when you toggle an already-open tiled window to floating, which is our case.

hyprctl dispatch togglefloating

# `floating: 1` (tab-indented) in `hyprctl activewindow` means it's now floating.
if hyprctl activewindow | grep -q "floating: 1"; then
	hyprctl dispatch resizeactive exact 50% 50%
	hyprctl dispatch centerwindow
fi
