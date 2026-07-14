import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// Command palette — Super+P. Fuzzy list of one-shot actions: apply a theme,
// open a panel, flip a toggle, a couple of window/session actions. Each action
// just fires the same IPC call a keybind would (`qs ipc call …`) or a Hyprland
// dispatch, so the palette stays a thin front-end over stuff that already works.
// Same overlay skeleton as the launcher (scrim + centred card + IPC toggle).
PanelWindow {
    id: root

    property bool open: false
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-commandpalette"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || exitTrans.running

    property string query: ""
    property int selectedIndex: 0

    // ---- how actions run: everything routes through an already-wired path ----
    function ipc() { Quickshell.execDetached(["qs", "ipc", "call"].concat(Array.from(arguments))) }
    function sh(cmd) { Quickshell.execDetached(cmd) }
    function dispatch(d) { Hyprland.dispatch(d) }

    // themes discovered on disk (a dir under ~/.config/themes with a wallpaper*;
    // that filter naturally skips `default`, which is just the base config.toml)
    property var themeNames: []
    Process {
        id: themeScan
        command: ["bash", "-c",
            'for d in "$HOME"/.config/themes/*/; do n=$(basename "$d"); ' +
            'ls "$d" 2>/dev/null | grep -qE "^wallpaper[0-9]*\\.(jpg|jpeg|png|webp|gif|mp4)$" && echo "$n"; done']
        stdout: StdioCollector {
            onStreamFinished: root.themeNames = text.trim().split("\n").filter(x => x.length > 0)
        }
    }

    readonly property var actions: buildActions()
    function buildActions() {
        const a = []
        for (const n of themeNames)
            a.push({ title: "Theme: " + n, cat: "Theme", run: () => root.ipc("theme", "apply", n) })
        a.push({ title: "Next theme",            cat: "Theme",   run: () => root.ipc("theme", "next") })
        a.push({ title: "Previous theme",        cat: "Theme",   run: () => root.ipc("theme", "prev") })
        a.push({ title: "Reload theme widgets",  cat: "Theme",   run: () => root.ipc("themeReload", "reload") })

        a.push({ title: "Theme gallery",         cat: "Open",    run: () => root.ipc("themeSwitcher", "toggle") })
        a.push({ title: "App launcher",          cat: "Open",    run: () => root.ipc("launcher", "toggle") })
        a.push({ title: "Clipboard history",     cat: "Open",    run: () => root.ipc("clipboard", "toggle") })
        a.push({ title: "Control center",        cat: "Open",    run: () => root.ipc("controlPopup", "toggle") })
        a.push({ title: "Keybind cheat sheet",   cat: "Open",    run: () => root.ipc("shortcuts", "toggle") })
        a.push({ title: "Settings",              cat: "Open",    run: () => root.ipc("shortcuts", "settings") })
        a.push({ title: "Theme marketplace",     cat: "Open",    run: () => root.ipc("shortcuts", "marketplace") })
        a.push({ title: "Extensions",            cat: "Open",    run: () => root.ipc("shortcuts", "extensions") })

        a.push({ title: "Toggle auto-lock",      cat: "Toggle",  run: () => root.ipc("shortcuts", "autolock") })
        a.push({ title: "Pin system info",       cat: "Toggle",  run: () => root.ipc("sysinfo", "toggle") })
        a.push({ title: "Interface scale: reset",   cat: "Scale", run: () => root.ipc("uiScale", "reset") })
        a.push({ title: "Interface scale: larger",  cat: "Scale", run: () => root.ipc("uiScale", "nudge", "0.05") })
        a.push({ title: "Interface scale: smaller", cat: "Scale", run: () => root.ipc("uiScale", "nudge", "-0.05") })
        a.push({ title: "Lyrics: nudge earlier", cat: "Lyrics",  run: () => root.ipc("lyricOffset", "earlier") })
        a.push({ title: "Lyrics: nudge later",   cat: "Lyrics",  run: () => root.ipc("lyricOffset", "later") })
        a.push({ title: "Lyrics: reset sync",    cat: "Lyrics",  run: () => root.ipc("lyricOffset", "reset") })

        a.push({ title: "Fullscreen window",     cat: "Window",  run: () => root.dispatch("fullscreen 0") })
        a.push({ title: "Toggle floating",       cat: "Window",  run: () => root.dispatch("togglefloating") })
        a.push({ title: "Close window",          cat: "Window",  run: () => root.dispatch("killactive") })
        a.push({ title: "Reload Hyprland",       cat: "Window",  run: () => root.sh(["hyprctl", "reload"]) })

        a.push({ title: "Lock screen",           cat: "Session", run: () => root.ipc("lock", "lock") })
        a.push({ title: "Suspend",               cat: "Session", run: () => root.sh(["systemctl", "suspend"]) })
        a.push({ title: "Log out",               cat: "Session", run: () => root.dispatch("exit") })
        return a
    }

    readonly property var results: filterActions(query, actions)
    function filterActions(q, list) {
        if (!q) return list
        const ql = q.toLowerCase()
        return list
            .filter(x => (x.title + " " + x.cat).toLowerCase().includes(ql))
            .sort((x, y) => {
                // title prefix beats title-contains beats category-only match
                const xr = x.title.toLowerCase().startsWith(ql) ? 0
                         : x.title.toLowerCase().includes(ql) ? 1 : 2
                const yr = y.title.toLowerCase().startsWith(ql) ? 0
                         : y.title.toLowerCase().includes(ql) ? 1 : 2
                return xr - yr
            })
    }

    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        themeScan.running = true
        searchInput.text = ""
        selectedIndex = 0
        open = true
        Qt.callLater(searchInput.forceActiveFocus)
    }
    function closeMenu() { open = false }
    function activate(item) {
        if (!item || !item.run) return
        // close first so the palette's exclusive keyboard grab is gone before an
        // action that opens another panel (or acts on the window underneath) fires
        closeMenu()
        item.run()
    }
    function moveSel(delta) {
        if (results.length === 0) return
        selectedIndex = Math.max(0, Math.min(results.length - 1, selectedIndex + delta))
    }

    IpcHandler {
        target: "commandPalette"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
    }

    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.closeMenu()
    }

    Item {
        id: morph
        width: searchBox.width
        height: layoutCol.height
        x: (parent.width - width) / 2
        y: (parent.height - searchBox.height) / 2
        opacity: 0
        scale: 0.92
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
                    NumberAnimation { property: "opacity"; duration: 200; easing.type: Easing.OutCubic }
                    SpringAnimation { property: "scale"; spring: 3; damping: 0.34; epsilon: 0.001 }
                }
            },
            Transition {
                id: exitTrans
                from: "shown"
                ParallelAnimation {
                    NumberAnimation { property: "opacity"; duration: 160; easing.type: Easing.InCubic }
                    NumberAnimation { property: "scale"; duration: 160; easing.type: Easing.InCubic }
                }
            }
        ]

        Column {
            id: layoutCol
            width: parent.width
            spacing: 10

            Rectangle {
                id: searchBox
                width: 520
                height: 52
                radius: Theme.popupRadius
                color: Theme.glassBg
                border.color: Theme.glassBorder
                border.width: 1

                MouseArea { anchors.fill: parent }

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

                Text {
                    id: searchGlyph
                    anchors.left: parent.left
                    anchors.leftMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(0xF0349) // nf-md-magnify
                    font.family: Theme.icon
                    font.pixelSize: 18
                    color: Theme.textSecondary
                }

                Rectangle {
                    id: modePill
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.verticalCenter: parent.verticalCenter
                    height: 22
                    width: pillText.implicitWidth + 18
                    radius: 11
                    color: Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.16)
                    Text {
                        id: pillText
                        anchors.centerIn: parent
                        text: "command"
                        color: Theme.accent
                        font.pixelSize: 11
                        font.bold: true
                    }
                }

                TextInput {
                    id: searchInput
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: 12
                    anchors.right: modePill.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.textBright
                    font.pixelSize: 16
                    selectionColor: Theme.accent
                    selectedTextColor: Theme.onAccent
                    clip: true
                    focus: true

                    onTextChanged: {
                        root.query = text
                        root.selectedIndex = 0
                    }

                    Keys.onPressed: (e) => {
                        if (e.key === Qt.Key_Down) { root.moveSel(1); e.accepted = true }
                        else if (e.key === Qt.Key_Up) { root.moveSel(-1); e.accepted = true }
                        else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) {
                            root.activate(root.results[root.selectedIndex]); e.accepted = true
                        } else if (e.key === Qt.Key_Escape) {
                            root.closeMenu(); e.accepted = true
                        }
                    }

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: "Run a command…"
                        color: Theme.textMuted
                        font: searchInput.font
                        visible: searchInput.text.length === 0
                    }
                }
            }

            Rectangle {
                id: resultsPanel
                width: searchBox.width
                height: resultsCol.implicitHeight + 16
                radius: Theme.popupRadius
                color: Theme.glassBg
                border.color: Theme.glassBorder
                border.width: 1

                MouseArea { anchors.fill: parent }

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
                    id: resultsCol
                    x: 8
                    y: 8
                    width: parent.width - 16

                    ListView {
                        id: list
                        width: parent.width
                        height: Math.min(root.results.length, 9) * 40
                        visible: root.results.length > 0
                        clip: true
                        model: root.results
                        currentIndex: root.selectedIndex
                        boundsBehavior: Flickable.StopAtBounds
                        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                        delegate: Rectangle {
                            id: rowItem
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: 40
                            radius: 11
                            color: ListView.isCurrentItem
                                ? Theme.rowSelected
                                : (rowMa.containsMouse ? Theme.rowHover : "transparent")
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Rectangle {
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8; height: 8; radius: 4
                                color: rowItem.ListView.isCurrentItem ? Theme.accent : "transparent"
                                border.width: rowItem.ListView.isCurrentItem ? 0 : 1
                                border.color: Theme.dotBorder
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: 34
                                anchors.right: catLabel.left
                                anchors.rightMargin: 10
                                anchors.verticalCenter: parent.verticalCenter
                                text: rowItem.modelData.title
                                textFormat: Text.PlainText
                                color: rowItem.ListView.isCurrentItem ? Theme.textBright : Theme.textTertiary
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }

                            Text {
                                id: catLabel
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: rowItem.modelData.cat
                                textFormat: Text.PlainText
                                color: Theme.textMuted
                                font.pixelSize: 11
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.selectedIndex = rowItem.index
                                onClicked: root.activate(root.results[rowItem.index])
                            }
                        }
                    }

                    Text {
                        visible: root.results.length === 0
                        width: parent.width
                        text: "No commands"
                        color: Theme.textMuted
                        font.pixelSize: 13
                        font.italic: true
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 8
                        bottomPadding: 8
                    }
                }
            }
        }
    }
}
