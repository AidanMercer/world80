import Quickshell
import Quickshell.Io
import QtQuick
import "modules/common"
import "modules/bar"
import "modules/archlogo"
import "modules/launcher"
import "modules/clipboard"
import "modules/themeclock"
import "modules/videowall"
import "modules/themesysinfo"
import "modules/themelyrics"
import "modules/themeswitcher"
import "modules/shortcuts"
import "modules/osd"
import "modules/lock"
import "modules/notifications"

ShellRoot {
    id: shellRoot

    // Construct the shared audio feed up front. Theme widgets consume it through
    // its mirror file (they can't import the singleton), so without this reference
    // nothing would ever instantiate it and cava would never start.
    readonly property var audioBus: AudioBus

    // Per-monitor video wallpaper: plays the active video variant over the
    // still that awww holds (awww can't animate video). Background layer,
    // so it stacks under every Bottom-layer scenery widget below.
    Variants {
        model: Quickshell.screens
        VideoWall {}
    }

    Variants {
        model: Quickshell.screens
        Bar {}
    }

    // Control popup (network / sound / bluetooth / power / display), one per
    // monitor. Decoupled from the bar so it works under any bar — default or a
    // theme's own — and toggled through the ControlBus singleton (Super+M / the
    // bar's status button).
    Variants {
        model: Quickshell.screens
        ControlPopup {}
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

    // Per-monitor desktop system-info widget owned by the active theme: each theme
    // folder can ship a sysinfo.qml that loads only while its wallpaper is showing.
    Variants {
        model: Quickshell.screens
        ThemeSysInfo {}
    }

    // Per-monitor desktop lyric visualizer owned by the active theme: each theme
    // folder can ship a lyrics.qml that loads only while its wallpaper is showing.
    Variants {
        model: Quickshell.screens
        ThemeLyrics {}
    }

    // Per-screen "identify" badge: a big white card naming the physical display
    // while you drag its box in the Display tab. One overlay per monitor.
    Variants {
        model: Quickshell.screens
        DisplayIdentify {}
    }

    // Volume / brightness OSD; the XF86 media keys call into it over IPC.
    Osd {}

    // Notification daemon + popup stack, top-right on the focused monitor.
    Notifications {}

    // Session lock — animated per-theme clock + PAM. Idle until triggered with
    // `qs ipc call lock lock` (hypridle lock_cmd / loginctl lock-session).
    Lock {}

    // Single app launcher window; toggled over IPC from the Super keybind.
    Launcher {}

    // Clipboard history picker (cliphist-backed); toggled via `qs ipc call
    // clipboard toggle` (Super+V in hyprland.conf). Also owns the wl-paste
    // watchers that collect the history while the shell runs.
    ClipboardPopup {}

    // Theme switcher overlay; toggled via `qs ipc call themeSwitcher toggle`
    // (Super+Shift+T in hyprland.conf).
    ThemeSwitcher {}

    // Keybind cheat sheet; toggled via `qs ipc call shortcuts toggle`
    // (Super+/ in hyprland.conf).
    ShortcutsPopup {}

    // Super+M (hyprland.conf) toggles the Arch-logo control popup. We route
    // through the ControlBus singleton, which opens the popup on whichever
    // monitor currently has focus. One handler, never duplicated.
    IpcHandler {
        target: "controlPopup"
        function toggle(): void { ControlBus.toggleFocused() }
    }

    // Live lyric-sync calibration. The desktop lyric visualizer renders per-monitor
    // (theme lyrics.qml, instantiated once per screen) and can't import a shell
    // singleton, so the audio-latency offset is shared through a tiny state file:
    // THIS one handler writes it (never duplicated), every lyrics.qml instance
    // watches it. Nudged by ear from $mod+bracket keys (hyprland.conf).
    property int lyricOffsetMs: -250
    function setLyricOffset(v) {
        shellRoot.lyricOffsetMs = Math.max(-1500, Math.min(1500, v))
        lyricOffsetFile.setText(String(shellRoot.lyricOffsetMs) + "\n")
    }
    FileView {
        id: lyricOffsetFile
        path: Quickshell.stateDir + "/lyric-offset"
        blockLoading: true
        preload: true
        printErrors: false
        onLoaded: {
            const v = parseInt(text().trim(), 10)
            if (!isNaN(v)) shellRoot.lyricOffsetMs = Math.max(-1500, Math.min(1500, v))
        }
    }
    IpcHandler {
        target: "lyricOffset"
        // +offset = lyrics earlier, -offset = lyrics later (cancels output latency)
        function earlier(): void { shellRoot.setLyricOffset(shellRoot.lyricOffsetMs + 20) }
        function later():   void { shellRoot.setLyricOffset(shellRoot.lyricOffsetMs - 20) }
        function nudge(ms: int): void { shellRoot.setLyricOffset(shellRoot.lyricOffsetMs + ms) }
        function reset():   void { shellRoot.setLyricOffset(-250) }
        function get():     string { return String(shellRoot.lyricOffsetMs) }
    }

    // Sys-info pin. Hover-reveal themes open their readout only while the bar's
    // trigger is hovered; Super+. (hyprland.conf) flips this pin so the panel
    // stays up hands-free. Same mirror-file idiom as the hover flag: THIS one
    // handler writes $XDG_RUNTIME_DIR/theme-sysinfo-pin, every sysinfo.qml
    // watches it and ORs it with the hover flag. Always-on themes (moon,
    // vinland) simply ignore it.
    property bool sysinfoPinned: false
    FileView {
        id: sysinfoPinFile
        path: {
            const rt = Quickshell.env("XDG_RUNTIME_DIR")
            return ((rt && String(rt).length) ? String(rt) : "/tmp") + "/theme-sysinfo-pin"
        }
        blockLoading: true
        preload: true
        printErrors: false
        onLoaded: shellRoot.sysinfoPinned = text().trim() === "1"
    }
    IpcHandler {
        target: "sysinfo"
        function toggle(): void {
            shellRoot.sysinfoPinned = !shellRoot.sysinfoPinned
            sysinfoPinFile.setText(shellRoot.sysinfoPinned ? "1\n" : "0\n")
        }
        function get(): string { return shellRoot.sysinfoPinned ? "1" : "0" }
    }

    // Re-read the active theme's config.toml whenever the wallpaper changes.
    Connections {
        target: ControlBus
        function onWallpaperChanged() { ThemeConfig.reload() }
    }

    // Hot-reload the active theme's widgets without swapping the wallpaper. The
    // theme files live outside the qs config tree, so quickshell's own watcher
    // never sees edits to them — bind this to a key (e.g. `qs ipc call themeReload
    // reload`) to force the loaders to re-read from disk while iterating.
    IpcHandler {
        target: "themeReload"
        function reload(): void {
            ThemeConfig.reload()
            ControlBus.notifyThemeReload()
        }
    }
}
