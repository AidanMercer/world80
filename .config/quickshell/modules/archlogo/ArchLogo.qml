import QtQuick
import Quickshell
import Quickshell.Wayland
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

    property string cavaPath: ""                 // theme's cava.qml, "" if none
    property bool queryDone: false               // awww answered at least once
    property int retriesLeft: 10

    // Encode each segment so theme names with spaces ("your name") survive.
    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // Ask awww what THIS monitor is displaying; the "__OK__" marker proves awww
    // answered (vs. not-painted-yet at login). Anything after it is the theme's
    // cava.qml path, emitted only if the file exists.
    Process {
        id: queryProc
        command: ["bash", "-c",
            'name="$1"; ' +
            'line=$(awww query 2>/dev/null | grep -m1 -- "$name:"); ' +
            'img=$(printf "%s" "$line" | sed -n "s/.*image: //p"); ' +
            '[ -n "$img" ] || exit 0; ' +
            'printf "__OK__\\n"; ' +
            'c="$(dirname "$img")/cava.qml"; ' +
            '[ -f "$c" ] && printf "%s" "$c"',
            "_", root.modelData ? root.modelData.name : ""]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.indexOf("__OK__") === -1) return
                root.retriesLeft = 0
                root.queryDone = true
                root.cavaPath = (text.split("__OK__")[1] || "").trim()
            }
        }
    }

    // theme's own visualizer
    Loader {
        anchors.fill: parent
        active: root.cavaPath !== ""
        source: root.cavaPath !== "" ? root.fileUrl(root.cavaPath) : ""
    }

    // default Arch visualizer — once we know the theme ships no cava.qml
    Loader {
        anchors.fill: parent
        active: root.queryDone && root.cavaPath === ""
        sourceComponent: archComponent
    }
    Component {
        id: archComponent
        ArchVisualizer {}
    }

    Component.onCompleted: queryProc.running = true

    // awww may not have painted this output yet (login, hotplug), so an empty
    // answer isn't final — ask again a few times before giving up.
    Timer {
        interval: 2000
        repeat: true
        running: !root.queryDone && root.retriesLeft > 0
        onTriggered: {
            root.retriesLeft--
            queryProc.running = true
        }
    }

    Connections {
        target: ControlBus
        function onWallpaperChanged() {
            root.queryDone = false
            root.retriesLeft = 10
            queryProc.running = true
        }
    }
}
