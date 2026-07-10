import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// Per-monitor desktop lyric visualizer owned by the *active theme*.
//
// Same idea as ThemeClock / ThemeSysInfo: each theme folder
// (~/.config/themes/<name>/) may drop a lyrics.qml next to its wallpaper. This
// window asks awww which wallpaper the monitor is showing, walks up to that
// theme folder, and loads its lyrics.qml if present. No lyrics.qml → nothing
// renders. Swap the wallpaper and it swaps too — so to give a future theme
// lyrics you just drop a lyrics.qml in its folder, nothing here changes.
//
// The heavy lifting (MPRIS clock, fetch, word timing, silence detection) lives
// in LyricsEngine — one per window, injected into the theme widget as `engine`
// when the file declares `property var engine` (same grep handshake as `pal`),
// and only running while such a widget is loaded. Theme lyrics.qml files are
// styling only; a fully self-contained widget that declares neither still works.
//
// Bottom layer (above wallpaper, below windows), fully click-through scenery.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-themelyrics"
    WlrLayershell.layer: WlrLayer.Bottom

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}
    visible: lyricsPath !== "" && slotOn

    property string themeDir: ActiveTheme.dirFor(root.modelData ? root.modelData.name : "")
    // per-theme toggle (Super+Shift+/ → Settings); also parks the engine so a
    // disabled lyrics widget stops fetching/polling entirely
    readonly property bool slotOn: ThemeSettings.on(root.themeDir, "lyrics")
    onSlotOnChanged: remount()
    property string lyricsPath: ""
    property bool wantsPal: false               // widget declares `property var pal`
    property bool wantsEngine: false            // widget declares `property var engine`
    property int reloadNonce: 0

    property ThemePalette pal: ThemePalette { themeDir: root.themeDir }

    // Only ONE instance (the primary screen) should run singletons like the cava
    // silence-detector; the renderer/clock are fine per-screen. lyrics.qml defaults
    // isPrimary=false and we forward the real value onto it once it loads.
    readonly property bool isPrimary:
        Quickshell.screens.length > 0 && root.modelData === Quickshell.screens[0]

    // the engine only spends cycles (timers, cava, fetches) while a widget that
    // wants it is actually loaded; a theme without lyrics costs nothing
    property LyricsEngine engine: LyricsEngine {
        isPrimary: root.isPrimary
        active: root.lyricsPath !== "" && root.wantsEngine && root.slotOn
    }

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // ActiveTheme already knows this monitor's theme folder (one shared awww query);
    // we just confirm it ships a lyrics.qml. Re-runs when the folder changes (theme
    // switch) or a hot-reload is forced.
    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const pal = parts.indexOf("PAL") > 0
                const eng = parts.indexOf("ENGINE") > 0
                const changed = parts[0] !== root.lyricsPath
                    || pal !== root.wantsPal || eng !== root.wantsEngine
                root.wantsPal = pal
                root.wantsEngine = eng
                root.lyricsPath = parts[0]
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
            'd="$1"; f="$d/lyrics.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; ' +
            'printf "%s" "$f"; grep -q "property var pal" "$f" && printf "\\tPAL"; ' +
            'grep -q "property var engine" "$f" && printf "\\tENGINE"; true',
            "_", root.themeDir]
        existProc.running = true
    }
    onThemeDirChanged: rescan()

    Loader {
        id: lyricsLoader
        anchors.fill: parent
        onLoaded: if (item && item.hasOwnProperty("isPrimary")) item.isPrimary = root.isPrimary
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
    // setSource instead of a source binding so the widget gets `pal`/`engine` as
    // initial properties — its bindings never see them undefined. Called from the
    // exist-check collector (path/flags answer changed) and on nonce bumps.
    function remount() {
        if (root.lyricsPath === "" || !root.slotOn) { lyricsLoader.source = ""; return }
        engine.resetTuning()   // one theme's pacing tweak can't leak into the next
        const url = root.fileUrl(root.lyricsPath) + "?v=" + root.reloadNonce
        let props = {}
        if (root.wantsPal) props.pal = root.pal
        if (root.wantsEngine) props.engine = root.engine
        lyricsLoader.setSource(url, props)
    }
    onReloadNonceChanged: remount()

    // Hot-reload: watch the loaded file ourselves (quickshell only watches its own
    // config tree, not the theme dirs) and bump the ?v= nonce on save to recompile.
    // Rescan too, so adding/removing the widget's `pal` property takes on save.
    FileView {
        path: root.lyricsPath
        watchChanges: root.lyricsPath !== ""
        printErrors: false
        onFileChanged: { root.rescan(); root.reloadNonce++ }
    }
    // keep it correct if the screen list reorders after load
    onIsPrimaryChanged: if (lyricsLoader.item && lyricsLoader.item.hasOwnProperty("isPrimary"))
                            lyricsLoader.item.isPrimary = root.isPrimary

    Component.onCompleted: rescan()

    Connections {
        target: ControlBus
        function onThemeReloadRequested() {
            root.reloadNonce++
            root.rescan()
        }
    }
}
