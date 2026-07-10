# TODO

## Theming (wallpaper-driven)
- [x] frostify themed with the wallpaper theme
- [x] kitty better themed to the wallpaper (theme-colors.sh retints on switch)
- [x] super fuzzel launcher should be custom themed (theme-colors.sh too)
- [x] better lockscreen / per-theme lockscreens (lock.qml slot, bareLock takeover)
- [x] video wallpapers (mp4 per variant, VideoWall + lock map still→mp4 by suffix)
- [x] video themes (avalon + vinland, bare lock, per-theme .qsb shaders)
- [ ] themed sddm greeter (matches current wallpaper theme, boot→desktop cohesion)

## Apps / widgets
- [x] custom file explorer (mica — PySide6+QML miller-columns manager, live world80 theming, Super+E)
- [x] multi-mode launcher (prefix modes in the Super launcher: `e ` emoji, `w ` window switch/kill, `c ` clipboard, `u `/inline unit convert, `=` calc; live currency still TODO)
- [x] command palette (Super+P — fuzzy over theme apply/next/prev, open any panel, toggles (autolock/sysinfo/ui-scale/lyrics), window + session actions; each fires the matching `qs ipc call …` or hypr dispatch)
- [x] live lyrics (LyricsEngine in the shell + lyrics.qml per theme)
- [x] better Super+M menu (popup.qml chrome slot)
- [x] control center (bluetooth/network/display/sound/power tabs)
- [x] media controls widget (MPRIS)
- [x] clipboard history popup (cliphist)
- [x] volume / brightness OSD

## Custom apps
- [x] frostify — music player
- [x] mica — file explorer
- [x] text / markdown editor (vellum — PySide6+QML modal vim editor + live themed markdown preview; follows world80 like mica/frostify, ~/dev/vellum)
- [ ] browser (keyboard-driven, yazi-style modal nav)
- [ ] image / gallery viewer (keyboard-driven, themed, pairs with mica)
- [ ] pdf / document reader (vim keys, themed chrome)
- [ ] system dashboard (full-window btop-style CPU/mem/net/procs, keyboard-driven)

## Theme settings & layout
- [x] per-theme settings in the Super+Shift+/ sheet (clock/visualizer/sysinfo/lyrics toggles, ThemeSettings singleton, loaders unmount live)
- [x] auto-sizing for large monitor vs laptop/work screen (pal.uiScale, all themes)
- [x] interface scale slider (80–140%, UiScale singleton)

## Wallpapers & theme browsing
- [x] more custom wallpapers + push to github (10 themes, multi-wallpaper variants in the switcher)
- [x] gallery theme switcher (Super+/, vertical wallpaper-variant rail)
- [x] theme marketplace — browse + download themes from github (Super+/ 3rd tab)
- [x] custom theme-switch transition (chrome bows out → awww wipes the wallpaper daemon-side, immune to qs compile stalls → new chrome + already-playing video emerge during the wipe's tail; ControlBus.swapping gates every theme loader)

## Slot parity (older themes missing newer slots)
- [x] moon: lock.qml + notif.qml (breach-deck bare lock, HUD notif cards)
- [x] shiro: popup.qml (washi card) + sysinfo.qml (margin-notes slip)
- [x] avalon: sysinfo.qml (hanging vitals ledger)
- [x] lonely-train: sysinfo.qml (arrivals board)

## Motion / eye-candy (all togglable via Super+Shift+/)
- [ ] workspace overview / zoom-out exposé (live window thumbnails, themed grid)
- [ ] cursor parallax (subtle wallpaper depth-shift between workspaces)
- [ ] theme-native ambient particles (avalon petals / vinland snow drifting on desktop, occlusion-gated)

## System / desktop polish
- [x] captive portal watcher (nmcli monitor → sticky card → open login page)
- [x] sysinfo hover-pin (Super+., overlay layer)
- [ ] notification center — history + do-not-disturb (notifs are transient right now)
- [x] battery-low notifications (BAT* poll in Notifications.qml → sticky cards: low 20% / critical 10% while discharging, latched; plugging in clears them silently — no charge spam; `qs ipc call battery test low|crit`)

## Misc
- [ ] custom fastfetch
