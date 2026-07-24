pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Split mode: one wide monitor cut into two halves that act like two monitors.
// hypr/split-mode.sh owns the hyprland side and mirrors what it did into a
// runtime state file; this just watches that file so the HUD (and anything else
// that cares) can follow along. Same mirror-file idiom as the lyric offset and
// the sysinfo pin — one writer, many readers.
QtObject {
    id: bus

    property bool on: false
    property real ratio: 0.5
    property int seam: 0          // logical px from the monitor's left edge
    property string zone: "l"     // which half owns focus
    property int left: 1          // regular workspace showing in the left half
    property int right: 1         // special:spN showing in the right half
    property int spaces: 5
    property string monitor: ""   // only this screen is split

    readonly property string _dir: Quickshell.env("HOME") + "/dotfiles/.config/hypr"

    function toggle() { Quickshell.execDetached([bus._dir + "/split-mode.sh", "toggle"]) }
    function set(v) { Quickshell.execDetached([bus._dir + "/split-mode.sh", v ? "on" : "off"]) }
    function nudgeRatio(d) { Quickshell.execDetached([bus._dir + "/split-mode.sh", "ratio", d > 0 ? "+" : "-"]) }

    function _parse(t) {
        try {
            const s = JSON.parse(t)
            bus.on = !!s.on
            bus.ratio = s.ratio ?? 0.5
            bus.seam = s.seam ?? 0
            bus.zone = s.zone ?? "l"
            bus.left = s.left ?? 1
            bus.right = s.right ?? 1
            bus.spaces = s.spaces ?? 5
            bus.monitor = s.monitor ?? ""
        } catch (e) {
            bus.on = false
        }
    }

    property FileView _file: FileView {
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/world80-split"
        watchChanges: true
        blockLoading: true
        preload: true
        printErrors: false
        onLoaded: bus._parse(text())
        onFileChanged: reload()
    }
}
