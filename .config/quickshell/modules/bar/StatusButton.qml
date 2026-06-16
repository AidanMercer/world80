import QtQuick
import QtQuick.Effects
import Quickshell.Io
import "../common"

// The single status button: a bare Arch glyph that sits just right of the
// workspaces. Clicking it opens the ControlPopup (network / sound / bluetooth /
// power). It shows only the Arch glyph, but it is the persistent owner of two
// bits of state the popup displays:
//   • the uptime readout (shown in the popup header), and
//   • the polled network status (shown in the popup's Network tab).
// Keeping these here means they stay live whether or not the popup is open,
// exactly like the old always-on bubbles did.
Item {
    id: root
    width: Theme.bubbleHeight
    height: Theme.bubbleHeight

    property bool active: false
    signal popupToggleRequested()

    readonly property string iconArch: String.fromCodePoint(0xF303) // nf-linux-archlinux

    // ── uptime state: read from /proc/uptime, advanced locally each second ──
    property real seconds: 0
    readonly property string uptimeText: "up " + formatUptime(seconds)

    function formatUptime(s) {
        const total = Math.floor(s)
        const d = Math.floor(total / 86400)
        const h = Math.floor((total % 86400) / 3600)
        const m = Math.floor((total % 3600) / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }

    // ── network state: polled; consumed by the popup's Network tab ──
    property string connType: "none"   // "wifi" | "ethernet" | "none"
    property string connName: ""

    function refresh() { netProc.running = true }

    function parseNm(raw) {
        let nextType = "none"
        let nextName = ""
        for (const line of raw.trim().split("\n")) {
            if (!line) continue
            const parts = line.split(":")
            const type = parts[0]
            const state = parts[1]
            const name = parts.slice(2).join(":")
            if (type === "loopback") continue
            if (state !== "connected") continue
            if (type === "wifi") {
                nextType = "wifi"
                nextName = name
                break
            }
            if (type === "ethernet" && nextType === "none") {
                nextType = "ethernet"
                nextName = name
            }
        }
        connType = nextType
        connName = nextName
    }

    // Brighten the glyph while the popup is open or the button is hovered.
    Text {
        anchors.centerIn: parent
        text: root.iconArch
        color: Theme.accent
        font.family: Theme.icon
        font.pixelSize: 15
        opacity: root.active || ma.containsMouse ? 1.0 : 0.75
        Behavior on opacity { NumberAnimation { duration: 150 } }

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Theme.textShadow
            shadowBlur: 0.6
            shadowVerticalOffset: 0
            shadowHorizontalOffset: 0
        }
    }

    MouseArea {
        id: ma
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.popupToggleRequested()
    }

    // ── uptime: read once, tick every second, re-sync periodically to correct
    //    drift (e.g. after the machine suspends) ──
    Process {
        id: uptimeProc
        command: ["cat", "/proc/uptime"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const first = parseFloat(text.trim().split(/\s+/)[0])
                if (!isNaN(first)) root.seconds = first
            }
        }
    }

    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.seconds += 1 }
    Timer { interval: 300000; running: true; repeat: true; onTriggered: uptimeProc.running = true }

    // ── network: lightweight status poll feeding the Network tab ──
    Process {
        id: netProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device", "status"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.parseNm(text)
        }
    }

    Timer {
        interval: 5000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: netProc.running = true
    }
}
