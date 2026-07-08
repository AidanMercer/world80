import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// Fullscreen, transparent layer-shell overlay holding a card with two tabs:
//   • Shortcuts — a "cheat sheet" listing every keybind (hand-maintained).
//   • Settings  — toggles for shell/system behaviour (keep the laptop awake
//     when the lid is shut, auto-lock on idle).
// Centred on the focused monitor; click the scrim or press Esc to dismiss.
// Same proven scrim pattern as the launcher / control popup (a
// HyprlandFocusGrab races the map and often misses).
//
// Opened/closed over IPC:
//   qs ipc call shortcuts toggle     → Shortcuts tab (Super+/)
//   qs ipc call shortcuts settings   → Settings tab  (Super+Shift+/)
//
// The bind list below is hand-maintained — if you add/rename a bind in
// hyprland.conf, update the matching row here so the sheet stays honest.
PanelWindow {
    id: root

    property bool open: false
    property bool closing: false        // keep mapped through the close fade
    property int tab: 0                  // 0 = Shortcuts, 1 = Settings
    property int settingsRow: 0          // cursor within the Settings tab
    readonly property int settingsCount: 2

    // ── keep-laptop-awake setting ──────────────────────────────────────
    // Holds a logind block-inhibitor on handle-lid-switch while on, so
    // closing the lid does nothing. Persisted across shell restarts.
    property bool keepAwake: false

    // ── auto-lock setting ───────────────────────────────────────────────
    // The shell owns hypridle now (no exec-once in hyprland.conf): while on
    // it runs as a child process and the 5 min lock in hypridle.conf applies;
    // off means no idle daemon at all. Dies with the shell, comes back with it.
    property bool autoLock: false

    // Captured at open() time so follow_mouse can't remap the window mid-use.
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-shortcuts"
    WlrLayershell.layer: WlrLayer.Overlay
    // Grab the keyboard only while open so Esc/keys reach the card; the
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
                { keys: ["Super", "S"],          desc: "Frostify" },
                { keys: ["Super", "R"],          desc: "App launcher" }
            ]},
            { title: "System", binds: [
                { keys: ["Super", "M"],          desc: "Control center" },
                { keys: ["Super", "V"],          desc: "Clipboard history" },
                { keys: ["Super", "Shift", "T"], desc: "Themes" },
                { keys: ["Super", "Shift", "R"], desc: "Restart shell" },
                { keys: ["Super", "L"],          desc: "Lock screen" },
                { keys: ["Super", "Shift", "S"], desc: "Screenshot region" },
                { keys: ["Super", "/"],          desc: "This sheet" },
                { keys: ["Super", "Shift", "/"], desc: "Settings" }
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
                { keys: ["Super", "← → ↑ ↓"],        desc: "Focus window" },
                { keys: ["Super", "Q"],              desc: "Close window" },
                { keys: ["Super", "F"],              desc: "Toggle float" },
                { keys: ["Super", "Drag"],           desc: "Move window" },
                { keys: ["Super", "Right-drag"],     desc: "Resize window" },
                { keys: ["Super", "Shift", "← →"],   desc: "Send to monitor" },
                { keys: ["Super", "Shift", "↑ ↓"],   desc: "Move in layout" }
            ]},
            { title: "Lyrics", binds: [
                { keys: ["Super", "]"],          desc: "Sync later" },
                { keys: ["Super", "["],          desc: "Sync earlier" },
                { keys: ["Super", "Shift", "\\"], desc: "Reset sync" }
            ]}
        ]
    ]

    // ── persistence + inhibitor ─────────────────────────────────────────
    // State file is read synchronously at startup so the inhibitor comes back
    // up in the same state it was left in.
    FileView {
        id: stateFile
        path: Quickshell.stateDir + "/keep-awake"
        blockLoading: true
        preload: true
        printErrors: false
    }

    function setKeepAwake(v) {
        root.keepAwake = v
        stateFile.setText(v ? "1\n" : "0\n")
    }

    FileView {
        id: autoLockFile
        path: Quickshell.stateDir + "/auto-lock"
        blockLoading: true
        preload: true
        printErrors: false
    }

    function setAutoLock(v) {
        root.autoLock = v
        autoLockFile.setText(v ? "1\n" : "0\n")
    }

    Component.onCompleted: {
        root.keepAwake = stateFile.text().trim() === "1"
        root.autoLock = autoLockFile.text().trim() === "1"
    }

    // While running, logind ignores the lid switch. Killed on shell exit, which
    // releases the lock — Component.onCompleted re-arms it on next start.
    Process {
        id: lidInhibitor
        running: root.keepAwake
        command: ["systemd-inhibit",
                  "--what=handle-lid-switch",
                  "--who=frostify shell",
                  "--why=Keep laptop awake when the lid is shut",
                  "--mode=block",
                  "sleep", "infinity"]
    }

    Process {
        id: idleDaemon
        running: root.autoLock
        command: ["hypridle"]
    }

    // ── lifecycle ───────────────────────────────────────────────────────
    function openMenu(which) {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        closing = false
        tab = which
        settingsRow = 0
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
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu(0) }
        function settings(): void {
            if (root.open && root.tab === 1) root.closeMenu()
            else root.openMenu(1)
        }
        // flip auto-lock without opening the sheet (scripts / future keybind)
        function autolock(): void { root.setAutoLock(!root.autoLock) }
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

            Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            // Esc / click-outside always close. Left/Right switch tabs. The
            // Settings tab is interactive (Up/Down + Enter/Space), so only the
            // passive Shortcuts tab keeps the old "press anything to dismiss".
            Keys.onPressed: (e) => {
                if (e.key === Qt.Key_Escape) { root.closeMenu(); e.accepted = true; return }
                if (e.key === Qt.Key_Left)  { root.tab = 0; e.accepted = true; return }
                if (e.key === Qt.Key_Right) { root.tab = 1; e.accepted = true; return }

                if (root.tab === 1) {
                    if (e.key === Qt.Key_Up) {
                        root.settingsRow = Math.max(0, root.settingsRow - 1); e.accepted = true; return
                    }
                    if (e.key === Qt.Key_Down) {
                        root.settingsRow = Math.min(root.settingsCount - 1, root.settingsRow + 1); e.accepted = true; return
                    }
                    if (e.key === Qt.Key_Space || e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                        if (root.settingsRow === 0) root.setKeepAwake(!root.keepAwake)
                        else if (root.settingsRow === 1) root.setAutoLock(!root.autoLock)
                        e.accepted = true; return
                    }
                    e.accepted = true   // swallow stray keys instead of closing
                    return
                }

                // Shortcuts tab: any non-modifier key dismisses.
                if (!root.modifierKeys.includes(e.key)) { root.closeMenu(); e.accepted = true }
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

                        // tab switcher
                        Row {
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 4

                            Repeater {
                                model: ["Keyboard Shortcuts", "Settings"]

                                delegate: Rectangle {
                                    id: tabChip
                                    required property int index
                                    required property var modelData
                                    readonly property bool current: root.tab === index
                                    height: 24
                                    width: tabText.implicitWidth + 22
                                    radius: 7
                                    color: current ? Theme.rowSelected
                                                   : (tabHover.hovered ? Theme.rowHover : "transparent")
                                    border.color: current ? Theme.glassBorder : "transparent"
                                    border.width: 1

                                    Text {
                                        id: tabText
                                        anchors.centerIn: parent
                                        text: tabChip.modelData
                                        color: tabChip.current ? Theme.textBright : Theme.textMuted
                                        font.pixelSize: 13
                                        font.weight: tabChip.current ? Font.DemiBold : Font.Normal
                                    }

                                    HoverHandler { id: tabHover }
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.tab = tabChip.index
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.tab === 1 ? "← → switch · Esc close" : "Esc to close"
                        color: Theme.textMuted
                        font.pixelSize: 11
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.divider }

                // ── Shortcuts tab: two columns of sections ──
                Row {
                    width: parent.width
                    spacing: 36
                    visible: root.tab === 0

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

                // ── Settings tab ──
                Column {
                    width: parent.width
                    spacing: 10
                    visible: root.tab === 1

                    // row 0 — keep laptop awake when lid shut
                    Rectangle {
                        width: parent.width
                        height: 56
                        radius: 10
                        color: root.settingsRow === 0 ? Theme.rowSelected
                                                      : (awakeHover.hovered ? Theme.rowHover : "transparent")
                        border.color: root.settingsRow === 0 ? Theme.glassBorder : "transparent"
                        border.width: 1

                        HoverHandler { id: awakeHover }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.settingsRow = 0; root.setKeepAwake(!root.keepAwake) }
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.right: toggle.left
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: "Keep laptop awake when lid is shut"
                                color: Theme.textBright
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width
                                text: "Hold a system lock so closing the lid won't suspend."
                                color: Theme.textMuted
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }

                        // pill toggle
                        Rectangle {
                            id: toggle
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            width: 44
                            height: 24
                            radius: 12
                            color: root.keepAwake ? Theme.accent : Theme.trackBg
                            border.color: root.keepAwake ? Theme.accent : Theme.glassBorder
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: 140 } }

                            Rectangle {
                                width: 18
                                height: 18
                                radius: 9
                                color: root.keepAwake ? Theme.textBright : Theme.textMuted
                                anchors.verticalCenter: parent.verticalCenter
                                x: root.keepAwake ? parent.width - width - 3 : 3
                                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 140 } }
                            }
                        }
                    }

                    // row 1 — auto-lock on idle
                    Rectangle {
                        width: parent.width
                        height: 56
                        radius: 10
                        color: root.settingsRow === 1 ? Theme.rowSelected
                                                      : (lockHover.hovered ? Theme.rowHover : "transparent")
                        border.color: root.settingsRow === 1 ? Theme.glassBorder : "transparent"
                        border.width: 1

                        HoverHandler { id: lockHover }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { root.settingsRow = 1; root.setAutoLock(!root.autoLock) }
                        }

                        Column {
                            anchors.left: parent.left
                            anchors.leftMargin: 16
                            anchors.right: lockToggle.left
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 3

                            Text {
                                text: "Auto-lock when idle"
                                color: Theme.textBright
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                            }
                            Text {
                                width: parent.width
                                text: "Lock the screen after 5 minutes of inactivity."
                                color: Theme.textMuted
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }

                        Rectangle {
                            id: lockToggle
                            anchors.right: parent.right
                            anchors.rightMargin: 16
                            anchors.verticalCenter: parent.verticalCenter
                            width: 44
                            height: 24
                            radius: 12
                            color: root.autoLock ? Theme.accent : Theme.trackBg
                            border.color: root.autoLock ? Theme.accent : Theme.glassBorder
                            border.width: 1
                            Behavior on color { ColorAnimation { duration: 140 } }

                            Rectangle {
                                width: 18
                                height: 18
                                radius: 9
                                color: root.autoLock ? Theme.textBright : Theme.textMuted
                                anchors.verticalCenter: parent.verticalCenter
                                x: root.autoLock ? parent.width - width - 3 : 3
                                Behavior on x { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
                                Behavior on color { ColorAnimation { duration: 140 } }
                            }
                        }
                    }
                }
            }
        }
    }
}
