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
// StatusButton). The active theme can ship a popup.qml next to its wallpaper to
// replace the card's chrome — an invisible Item declaring `pal`/`popup`/`audio`
// (all injected) plus cardBg/cardBorder/cardBorderWidth/cardRadius and optional
// backdrop/header/footer/overlay Components, mounted around the shared tabs.
// No popup.qml → the glass card. `cyber = true` in config.toml still tints the
// tab bar + shared controls (Theme.qml retints its accent colors), so a HUD
// theme gets neon sliders/rings/rows without per-tab edits.
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

    // global interface scale (Settings → Interface scale). The card's steady-state
    // transform is this, so the whole popup — fonts, padding, spacing — grows as
    // one and stays anchored to its bar edge via morph's transformOrigin.
    readonly property real uiScale: UiScale.factor

    // ── theme chrome: the theme's popup.qml when it ships one, glass otherwise ──
    readonly property bool cyber: ThemeConfig.cyber
    readonly property color accentCol: ThemeConfig.accent      // primary accent
    readonly property color cyanCol: ThemeConfig.accent2       // secondary
    readonly property color magentaCol: ThemeConfig.accent3    // alert
    readonly property color amberCol: ThemeConfig.accentWarn   // amber
    readonly property color dimCol: ThemeConfig.accentDim      // muted trace

    property string themeDir: ActiveTheme.dirFor(root.monitorName)
    property string chromePath: ""
    property int chromeNonce: 0
    property ThemePalette pal: ThemePalette { themeDir: root.themeDir }
    // this monitor's bar edge — the card hangs off whichever side the bar is on
    readonly property string barEdge: pal.barPosition
    readonly property var chrome: chromeLoader.item

    readonly property color cardBg: chrome ? chrome.cardBg : Theme.glassBg
    readonly property color cardBorder: chrome ? chrome.cardBorder : Theme.glassBorder
    readonly property int cardRadius: chrome ? chrome.cardRadius : Theme.popupRadius

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }
    Process {
        id: chromeProc
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim()
                if (p !== root.chromePath) { root.chromePath = p; root.remountChrome() }
            }
        }
    }
    // command built at call time, not bound — the one-behind trap again
    function rescanChrome() {
        chromeProc.command = ["bash", "-c",
            'd="$1"; f="$d/popup.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; printf "%s" "$f"',
            "_", root.themeDir]
        chromeProc.running = true
    }
    onThemeDirChanged: rescanChrome()
    function remountChrome() {
        if (root.chromePath === "") { chromeLoader.source = ""; return }
        chromeLoader.setSource(root.fileUrl(root.chromePath) + "?v=" + root.chromeNonce,
                               { pal: root.pal, popup: root, audio: AudioBus })
    }
    onChromeNonceChanged: remountChrome()
    // non-visual provider object; the card mounts its Components in the slots below
    Loader { id: chromeLoader }
    FileView {
        path: root.chromePath
        watchChanges: root.chromePath !== ""
        printErrors: false
        onFileChanged: root.chromeNonce++
    }
    Connections {
        target: ControlBus
        function onThemeReloadRequested() { root.chromeNonce++; root.rescanChrome() }
        function onTabNavRequested(delta) {
            if (!root.open) return
            root.currentTab = (root.currentTab + delta + root.tabs.length) % root.tabs.length
        }
    }
    Component.onCompleted: rescanChrome()

    onOpenChanged: if (open) { uptimeProc.running = true; resetNav(); Qt.callLater(card.forceActiveFocus) }

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
    // only ticks while the card is up — closed, uptime just goes stale until
    // the re-read on open
    Timer { interval: 1000; running: root.open; repeat: true; onTriggered: root.uptimeSeconds += 1 }

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
    // poll only while open (nothing shows this state while closed) —
    // triggeredOnStart refreshes the instant the card comes up
    Timer {
        interval: 5000
        running: root.open
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
        // horizontal bar: centred just past it; vertical bar: tucked in beside it
        x: root.barEdge === "left" ? Theme.barHeight + 4
         : root.barEdge === "right" ? root.width - width - Theme.barHeight - 4
         : Math.max(8, (root.width - width) / 2)
        y: root.barEdge === "left" || root.barEdge === "right" ? 8
         : root.barEdge === "bottom" ? root.height - height - Theme.barHeight - 4
         : Theme.barHeight + 4
        opacity: 0
        scale: 0.78
        transformOrigin: root.barEdge === "left" ? Item.TopLeft
                       : root.barEdge === "right" ? Item.TopRight
                       : root.barEdge === "bottom" ? Item.Bottom
                       : Item.Top

        states: State {
            name: "shown"
            when: root.open
            PropertyChanges { target: morph; opacity: 1; scale: root.uiScale }
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
            radius: root.cardRadius
            color: root.cardBg
            border.color: root.cardBorder
            border.width: root.chrome ? root.chrome.cardBorderWidth : 1
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

            // ── theme chassis behind the content (chrome.backdrop) ──
            Loader {
                id: backdropSlot
                anchors.fill: parent
                active: !!(root.chrome && root.chrome.backdrop)
                sourceComponent: backdropSlot.active ? root.chrome.backdrop : undefined
            }

            // top highlight (glass only — a theme backdrop draws its own edges)
            Rectangle {
                visible: !backdropSlot.active
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

                // ── header: the theme's (chrome.header), else Arch glyph + uptime ──
                Loader {
                    id: headerSlot
                    width: parent.width
                    active: !!(root.chrome && root.chrome.header)
                    visible: active
                    sourceComponent: headerSlot.active ? root.chrome.header : undefined
                }
                Row {
                    visible: !headerSlot.active
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

                // ── footer: theme-only (chrome.footer); glass has none ──
                Loader {
                    id: footerSlot
                    width: parent.width
                    active: !!(root.chrome && root.chrome.footer)
                    visible: active
                    sourceComponent: footerSlot.active ? root.chrome.footer : undefined
                }
            }

            // ── theme overlay above the content (chrome.overlay — scanlines etc).
            // Must not carry a MouseArea, so clicks pass through to the tabs. ──
            Loader {
                id: overlaySlot
                anchors.fill: parent
                active: !!(root.chrome && root.chrome.overlay)
                sourceComponent: overlaySlot.active ? root.chrome.overlay : undefined
            }
        }
    }
}
