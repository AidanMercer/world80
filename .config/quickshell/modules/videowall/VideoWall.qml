import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// Plays the active video wallpaper (awww only paints stills — the switcher
// gives awww the video's extracted <name>.still.png and this loops the real
// video on top). A theme can ship several wallpaper*.mp4 variants; whichever
// still awww is holding names the video to play. Background layer: maps after
// awww's long-lived surface, so it stacks above the still and below all
// Bottom-layer scenery. Needs working VAAPI or a 4K60 loop costs ~1.5 cores
// (LIBVA_DRIVER_NAME in hyprland env).
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

    property string activeImg: ActiveTheme.imgFor(root.modelData ? root.modelData.name : "")
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
            'img="$1"; case "$img" in *.still.png) v="${img%.still.png}.mp4"; ' +
            '[ -f "$v" ] && printf "%s" "$v";; esac; true',
            "_", root.activeImg]
        existProc.running = true
    }
    onActiveImgChanged: rescan()
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
