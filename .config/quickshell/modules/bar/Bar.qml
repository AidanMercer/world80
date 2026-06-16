import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// Top bar wrapper, owned by the active theme. Reserves the bar's height/exclusive
// zone, then loads either a theme's own bar.qml or the default BarContent. Same
// loader idea as ArchLogo/ThemeClock: a theme folder (~/.config/themes/<name>/)
// may drop a bar.qml next to its wallpaper; no bar.qml → the default bar shows.
//
// The theme's bar.qml is loaded by file path so it can't import the repo modules,
// so it's self-contained — it gets only its Hyprland screen, injected after load.
PanelWindow {
    id: bar
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-bar"

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    color: "transparent"

    property string barPath: ""                  // theme's bar.qml, "" if none
    property bool queryDone: false
    property int retriesLeft: 10

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    Process {
        id: queryProc
        command: ["bash", "-c",
            'name="$1"; ' +
            'line=$(awww query 2>/dev/null | grep -m1 -- "$name:"); ' +
            'img=$(printf "%s" "$line" | sed -n "s/.*image: //p"); ' +
            '[ -n "$img" ] || exit 0; ' +
            'printf "__OK__\\n"; ' +
            'c="$(dirname "$img")/bar.qml"; ' +
            '[ -f "$c" ] && printf "%s" "$c"',
            "_", bar.screen ? bar.screen.name : ""]
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.indexOf("__OK__") === -1) return
                bar.retriesLeft = 0
                bar.queryDone = true
                bar.barPath = (text.split("__OK__")[1] || "").trim()
            }
        }
    }

    // theme's own bar — self-contained, gets its screen injected after load
    Loader {
        id: themeLoader
        anchors.fill: parent
        active: bar.barPath !== ""
        source: bar.barPath !== "" ? bar.fileUrl(bar.barPath) : ""
        onLoaded: if (item) item.barScreen = bar.screen
    }

    // default bar — once we know the theme ships no bar.qml
    Loader {
        anchors.fill: parent
        active: bar.queryDone && bar.barPath === ""
        sourceComponent: defaultContent
    }
    Component {
        id: defaultContent
        BarContent { barWindow: bar }
    }

    Component.onCompleted: queryProc.running = true

    Timer {
        interval: 2000
        repeat: true
        running: !bar.queryDone && bar.retriesLeft > 0
        onTriggered: {
            bar.retriesLeft--
            queryProc.running = true
        }
    }

    Connections {
        target: ControlBus
        function onWallpaperChanged() {
            bar.queryDone = false
            bar.retriesLeft = 10
            queryProc.running = true
        }
    }
}
