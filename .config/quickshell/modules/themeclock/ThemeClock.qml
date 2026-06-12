import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
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
    visible: clockPath !== ""

    property string clockPath: ""

    // Encode each segment so theme names with spaces ("your name") survive.
    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // Ask awww what THIS monitor is displaying, then emit the theme's clock.qml
    // path iff it exists. sed grabs everything after "image: " (the path).
    Process {
        id: queryProc
        command: ["bash", "-c",
            'name="$1"; ' +
            'line=$(awww query 2>/dev/null | grep -m1 -- "$name:"); ' +
            'img=$(printf "%s" "$line" | sed -n "s/.*image: //p"); ' +
            '[ -n "$img" ] || exit 0; ' +
            'c="$(dirname "$img")/clock.qml"; ' +
            '[ -f "$c" ] && printf "%s" "$c"',
            "_", root.modelData ? root.modelData.name : ""]
        stdout: StdioCollector {
            onStreamFinished: root.clockPath = text.trim()
        }
    }

    Loader {
        anchors.fill: parent
        active: root.clockPath !== ""
        source: root.clockPath !== "" ? root.fileUrl(root.clockPath) : ""
    }

    Component.onCompleted: queryProc.running = true

    Connections {
        target: ControlBus
        function onWallpaperChanged() { queryProc.running = true }
    }
}
