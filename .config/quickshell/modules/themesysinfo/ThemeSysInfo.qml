import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import "../common"

// Per-monitor desktop system-info widget owned by the *active theme*.
//
// Same idea as ThemeClock: each theme folder (~/.config/themes/<name>/) may drop
// a sysinfo.qml next to its wallpaper. This window asks awww which wallpaper the
// monitor is showing, walks up to that theme folder, and loads its sysinfo.qml if
// present. No sysinfo.qml → nothing renders. Swap the wallpaper and it swaps too.
//
// Hover/pin reveals live on the Overlay layer (above every window) so the
// readout slides out over whatever you're working in — click-through, so it
// never steals a click. Always-on readouts are desktop scenery, not something
// to paint over your windows all day: a sysinfo.qml carrying the
// `desktopSysinfo` marker (same idea as lock.qml's bareLock) sits on the
// Bottom layer instead, under windows like the theme clock.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-themesysinfo"
    WlrLayershell.layer: onDesktop ? WlrLayer.Bottom : WlrLayer.Overlay

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}
    visible: infoPath !== "" && slotOn

    property string themeDir: ActiveTheme.dirFor(root.modelData ? root.modelData.name : "")
    // per-theme toggle (Super+Shift+/ → Settings); flipping it mounts/unmounts live
    readonly property bool slotOn: ThemeSettings.on(root.themeDir, "sysinfo")
    onSlotOnChanged: remount()
    property string infoPath: ""
    property bool wantsPal: false               // widget declares `property var pal`
    property bool onDesktop: false              // widget carries `desktopSysinfo`
    property int reloadNonce: 0

    property ThemePalette pal: ThemePalette { themeDir: root.themeDir }

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // ActiveTheme already knows this monitor's theme folder (one shared awww query);
    // we just confirm it ships a sysinfo.qml. Re-runs when the folder changes (theme
    // switch) or a hot-reload is forced.
    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const pal = parts.includes("PAL")
                const desk = parts.includes("DESK")
                const changed = parts[0] !== root.infoPath
                    || pal !== root.wantsPal || desk !== root.onDesktop
                root.wantsPal = pal
                root.onDesktop = desk
                root.infoPath = parts[0]
                if (changed) root.remount()
            }
        }
    }
    // Build the lookup command from the CURRENT themeDir at call time, NOT via a
    // declarative `command: [...root.themeDir]` binding. On a theme switch the
    // onThemeDirChanged handler fires BEFORE such a binding re-evaluates, so the
    // process would launch with the PREVIOUS theme's dir and load the wrong widget
    // (the one-behind bug). Reading themeDir at start time always sees the new value.
    function rescan() {
        existProc.command = ["bash", "-c",
            'd="$1"; f="$d/sysinfo.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; ' +
            'printf "%s" "$f"; grep -q "property var pal" "$f" && printf "\\tPAL"; ' +
            'grep -q "desktopSysinfo" "$f" && printf "\\tDESK"; true',
            "_", root.themeDir]
        existProc.running = true
    }
    onThemeDirChanged: rescan()

    Loader {
        id: widgetLoader
        anchors.fill: parent
        // theme swap: bow out before awww's wallpaper wipe, emerge while the
        // wipe finishes its sweep
        opacity: ControlBus.swapping ? 0 : 1
        Behavior on opacity {
            id: fadeBeh
            NumberAnimation { duration: ControlBus.swapping ? 140 : 450; easing.type: Easing.OutCubic }
        }
        // a widget that lands after the swap settled still fades in: snap to 0
        // with the Behavior muted, then hand the property back to its binding
        onItemChanged: {
            if (!item || ControlBus.swapping) return
            fadeBeh.enabled = false
            opacity = 0
            fadeBeh.enabled = true
            opacity = Qt.binding(() => ControlBus.swapping ? 0 : 1)
        }
    }

    // Same contract as ThemeClock: declare `property bool occluded` to be
    // told, and park pollers/animations while it's true. On the Overlay layer
    // only the lock hides this widget; desktop-marked widgets sit under
    // windows, so a fullscreen window on this monitor covers them too.
    readonly property var hyprMon: Hyprland.monitorFor(root.modelData)
    readonly property bool occluded: ControlBus.sessionLocked
        || (root.onDesktop && Hyprland.toplevels.values.some(t =>
            t.wayland && t.wayland.fullscreen
            && t.monitor === root.hyprMon
            && t.workspace && t.workspace.active))
    Binding {
        target: widgetLoader.item
        property: "occluded"
        value: root.occluded
        when: widgetLoader.item !== null && widgetLoader.item.hasOwnProperty("occluded")
    }
    // setSource instead of a source binding so the widget gets `pal` as an
    // initial property — its bindings never see pal undefined. Called from the
    // exist-check collector (path/pal answer changed) and on nonce bumps.
    function remount() {
        if (root.infoPath === "" || !root.slotOn) { widgetLoader.source = ""; return }
        const url = root.fileUrl(root.infoPath) + "?v=" + root.reloadNonce
        widgetLoader.setSource(url, root.wantsPal ? { pal: root.pal } : {})
    }
    onReloadNonceChanged: remount()

    // Hot-reload: watch the loaded file ourselves (quickshell only watches its own
    // config tree, not the theme dirs) and bump the ?v= nonce on save to recompile.
    // Rescan too, so adding/removing the widget's `pal` property takes on save.
    FileView {
        path: root.infoPath
        watchChanges: root.infoPath !== ""
        printErrors: false
        onFileChanged: { root.rescan(); root.reloadNonce++ }
    }

    Component.onCompleted: rescan()

    Connections {
        target: ControlBus
        function onThemeReloadRequested() {
            root.reloadNonce++
            root.rescan()
        }
    }
}
