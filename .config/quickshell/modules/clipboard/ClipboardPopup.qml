import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// Clipboard history picker (cliphist), same surface pattern as the launcher.
// Toggled via `qs ipc call clipboard toggle` (Super+V). The shell owns the
// wl-paste watchers too — no exec-once, same idea as hypridle.
PanelWindow {
    id: root

    property bool open: false
    // Captured at open() time so a wandering cursor can't remap the window mid-use.
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-clipboard"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || exitTrans.running

    // text and images are separate offer types, so two watchers. Either can die —
    // or start before the seat is up — and history then stops recording that type
    // silently while the popup still lists the old entries, so restart them.
    Process {
        id: textWatcher
        running: true
        property double startedAt: 0
        command: ["wl-paste", "--type", "text", "--watch", "cliphist", "store"]
        onRunningChanged: if (running) startedAt = Date.now()
        onExited: root.rearm(textWatcher, textRetry)
    }
    Timer { id: textRetry; interval: 1000; onTriggered: textWatcher.running = true }

    Process {
        id: imageWatcher
        running: true
        property double startedAt: 0
        command: ["wl-paste", "--type", "image", "--watch", "cliphist", "store"]
        onRunningChanged: if (running) startedAt = Date.now()
        onExited: root.rearm(imageWatcher, imageRetry)
    }
    Timer { id: imageRetry; interval: 1000; onTriggered: imageWatcher.running = true }

    // back off up to a minute so a watcher that can't run doesn't spin; one that
    // stayed up a while earns the short retry back
    function rearm(proc, timer) {
        const lived = Date.now() - proc.startedAt
        timer.interval = lived > 30000 ? 1000 : Math.min(timer.interval * 2, 60000)
        timer.start()
    }

    property string query: ""
    property int selectedIndex: 0
    property var entries: []          // {line, id, preview, isImage, meta}
    property bool wipeArmed: false    // "clear all" needs a second click
    property int thumbNonce: 0        // bumped when new thumbnails land on disk

    readonly property string thumbDir:
        (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/quickshell-cliphist"

    // cliphist keeps ~750 entries; rendering them all per keystroke is pointless
    readonly property int maxShown: 60
    readonly property var results: {
        const q = query.trim().toLowerCase()
        const all = q === ""
            ? entries
            : entries.filter(e => e.preview.toLowerCase().includes(q))
        return all.slice(0, maxShown)
    }
    readonly property int hiddenCount: {
        const q = query.trim().toLowerCase()
        const all = q === ""
            ? entries.length
            : entries.filter(e => e.preview.toLowerCase().includes(q)).length
        return Math.max(0, all - maxShown)
    }

    // "<id>\t<preview>" per line; binary previews look like
    // "[[ binary data 1.2 MiB png 1920x1080 ]]"
    function parseList(text) {
        const out = []
        for (const line of text.split("\n")) {
            if (!line) continue
            const tab = line.indexOf("\t")
            if (tab < 1) continue
            const id = line.slice(0, tab)
            const raw = line.slice(tab + 1)
            const m = raw.match(/^\[\[ binary data\s+(.+?)\s+(\w+)\s+(\d+)x(\d+)/)
            out.push({
                line: line,
                id: id,
                isImage: m !== null,
                meta: m ? (m[2] + " · " + m[3] + "×" + m[4] + " · " + m[1]) : "",
                preview: m ? ("image · " + m[2] + " · " + m[3] + "×" + m[4])
                           : raw.replace(/\s+/g, " ").trim()
            })
        }
        return out
    }

    Process {
        id: listProc
        command: ["cliphist", "list"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.entries = root.parseList(text)
                root.selectedIndex = Math.min(root.selectedIndex,
                    Math.max(0, root.results.length - 1))
                root.decodeThumbs()
            }
        }
    }
    function refresh() { listProc.running = true }

    // ids are content-stable so decoded thumbs never go stale; the runtime
    // dir evaporates on reboot
    Process {
        id: thumbProc
        onExited: root.thumbNonce++
    }
    function decodeThumbs() {
        const ids = entries.filter(e => e.isImage).map(e => e.id)
        if (ids.length === 0) return
        thumbProc.command = ["bash", "-c",
            'd="$1"; shift; mkdir -p "$d"; for id in "$@"; do f="$d/$id"; ' +
            '[ -f "$f" ] || cliphist decode "$id" > "$f" 2>/dev/null; done; true',
            "_", root.thumbDir].concat(ids)
        thumbProc.running = true
    }
    function thumbSrc(id, nonce) {
        // the nonce has to land in the URL itself — an identical source string is
        // a no-op to Qt's image loader, so a thumb decoded after the row appeared
        // would never show. Qt strips the query when it opens the local file.
        return "file://" + thumbDir + "/" + id + "?v=" + nonce
    }

    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        searchInput.text = ""
        selectedIndex = 0
        wipeArmed = false
        refresh()
        open = true
        Qt.callLater(searchInput.forceActiveFocus)
    }
    function closeMenu() { open = false }

    // the watcher re-stores what we copy, bumping it to the top — exactly right
    function copyEntry(e) {
        if (!e) return
        Quickshell.execDetached(["bash", "-c",
            'printf "%s" "$1" | cliphist decode | wl-copy', "_", e.line])
        closeMenu()
    }
    function deleteEntry(e) {
        if (!e) return
        deleteProc.command = ["bash", "-c",
            'printf "%s" "$1" | cliphist delete', "_", e.line]
        deleteProc.running = true
    }
    Process {
        id: deleteProc
        onExited: root.refresh()
    }
    function wipeAll() {
        if (!wipeArmed) { wipeArmed = true; return }
        wipeArmed = false
        wipeProc.running = true
    }
    Process {
        id: wipeProc
        command: ["cliphist", "wipe"]
        onExited: root.refresh()
    }

    function moveSel(delta) {
        if (results.length === 0) return
        selectedIndex = Math.max(0, Math.min(results.length - 1, selectedIndex + delta))
    }

    IpcHandler {
        target: "clipboard"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
    }

    // scrim: click outside to dismiss
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

                MouseArea { anchors.fill: parent }   // swallow scrim clicks

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

                TextInput {
                    id: searchInput
                    anchors.left: searchGlyph.right
                    anchors.leftMargin: 12
                    anchors.right: parent.right
                    anchors.rightMargin: 16
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
                            root.copyEntry(root.results[root.selectedIndex])
                            e.accepted = true
                        } else if (e.key === Qt.Key_Delete) {
                            root.deleteEntry(root.results[root.selectedIndex])
                            e.accepted = true
                        } else if (e.key === Qt.Key_Escape) {
                            root.closeMenu(); e.accepted = true
                        }
                    }

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: "Filter clipboard history…"
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

                MouseArea { anchors.fill: parent }   // swallow scrim clicks

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
                        height: Math.min(contentHeight, 8 * 46)
                        visible: root.results.length > 0
                        clip: true
                        model: root.results
                        currentIndex: root.selectedIndex
                        boundsBehavior: Flickable.StopAtBounds
                        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                        delegate: Rectangle {
                            id: row
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: modelData.isImage ? 62 : 42
                            radius: 11
                            color: ListView.isCurrentItem
                                ? Theme.rowSelected
                                : (rowMa.containsMouse ? Theme.rowHover : "transparent")
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Rectangle {
                                id: dot
                                visible: !row.modelData.isImage
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 8
                                radius: 4
                                color: row.ListView.isCurrentItem ? Theme.accent : "transparent"
                                border.width: row.ListView.isCurrentItem ? 0 : 1
                                border.color: Theme.dotBorder
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            // image entries: real thumbnail (decoded async into
                            // the runtime dir; dim well shows until it lands)
                            Rectangle {
                                id: thumbWell
                                visible: row.modelData.isImage
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                width: 74
                                height: 50
                                radius: 8
                                color: Theme.insetBg
                                clip: true

                                Image {
                                    anchors.fill: parent
                                    source: row.modelData.isImage
                                        ? root.thumbSrc(row.modelData.id, root.thumbNonce)
                                        : ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    cache: false
                                }
                            }

                            Text {
                                anchors.left: parent.left
                                anchors.leftMargin: row.modelData.isImage ? 92 : 34
                                anchors.right: parent.right
                                anchors.rightMargin: 34
                                anchors.verticalCenter: parent.verticalCenter
                                text: row.modelData.isImage
                                    ? row.modelData.meta
                                    : row.modelData.preview
                                textFormat: Text.PlainText
                                color: row.ListView.isCurrentItem ? Theme.textBright : Theme.textTertiary
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }

                            // per-row delete, revealed on hover
                            Text {
                                visible: rowMa.containsMouse || delMa.containsMouse
                                anchors.right: parent.right
                                anchors.rightMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                text: "×"
                                font.pixelSize: 16
                                font.bold: true
                                color: delMa.containsMouse ? Theme.danger : Theme.textMuted

                                MouseArea {
                                    id: delMa
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.deleteEntry(row.modelData)
                                }
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                anchors.rightMargin: 28   // leave the × its own hit area
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.selectedIndex = row.index
                                onClicked: root.copyEntry(root.results[row.index])
                            }
                        }
                    }

                    Text {
                        visible: root.results.length === 0
                        width: parent.width
                        text: root.entries.length === 0
                            ? "Nothing copied yet"
                            : "No matches"
                        color: Theme.textMuted
                        font.pixelSize: 13
                        font.italic: true
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 6
                        bottomPadding: 6
                    }

                    // footer: overflow count + guarded clear-all
                    Item {
                        width: parent.width
                        height: 24
                        visible: root.entries.length > 0

                        Text {
                            anchors.left: parent.left
                            anchors.leftMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.hiddenCount > 0 ? "+ " + root.hiddenCount + " more — keep typing" : ""
                            color: Theme.textMuted
                            font.pixelSize: 11
                            font.italic: true
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.rightMargin: 14
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.wipeArmed ? "really clear everything?" : "clear all"
                            color: root.wipeArmed ? Theme.danger : (wipeMa.containsMouse ? Theme.textSecondary : Theme.textMuted)
                            font.pixelSize: 11

                            MouseArea {
                                id: wipeMa
                                anchors.fill: parent
                                anchors.margins: -4
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.wipeAll()
                            }
                        }
                    }
                }
            }
        }
    }
}
