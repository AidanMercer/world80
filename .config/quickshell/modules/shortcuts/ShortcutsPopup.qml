import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// Fullscreen, transparent layer-shell overlay holding a "cheat sheet" card that
// lists every keybind. Centred on the focused monitor; click the scrim, press
// Esc, or hit any key to dismiss. Same proven scrim pattern as the launcher /
// control popup (a HyprlandFocusGrab races the map and often misses).
//
// Opened/closed over IPC:
//   qs ipc call shortcuts toggle   (wired to Super+/ in hyprland.conf)
//
// The bind list below is hand-maintained — if you add/rename a bind in
// hyprland.conf, update the matching row here so the sheet stays honest.
PanelWindow {
    id: root

    property bool open: false
    property bool closing: false        // keep mapped through the close fade
    // Captured at open() time so follow_mouse can't remap the window mid-use.
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-shortcuts"
    WlrLayershell.layer: WlrLayer.Overlay
    // Grab the keyboard only while open so Esc/any-key reach the card; the
    // focused window keeps the keyboard the rest of the time.
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || closing

    readonly property string iconArch: String.fromCodePoint(0xF303) // nf-linux-archlinux

    // Bare modifier taps shouldn't close the sheet (otherwise letting go of Super
    // would shut it the instant it opens).
    readonly property var modifierKeys: [
        Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_AltGr,
        Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R,
        Qt.Key_CapsLock, Qt.Key_NumLock, Qt.Key_ScrollLock
    ]

    // ── the cheat-sheet data ────────────────────────────────────────────
    // `columns` is an array of columns; each column is an array of sections;
    // each section has a title and a list of binds. A bind's `keys` is the list
    // of keycap labels rendered left→right with "+" between them.
    readonly property var columns: [
        [
            { title: "Apps", binds: [
                { keys: ["Super", "T"],          desc: "Terminal" },
                { keys: ["Super", "W"],          desc: "Browser" },
                { keys: ["Super", "E"],          desc: "Files" },
                { keys: ["Super", "C"],          desc: "Code" },
                { keys: ["Super", "G"],          desc: "GitHub Desktop" },
                { keys: ["Super", "Shift", "C"], desc: "Claude" },
                { keys: ["Super", "R"],          desc: "App launcher" }
            ]},
            { title: "System", binds: [
                { keys: ["Super", "M"],          desc: "Control center" },
                { keys: ["Super", "Shift", "T"], desc: "Themes" },
                { keys: ["Super", "L"],          desc: "Lock screen" },
                { keys: ["Super", "Shift", "S"], desc: "Screenshot region" },
                { keys: ["Super", "/"],          desc: "This sheet" }
            ]},
            { title: "Workspaces", binds: [
                { keys: ["Super", "1 – 5"],            desc: "Switch workspace" },
                { keys: ["Super", "Scroll"],          desc: "Cycle this monitor" },
                { keys: ["Super", "Ctrl", "← →"],     desc: "Prev / next" },
                { keys: ["Super", "Ctrl", "Shift", "← →"], desc: "Carry window" }
            ]}
        ],
        [
            { title: "Windows", binds: [
                { keys: ["Super", "Q"],              desc: "Close window" },
                { keys: ["Super", "F"],              desc: "Toggle float" },
                { keys: ["Super", "Drag"],           desc: "Move window" },
                { keys: ["Super", "Right-drag"],     desc: "Resize window" },
                { keys: ["Super", "Shift", "← →"],   desc: "Send to monitor" },
                { keys: ["Super", "Shift", "↑ ↓"],   desc: "Move in layout" }
            ]},
            { title: "Canvas", binds: [
                { keys: ["Super", "← → ↑ ↓"],        desc: "Focus nearest window" },
                { keys: ["Super", "Home"],           desc: "Recenter" },
                { keys: ["Super", "S"],              desc: "Spread" },
                { keys: ["Super", "Tab"],            desc: "Overview" },
                { keys: ["Super", "H"],              desc: "Toggle canvas" },
                { keys: ["Super", "Shift", "M"],     desc: "Minimap" },
                { keys: ["Super", "Ctrl", "↑ / ↓"], desc: "Zoom out / in" },
                { keys: ["Super", "Shift", "1 – 5"], desc: "Resize window" },
                { keys: ["Super", "Shift", "H"],     desc: "Canvas settings" }
            ]}
        ]
    ]

    // ── lifecycle ───────────────────────────────────────────────────────
    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        closing = false
        open = true
        Qt.callLater(card.forceActiveFocus)
    }
    function closeMenu() {
        if (!open) return
        open = false
        closing = true
        closeHold.restart()
    }
    Timer { id: closeHold; interval: 220; onTriggered: root.closing = false }

    IpcHandler {
        target: "shortcuts"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
    }

    // ── scrim: transparent (no dimming), click-outside to dismiss ───────
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.closeMenu()
    }

    Item {
        id: morph
        width: card.width
        height: card.height
        anchors.centerIn: parent
        opacity: 0
        scale: 0.92
        transformOrigin: Item.Center

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
                    SpringAnimation { property: "scale"; spring: 3; damping: 0.34; epsilon: 0.001 }
                }
            },
            Transition {
                from: "shown"
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; duration: 170; easing.type: Easing.InCubic }
                    NumberAnimation { property: "scale"; duration: 170; easing.type: Easing.InCubic }
                }
            }
        ]

        Rectangle {
            id: card
            width: 816
            height: content.implicitHeight + 40
            radius: Theme.popupRadius
            color: Theme.glassBg
            border.color: Theme.glassBorder
            border.width: 1
            focus: true

            // Esc or any non-modifier key dismisses — a help sheet has nothing to
            // navigate, so "press anything to get back to work" is the whole UX.
            Keys.onPressed: (e) => {
                if (!root.modifierKeys.includes(e.key)) {
                    root.closeMenu()
                    e.accepted = true
                }
            }

            // Swallow clicks on the card so they don't fall through to the scrim.
            MouseArea { anchors.fill: parent }

            // top inner highlight, matching the control popup
            Rectangle {
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
                anchors.margins: 20
                spacing: 16

                // ── header ──
                Item {
                    width: parent.width
                    height: 22

                    Row {
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
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
                            text: "Keyboard Shortcuts"
                            color: Theme.textBright
                            font.pixelSize: 15
                            font.weight: Font.DemiBold
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Esc to close"
                        color: Theme.textMuted
                        font.pixelSize: 11
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.divider }

                // ── two columns of sections ──
                Row {
                    width: parent.width
                    spacing: 36

                    Repeater {
                        model: root.columns

                        delegate: Column {
                            id: col
                            required property var modelData    // array of sections
                            width: (parent.width - parent.spacing) / 2
                            spacing: 18

                            Repeater {
                                model: col.modelData

                                delegate: Column {
                                    id: section
                                    required property var modelData   // { title, binds }
                                    width: parent.width
                                    spacing: 7

                                    Text {
                                        text: section.modelData.title
                                        color: Theme.accent
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        font.capitalization: Font.AllUppercase
                                        font.letterSpacing: 1.4
                                    }

                                    Repeater {
                                        model: section.modelData.binds

                                        delegate: Item {
                                            id: bindRow
                                            required property var modelData   // { keys, desc }
                                            width: parent.width
                                            height: 26

                                            Text {
                                                anchors.left: parent.left
                                                anchors.verticalCenter: parent.verticalCenter
                                                width: Math.max(0, parent.width - caps.width - 14)
                                                text: bindRow.modelData.desc
                                                color: Theme.textSecondary
                                                font.pixelSize: 13
                                                elide: Text.ElideRight
                                            }

                                            Row {
                                                id: caps
                                                anchors.right: parent.right
                                                anchors.verticalCenter: parent.verticalCenter
                                                spacing: 5

                                                Repeater {
                                                    model: bindRow.modelData.keys

                                                    delegate: Row {
                                                        id: chip
                                                        required property int index
                                                        required property var modelData   // a key label
                                                        spacing: 5

                                                        Text {
                                                            visible: chip.index > 0
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            text: "+"
                                                            color: Theme.textMuted
                                                            font.pixelSize: 12
                                                        }

                                                        Rectangle {
                                                            anchors.verticalCenter: parent.verticalCenter
                                                            height: 22
                                                            width: Math.max(22, keyLabel.implicitWidth + 14)
                                                            radius: 6
                                                            color: Theme.rowSelected
                                                            border.color: Theme.glassBorder
                                                            border.width: 1

                                                            Text {
                                                                id: keyLabel
                                                                anchors.centerIn: parent
                                                                text: chip.modelData
                                                                color: Theme.textBright
                                                                font.family: Theme.mono
                                                                font.pixelSize: 12
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
