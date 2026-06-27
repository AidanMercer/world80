import QtQuick
import Quickshell.Io
import "../common"

// Network tab: shows the active connection and a scannable wifi list.
// `connType`/`connName` are fed in from StatusButton (the always-on poll);
// the wifi rescan only runs while `active` (this tab visible + popup open) to
// avoid burning radio scans in the background.
//
// The wifi list is a fixed-height ListView so the tab (and therefore the
// popup) stays the same size no matter how many networks are in range — you
// scroll the list instead of growing the window.
Item {
    id: root
    implicitHeight: col.implicitHeight

    property string connType: "none"
    property string connName: ""
    property bool active: false
    property var networks: []
    property var savedConns: []

    // inline password entry: when pendingSsid is set the password field is
    // shown for that network (a new secured one we don't have saved yet).
    property string pendingSsid: ""
    property bool connecting: false
    property bool authFailed: false

    // height of the scrollable wifi area (≈ 5 rows); keep this constant
    readonly property int listHeight: 172

    signal connectionChanged()
    signal returnFocus()

    // Keyboard navigation, driven by ControlPopup's Up/Down/Enter. navIndex
    // highlights a wifi row (-1 = none); activateNav connects to it. Keep the
    // highlighted row scrolled into view as it moves through the fixed-height
    // list. (navIndex is positional, so a background rescan that re-sorts the
    // list can shift which network is highlighted — acceptable for a brief popup.)
    property int navIndex: -1
    readonly property int navCount: networks.length
    function activateNav() { connectTo(networks[navIndex].ssid) }
    onNavIndexChanged: if (navIndex >= 0) list.positionViewAtIndex(navIndex, ListView.Contain)

    onActiveChanged: {
        if (active) { wifiListProc.running = true; savedProc.running = true }
        else cancelPassword()
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

    function isSecured(net) {
        return net && net.security && net.security !== "" && net.security !== "--"
    }

    // open or already-saved networks connect on one click; a new secured one
    // drops into the inline password field instead of failing silently.
    function connectTo(ssid) {
        const net = networks.find(n => n.ssid === ssid)
        if (isSecured(net) && savedConns.indexOf(ssid) < 0) {
            pendingSsid = ssid
            authFailed = false
            pwInput.text = ""
            Qt.callLater(pwInput.forceActiveFocus)
        } else {
            runConnect(ssid, "")
        }
    }

    function runConnect(ssid, password) {
        let cmd = ["nmcli", "device", "wifi", "connect", ssid]
        if (password) cmd = cmd.concat(["password", password])
        wifiConnectProc.command = cmd
        connecting = true
        wifiConnectProc.running = true
    }

    function submitPassword() {
        if (!pwInput.text) return
        runConnect(pendingSsid, pwInput.text)
    }

    function cancelPassword() {
        pendingSsid = ""
        pwInput.text = ""
        authFailed = false
        connecting = false
        root.returnFocus()
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
        onExited: (code, status) => {
            connecting = false
            if (code === 0) {
                pendingSsid = ""
                pwInput.text = ""
                root.returnFocus()
            } else if (pendingSsid) {
                // nmcli exited non-zero while a password was pending — almost
                // always a bad passphrase. keep the field up so they can retry.
                authFailed = true
            }
            wifiListProc.running = true
            root.connectionChanged()
        }
    }

    Process {
        id: savedProc
        command: ["nmcli", "-t", "-f", "NAME", "connection", "show"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.savedConns = text.trim().split("\n").filter(s => s.length > 0)
        }
    }

    Timer {
        interval: 4000
        running: root.active
        repeat: true
        onTriggered: wifiListProc.running = true
    }

    Column {
        id: col
        width: parent.width
        spacing: 10

        // ── active connection ──
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

        // ── WIFI section header ──
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

        // ── fixed-height scrollable wifi list ──
        Item {
            width: parent.width
            height: root.listHeight

            ListView {
                id: list
                anchors.fill: parent
                clip: true
                spacing: 2
                model: root.networks
                boundsBehavior: Flickable.StopAtBounds

                delegate: Rectangle {
                    id: netRow
                    required property var modelData
                    required property int index
                    readonly property bool navSelected: root.navIndex === index
                    width: list.width
                    height: 34
                    radius: 11
                    color: modelData.inUse
                        ? Theme.rowSelected
                        : ((navSelected || netRowMa.containsMouse) ? Theme.rowHover : "transparent")
                    // accent ring marks the keyboard-highlighted row.
                    border.width: navSelected ? 1 : 0
                    border.color: Theme.accent
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
                        anchors.rightMargin: 14
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

            // slim scroll indicator, only when the list overflows
            Rectangle {
                visible: list.contentHeight > list.height
                anchors.right: parent.right
                width: 3
                radius: 1.5
                color: Theme.subtleDivider
                y: list.visibleArea.yPosition * list.height
                height: Math.max(24, list.visibleArea.heightRatio * list.height)
            }

            // empty state, centered in the list area
            Text {
                visible: root.networks.length === 0
                anchors.centerIn: parent
                text: "Scanning…"
                color: Theme.textMuted
                font.pixelSize: 12
                font.italic: true
            }
        }

        // ── inline password entry for a new secured network ──
        Column {
            visible: root.pendingSsid !== ""
            width: parent.width
            spacing: 6

            Text {
                width: parent.width
                text: "Password for " + root.pendingSsid
                color: Theme.textPrimary
                font.pixelSize: 12
                elide: Text.ElideRight
            }

            Rectangle {
                width: parent.width
                height: 34
                radius: 9
                color: Theme.rowHover
                border.width: 1
                border.color: root.authFailed ? "#ff2e6c"
                    : (pwInput.activeFocus ? Theme.accent : Theme.divider)

                TextInput {
                    id: pwInput
                    anchors.left: parent.left
                    anchors.right: showBtn.left
                    anchors.leftMargin: 12
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.textBright
                    font.pixelSize: 13
                    echoMode: showBtn.reveal ? TextInput.Normal : TextInput.Password
                    selectionColor: Theme.accent
                    selectedTextColor: "#1a1a22"
                    clip: true
                    enabled: !root.connecting

                    onTextChanged: root.authFailed = false

                    Keys.onPressed: (e) => {
                        if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                            root.submitPassword(); e.accepted = true
                        } else if (e.key === Qt.Key_Escape) {
                            root.cancelPassword(); e.accepted = true
                        }
                    }

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: root.connecting ? "Connecting…" : "Enter password"
                        color: Theme.textMuted
                        font: pwInput.font
                        visible: pwInput.text.length === 0
                    }
                }

                // show/hide toggle (mdi eye / eye-off)
                Text {
                    id: showBtn
                    property bool reveal: false
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: reveal ? String.fromCodePoint(0xF0209) : String.fromCodePoint(0xF0208)
                    font.family: Theme.icon
                    font.pixelSize: 16
                    color: Theme.textTertiary

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -6
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { showBtn.reveal = !showBtn.reveal; pwInput.forceActiveFocus() }
                    }
                }
            }

            Text {
                visible: root.authFailed
                text: "Wrong password — try again"
                color: "#ff2e6c"
                font.pixelSize: 10
            }
        }

        Text {
            visible: root.pendingSsid === ""
            width: parent.width
            text: "Click to connect. Secured networks ask for a password."
            color: Theme.textMuted
            font.pixelSize: 10
            wrapMode: Text.WordWrap
            topPadding: 4
        }
    }
}
