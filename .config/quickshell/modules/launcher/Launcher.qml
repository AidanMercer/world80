import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// Fullscreen, transparent layer-shell overlay. The launcher card is centred
// inside it; clicking the surrounding scrim (or pressing Esc) dismisses it.
// Opened/closed over IPC: `qs ipc call launcher toggle` (wired to Super in
// hyprland.conf).
PanelWindow {
    id: root

    property bool open: false
    // The monitor the launcher should appear on. Captured at open() time so a
    // wandering cursor (follow_mouse) can't remap the window mid-use.
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-launcher"
    WlrLayershell.layer: WlrLayer.Overlay
    // Grab the keyboard only while open, so typing goes to the search box and
    // other windows keep their focus the rest of the time.
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    // Ignore the bar's exclusive zone so the scrim covers the full output,
    // including the strip under the bar (otherwise the top 44px stays bright).
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    // Stay mapped during the close animation, mirroring the popups.
    visible: open || exitTrans.running

    // ---- data ----------------------------------------------------------
    property string query: ""
    property int selectedIndex: 0
    // Reading DesktopEntries.applications in a live binding keeps the (lazy)
    // service populated; .values is the plain JS array of entries.
    readonly property var allApps: DesktopEntries.applications.values
    readonly property var appResults: filterApps(query, allApps)
    // A pure arithmetic query (or one forced with a leading "=") gets a synthetic
    // calculator row pinned to the TOP; activate() copies its result.
    readonly property var calcResult: evalMath(query)
    readonly property bool hasCalc: calcResult !== null
    // Whenever the user has typed something, append a synthetic web-search row as
    // the last result so it's always visible and reachable by arrow keys.
    // activate() decides whether a given row launches an app or runs the search.
    property var results: {
        if (query.length === 0) return appResults
        const base = appResults.concat([{ webSearch: true }])
        return hasCalc ? [{ calc: true }].concat(base) : base
    }

    // Evaluate a numeric expression safely: only digits/operators/parens pass the
    // gate (no letters → nothing to reference), so the eval can't reach any scope.
    // A plain number isn't treated as math unless the user leads with "=".
    function evalMath(raw) {
        let s = (raw || "").trim()
        const forced = s.startsWith("=")
        if (forced) s = s.slice(1).trim()
        if (s.length === 0) return null
        if (!/^[0-9+\-*/%.()\s]+$/.test(s)) return null
        if (!forced && !/[0-9]\s*[-+*/%]\s*[-+(]*\s*[0-9]/.test(s)) return null
        try {
            const v = Function('"use strict"; return (' + s + ')')()
            if (typeof v === "number" && isFinite(v))
                return { expr: s, value: Math.round(v * 1e10) / 1e10 }
        } catch (e) {}
        return null
    }

    function filterApps(q, apps) {
        const list = (apps || []).filter(a => a && a.name && !a.noDisplay)
        if (!q)
            return list.slice().sort((a, b) => a.name.localeCompare(b.name))
        const ql = q.toLowerCase()
        return list
            .filter(a => a.name.toLowerCase().includes(ql))
            .sort((a, b) => {
                // Prefix matches rank above mid-string matches.
                const ar = a.name.toLowerCase().startsWith(ql) ? 0 : 1
                const br = b.name.toLowerCase().startsWith(ql) ? 0 : 1
                if (ar !== br) return ar - br
                return a.name.localeCompare(b.name)
            })
    }

    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        searchInput.text = ""   // resets query + selection via onTextChanged
        selectedIndex = 0
        open = true
        Qt.callLater(searchInput.forceActiveFocus)
    }
    function closeMenu() { open = false }
    function launch(entry) {
        if (!entry) return
        entry.execute()
        closeMenu()
    }

    // Activate a result row: the calc row copies its result, the synthetic
    // web-search row runs the search, every other row is a real app to launch.
    function activate(item) {
        if (!item) return
        if (item.calc) root.copyResult()
        else if (item.webSearch) root.searchWeb(root.query)
        else root.launch(item)
    }
    function copyResult() {
        if (!root.hasCalc) return
        Quickshell.execDetached(["wl-copy", "--", String(root.calcResult.value)])
        closeMenu()
    }

    // Opens the query in the default browser (zen, via xdg-open). %1 is the
    // URL-encoded query — change searchUrl to use a different engine.
    property string searchUrl: "https://www.google.com/search?q=%1"
    function searchWeb(q) {
        if (!q) return
        Quickshell.execDetached(["xdg-open", root.searchUrl.arg(encodeURIComponent(q))])
        closeMenu()
    }
    function moveSel(delta) {
        if (results.length === 0) return
        selectedIndex = Math.max(0, Math.min(results.length - 1, selectedIndex + delta))
    }

    IpcHandler {
        target: "launcher"
        // Only `toggle` is wired to a key (Super tap / Super+R in hyprland.conf).
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
    }

    // ---- scrim (click-outside to dismiss) ------------------------------
    // Transparent (no dimming), like the control popup: the desktop shows
    // through crisp and only the card is frosted, via the ignore_alpha
    // layerrule for quickshell-launcher in hyprland.conf.
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.closeMenu()
    }

    // ---- the floating launcher ----------------------------------------
    // Only the search box is a frosted surface; the results below have no
    // background and float over the clear desktop. The search box is centred
    // both ways; results grow downward from it without shifting it.
    Item {
        id: morph
        width: searchBox.width
        height: layoutCol.height
        x: (parent.width - width) / 2
        // Centre the *search box* on screen (its half-height, not the whole
        // column's) so it stays put as the results list grows and shrinks.
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

            // ── the only frosted surface: the search box ──
            Rectangle {
                id: searchBox
                width: 480
                height: 52
                radius: Theme.popupRadius
                color: Theme.glassBg
                border.color: Theme.glassBorder
                border.width: 1

                // Swallow clicks on the box so they don't fall through to the
                // scrim and close the launcher.
                MouseArea { anchors.fill: parent }

                // Thin highlight along the top edge, same as the popups.
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
                            root.activate(root.results[root.selectedIndex])
                            e.accepted = true
                        } else if (e.key === Qt.Key_Escape) {
                            root.closeMenu(); e.accepted = true
                        }
                    }

                    Text {
                        anchors.fill: parent
                        verticalAlignment: Text.AlignVCenter
                        text: "Search apps…"
                        color: Theme.textMuted
                        font: searchInput.font
                        visible: searchInput.text.length === 0
                    }
                }
            }

            // ── results: their own frosted panel, floating below the box ──
            // glassBg (alpha 0.22) clears the blur threshold, so the whole panel
            // frosts; the row hover/selected tints sit below it and just read as
            // faint highlights on top of the frost.
            Rectangle {
                id: resultsPanel
                width: searchBox.width
                height: resultsCol.implicitHeight + 16
                radius: Theme.popupRadius
                color: Theme.glassBg
                border.color: Theme.glassBorder
                border.width: 1

                // Swallow clicks on the panel background so they don't fall
                // through to the scrim and close the launcher.
                MouseArea { anchors.fill: parent }

                // Thin highlight along the top edge, same as the search box.
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
                        height: Math.min(root.results.length, 8) * 42
                        visible: root.results.length > 0
                        clip: true
                        model: root.results
                        currentIndex: root.selectedIndex
                        boundsBehavior: Flickable.StopAtBounds
                        onCurrentIndexChanged: positionViewAtIndex(currentIndex, ListView.Contain)

                        delegate: Rectangle {
                            id: appRow
                            required property var modelData
                            required property int index
                            // The synthetic last row (see root.results) is the
                            // web-search action. Detect it by position — reading
                            // a custom prop off the mixed app/web model via
                            // modelData is unreliable, so use the index instead.
                            readonly property bool isWeb: root.query.length > 0
                                && index === root.results.length - 1
                            // calc row, when present, is always pinned to index 0
                            readonly property bool isCalc: root.hasCalc && index === 0
                            width: ListView.view.width
                            height: 42
                            radius: 11
                            color: ListView.isCurrentItem
                                ? Theme.rowSelected
                                : (rowMa.containsMouse ? Theme.rowHover : "transparent")
                            Behavior on color { ColorAnimation { duration: 120 } }

                            // App rows get a dot; the web-search row gets a
                            // magnifier glyph in its place.
                            Rectangle {
                                id: dot
                                visible: !appRow.isWeb && !appRow.isCalc
                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: 8
                                height: 8
                                radius: 4
                                color: appRow.ListView.isCurrentItem ? Theme.accent : "transparent"
                                border.width: appRow.ListView.isCurrentItem ? 0 : 1
                                border.color: Theme.dotBorder
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            Text {
                                visible: appRow.isWeb || appRow.isCalc
                                anchors.left: parent.left
                                anchors.leftMargin: 12
                                anchors.verticalCenter: parent.verticalCenter
                                // nf-md-equal on the calc row, nf-md-magnify on web
                                text: String.fromCodePoint(appRow.isCalc ? 0xF0DF1 : 0xF0349)
                                font.family: Theme.icon
                                font.pixelSize: 16
                                color: Theme.accent
                            }

                            Text {
                                // Fixed left edge so app names and the search
                                // label line up regardless of leading icon.
                                anchors.left: parent.left
                                anchors.leftMargin: 34
                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                text: appRow.isWeb
                                    ? "Search the web for “" + root.query + "”"
                                    : (appRow.modelData && appRow.modelData.name) || ""
                                color: appRow.ListView.isCurrentItem ? Theme.textBright : Theme.textTertiary
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }

                            MouseArea {
                                id: rowMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onEntered: root.selectedIndex = appRow.index
                                // Pass the real array element (not modelData) so
                                // activate() reads webSearch reliably.
                                onClicked: root.activate(root.results[appRow.index])
                            }
                        }
                    }

                    // Only reachable with an empty query and no apps installed;
                    // a non-empty query always has at least the web-search row.
                    Text {
                        visible: root.results.length === 0
                        width: parent.width
                        text: "No applications"
                        color: Theme.textMuted
                        font.pixelSize: 13
                        font.italic: true
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 6
                        bottomPadding: 6
                    }
                }
            }
        }
    }
}
