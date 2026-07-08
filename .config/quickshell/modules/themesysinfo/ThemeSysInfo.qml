import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// Per-monitor desktop system-info widget owned by the *active theme*.
//
// Same idea as ThemeClock: each theme folder (~/.config/themes/<name>/) may drop
// a sysinfo.qml next to its wallpaper. This window asks awww which wallpaper the
// monitor is showing, walks up to that theme folder, and loads its sysinfo.qml if
// present. No sysinfo.qml → nothing renders. Swap the wallpaper and it swaps too.
//
// Overlay layer (above every window, not just the wallpaper) so the readout
// stays visible over whatever you're working in — still fully click-through
// scenery (empty input mask), so it never steals a click from the window under it.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-themesysinfo"
    WlrLayershell.layer: WlrLayer.Overlay

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}
    visible: infoPath !== ""

    property string themeDir: ActiveTheme.dirFor(root.modelData ? root.modelData.name : "")
    property string infoPath: ""
    property bool wantsPal: false               // widget declares `property var pal`
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
                const changed = parts[0] !== root.infoPath || (parts.length > 1) !== root.wantsPal
                root.wantsPal = parts.length > 1
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
            'printf "%s" "$f"; grep -q "property var pal" "$f" && printf "\\tPAL"; true',
            "_", root.themeDir]
        existProc.running = true
    }
    onThemeDirChanged: rescan()

    Loader {
        id: widgetLoader
        anchors.fill: parent
    }
    // setSource instead of a source binding so the widget gets `pal` as an
    // initial property — its bindings never see pal undefined. Called from the
    // exist-check collector (path/pal answer changed) and on nonce bumps.
    function remount() {
        if (root.infoPath === "") { widgetLoader.source = ""; return }
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
