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
// Bottom layer (above wallpaper, below windows), fully click-through scenery.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-themesysinfo"
    WlrLayershell.layer: WlrLayer.Bottom

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}
    visible: infoPath !== ""

    property string infoPath: ""
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
            's="$(dirname "$img")/sysinfo.qml"; ' +
            '[ -f "$s" ] && printf "%s" "$s"',
            "_", root.modelData ? root.modelData.name : ""]
        stdout: StdioCollector {
            onStreamFinished: root.infoPath = text.trim()
        }
    }

    Loader {
        anchors.fill: parent
        active: root.infoPath !== ""
        source: root.infoPath !== "" ? root.fileUrl(root.infoPath) : ""
    }

    Component.onCompleted: queryProc.running = true

    Timer {
        interval: 2000
        repeat: true
        running: root.infoPath === "" && root.retriesLeft > 0
        onTriggered: {
            root.retriesLeft--
            queryProc.running = true
        }
    }

    Connections {
        target: ControlBus
        function onWallpaperChanged() {
            root.retriesLeft = 10
            queryProc.running = true
        }
    }
}
