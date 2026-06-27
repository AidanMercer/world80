import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import "../common"

// Fullscreen, transparent layer-shell overlay holding the status card (Network /
// Sound / Bluetooth / Power / Display, with an uptime header). Created once per
// monitor in shell.qml — decoupled from the bar — so it works no matter which
// bar (default or a theme's own) is loaded. Opens when ControlBus names this
// monitor; clicking the surrounding scrim dismisses it.
//
// It owns its own uptime + network polling (so it doesn't depend on the bar's
// StatusButton) and switches to a full cyberpunk HUD — chamfered Canvas frame,
// neon stroke + cyan rule + magenta corner tick, CRT scanlines, blink pip, mono
// labels, a sliding tab underline and an EDGERUNNER sign-off — when the active
// theme sets `cyber = true` in its config.toml. The reused tabs come along for
// free: Theme.qml retints its shared accent colors to the neon palette when
// cyber is on, so sliders/rings/rows go neon without per-tab edits. Everything
// here is gated on `cyber`, so glass themes render byte-for-byte as before.
//
// We use a scrim rather than HyprlandFocusGrab because the grab races the popup's
// mapping and often fails to attach. The Launcher uses this same scrim pattern.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    readonly property string monitorName: modelData ? modelData.name : ""
    readonly property bool open: monitorName !== "" && ControlBus.openMonitor === monitorName
    property int currentTab: 0  // 0 = network, 1 = sound, 2 = bluetooth, 3 = power, 4 = display

    // ── theme chrome: cyberpunk when the theme opts in, glass otherwise ──
    readonly property bool cyber: ThemeConfig.cyber
    readonly property color accentCol: ThemeConfig.accent      // neon yellow
    readonly property color cyanCol: ThemeConfig.accent2       // secondary cyan
    readonly property color magentaCol: ThemeConfig.accent3    // alert magenta
    readonly property color amberCol: ThemeConfig.accentWarn   // amber
    readonly property color dimCol: ThemeConfig.accentDim      // muted trace
    readonly property color cardBg: cyber ? Qt.rgba(0.03, 0.03, 0.045, 0.93) : Theme.glassBg
    readonly property color cardBorder: cyber ? accentCol : Theme.glassBorder
    readonly property int cardRadius: cyber ? 5 : Theme.popupRadius
    // optional roaming scan beam — off by default (a transient popup shouldn't
    // sweep while you're aiming at a slider); flip to true to opt in.
    property bool scanBeam: false

    onOpenChanged: if (open) { resetNav(); Qt.callLater(card.forceActiveFocus) }

    function tabList() { return [networkTab, soundTab, bluetoothTab, powerTab, displayTab] }
    function activeTabItem() { return tabList()[currentTab] }

    function navMove(delta) {
        const t = activeTabItem()
        if (!t || t.navCount === 0) return
        if (t.navIndex < 0) t.navIndex = delta > 0 ? 0 : t.navCount - 1
        else t.navIndex = (t.navIndex + delta + t.navCount) % t.navCount
    }
    function navActivate() {
        const t = activeTabItem()
        if (t && t.navIndex >= 0 && t.navIndex < t.navCount) t.activateNav()
    }
    function resetNav() {
        const ts = tabList()
        for (let i = 0; i < ts.length; i++) ts[i].navIndex = -1
    }
    onCurrentTabChanged: resetNav()

    readonly property var modifierKeys: [
        Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_AltGr,
        Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R,
        Qt.Key_CapsLock, Qt.Key_NumLock, Qt.Key_ScrollLock
    ]

    // ── uptime: read /proc/uptime, tick locally, re-sync to correct drift ──
    property real uptimeSeconds: 0
    readonly property string uptimeText: "up " + formatUptime(uptimeSeconds)
    function formatUptime(s) {
        const total = Math.floor(s)
        const d = Math.floor(total / 86400)
        const h = Math.floor((total % 86400) / 3600)
        const m = Math.floor((total % 3600) / 60)
        if (d > 0) return d + "d " + h + "h"
        if (h > 0) return h + "h " + m + "m"
        return m + "m"
    }
    Process {
        id: uptimeProc
        command: ["cat", "/proc/uptime"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                const first = parseFloat(text.trim().split(/\s+/)[0])
                if (!isNaN(first)) root.uptimeSeconds = first
            }
        }
    }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.uptimeSeconds += 1 }
    Timer { interval: 300000; running: true; repeat: true; onTriggered: uptimeProc.running = true }

    // ── network: lightweight status poll feeding the Network tab ──
    property string connType: "none"   // "wifi" | "ethernet" | "none"
    property string connName: ""
    signal connectionChanged()
    function refreshNet() { netProc.running = true }
    function parseNm(raw) {
        let nextType = "none", nextName = ""
        for (const line of raw.trim().split("\n")) {
            if (!line) continue
            const parts = line.split(":")
            const type = parts[0], state = parts[1], name = parts.slice(2).join(":")
            if (type === "loopback") continue
            if (state !== "connected") continue
            if (type === "wifi") { nextType = "wifi"; nextName = name; break }
            if (type === "ethernet" && nextType === "none") { nextType = "ethernet"; nextName = name }
        }
        connType = nextType
        connName = nextName
    }
    Process {
        id: netProc
        command: ["nmcli", "-t", "-f", "TYPE,STATE,CONNECTION", "device", "status"]
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseNm(text) }
    }
    // poll faster while open, lazily while closed
    Timer {
        interval: root.open ? 5000 : 30000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: netProc.running = true
    }
    onConnectionChanged: refreshNet()

    WlrLayershell.namespace: "quickshell-control-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || exitTrans.running

    readonly property string iconArch: String.fromCodePoint(0xF303) // nf-linux-archlinux

    readonly property var tabs: [
        { label: "Network",   glyph: 0xF05A9 },
        { label: "Sound",     glyph: 0xF057E },
        { label: "Bluetooth", glyph: 0xF00AF },
        { label: "Power",     glyph: 0xF0425 },
        { label: "Display",   glyph: 0xF0379 }
    ]

    // ── scrim: transparent (no dimming), click-outside to dismiss ──
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: ControlBus.close()
    }

    Item {
        id: morph
        width: card.width
        height: card.height
        // top-centre, just under the bar
        x: Math.max(8, (root.width - width) / 2)
        y: Theme.barHeight + 4
        opacity: 0
        scale: 0.78
        transformOrigin: Item.Top

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
            id: card
            width: 432
            height: content.implicitHeight + 32
            radius: root.cyber ? 0 : root.cardRadius
            color: root.cyber ? "transparent" : root.cardBg
            border.color: root.cardBorder
            border.width: root.cyber ? 0 : 1
            focus: true

            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Escape) {
                    ControlBus.close(); e.accepted = true
                } else if (e.key === Qt.Key_Right || e.key === Qt.Key_Tab) {
                    root.currentTab = (root.currentTab + 1) % root.tabs.length
                    e.accepted = true
                } else if (e.key === Qt.Key_Left || e.key === Qt.Key_Backtab) {
                    root.currentTab = (root.currentTab + root.tabs.length - 1) % root.tabs.length
                    e.accepted = true
                } else if (e.key === Qt.Key_Down) {
                    root.navMove(1); e.accepted = true
                } else if (e.key === Qt.Key_Up) {
                    root.navMove(-1); e.accepted = true
                } else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                    root.navActivate(); e.accepted = true
                } else if (!root.modifierKeys.includes(e.key)) {
                    ControlBus.close(); e.accepted = true
                }
            }

            MouseArea { anchors.fill: parent }

            // ── cyber chassis: chamfered Canvas frame drawn behind the content.
            // Top-left + bottom-right corner cuts, a faint wide glow stroke under a
            // crisp neon edge, a cyan inner rule along the top and a magenta corner
            // tick bottom-right — sysinfo.qml's HUD grammar. Canvas doesn't repaint
            // on resize and the card grows per tab, so we requestPaint() on size. ──
            Canvas {
                id: frameCanvas
                anchors.fill: parent
                visible: root.cyber
                // card resizes per tab; repaint the chamfer to fit (cyber only —
                // no point rastering this hidden surface on glass themes)
                onWidthChanged: if (root.cyber) requestPaint()
                onHeightChanged: if (root.cyber) requestPaint()
                Component.onCompleted: if (root.cyber) requestPaint()
                Connections { target: root; function onCyberChanged() { frameCanvas.requestPaint() } }
                onPaint: {
                    const ctx = getContext("2d")
                    const w = width, h = height, c = 13
                    ctx.reset()
                    ctx.beginPath()
                    ctx.moveTo(c, 0); ctx.lineTo(w, 0); ctx.lineTo(w, h - c)
                    ctx.lineTo(w - c, h); ctx.lineTo(0, h); ctx.lineTo(0, c)
                    ctx.closePath()
                    ctx.fillStyle = "rgba(7,7,12,0.95)"
                    ctx.fill()
                    // fake glow: wide low-alpha stroke first, crisp edge on top
                    ctx.strokeStyle = root.accentCol
                    ctx.lineWidth = 3
                    ctx.globalAlpha = 0.18
                    ctx.stroke()
                    ctx.globalAlpha = 1
                    ctx.lineWidth = 1.4
                    ctx.stroke()
                    // cyan inner rule under the top edge
                    ctx.beginPath()
                    ctx.moveTo(14, 4); ctx.lineTo(w - 6, 4)
                    ctx.strokeStyle = root.cyanCol
                    ctx.lineWidth = 1
                    ctx.globalAlpha = 0.5
                    ctx.stroke()
                    ctx.globalAlpha = 1
                    // magenta corner tick, bottom-right
                    ctx.beginPath()
                    ctx.moveTo(w - 4, h - 22); ctx.lineTo(w - 4, h - 6); ctx.lineTo(w - 20, h - 6)
                    ctx.strokeStyle = root.magentaCol
                    ctx.lineWidth = 1.6
                    ctx.stroke()
                }
            }

            // cyan L-brackets on the two square corners (top-right, bottom-left) —
            // the chamfered corners carry the diagonal cut, these "lock" the others.
            Repeater {
                model: [
                    { ax: "right", ay: "top" },
                    { ax: "left",  ay: "bottom" }
                ]
                delegate: Item {
                    required property var modelData
                    visible: root.cyber
                    width: 16
                    height: 16
                    x: modelData.ax === "left" ? 0 : card.width - width
                    y: modelData.ay === "top" ? 0 : card.height - height

                    Rectangle {
                        width: parent.width
                        height: 2
                        color: root.cyanCol
                        y: parent.modelData.ay === "top" ? 0 : parent.height - height
                    }
                    Rectangle {
                        width: 2
                        height: parent.height
                        color: root.cyanCol
                        x: parent.modelData.ax === "left" ? 0 : parent.width - width
                    }
                }
            }

            // top highlight (glass only — the cyber cyan rule is drawn in frameCanvas)
            Rectangle {
                visible: !root.cyber
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: parent.radius
                anchors.rightMargin: parent.radius
                anchors.topMargin: 1
                height: 1
                color: Theme.glassHighlight
            }

            Column {
                id: content
                anchors.fill: parent
                anchors.margins: 16
                spacing: 14

                // ── header (glass): Arch glyph + uptime ──
                Row {
                    visible: !root.cyber
                    width: parent.width
                    spacing: 8

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.iconArch
                        color: Theme.accent
                        font.family: Theme.icon
                        font.pixelSize: 16
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.uptimeText
                        color: Theme.textSecondary
                        font.pixelSize: 12
                        font.family: Theme.mono
                    }
                }

                // ── header (cyber): blink pip + SYSTEM // CTRL.DECK + UP uptime ──
                Item {
                    visible: root.cyber
                    width: parent.width
                    height: 16

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 6; height: 6; radius: 1
                            color: root.magentaCol
                            SequentialAnimation on opacity {
                                running: root.cyber && root.open
                                loops: Animation.Infinite
                                NumberAnimation { to: 0.25; duration: 700 }
                                NumberAnimation { to: 1.0; duration: 700 }
                            }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.iconArch
                            font.family: Theme.icon
                            font.pixelSize: 13
                            color: root.cyanCol
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "SYSTEM"
                            font.family: Theme.mono
                            font.weight: Font.Bold
                            font.pixelSize: 13
                            font.letterSpacing: 4
                            color: root.accentCol
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "// CTRL.DECK"
                            font.family: Theme.mono
                            font.pixelSize: 9
                            font.letterSpacing: 2
                            color: root.cyanCol
                            opacity: 0.7
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "UP " + root.uptimeText.replace("up ", "").toUpperCase()
                            font.family: Theme.mono
                            font.pixelSize: 10
                            font.letterSpacing: 1
                            color: root.dimCol
                        }
                    }
                }

                // header divider (cyber only)
                Rectangle {
                    visible: root.cyber
                    width: parent.width
                    height: 1
                    color: root.dimCol
                    opacity: 0.5
                }

                // ── segmented tab bar (+ sliding cyber underline) ──
                Item {
                    id: tabBarWrap
                    width: parent.width
                    height: 32

                    Row {
                        id: tabBar
                        anchors.fill: parent
                        spacing: 4

                        Repeater {
                            model: root.tabs

                            delegate: Rectangle {
                                id: tab
                                required property int index
                                required property var modelData
                                readonly property bool selected: root.currentTab === index

                                width: (tabBar.width - tabBar.spacing * (root.tabs.length - 1)) / root.tabs.length
                                height: tabBar.height
                                radius: root.cyber ? 0 : 10
                                color: root.cyber
                                    ? "transparent"
                                    : (selected ? Theme.rowSelected : (tabMa.containsMouse ? Theme.rowHover : "transparent"))
                                border.width: 0
                                Behavior on color { ColorAnimation { duration: 150 } }

                                Row {
                                    anchors.centerIn: parent
                                    spacing: 6

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: String.fromCodePoint(tab.modelData.glyph)
                                        font.family: Theme.icon
                                        font.pixelSize: 14
                                        color: tab.selected
                                            ? (root.cyber ? root.accentCol : Theme.accent)
                                            : (root.cyber ? (tabMa.containsMouse ? root.cyanCol : root.dimCol) : Theme.textSecondary)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                    }

                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: tab.modelData.label
                                        font.pixelSize: 11
                                        font.family: root.cyber ? Theme.mono : ""
                                        font.weight: (root.cyber && tab.selected) ? Font.Bold : Font.Normal
                                        font.letterSpacing: root.cyber ? 1 : 0
                                        color: tab.selected
                                            ? (root.cyber ? root.accentCol : Theme.textBright)
                                            : (root.cyber ? root.dimCol : Theme.textSecondary)
                                        Behavior on color { ColorAnimation { duration: 150 } }
                                    }
                                }

                                MouseArea {
                                    id: tabMa
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.currentTab = tab.index
                                }
                            }
                        }
                    }

                    // magenta underline that slides under the active segment — also
                    // the keyboard-focus indicator (moves on Left/Right nav).
                    Rectangle {
                        id: tabCursor
                        visible: root.cyber
                        height: 2
                        color: root.magentaCol
                        y: tabBar.height - 2
                        width: (tabBar.width - tabBar.spacing * (root.tabs.length - 1)) / root.tabs.length
                        x: root.currentTab * (width + tabBar.spacing)
                        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                    }
                }

                // ── tab contents (only the active one is visible/sized) ──
                NetworkTab {
                    id: networkTab
                    width: parent.width
                    visible: root.currentTab === 0
                    active: root.open && root.currentTab === 0
                    connType: root.connType
                    connName: root.connName
                    onConnectionChanged: root.connectionChanged()
                    onReturnFocus: card.forceActiveFocus()
                }

                SoundTab {
                    id: soundTab
                    width: parent.width
                    visible: root.currentTab === 1
                }

                BluetoothTab {
                    id: bluetoothTab
                    width: parent.width
                    visible: root.currentTab === 2
                    active: root.open && root.currentTab === 2
                }

                PowerTab {
                    id: powerTab
                    width: parent.width
                    visible: root.currentTab === 3
                    onActionTriggered: ControlBus.close()
                }

                DisplayTab {
                    id: displayTab
                    width: parent.width
                    visible: root.currentTab === 4
                    active: root.open && root.currentTab === 4
                }

                // ── cyber footer: NET status (left) + EDGERUNNER sign-off (right) ──
                Rectangle {
                    visible: root.cyber
                    width: parent.width
                    height: 1
                    color: root.dimCol
                    opacity: 0.5
                }
                Item {
                    visible: root.cyber
                    width: parent.width
                    height: 13

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 5

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: String.fromCodePoint(root.connType === "ethernet" ? 0xF059F
                                : root.connType === "wifi" ? 0xF05A9 : 0xF092F)
                            font.family: Theme.icon
                            font.pixelSize: 11
                            color: root.connType === "none" ? root.magentaCol : root.cyanCol
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.connType === "none" ? "OFFLINE" : (root.connName || "ONLINE")
                            font.family: Theme.mono
                            font.pixelSize: 9
                            color: root.connType === "none" ? root.magentaCol : root.cyanCol
                        }
                    }

                    Row {
                        anchors.right: parent.right
                        // clear the bottom-right chamfer + magenta corner tick (~20px in)
                        anchors.rightMargin: 16
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "// EDGERUNNER CTRL"
                            font.family: Theme.mono
                            font.pixelSize: 8
                            font.letterSpacing: 2
                            color: root.accentCol
                            opacity: 0.55
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 7; height: 11
                            color: root.accentCol
                            SequentialAnimation on opacity {
                                running: root.cyber && root.open
                                loops: Animation.Infinite
                                NumberAnimation { to: 0; duration: 0 }
                                PauseAnimation { duration: 440 }
                                NumberAnimation { to: 1; duration: 0 }
                                PauseAnimation { duration: 440 }
                            }
                        }
                    }
                }
            }

            // faint CRT scanlines over the whole card (cyber only). No MouseArea,
            // so clicks/scrolls pass straight through to the tabs below.
            Canvas {
                id: scanCanvas
                anchors.fill: parent
                visible: root.cyber
                opacity: 0.4
                onWidthChanged: if (root.cyber) requestPaint()
                onHeightChanged: if (root.cyber) requestPaint()
                Component.onCompleted: if (root.cyber) requestPaint()
                Connections { target: root; function onCyberChanged() { scanCanvas.requestPaint() } }
                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    ctx.strokeStyle = "rgba(0,0,0,0.5)"
                    ctx.lineWidth = 1
                    for (let y = 3; y < height; y += 3) {
                        ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(width, y); ctx.stroke()
                    }
                }
            }

            // optional roaming scan beam — opt-in via root.scanBeam (default off)
            Rectangle {
                visible: root.cyber && root.scanBeam
                width: card.width
                height: 2
                color: root.cyanCol
                opacity: 0.25
                SequentialAnimation on y {
                    running: root.cyber && root.open && root.scanBeam
                    loops: Animation.Infinite
                    NumberAnimation { to: card.height; duration: 4200; easing.type: Easing.InOutSine }
                    NumberAnimation { to: 0; duration: 0 }
                    PauseAnimation { duration: 1600 }
                }
            }
        }
    }
}
