import QtQuick
import QtMultimedia
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
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
    function resolve(img) {
        existProc.command = ["bash", "-c",
            'img="$1"; case "$img" in *.still.png) v="${img%.still.png}.mp4"; ' +
            '[ -f "$v" ] && printf "%s" "$v";; esac; true',
            "_", img]
        existProc.running = true
    }
    function rescan() { resolve(root.activeImg) }
    onActiveImgChanged: rescan()
    Component.onCompleted: rescan()

    Connections {
        target: ControlBus
        function onThemeReloadRequested() { root.rescan() }
        // theme swap: once the old video has bowed out, jump straight to the
        // incoming one so it's buffered and MOVING while still invisible —
        // the reveal exposes a live wallpaper, not a still that starts late.
        // ActiveTheme's requery lands later and just re-confirms this path.
        function onSwappingChanged() { if (ControlBus.swapping) swapJump.restart() }
    }
    Timer {
        id: swapJump
        interval: 160   // just past the 140ms fade-out
        onTriggered: if (ControlBus.swapTarget !== "") root.resolve(ControlBus.swapTarget)
    }

    // a fullscreen window hides the wallpaper completely — don't decode behind it.
    // workspace.active so a fullscreen window parked on another workspace doesn't
    // freeze the visible loop; every miss falls through to false = keep playing.
    readonly property var hyprMon: Hyprland.monitorFor(root.modelData)
    readonly property bool covered: Hyprland.toplevels.values.some(t =>
        t.wayland && t.wayland.fullscreen
        && t.monitor === root.hyprMon
        && t.workspace && t.workspace.active)

    // the lock surfaces cover everything (and play their own copy) — pause behind them
    readonly property bool shouldPlay: root.videoPath !== "" && !ControlBus.sessionLocked && !root.covered
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
        // theme swap: drop to the still underneath so awww's wipe morphs
        // still→still, then the new video — already playing — emerges over
        // its own first frame while the wipe finishes
        opacity: ControlBus.swapping ? 0 : 1
        Behavior on opacity {
            NumberAnimation { duration: ControlBus.swapping ? 140 : 450; easing.type: Easing.OutCubic }
        }
    }
}
