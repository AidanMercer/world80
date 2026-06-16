pragma Singleton
import QtQuick
import Quickshell.Io

// Per-theme bar settings. Each theme folder (~/.config/themes/<name>/) may drop a
// config.toml next to its wallpaper; we ask awww which wallpaper is showing, walk
// up to that folder and read it. Re-queried on every wallpaper change (shell.qml
// wires ControlBus.wallpaperChanged -> reload).
//
// Recognised keys (flat TOML):
//   bubbles = true | false   # glass pills behind the bar clusters (default: false)
//   accent  = "#rrggbb"      # glow color of the center cava visualizer
QtObject {
    id: root

    property bool bubbles: false
    // default matches Theme.accent; hardcoded here to avoid a singleton import cycle.
    property color accent: "#a8b5e8"
    property int retriesLeft: 10

    function reload() { retriesLeft = 10; queryProc.running = true }

    // The "__OK__" marker tells us awww actually answered (vs. not-painted-yet at
    // login) — only then do we trust the parsed value and stop retrying. A theme
    // with no config.toml just yields the marker alone -> defaults hold.
    function parse(text) {
        if (text.indexOf("__OK__") === -1) return
        retriesLeft = 0
        let b = false
        let a = "#a8b5e8"
        for (const line of text.split("\n")) {
            const m = line.match(/^\s*bubbles\s*=\s*(true|false)\b/i)
            if (m) b = m[1].toLowerCase() === "true"
            const c = line.match(/^\s*accent\s*=\s*["']?(#[0-9a-fA-F]{3,8}|[a-zA-Z]+)["']?/)
            if (c) a = c[1]
        }
        root.bubbles = b
        root.accent = a
    }

    property Process _query: Process {
        id: queryProc
        command: ["bash", "-c",
            'img=$(awww query 2>/dev/null | sed -n "s/.*image: //p" | head -1); ' +
            '[ -n "$img" ] || exit 0; ' +
            'printf "__OK__\\n"; ' +
            'cat "$(dirname "$img")/config.toml" 2>/dev/null']
        stdout: StdioCollector { onStreamFinished: root.parse(text) }
    }

    // awww may not have painted yet at login — keep asking until it answers.
    property Timer _retry: Timer {
        interval: 1500
        repeat: true
        running: root.retriesLeft > 0
        onTriggered: { root.retriesLeft--; queryProc.running = true }
    }

    Component.onCompleted: queryProc.running = true
}
