pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

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
    property string mode: "off"   // off | split | center

    readonly property string _dir: Quickshell.env("HOME") + "/dotfiles/.config/hypr"

    function toggle() { Quickshell.execDetached([bus._dir + "/split-mode.sh", "toggle"]) }
    function set(v) { Quickshell.execDetached([bus._dir + "/split-mode.sh", v ? "on" : "off"]) }
    function centre() { Quickshell.execDetached([bus._dir + "/split-mode.sh", "center"]) }
    function nudgeRatio(d) { Quickshell.execDetached([bus._dir + "/split-mode.sh", "ratio", d > 0 ? "+" : "-"]) }

    // the writers truncate before writing, so a read can land on an empty or
    // half-written file. hold the last good values instead of reading that as
    // "not split", which made the seam blink on every switch.
    function _parse(t) {
        if (!t || !t.trim()) return
        let s
        try {
            s = JSON.parse(t)
        } catch (e) {
            return
        }
        bus.on = !!s.on
        bus.ratio = s.ratio ?? 0.5
        bus.seam = s.seam ?? 0
        bus.zone = s.zone ?? "l"
        bus.left = s.left ?? 1
        bus.right = s.right ?? 1
        bus.spaces = s.spaces ?? 5
        bus.monitor = s.monitor ?? ""
        bus.mode = s.mode ?? (s.on ? "split" : "off")
    }

    // While a special workspace is open, hyprland won't drop focus onto an empty
    // regular workspace — it leaves it on whatever you were last in. Step the left
    // half to an empty space and focus is still back on the old one, so the first
    // window you open there doesn't take focus and the view snaps back to where
    // focus actually is. Hand the new window the focus it should have had.
    property Connections _hypr: Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (!bus.on || event.name !== "openwindow")
                return
            const parts = String(event.data).split(",")
            if (parts.length < 2)
                return
            const here = bus.zone === "r" ? "special:sp" + bus.right : String(bus.left)
            if (parts[1] === here)
                Hyprland.dispatch("focuswindow address:0x" + parts[0])
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
