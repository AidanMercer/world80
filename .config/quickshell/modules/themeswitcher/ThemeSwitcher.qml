import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import "../common"

// Fullscreen, transparent layer-shell overlay holding a coverflow of "themes".
// A theme is just a folder under ~/.config/themes/<name>/ containing a
// wallpaper.<ext>. Pick one and hit Enter to swap the wallpaper via `awww`.
//
// Built to mirror Launcher.qml: same PanelWindow + WlrLayershell + scrim +
// IpcHandler shape. Opened/closed over IPC:
//   qs ipc call themeSwitcher toggle   (wired to Super+Shift+T in hyprland.conf)
//
// First increment is deliberately wallpaper-only — no colour regeneration.
// The hand-picked Theme.qml palette stays put.
PanelWindow {
    id: root

    property bool open: false
    // True from the moment Enter is pressed until the window closes; used to
    // fade the carousel away while awww does its cross-fade underneath.
    property bool applying: false
    // Kept true through the close fade so the window stays mapped long enough
    // for the dim/scrim to animate out (same trick as the launcher).
    property bool closing: false

    // Pin to the focused monitor at open() time so a wandering cursor can't
    // remap the surface mid-use. awww still swaps the wallpaper on every
    // output; only this UI is single-monitor.
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-themeswitcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    // Cover the whole output, including the strip under the bar.
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || closing

    // ---- data ----------------------------------------------------------
    property int selectedIndex: 0
    ListModel { id: themeModel }

    // Build "name\tpath" lines, one per theme folder that has a wallpaper.<ext>.
    // nullglob keeps the loop from running on a literal glob when the folder
    // is missing/empty; we stop at the first matching extension per theme.
    Process {
        id: scanProc
        running: false
        command: ["bash", "-c",
            'shopt -s nullglob; for d in "$HOME"/.config/themes/*/; do ' +
            'name=$(basename "$d"); ' +
            'for f in "$d"wallpaper.jpg "$d"wallpaper.jpeg "$d"wallpaper.png "$d"wallpaper.webp "$d"wallpaper.gif "$d"wallpaper.mp4; do ' +
            '[ -e "$f" ] && { printf "%s\\t%s\\n" "$name" "$f"; break; }; done; done']
        stdout: StdioCollector {
            onStreamFinished: root.loadThemes(text)
        }
    }

    function loadThemes(out) {
        themeModel.clear()
        const lines = (out || "").trim().split("\n").filter(l => l.length)
        for (const line of lines) {
            const parts = line.split("\t")
            if (parts.length >= 2)
                themeModel.append({ name: parts[0], wallpaper: parts[1] })
        }
        if (root.selectedIndex >= themeModel.count)
            root.selectedIndex = Math.max(0, themeModel.count - 1)
    }

    // Encode each path segment so spaces ("your name/") survive the file URL.
    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // ---- lifecycle -----------------------------------------------------
    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        applying = false
        closing = false
        selectedIndex = 0
        open = true
        scanProc.running = true            // rescan each open so new folders show
        Qt.callLater(keyCatcher.forceActiveFocus)
    }
    function closeMenu() {
        if (!open) return
        open = false
        closing = true
        closeHold.restart()
    }
    Timer { id: closeHold; interval: 240; onTriggered: root.closing = false }

    function moveSel(delta) {
        if (themeModel.count === 0) return
        // Wrap around the ends, like a real carousel.
        selectedIndex = (selectedIndex + delta + themeModel.count) % themeModel.count
    }

    function applyTheme() {
        if (applying || themeModel.count === 0) return
        const t = themeModel.get(selectedIndex)
        if (!t || !t.wallpaper) return
        applying = true
        // No setsid: let onExited fire when awww has handed off the swap.
        applyProc.command = ["awww", "img",
            "--transition-type", "fade",
            "--transition-duration", "0.7",
            t.wallpaper]
        applyProc.running = true
    }

    Process {
        id: applyProc
        running: false
        // awww returns as soon as the daemon accepts the image; the fade then
        // plays on the desktop. Close the overlay so it's revealed underneath.
        onExited: (code, status) => root.closeMenu()
    }

    IpcHandler {
        target: "themeSwitcher"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
    }

    // ---- keyboard ------------------------------------------------------
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            if (root.applying) { e.accepted = true; return }
            if (e.key === Qt.Key_Left || e.key === Qt.Key_Up) { root.moveSel(-1); e.accepted = true }
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Down) { root.moveSel(1); e.accepted = true }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.applyTheme(); e.accepted = true }
            else if (e.key === Qt.Key_Escape) { root.closeMenu(); e.accepted = true }
        }
    }

    // ---- dim backdrop (click-outside to cancel) ------------------------
    Rectangle {
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.42)
        opacity: root.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        MouseArea {
            anchors.fill: parent
            onClicked: if (!root.applying) root.closeMenu()
        }
    }

    // ---- foreground content (title / carousel / hint) ------------------
    Item {
        id: content
        anchors.fill: parent
        opacity: root.open && !root.applying ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

        Text {
            id: title
            anchors.horizontalCenter: parent.horizontalCenter
            y: parent.height * 0.16
            text: "Themes"
            color: Theme.textBright
            font.pixelSize: 24
            font.weight: Font.DemiBold
        }

        // ---- empty state ----
        Text {
            anchors.centerIn: parent
            visible: themeModel.count === 0
            horizontalAlignment: Text.AlignHCenter
            color: Theme.textSecondary
            font.pixelSize: 15
            text: "No themes found.\nDrop a folder with a wallpaper.<ext> into ~/.config/themes/"
        }

        // ---- coverflow ----
        PathView {
            id: pv
            anchors.centerIn: parent
            width: Math.min(parent.width, 1100)
            height: 320
            visible: themeModel.count > 0
            model: themeModel
            pathItemCount: 3
            preferredHighlightBegin: 0.5
            preferredHighlightEnd: 0.5
            highlightRangeMode: PathView.StrictlyEnforceRange
            snapMode: PathView.SnapToItem
            // Two-way bind to selectedIndex so keyboard and drag stay in sync.
            currentIndex: root.selectedIndex
            onCurrentIndexChanged: root.selectedIndex = currentIndex

            path: Path {
                startX: pv.width * 0.13; startY: pv.height / 2
                PathAttribute { name: "iz";     value: 0 }
                PathAttribute { name: "iscale"; value: 0.66 }
                PathAttribute { name: "iopac";  value: 0.38 }
                PathLine { x: pv.width * 0.5; y: pv.height / 2 }
                PathAttribute { name: "iz";     value: 2 }
                PathAttribute { name: "iscale"; value: 1.0 }
                PathAttribute { name: "iopac";  value: 1.0 }
                PathLine { x: pv.width * 0.87; y: pv.height / 2 }
                PathAttribute { name: "iz";     value: 0 }
                PathAttribute { name: "iscale"; value: 0.66 }
                PathAttribute { name: "iopac";  value: 0.38 }
            }

            delegate: Item {
                id: card
                required property string name
                required property string wallpaper
                required property int index
                width: 300
                height: 300
                z: PathView.iz ?? 0
                scale: PathView.iscale ?? 0.66
                opacity: PathView.iopac ?? 0.38
                Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

                ClippingRectangle {
                    anchors.fill: parent
                    radius: 22
                    color: Theme.glassBg
                    border.width: card.PathView.isCurrentItem ? 2 : 1
                    border.color: card.PathView.isCurrentItem ? Theme.accent : Theme.glassBorder

                    Image {
                        anchors.fill: parent
                        source: root.fileUrl(card.wallpaper)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: true
                    }

                    // bottom gradient so the label stays legible on any wallpaper
                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                        height: 70
                        gradient: Gradient {
                            GradientStop { position: 0; color: "transparent" }
                            GradientStop { position: 1; color: Qt.rgba(0, 0, 0, 0.58) }
                        }
                    }
                    Text {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: 14 }
                        text: card.name
                        color: Theme.textBright
                        font.pixelSize: 17
                        font.weight: Font.Medium
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (card.PathView.isCurrentItem) root.applyTheme()
                        else root.selectedIndex = card.index
                    }
                }
            }
        }

        // ---- hint + buttons ----
        Column {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: parent.height * 0.14
            spacing: 16
            visible: themeModel.count > 0

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 12

                // Cancel
                Rectangle {
                    width: 110; height: 40; radius: 20
                    color: cancelMa.containsMouse ? Theme.rowSelected : Theme.glassBg
                    border.color: Theme.glassBorder
                    border.width: 1
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "Cancel"
                        color: Theme.textSecondary
                        font.pixelSize: 14
                    }
                    MouseArea {
                        id: cancelMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.closeMenu()
                    }
                }

                // Apply
                Rectangle {
                    width: 130; height: 40; radius: 20
                    color: applyMa.containsMouse ? Qt.lighter(Theme.accent, 1.08) : Theme.accent
                    Behavior on color { ColorAnimation { duration: 120 } }
                    Text {
                        anchors.centerIn: parent
                        text: "Apply"
                        color: "#1a1a22"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }
                    MouseArea {
                        id: applyMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.applyTheme()
                    }
                }
            }

            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "←  →  browse     ·     Enter  apply     ·     Esc  cancel"
                color: Theme.textMuted
                font.pixelSize: 12
            }
        }
    }
}
