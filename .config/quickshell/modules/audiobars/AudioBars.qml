import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// A cava-style audio spectrum pinned to the right edge of the screen. We run
// `cava` in raw-ascii mode (see cava.conf) so it streams one line per frame —
// 40 numbers 0..1000 — on stdout; we parse each line and let the bars follow.
//
// The window sits on the Bottom layer — above the wallpaper, below your
// windows — and is fully click-through, so it's a passive ambient overlay you
// see in the gaps. Frosting comes from the `blur` layerrule on this namespace
// in hyprland.conf. One per screen via Variants in shell.qml.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    readonly property int barCount: 40
    readonly property int maxLen: 110          // how far the loudest bar reaches, px
    property var levels: []                     // barCount values, each 0..1

    WlrLayershell.namespace: "quickshell-audiobars"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    // Span the full right edge, starting just under the top bar.
    anchors { top: true; right: true; bottom: true }
    margins.top: Theme.barHeight
    implicitWidth: maxLen + 12
    exclusionMode: ExclusionMode.Ignore        // don't reserve space / push windows
    color: "transparent"

    // Empty input region → clicks fall straight through to the window beneath.
    mask: Region {}

    Process {
        id: cava
        running: true
        command: ["cava", "-p", Qt.resolvedUrl("cava.conf").toString().replace("file://", "")]
        // SplitParser hands us one frame at a time (default split marker "\n"),
        // instead of waiting for the stream to end (it never does).
        stdout: SplitParser {
            onRead: line => root.parseFrame(line)
        }
    }

    // blend two colors; t=0 → a, t=1 → b, with an explicit alpha
    function mix(a, b, t, alpha) {
        return Qt.rgba(a.r + (b.r - a.r) * t,
                       a.g + (b.g - a.g) * t,
                       a.b + (b.b - a.b) * t,
                       alpha)
    }

    function parseFrame(line) {
        const parts = line.split(";")
        const out = []
        for (let i = 0; i < parts.length; i++) {
            if (parts[i] === "") continue       // skip the trailing empty after the last ';'
            out.push(Math.min(1, parseInt(parts[i]) / 1000))
        }
        if (out.length) root.levels = out
    }

    Column {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        width: root.maxLen
        height: parent.height

        Repeater {
            model: root.barCount

            Item {
                width: root.maxLen
                height: root.height / root.barCount

                Rectangle {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    height: Math.max(2, parent.height - 3)
                    radius: height / 2
                    // grows left from the edge; never fully vanishes so the strip
                    // keeps a faint baseline at silence
                    width: Math.max(2, level * root.maxLen)
                    Behavior on width { NumberAnimation { duration: 45; easing.type: Easing.OutQuad } }

                    readonly property real level: root.levels[index] || 0
                    // position down the strip, 0 (top) → 1 (bottom)
                    readonly property real t: index / (root.barCount - 1)

                    // theme accent gradient, periwinkle (top) → lavender (bottom),
                    // staying translucent so Hyprland's blur shows through. Louder
                    // bars lift their alpha so the spectrum glows on the beat.
                    color: root.mix(Theme.volGradStart, Theme.volGradEnd, t, 0.32 + level * 0.33)
                    border.color: root.mix(Theme.volGradStart, Theme.volGradEnd, t, 0.45 + level * 0.4)
                    border.width: 1
                }
            }
        }
    }
}
