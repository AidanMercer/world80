import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import "../common"

// Per-monitor desktop clock that belongs to the *active theme*, not to the bar.
//
// Each theme folder (~/.config/themes/<name>/) may drop a clock.qml next to its
// wallpaper. This window asks awww which wallpaper the monitor is currently
// showing, walks up to that theme folder, and loads its clock.qml if present.
// No clock.qml → nothing renders. Swap the wallpaper and the clock swaps with it.
//
// It sits on the Bottom layer (above the wallpaper, below real windows) and is
// fully click-through, so it reads as part of the desktop.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-themeclock"
    WlrLayershell.layer: WlrLayer.Bottom

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}                         // click-through: it's just scenery
    visible: clockPath !== "" && slotOn

    property string themeDir: ActiveTheme.dirFor(root.modelData ? root.modelData.name : "")
    // per-theme toggle (Super+Shift+/ → Settings); flipping it mounts/unmounts live
    readonly property bool slotOn: ThemeSettings.on(root.themeDir, "clock")
    onSlotOnChanged: remount()
    property string clockPath: ""
    property bool wantsPal: false               // widget declares `property var pal`
    property int reloadNonce: 0

    property ThemePalette pal: ThemePalette { themeDir: root.themeDir }

    // Encode each segment so theme names with spaces ("your name") survive.
    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // ActiveTheme already knows this monitor's theme folder (one shared awww query);
    // we just confirm it ships a clock.qml. Re-runs when the folder changes (theme
    // switch) or a hot-reload is forced.
    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const changed = parts[0] !== root.clockPath || (parts.length > 1) !== root.wantsPal
                root.wantsPal = parts.length > 1
                root.clockPath = parts[0]
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
            'd="$1"; f="$d/clock.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; ' +
            'printf "%s" "$f"; grep -q "property var pal" "$f" && printf "\\tPAL"; true',
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

    // The lock or a fullscreen window hides the desktop entirely (same rule as
    // VideoWall). Widgets that declare `property bool occluded` get told, so
    // their loops:Infinite animations can stop keeping the render loop awake.
    readonly property var hyprMon: Hyprland.monitorFor(root.modelData)
    readonly property bool occluded: ControlBus.sessionLocked
        || Hyprland.toplevels.values.some(t =>
            t.wayland && t.wayland.fullscreen
            && t.monitor === root.hyprMon
            && t.workspace && t.workspace.active)
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
        if (root.clockPath === "" || !root.slotOn) { widgetLoader.source = ""; return }
        const url = root.fileUrl(root.clockPath) + "?v=" + root.reloadNonce
        widgetLoader.setSource(url, root.wantsPal ? { pal: root.pal } : {})
    }
    onReloadNonceChanged: remount()

    // Hot-reload: watch the loaded file ourselves (quickshell only watches its own
    // config tree, not the theme dirs) and bump the ?v= nonce on save to recompile.
    // Rescan too, so adding/removing the widget's `pal` property takes on save.
    FileView {
        path: root.clockPath
        watchChanges: root.clockPath !== ""
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
