import QtQuick
import Quickshell.Io
import "../common"

Bubble {
    id: root
    width: netRow.width + 22

    property string connType: "none"
    property string connName: ""

    // Symbols Nerd Font glyphs (codepoints avoid mojibake in source)
    readonly property string iconWifi: String.fromCodePoint(0xF05A9)      // nf-md-wifi
    readonly property string iconEthernet: String.fromCodePoint(0xF0200)  // nf-md-ethernet
    readonly property string iconOffline: String.fromCodePoint(0xF05AA)   // nf-md-wifi_off

    signal popupToggleRequested()

    function refresh() {
        netProc.running = true
    }

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

    Row {
        id: netRow
        anchors.centerIn: parent
        spacing: 6

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.connType === "wifi" ? root.iconWifi
                : root.connType === "ethernet" ? root.iconEthernet
                : root.iconOffline
            color: Theme.textPrimary
            font.family: Theme.icon
            font.pixelSize: 15
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.connType === "wifi" ? root.connName
                : root.connType === "ethernet" ? "Ethernet"
                : "Offline"
            color: Theme.textPrimary
            font.pixelSize: 13
            elide: Text.ElideRight
            width: Math.min(implicitWidth, 140)
        }
    }

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

    MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.popupToggleRequested()
    }
}
