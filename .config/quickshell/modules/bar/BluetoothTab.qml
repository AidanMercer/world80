import QtQuick
import Quickshell.Bluetooth
import "../common"

// Bluetooth tab built on Quickshell's native BlueZ binding.
// When the BlueZ daemon isn't running, Bluetooth.defaultAdapter is null and we
// show an "unavailable" hint instead of an empty list. Discovery only runs
// while this tab is active so the radio isn't scanning in the background.
Item {
    id: root
    implicitHeight: col.implicitHeight

    property bool active: false
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool ready: adapter !== null

    // A device's connected/paired flags don't bump Bluetooth.devices, so the
    // grouped list below won't re-sort on its own when something connects or
    // drops. Tick this (on tap + on a slow timer) to force a re-group so a
    // device hops into the right section. navIndex/positional nav can shift
    // when this re-sorts — fine for a brief popup.
    property int rev: 0
    Timer {
        interval: 2000
        running: root.active && root.ready && root.adapter.enabled
        repeat: true
        onTriggered: root.rev++
    }

    // Each entry wraps a device with its section group, so the ListView can
    // draw section headers. Shared by the list and keyboard nav so both index
    // into the same ordering. Empty when the stack is off. (rev is read only to
    // make this binding re-run on connect/disconnect — see above.)
    readonly property var deviceList: ready && adapter.enabled
        ? buildList(Bluetooth.devices?.values ?? [], rev)
        : []

    // Keyboard navigation, driven by ControlPopup's Up/Down/Enter. navIndex
    // highlights a device row (-1 = none); activateNav (dis)connects/pairs it.
    property int navIndex: -1
    readonly property int navCount: deviceList.length
    function activateNav() { tapDevice(deviceList[navIndex].dev) }
    onNavIndexChanged: if (navIndex >= 0) devList.positionViewAtIndex(navIndex, ListView.Contain)

    // Right-click context menu. menuDev is the device whose menu is open
    // (null = closed); menuX/Y are its top-left anchor in root coordinates.
    // The menu lives at root level (not in a row) so the list's clip doesn't
    // eat it. Closes on tab switch / Bluetooth toggling off.
    property var menuDev: null
    property real menuX: 0
    property real menuY: 0
    function openMenu(d, x, y) { menuDev = d; menuX = x; menuY = y }
    function closeMenu() { menuDev = null }
    onActiveChanged: closeMenu()

    // Context-appropriate actions for a device. trusted is a settable property
    // (assign, don't call); forget/cancelPair/pair/connect/disconnect are methods.
    function menuActions(d) {
        if (!d) return []
        const a = []
        if (d.connected) a.push({ label: "Disconnect", fn: () => d.disconnect() })
        else if (d.paired) a.push({ label: "Connect", fn: () => d.connect() })
        if (d.pairing) a.push({ label: "Cancel pairing", fn: () => d.cancelPair() })
        else if (!d.paired) a.push({ label: "Pair", fn: () => d.pair() })
        if (d.paired) a.push({ label: d.trusted ? "Untrust" : "Trust", fn: () => { d.trusted = !d.trusted } })
        if (d.paired) a.push({ label: "Forget", fn: () => d.forget(), danger: true })
        return a
    }

    // height of the scrollable device area (≈ 5 rows); keep this constant so the
    // popup never grows when a scan turns up a pile of nearby devices.
    readonly property int listHeight: 200

    function deviceGroup(d) {
        if (d.connected) return "connected"
        if (d.paired) return "paired"
        return "available"
    }

    // connected first, then paired (remembered), then unpaired — alphabetical
    // within each group. The "group" key drives the ListView's section headers.
    function buildList(list) {
        function rank(g) { return g === "connected" ? 0 : (g === "paired" ? 1 : 2) }
        return [...list]
            .map(d => ({ dev: d, group: deviceGroup(d) }))
            .sort((a, b) => {
                const r = rank(a.group) - rank(b.group)
                if (r !== 0) return r
                return (a.dev.deviceName || a.dev.name || "").localeCompare(b.dev.deviceName || b.dev.name || "")
            })
    }

    function sectionLabel(g) {
        return g === "connected" ? "CONNECTED" : (g === "paired" ? "PAIRED" : "AVAILABLE")
    }

    function statusText(d) {
        if (d.pairing) return "Pairing…"
        if (d.state === BluetoothDeviceState.Connecting) return "Connecting…"
        if (d.state === BluetoothDeviceState.Disconnecting) return "Disconnecting…"
        if (d.connected) return d.batteryAvailable ? "Connected · " + Math.round(d.battery * 100) + "%" : "Connected"
        if (d.paired) return "Paired"
        return "Available"
    }

    function tapDevice(d) {
        if (d.connected) d.disconnect()
        else if (d.paired) d.connect()
        else d.pair()
        rev++
    }

    // Scan only while the tab is open and the adapter is on.
    Binding {
        target: root.adapter
        property: "discovering"
        value: root.active && root.ready && root.adapter.enabled
        when: root.ready
    }

    Column {
        id: col
        width: parent.width
        spacing: 10

        // ── header: bluetooth label + power toggle ──
        Item {
            width: parent.width
            height: 24

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(root.ready && root.adapter.enabled ? 0xF00AF : 0xF00B2) // bluetooth / off
                    font.family: Theme.icon
                    font.pixelSize: 18
                    color: root.ready && root.adapter.enabled ? Theme.accent : Theme.textDim
                }

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Bluetooth"
                    color: Theme.textBright
                    font.pixelSize: 13
                }
            }

            // toggle switch (only meaningful when the stack is up)
            Rectangle {
                id: toggle
                visible: root.ready
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 38
                height: 20
                radius: 10
                color: root.ready && root.adapter.enabled ? Theme.accent : Theme.trackBg2
                Behavior on color { ColorAnimation { duration: 150 } }

                Rectangle {
                    width: 14
                    height: 14
                    radius: 7
                    color: Theme.textBright
                    anchors.verticalCenter: parent.verticalCenter
                    x: root.ready && root.adapter.enabled ? parent.width - width - 3 : 3
                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.ready) root.adapter.enabled = !root.adapter.enabled
                }
            }
        }

        // ── unavailable hint ──
        Text {
            visible: !root.ready
            width: parent.width
            text: "Bluetooth unavailable.\nInstall bluez and start bluetooth.service."
            color: Theme.textMuted
            font.pixelSize: 12
            font.italic: true
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            topPadding: 6
        }

        // ── fixed-height scrollable device list, grouped into sections ──
        Item {
            visible: root.ready
            width: parent.width
            height: root.listHeight

            ListView {
                id: devList
                anchors.fill: parent
                clip: true
                spacing: 2
                model: root.deviceList
                boundsBehavior: Flickable.StopAtBounds

                section.property: "group"
                section.criteria: ViewSection.FullString
                section.delegate: Item {
                    required property string section
                    width: devList.width
                    height: 20

                    Text {
                        id: secHdr
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: 4
                        text: root.sectionLabel(parent.section)
                        color: Theme.textDim
                        font.pixelSize: 9
                        font.weight: Font.Bold
                        font.letterSpacing: 2
                    }

                    Rectangle {
                        anchors.left: secHdr.right
                        anchors.right: parent.right
                        anchors.verticalCenter: secHdr.verticalCenter
                        anchors.leftMargin: 10
                        height: 1
                        color: Theme.divider
                    }
                }

                delegate: Rectangle {
                    id: btRow
                    required property var modelData
                    required property int index
                    readonly property var dev: modelData.dev
                    readonly property bool navSelected: root.navIndex === index
                    width: devList.width
                    height: 38
                    radius: 11
                    color: dev.connected
                        ? Theme.rowSelected
                        : ((navSelected || btRowMa.containsMouse) ? Theme.rowHover : "transparent")
                    // accent ring marks the keyboard-highlighted row.
                    border.width: navSelected ? 1 : 0
                    border.color: Theme.accent
                    Behavior on color { ColorAnimation { duration: 150 } }

                    Text {
                        id: btIcon
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: String.fromCodePoint(btRow.dev.connected ? 0xF00B1 : 0xF00AF)
                        font.family: Theme.icon
                        font.pixelSize: 15
                        color: btRow.dev.connected ? Theme.accent : Theme.textTertiary
                    }

                    Column {
                        anchors.left: btIcon.right
                        anchors.leftMargin: 10
                        anchors.right: parent.right
                        anchors.rightMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 1

                        Text {
                            width: parent.width
                            text: btRow.dev.deviceName || btRow.dev.name || btRow.dev.address
                            color: btRow.dev.connected ? Theme.textBright : Theme.textTertiary
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: root.statusText(btRow.dev)
                            color: Theme.textMuted
                            font.pixelSize: 10
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: btRowMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onClicked: (mouse) => {
                            if (mouse.button === Qt.RightButton) {
                                const p = mapToItem(root, mouse.x, mouse.y)
                                root.openMenu(btRow.dev, p.x, p.y)
                            } else {
                                root.tapDevice(btRow.dev)
                            }
                        }
                    }
                }
            }

            // slim scroll indicator, only when the list overflows
            Rectangle {
                visible: devList.contentHeight > devList.height
                anchors.right: parent.right
                width: 3
                radius: 1.5
                color: Theme.subtleDivider
                y: devList.visibleArea.yPosition * devList.height
                height: Math.max(24, devList.visibleArea.heightRatio * devList.height)
            }

            // empty state, centered in the list area
            Text {
                visible: root.deviceList.length === 0
                anchors.centerIn: parent
                width: parent.width
                text: (root.ready && root.adapter.enabled) ? "Searching…" : "Turn Bluetooth on to scan for devices."
                color: Theme.textMuted
                font.pixelSize: 12
                font.italic: true
                horizontalAlignment: Text.AlignHCenter
            }
        }
    }

    // ── right-click context menu (root-level so the list clip can't trim it) ──
    // Catches any press outside the menu to dismiss it.
    MouseArea {
        anchors.fill: parent
        visible: root.menuDev !== null
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: root.closeMenu()
    }

    Rectangle {
        id: ctxMenu
        visible: root.menuDev !== null
        readonly property var actions: root.menuActions(root.menuDev)
        readonly property int rowH: 30
        width: 172
        height: actions.length * rowH + 8
        radius: 12
        color: Theme.menuBg
        border.width: 1
        border.color: Theme.divider
        // clamp inside root; flip above the cursor when it'd overflow the bottom.
        x: Math.max(0, Math.min(root.menuX, root.width - width))
        y: (root.menuY + height > root.height) ? Math.max(0, root.menuY - height) : root.menuY

        Column {
            anchors.fill: parent
            anchors.margins: 4

            Repeater {
                model: ctxMenu.actions

                delegate: Rectangle {
                    required property var modelData
                    width: parent.width
                    height: ctxMenu.rowH
                    radius: 8
                    color: itemMa.containsMouse ? Theme.rowHover : "transparent"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 12
                        anchors.verticalCenter: parent.verticalCenter
                        text: modelData.label
                        font.pixelSize: 12
                        color: modelData.danger ? Theme.danger : Theme.textTertiary
                    }

                    MouseArea {
                        id: itemMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            modelData.fn()
                            root.rev++
                            root.closeMenu()
                        }
                    }
                }
            }
        }
    }
}
