# TODO

## Theming (wallpaper-driven)
- [x] frostify themed with the wallpaper theme
- [x] kitty better themed to the wallpaper (theme-colors.sh retints on switch)
- [x] super fuzzel launcher should be custom themed (theme-colors.sh too)
- [x] better lockscreen / per-theme lockscreens (lock.qml slot, bareLock takeover)
- [x] video wallpapers (mp4 per variant, VideoWall + lock map still→mp4 by suffix)
- [x] video themes (avalon + vinland, bare lock, per-theme .qsb shaders)

## Apps / widgets
- [ ] custom file explorer
- [x] live lyrics (LyricsEngine in the shell + lyrics.qml per theme)
- [x] better Super+M menu (popup.qml chrome slot)
- [x] control center (bluetooth/network/display/sound/power tabs)
- [x] media controls widget (MPRIS)
- [x] clipboard history popup (cliphist)
- [x] volume / brightness OSD

## Theme settings & layout
- [x] per-theme settings in the Super+Shift+/ sheet (clock/visualizer/sysinfo/lyrics toggles, ThemeSettings singleton, loaders unmount live)
- [x] auto-sizing for large monitor vs laptop/work screen (pal.uiScale, all themes)
- [x] interface scale slider (80–140%, UiScale singleton)

## Wallpapers & theme browsing
- [x] more custom wallpapers + push to github (10 themes, multi-wallpaper variants in the switcher)
- [x] gallery theme switcher (Super+/, vertical wallpaper-variant rail)
- [x] theme marketplace — browse + download themes from github (Super+/ 3rd tab)

## Slot parity (older themes missing newer slots)
- [x] moon: lock.qml + notif.qml (breach-deck bare lock, HUD notif cards)
- [x] shiro: popup.qml (washi card) + sysinfo.qml (margin-notes slip)
- [x] avalon: sysinfo.qml (hanging vitals ledger)
- [x] lonely-train: sysinfo.qml (arrivals board)

## System / desktop polish
- [x] captive portal watcher (nmcli monitor → sticky card → open login page)
- [x] sysinfo hover-pin (Super+., overlay layer)
- [ ] notification center — history + do-not-disturb (notifs are transient right now)
- [ ] calendar / agenda popup on the date bubble
- [ ] weather widget (bar or control popup)
- [ ] battery-low + charge notifications (for the laptop)
- [ ] screenshot markup / annotate after hyprshot

## Misc
- [ ] custom fastfetch
