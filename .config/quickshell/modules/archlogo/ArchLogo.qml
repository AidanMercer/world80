import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Io
import "../common"

// Centerpiece desktop widget: the audio-reactive logo, owned by the active theme.
//
// Each theme folder (~/.config/themes/<name>/) may drop a cava.qml next to its
// wallpaper. This window asks awww which wallpaper the monitor is showing, walks
// up to that theme folder, and loads its cava.qml if present. No cava.qml → the
// default ArchVisualizer (the Arch triangle) is shown instead. Same loader idea
// as ThemeClock, so a theme can ship both a clock.qml and a cava.qml.
//
// Bottom layer (above wallpaper, below windows) and fully click-through — passive
// scenery. The layer surface and the awww query live here; the loaded visual just
// draws into it.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-archlogo"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}                              // click-through scenery
    visible: slotOn

    property string themeDir: ActiveTheme.dirFor(root.modelData ? root.modelData.name : "")
    // per-theme toggle (Super+Shift+/ → Settings) — covers the theme's cava.qml
    // AND the default Arch triangle; flipping it mounts/unmounts live
    readonly property bool slotOn: ThemeSettings.on(root.themeDir, "cava")
    onSlotOnChanged: remount()
    property string cavaPath: ""                 // theme's cava.qml, "" if none
    property bool checked: false                 // existence check has returned
    property bool wantsPal: false                // widget declares `property var pal`
    property int reloadNonce: 0

    property ThemePalette pal: ThemePalette { themeDir: root.themeDir }

    // Same handshake as ThemeClock/ThemeSysInfo, plus a playing gate: a cava.qml
    // that declares `occluded`/`playing` gets its feed parked while the session is
    // locked, a fullscreen window covers this monitor, or nothing is playing — so
    // no resident cava readers and no repaints behind the lock.
    readonly property var hyprMon: Hyprland.monitorFor(root.modelData)
    readonly property bool occluded: ControlBus.sessionLocked
        || Hyprland.toplevels.values.some(t =>
            t.wayland && t.wayland.fullscreen
            && t.monitor === root.hyprMon
            && t.workspace && t.workspace.active)
    Binding {
        target: themeLoader.item
        property: "occluded"
        value: root.occluded
        when: themeLoader.item !== null && themeLoader.item.hasOwnProperty("occluded")
    }
    Binding {
        target: themeLoader.item
        property: "playing"
        value: AudioBus.playing
        when: themeLoader.item !== null && themeLoader.item.hasOwnProperty("playing")
    }

    // Encode each segment so theme names with spaces ("your name") survive.
    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // ActiveTheme already knows this monitor's theme folder (one shared awww query);
    // we just confirm it ships a cava.qml. `checked` flips once the answer is in, so
    // the default Arch visualizer only appears after we know there's no theme cava.
    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const changed = parts[0] !== root.cavaPath || (parts.length > 1) !== root.wantsPal
                root.wantsPal = parts.length > 1
                root.cavaPath = parts[0]
                root.checked = true
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
            'd="$1"; f="$d/cava.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; ' +
            'printf "%s" "$f"; grep -q "property var pal" "$f" && printf "\\tPAL"; true',
            "_", root.themeDir]
        existProc.running = true
    }
    onThemeDirChanged: { root.checked = false; rescan() }

    // theme's own visualizer
    Loader {
        id: themeLoader
        anchors.fill: parent
    }
    // setSource instead of a source binding so the widget gets `pal` as an
    // initial property — its bindings never see pal undefined. Called from the
    // exist-check collector (path/pal answer changed) and on nonce bumps.
    function remount() {
        if (root.cavaPath === "" || !root.slotOn) { themeLoader.source = ""; return }
        const url = root.fileUrl(root.cavaPath) + "?v=" + root.reloadNonce
        themeLoader.setSource(url, root.wantsPal ? { pal: root.pal } : {})
    }
    onReloadNonceChanged: remount()

    // Hot-reload: watch the loaded file ourselves (quickshell only watches its own
    // config tree, not the theme dirs) and bump the ?v= nonce on save to recompile.
    // Rescan too, so adding/removing the widget's `pal` property takes on save.
    FileView {
        path: root.cavaPath
        watchChanges: root.cavaPath !== ""
        printErrors: false
        onFileChanged: { root.rescan(); root.reloadNonce++ }
    }

    // default Arch visualizer — once we know the theme ships no cava.qml.
    // themeDir "" means no wallpaper yet (normal mid-boot now that the daemon
    // starts empty) — mount nothing, or the triangle flashes at the reveal
    // before the restored theme's cava takes over.
    Loader {
        anchors.fill: parent
        active: root.checked && root.themeDir !== "" && root.cavaPath === "" && root.slotOn
        sourceComponent: archComponent
    }
    Component {
        id: archComponent
        ArchVisualizer { occluded: root.occluded; playing: AudioBus.playing }
    }

    Component.onCompleted: rescan()

    Connections {
        target: ControlBus
        function onThemeReloadRequested() {
            root.reloadNonce++
            root.checked = false
            root.rescan()
        }
    }
}
