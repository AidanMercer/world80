import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import Quickshell.Io

ShellRoot {
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData
            screen: modelData

            WlrLayershell.namespace: "quickshell-bar"

            anchors {
                top: true
                left: true
                right: true
            }
            implicitHeight: 44
            color: "transparent"

            component Bubble: Rectangle {
                height: 32
                radius: 16
                color: Qt.rgba(0.1, 0.1, 0.14, 0.22)
                border.color: Qt.rgba(1, 1, 1, 0.18)
                border.width: 1
            }

            component SpeakerIcon: Canvas {
                id: speaker
                width: 16
                height: 12

                property color iconColor: "#e6e6f0"
                property bool muted: false
                property real level: 1.0

                onIconColorChanged: requestPaint()
                onMutedChanged: requestPaint()
                onLevelChanged: requestPaint()
                Component.onCompleted: requestPaint()

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.clearRect(0, 0, width, height)
                    ctx.fillStyle = iconColor
                    ctx.strokeStyle = iconColor
                    ctx.lineWidth = 1.4
                    ctx.lineCap = "round"

                    ctx.beginPath()
                    ctx.moveTo(0.5, 4.5)
                    ctx.lineTo(3, 4.5)
                    ctx.lineTo(7, 0.5)
                    ctx.lineTo(7, 11.5)
                    ctx.lineTo(3, 7.5)
                    ctx.lineTo(0.5, 7.5)
                    ctx.closePath()
                    ctx.fill()

                    if (muted) {
                        ctx.beginPath()
                        ctx.moveTo(10, 3)
                        ctx.lineTo(15, 9)
                        ctx.moveTo(15, 3)
                        ctx.lineTo(10, 9)
                        ctx.stroke()
                    } else {
                        const cx = 7.5, cy = 6
                        const a0 = -Math.PI / 3.5, a1 = Math.PI / 3.5
                        if (level > 0) {
                            ctx.beginPath()
                            ctx.arc(cx, cy, 3, a0, a1)
                            ctx.stroke()
                        }
                        if (level > 0.5) {
                            ctx.beginPath()
                            ctx.arc(cx, cy, 5.5, a0, a1)
                            ctx.stroke()
                        }
                    }
                }
            }

            Bubble {
                id: dateBubble
                anchors.left: parent.left
                anchors.leftMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: dateRow.width + 24

                Row {
                    id: dateRow
                    anchors.centerIn: parent
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(clock.date, "HH:mm")
                        color: "#e6e6f0"
                        font.pixelSize: 14
                        font.family: "monospace"
                        font.weight: Font.Medium
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 1
                        height: 14
                        color: Qt.rgba(1, 1, 1, 0.15)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(clock.date, "ddd, MMM d")
                        color: "#a8a8b8"
                        font.pixelSize: 13
                    }
                }
            }

            Bubble {
                id: wsBubble
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: wsRow.width + 10

                readonly property int wsPerPage: 5
                readonly property int focusedWsId: Hyprland.focusedWorkspace?.id ?? 1
                readonly property int wsPageStart: Math.floor((focusedWsId - 1) / wsPerPage) * wsPerPage + 1
                readonly property int activeIndex: focusedWsId - wsPageStart
                readonly property int pillWidth: 26
                readonly property int pillSpacing: 4

                Rectangle {
                    id: activeIndicator
                    width: wsBubble.pillWidth
                    height: 22
                    radius: 11
                    anchors.verticalCenter: parent.verticalCenter
                    x: wsRow.x + wsBubble.activeIndex * (wsBubble.pillWidth + wsBubble.pillSpacing)
                    color: Qt.rgba(0.1, 0.1, 0.14, 0.22)
                    border.color: Qt.rgba(1, 1, 1, 0.18)
                    border.width: 1

                    Behavior on x {
                        SpringAnimation { spring: 2.6; damping: 0.28; epsilon: 0.1 }
                    }
                }

                Row {
                    id: wsRow
                    anchors.centerIn: parent
                    spacing: wsBubble.pillSpacing

                    Repeater {
                        model: wsBubble.wsPerPage

                        delegate: Rectangle {
                            id: wsItem
                            required property int index
                            readonly property int wsId: wsBubble.wsPageStart + index
                            readonly property bool isActive: Hyprland.focusedWorkspace?.id === wsId
                            readonly property bool isOccupied: Hyprland.workspaces.values.some(ws => ws.id === wsId)

                            width: wsBubble.pillWidth
                            height: 22
                            radius: 11
                            color: !isActive && isOccupied
                                ? Qt.rgba(1, 1, 1, 0.08)
                                : "transparent"

                            Behavior on color { ColorAnimation { duration: 200 } }

                            Text {
                                anchors.centerIn: parent
                                text: wsItem.wsId
                                color: wsItem.isActive
                                    ? "#ffffff"
                                    : (wsItem.isOccupied ? "#e6e6f0" : "#6a6a78")
                                font.pixelSize: 11
                                font.weight: Font.Bold

                                Behavior on color { ColorAnimation { duration: 200 } }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Hyprland.dispatch(`workspace ${wsItem.wsId}`)
                            }
                        }
                    }
                }
            }

            Bubble {
                id: netBubble
                anchors.right: audioBubble.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: netRow.width + 22

                // "wifi" | "ethernet" | "none"
                property string connType: "none"
                property string connName: ""

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
                        text: netBubble.connType === "wifi" ? "📶"
                            : netBubble.connType === "ethernet" ? "🌐"
                            : "📡"
                        color: "#e6e6f0"
                        font.pixelSize: 13
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: netBubble.connType === "wifi" ? netBubble.connName
                            : netBubble.connType === "ethernet" ? "Ethernet"
                            : "Offline"
                        color: "#e6e6f0"
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
                        onStreamFinished: netBubble.parseNm(text)
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
                    onClicked: netPopup.open = !netPopup.open
                }
            }

            Bubble {
                id: audioBubble
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: audioRow.width + 22

                readonly property var sink: Pipewire.defaultAudioSink
                readonly property real vol: sink?.audio?.volume ?? 0
                readonly property bool muted: sink?.audio?.muted ?? false
                readonly property int volPercent: Math.round(vol * 100)

                Row {
                    id: audioRow
                    anchors.centerIn: parent
                    spacing: 6

                    SpeakerIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        iconColor: "#e6e6f0"
                        muted: audioBubble.muted
                        level: audioBubble.vol
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: audioBubble.volPercent + "%"
                        color: "#e6e6f0"
                        font.pixelSize: 13
                        font.family: "monospace"
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton

                    onClicked: function(mouse) {
                        if (mouse.button === Qt.RightButton) {
                            if (audioBubble.sink) audioBubble.sink.audio.muted = !audioBubble.sink.audio.muted
                        } else {
                            audioPopup.open = !audioPopup.open
                        }
                    }

                    onWheel: function(wheel) {
                        if (!audioBubble.sink) return
                        const step = 0.05
                        const cur = audioBubble.sink.audio.volume
                        audioBubble.sink.audio.volume = wheel.angleDelta.y > 0
                            ? Math.min(1, cur + step)
                            : Math.max(0, cur - step)
                    }
                }
            }

            HyprlandFocusGrab {
                windows: [audioPopup]
                active: audioPopup.open
                onCleared: audioPopup.open = false
            }

            HyprlandFocusGrab {
                windows: [netPopup]
                active: netPopup.open
                onCleared: netPopup.open = false
            }

            PopupWindow {
                id: audioPopup
                anchor.window: bar
                anchor.rect.x: bar.width - implicitWidth - 10
                anchor.rect.y: bar.implicitHeight + 4
                implicitWidth: 320
                implicitHeight: popupContent.implicitHeight + 32
                property bool open: false
                visible: open || audioExitTrans.running
                color: "transparent"

                Item {
                    id: audioMorph
                    anchors.fill: parent
                    opacity: 0
                    scale: 0.78
                    transformOrigin: Item.TopRight

                    states: State {
                        name: "shown"
                        when: audioPopup.open
                        PropertyChanges { target: audioMorph; opacity: 1; scale: 1 }
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
                            id: audioExitTrans
                            from: "shown"
                            ParallelAnimation {
                                NumberAnimation { property: "opacity"; duration: 180; easing.type: Easing.InCubic }
                                NumberAnimation { property: "scale"; duration: 180; easing.type: Easing.InCubic }
                            }
                        }
                    ]

                Rectangle {
                    anchors.fill: parent
                    radius: 20
                    color: Qt.rgba(0.10, 0.10, 0.14, 0.22)
                    border.color: Qt.rgba(1, 1, 1, 0.18)
                    border.width: 1

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.leftMargin: parent.radius
                        anchors.rightMargin: parent.radius
                        anchors.topMargin: 1
                        height: 1
                        color: Qt.rgba(1, 1, 1, 0.10)
                    }

                    Column {
                        id: popupContent
                        anchors.fill: parent
                        anchors.margins: 16
                        spacing: 14

                        Item {
                            width: parent.width
                            height: 32

                            SpeakerIcon {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: 22
                                height: 17
                                iconColor: audioBubble.muted ? "#777" : "#ffffff"
                                muted: audioBubble.muted
                                level: audioBubble.vol

                                Behavior on iconColor { ColorAnimation { duration: 200 } }
                            }

                            Text {
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: audioBubble.volPercent + "%"
                                color: audioBubble.muted ? "#777" : "#ffffff"
                                font.pixelSize: 24
                                font.family: "monospace"
                                font.weight: Font.Light

                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                        }

                        Item {
                            id: volSlider
                            width: parent.width
                            height: 18

                            readonly property real fillWidth: track.width * audioBubble.vol

                            Rectangle {
                                id: track
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.right: parent.right
                                height: 6
                                radius: 3
                                color: Qt.rgba(1, 1, 1, 0.08)

                                Rectangle {
                                    width: volSlider.fillWidth
                                    height: parent.height
                                    radius: 3
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0; color: audioBubble.muted ? "#555" : "#8a99e8" }
                                        GradientStop { position: 1; color: audioBubble.muted ? "#666" : "#c8a5e8" }
                                    }
                                }
                            }

                            Rectangle {
                                id: thumb
                                x: volSlider.fillWidth - width / 2
                                anchors.verticalCenter: parent.verticalCenter
                                width: 14
                                height: 14
                                radius: 7
                                color: "#ffffff"
                                border.color: Qt.rgba(0, 0, 0, 0.25)
                                border.width: 1
                                scale: sliderMa.pressed ? 1.15 : 1.0

                                Behavior on scale {
                                    NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
                                }
                            }

                            MouseArea {
                                id: sliderMa
                                anchors.fill: parent
                                anchors.topMargin: -6
                                anchors.bottomMargin: -6
                                cursorShape: Qt.PointingHandCursor
                                onPressed: (m) => setVol(m.x)
                                onPositionChanged: (m) => { if (pressed) setVol(m.x) }

                                function setVol(x) {
                                    if (!audioBubble.sink) return
                                    audioBubble.sink.audio.volume = Math.max(0, Math.min(1, x / volSlider.width))
                                }
                            }
                        }

                        component SectionHeader: Item {
                            property string label: ""
                            width: popupContent.width
                            height: 14

                            Text {
                                id: hdrLabel
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: parent.label
                                color: "#7a7a88"
                                font.pixelSize: 9
                                font.weight: Font.Bold
                                font.letterSpacing: 2
                            }

                            Rectangle {
                                anchors.left: hdrLabel.right
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 10
                                height: 1
                                color: Qt.rgba(1, 1, 1, 0.06)
                            }
                        }

                        component DeviceRow: Rectangle {
                            id: row
                            property var node
                            property bool isDefault: false
                            signal activated

                            width: popupContent.width
                            height: 34
                            radius: 11
                            color: isDefault
                                ? Qt.rgba(1, 1, 1, 0.09)
                                : (rowMa.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent")

                            Behavior on color { ColorAnimation { duration: 150 } }

                            Rectangle {
                                id: dot
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 8
                                radius: 4
                                color: row.isDefault ? "#a8b5e8" : "transparent"
                                border.width: row.isDefault ? 0 : 1
                                border.color: Qt.rgba(1, 1, 1, 0.22)

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }

                            Text {
                                anchors.left: dot.right
                                anchors.right: parent.right
                                anchors.leftMargin: 10
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.node?.description ?? row.node?.name ?? ""
                                color: row.isDefault ? "#ffffff" : "#c0c0c8"
                                font.pixelSize: 12
                                elide: Text.ElideRight

                                Behavior on color { ColorAnimation { duration: 150 } }
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: row.activated()
                            }
                        }

                        SectionHeader { label: "OUTPUT" }

                        Repeater {
                            model: Pipewire.nodes.values.filter(n => n.audio && n.isSink && !n.isStream)
                            delegate: DeviceRow {
                                required property var modelData
                                node: modelData
                                isDefault: modelData === Pipewire.defaultAudioSink
                                onActivated: Pipewire.preferredDefaultAudioSink = modelData
                            }
                        }

                        SectionHeader { label: "INPUT" }

                        Repeater {
                            model: Pipewire.nodes.values.filter(n => n.audio && !n.isSink && !n.isStream)
                            delegate: DeviceRow {
                                required property var modelData
                                node: modelData
                                isDefault: modelData === Pipewire.defaultAudioSource
                                onActivated: Pipewire.preferredDefaultAudioSource = modelData
                            }
                        }
                    }
                }
                }
            }

            PopupWindow {
                id: netPopup
                anchor.window: bar
                anchor.rect.x: netBubble.x + netBubble.width - implicitWidth
                anchor.rect.y: bar.implicitHeight + 2
                implicitWidth: 320
                implicitHeight: netPopupContent.implicitHeight + 24
                property bool open: false
                visible: open || netExitTrans.running
                color: "transparent"

                property var networks: []

                onOpenChanged: {
                    if (open) wifiListProc.running = true
                }

                // nmcli -t escapes ':' inside values as '\:' — split on unescaped colons
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
                        onStreamFinished: netPopup.parseWifi(text)
                    }
                }

                Process {
                    id: wifiConnectProc
                    running: false
                    onRunningChanged: {
                        if (!running) {
                            wifiListProc.running = true
                            netProc.running = true
                        }
                    }
                }

                Timer {
                    interval: 4000
                    running: netPopup.open
                    repeat: true
                    onTriggered: wifiListProc.running = true
                }

                Item {
                    id: netMorph
                    anchors.fill: parent
                    opacity: 0
                    scale: 0.78
                    transformOrigin: Item.TopRight

                    states: State {
                        name: "shown"
                        when: netPopup.open
                        PropertyChanges { target: netMorph; opacity: 1; scale: 1 }
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
                            id: netExitTrans
                            from: "shown"
                            ParallelAnimation {
                                NumberAnimation { property: "opacity"; duration: 180; easing.type: Easing.InCubic }
                                NumberAnimation { property: "scale"; duration: 180; easing.type: Easing.InCubic }
                            }
                        }
                    ]

                Rectangle {
                    anchors.fill: parent
                    radius: 20
                    color: Qt.rgba(0.10, 0.10, 0.14, 0.22)
                    border.color: Qt.rgba(1, 1, 1, 0.18)
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
                                text: netBubble.connType === "wifi" ? "📶"
                                    : netBubble.connType === "ethernet" ? "🌐"
                                    : "📡"
                                font.pixelSize: 16
                                color: "#e6e6f0"
                            }

                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: netBubble.connType === "wifi" ? netBubble.connName
                                    : netBubble.connType === "ethernet" ? "Ethernet"
                                    : "Disconnected"
                                color: "#ffffff"
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
                                color: "#7a7a88"
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
                                color: Qt.rgba(1, 1, 1, 0.06)
                            }
                        }

                        Text {
                            visible: netPopup.networks.length === 0
                            width: parent.width
                            text: "No networks found"
                            color: "#6a6a78"
                            font.pixelSize: 12
                            font.italic: true
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Repeater {
                            model: netPopup.networks

                            delegate: Rectangle {
                                id: netRow
                                required property var modelData
                                width: netPopupContent.width
                                height: 34
                                radius: 11
                                color: modelData.inUse
                                    ? Qt.rgba(1, 1, 1, 0.09)
                                    : (netRowMa.containsMouse ? Qt.rgba(1, 1, 1, 0.04) : "transparent")

                                Behavior on color { ColorAnimation { duration: 150 } }

                                Rectangle {
                                    id: sigDot
                                    anchors.left: parent.left
                                    anchors.leftMargin: 12
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 8
                                    height: 8
                                    radius: 4
                                    color: netRow.modelData.inUse ? "#a8b5e8" : "transparent"
                                    border.width: netRow.modelData.inUse ? 0 : 1
                                    border.color: Qt.rgba(1, 1, 1, 0.22)

                                    Behavior on color { ColorAnimation { duration: 150 } }
                                }

                                Text {
                                    anchors.left: sigDot.right
                                    anchors.leftMargin: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.right: sigBar.left
                                    anchors.rightMargin: 10
                                    text: netRow.modelData.ssid + (netRow.modelData.security ? "  🔒" : "")
                                    color: netRow.modelData.inUse ? "#ffffff" : "#c0c0c8"
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
                                    color: Qt.rgba(1, 1, 1, 0.10)

                                    Rectangle {
                                        width: parent.width * (netRow.modelData.signal / 100)
                                        height: parent.height
                                        radius: 2
                                        color: "#a8b5e8"
                                    }
                                }

                                MouseArea {
                                    id: netRowMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: netPopup.connectTo(netRow.modelData.ssid)
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: "Click to connect (saved or open networks).  Use nmtui for new secured ones."
                            color: "#6a6a78"
                            font.pixelSize: 10
                            wrapMode: Text.WordWrap
                            topPadding: 4
                        }
                    }
                }
                }
            }
        }
    }
}
