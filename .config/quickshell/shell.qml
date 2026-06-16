import Quickshell
import Quickshell.Io
import QtQuick
import "modules/common"
import "modules/bar"
import "modules/archlogo"
import "modules/launcher"
import "modules/themeclock"
import "modules/themeswitcher"
import "modules/shortcuts"
import "modules/osd"

ShellRoot {
    Variants {
        model: Quickshell.screens
        Bar {}
    }

    // Audio-reactive Arch logo, centered on each monitor. Driven by cava the same
    // way the old side spectrum was; the triangle outline bends with the audio.
    Variants {
        model: Quickshell.screens
        ArchLogo {}
    }

    // Per-monitor desktop clock owned by the active theme: each theme folder can
    // ship a clock.qml that loads only while its wallpaper is showing.
    Variants {
        model: Quickshell.screens
        ThemeClock {}
    }

    // Per-screen "identify" badge: a big white card naming the physical display
    // while you drag its box in the Display tab. One overlay per monitor.
    Variants {
        model: Quickshell.screens
        DisplayIdentify {}
    }

    // Volume / brightness OSD; the XF86 media keys call into it over IPC.
    Osd {}

    // Single app launcher window; toggled over IPC from the Super keybind.
    Launcher {}

    // Theme switcher overlay; toggled via `qs ipc call themeSwitcher toggle`
    // (Super+Shift+T in hyprland.conf).
    ThemeSwitcher {}

    // Keybind cheat sheet; toggled via `qs ipc call shortcuts toggle`
    // (Super+/ in hyprland.conf).
    ShortcutsPopup {}

    // Super+M (hyprland.conf) toggles the Arch-logo control popup. The popup
    // lives per-monitor inside each Bar, so rather than reach into a specific
    // window we route through the ControlBus singleton, which opens the popup on
    // whichever monitor currently has focus. One handler, never duplicated.
    IpcHandler {
        target: "controlPopup"
        function toggle(): void { ControlBus.toggleFocused() }
    }

    // Re-read the active theme's config.toml whenever the wallpaper changes.
    Connections {
        target: ControlBus
        function onWallpaperChanged() { ThemeConfig.reload() }
    }
}
