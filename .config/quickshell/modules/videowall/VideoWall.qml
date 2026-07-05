import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// Plays the active theme's wallpaper.mp4 (awww only paints stills — the
// switcher gives awww the theme's still.png and this loops the real video on
// top). Background layer: maps after awww's long-lived surface, so it stacks
// above the still and below all Bottom-layer scenery. Needs working VAAPI or
// a 4K60 loop costs ~1.5 cores (LIBVA_DRIVER_NAME in hyprland env).
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-videowall"
    WlrLayershell.layer: WlrLayer.Background

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}
    visible: videoPath !== ""

    property string themeDir: ActiveTheme.dirFor(root.modelData ? root.modelData.name : "")
    property string videoPath: ""

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: root.videoPath = text.trim()
        }
    }
    // command built at call time, not bound — the one-behind trap (see ThemeClock)
    function rescan() {
        existProc.command = ["bash", "-c",
            'd="$1"; f="$d/wallpaper.mp4"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; printf "%s" "$f"',
            "_", root.themeDir]
        existProc.running = true
    }
    onThemeDirChanged: rescan()
    Component.onCompleted: rescan()

    Connections {
        target: ControlBus
        function onThemeReloadRequested() { root.rescan() }
    }

    // the lock surfaces cover everything (and play their own copy) — pause behind them
    readonly property bool shouldPlay: root.videoPath !== "" && !ControlBus.sessionLocked
    onShouldPlayChanged: shouldPlay ? player.play() : player.pause()

    MediaPlayer {
        id: player
        source: root.videoPath !== "" ? root.fileUrl(root.videoPath) : ""
        videoOutput: vo
        loops: MediaPlayer.Infinite
        // no AudioOutput attached → the file's audio track never plays
        onSourceChanged: if (root.shouldPlay) play()
        onErrorOccurred: (err, str) => console.warn("videowall:", str)
    }
    VideoOutput {
        id: vo
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
    }
}
