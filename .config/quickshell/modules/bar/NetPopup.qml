import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

PopupWindow {
    id: root

    property var barWindow
    property real bubbleRight: 0
    property string connType: "none"
    property string connName: ""
    property bool open: false

    signal connectionChanged()

    property var networks: []

    anchor.window: barWindow
    anchor.rect.x: bubbleRight - implicitWidth
    anchor.rect.y: barWindow ? barWindow.implicitHeight + 2 : 0
    implicitWidth: 320
    implicitHeight: netPopupContent.implicitHeight + 24
    visible: open || exitTrans.running
    color: "transparent"

    onOpenChanged: {
        if (open) wifiListProc.running = true
    }

    function splitNm(line) {
        const parts = []
        let cur = ""
        for (let i = 0; i < line.length; i++) {
            if (line[i] === "\\" && line[i + 1] === ":") {
                cur += ":"
                i++
            } else if (line[i] === ":") {
                parts.push(cur)
                cur = ""
            } else {
                cur += line[i]
            }
        }
        parts.push(cur)
        return parts
    }

    function parseWifi(raw) {
        const seen = new Map()
        for (const line of raw.trim().split("\n")) {
            if (!line) continue
            const p = splitNm(line)
            const ssid = p[1]
            if (!ssid) continue
            const sig = parseInt(p[2]) || 0
            if (!seen.has(ssid) || seen.get(ssid).signal < sig) {
                seen.set(ssid, {
                    ssid: ssid,
                    signal: sig,
                    inUse: p[0] === "*",
                    security: p[3] || ""
                })
            }
        }
        networks = Array.from(seen.values()).sort((a, b) => b.signal - a.signal)
    }

    function connectTo(ssid) {
        wifiConnectProc.command = ["nmcli", "device", "wifi", "connect", ssid]
        wifiConnectProc.running = true
    }

    Process {
        id: wifiListProc
        command: ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "auto"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.parseWifi(text)
        }
    }

    Process {
        id: wifiConnectProc
        running: false
        onRunningChanged: {
            if (!running) {
                wifiListProc.running = true
                root.connectionChanged()
            }
        }
    }

    Timer {
        interval: 4000
        running: root.open
        repeat: true
        onTriggered: wifiListProc.running = true
    }

    Item {
        id: morph
        anchors.fill: parent
        opacity: 0
        scale: 0.78
        transformOrigin: Item.TopRight

        states: State {
            name: "shown"
            when: root.open
            PropertyChanges { target: morph; opacity: 1; scale: 1 }
        }

        transitions: [
            Transition {
                to: "shown"
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; duration: 220; easing.type: Easing.OutCubic }
                    SpringAnimation { property: "scale"; spring: 3; damping: 0.32; epsilon: 0.001 }
                }
            },
            Transition {
                id: exitTrans
                from: "shown"
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; duration: 180; easing.type: Easing.InCubic }
                    NumberAnimation { property: "scale"; duration: 180; easing.type: Easing.InCubic }
                }
            }
        ]

        Rectangle {
            anchors.fill: parent
            radius: Theme.popupRadius
            color: Theme.glassBg
            border.color: Theme.glassBorder
            border.width: 1

            Column {
                id: netPopupContent
                anchors.fill: parent
                anchors.margins: 12
                spacing: 10

                Row {
                    width: parent.width
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.connType === "wifi" ? String.fromCodePoint(0xF05A9)
                            : root.connType === "ethernet" ? String.fromCodePoint(0xF0200)
                            : String.fromCodePoint(0xF05AA)
                        font.family: Theme.icon
                        font.pixelSize: 18
                        color: Theme.textPrimary
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.connType === "wifi" ? root.connName
                            : root.connType === "ethernet" ? "Ethernet"
                            : "Disconnected"
                        color: Theme.textBright
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }
                }

                Item {
                    width: parent.width
                    height: 14

                    Text {
                        id: wifiHdr
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: "WIFI"
                        color: Theme.textDim
                        font.pixelSize: 9
                        font.weight: Font.Bold
                        font.letterSpacing: 2
                    }

                    Rectangle {
                        anchors.left: wifiHdr.right
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: 10
                        height: 1
                        color: Theme.divider
                    }
                }

                Text {
                    visible: root.networks.length === 0
                    width: parent.width
                    text: "No networks found"
                    color: Theme.textMuted
                    font.pixelSize: 12
                    font.italic: true
                    horizontalAlignment: Text.AlignHCenter
                }

                Repeater {
                    model: root.networks

                    delegate: Rectangle {
                        id: netRow
                        required property var modelData
                        width: netPopupContent.width
                        height: 34
                        radius: 11
                        color: modelData.inUse
                            ? Theme.rowSelected
                            : (netRowMa.containsMouse ? Theme.rowHover : "transparent")
                        Behavior on color { ColorAnimation { duration: 150 } }

                        Rectangle {
                            id: sigDot
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 8
                            height: 8
                            radius: 4
                            color: netRow.modelData.inUse ? Theme.accent : "transparent"
                            border.width: netRow.modelData.inUse ? 0 : 1
                            border.color: Theme.dotBorder
                            Behavior on color { ColorAnimation { duration: 150 } }
                        }

                        Text {
                            anchors.left: sigDot.right
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: sigBar.left
                            anchors.rightMargin: 10
                            text: netRow.modelData.ssid + (netRow.modelData.security ? "  " + String.fromCodePoint(0xF033E) : "")
                            color: netRow.modelData.inUse ? Theme.textBright : Theme.textTertiary
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }

                        Rectangle {
                            id: sigBar
                            anchors.right: parent.right
                            anchors.rightMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            width: 28
                            height: 4
                            radius: 2
                            color: Theme.trackBg2

                            Rectangle {
                                width: parent.width * (netRow.modelData.signal / 100)
                                height: parent.height
                                radius: 2
                                color: Theme.accent
                            }
                        }

                        MouseArea {
                            id: netRowMa
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.connectTo(netRow.modelData.ssid)
                        }
                    }
                }

                Text {
                    width: parent.width
                    text: "Click to connect (saved or open networks).  Use nmtui for new secured ones."
                    color: Theme.textMuted
                    font.pixelSize: 10
                    wrapMode: Text.WordWrap
                    topPadding: 4
                }
            }
        }
    }
}
