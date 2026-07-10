pragma Singleton
import QtQuick
import Quickshell.Hyprland

// Shared open-state for the Arch-logo control popup (the "Arch menu").
//
// The popup is created once *per monitor* (inside each Bar), but only one should
// ever be open at a time and it must be toggleable from a single global keybind
// (Super+M). So instead of each popup owning its own bool, they all read this one
// singleton: it holds the *name* of the monitor whose popup is open ("" = all
// closed). A popup opens only when openMonitor matches its own screen. Both the
// StatusButton click and the Super+M IPC funnel through here, keeping one source
// of truth.
QtObject {
    id: bus

    // Name of the monitor whose popup is currently open, or "" when none is.
    property string openMonitor: ""

    // Name of the physical monitor to flash an "identify" badge on (set while a
    // box is dragged in the Display tab), or "" for none. The per-screen
    // DisplayIdentify overlays watch this.
    property string identifyMonitor: ""

    // True while the session lock is engaged (set by Lock.qml). The video
    // wallpaper pauses its decoder behind the lock surfaces.
    property bool sessionLocked: false

    // Fired whenever the wallpaper changes (theme switch), so per-theme desktop
    // widgets — like the themeclock loader — can re-query awww and swap.
    signal wallpaperChanged()
    function notifyWallpaperChanged() { wallpaperChanged() }

    // Force the theme loaders to re-read their widget files from disk (hot-reload),
    // even when the wallpaper hasn't changed. Fired by the themeReload IPC.
    signal themeReloadRequested()
    function notifyThemeReload() { themeReloadRequested() }

    // Theme-switch transition. ThemeSwitcher freezes every monitor under a
    // frozen frame (ThemeTransition.qml) before touching awww; each cover
    // wipes the old frame into the incoming wallpaper (transitionTarget, the
    // exact image awww is about to show) while the swap finishes fully hidden
    // beneath, then fades itself off. Empty target = wipe to the live desktop
    // (the dry-run test).
    property string transitionTarget: ""
    signal transitionFreeze()
    function freezeScreens(target) { transitionTarget = target || ""; transitionFreeze() }

    // Toggle the popup on a specific monitor (used by the StatusButton click).
    function toggle(name) {
        openMonitor = (openMonitor === name) ? "" : name
        if (openMonitor === "") identifyMonitor = ""
    }

    // Toggle on whichever monitor has focus (used by the Super+M IPC handler).
    function toggleFocused() {
        const m = Hyprland.focusedMonitor
        toggle(m ? m.name : "")
    }

    function close() {
        openMonitor = ""
        identifyMonitor = ""
    }

    function identify(name) { identifyMonitor = name }
    function clearIdentify() { identifyMonitor = "" }
}
