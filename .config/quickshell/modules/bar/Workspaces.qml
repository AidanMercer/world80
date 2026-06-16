import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Widgets
import "../common"

Item {
    id: root
    width: wsRow.width
    height: Theme.bubbleHeight

    // The Hyprland monitor this bar lives on; each bar passes its own.
    required property var monitor

    // A strip of `wsCount` workspaces that PAGES in blocks of 10: page 1 is
    // 1..10, page 2 is 11..20, etc. Each slot shows the icon of an app living
    // on that workspace, or a small dot when empty.
    readonly property int wsCount: 10
    // This monitor's active workspace — not the global focus — so each
    // monitor's bar reflects the workspace it is actually showing.
    readonly property int activeWsId: monitor?.activeWorkspace?.id ?? 1
    // The first workspace id of the page the active workspace lives on.
    // floor((id-1)/10)*10 + 1 maps 1..10 -> 1, 11..20 -> 11, and so on. Special
    // / scratch workspaces have negative ids; fall back to page 1 for those.
    readonly property int pageBase: activeWsId >= 1
        ? Math.floor((activeWsId - 1) / wsCount) * wsCount + 1
        : 1

    readonly property int slotSize: 22
    readonly property int slotSpacing: 4

    // Keep the desktop-entry database alive. DesktopEntries.applications is a
    // LAZY model: it only scans .desktop files while something is observing it,
    // so heuristicLookup() returns null unless we hold a live binding to it.
    readonly property int _desktopEntriesKeepAlive: DesktopEntries.applications.values.length

    // Hyprland.toplevels stays empty until refreshToplevels() is called. At
    // login the bar starts with windows already open and no event incoming, so
    // without this kick every slot reads as unoccupied. A window opened via
    // `openwindow` also arrives with no class yet, so re-query on each window
    // lifecycle event to keep every window's class populated.
    Component.onCompleted: Hyprland.refreshToplevels()
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindow":
            case "movewindowv2":
            case "activewindowv2": // focus changed — refresh focusHistoryID
                Hyprland.refreshToplevels()
            }
        }
    }

    // Resolve a window class to an icon URL, degrading gracefully:
    //   desktop-entry icon  ->  the class name as an icon  ->  generic app
    function iconForClass(cls) {
        if (!cls)
            return ""
        const entry = DesktopEntries.heuristicLookup(cls)
        const name = (entry && entry.icon) ? entry.icon : cls.toLowerCase()
        return Quickshell.iconPath(name, "application-x-executable")
    }

    // Pick the icon for a workspace: the window that is — or was most recently —
    // focused there. Hyprland ranks windows by focusHistoryID (0 = focused),
    // so the smallest value wins. Just-opened windows can briefly lack a class,
    // so skip those and fall back to a generic icon if none has one yet.
    function iconForWindows(wins) {
        let best = null
        let bestFh = Infinity
        for (const w of wins) {
            const cls = w.lastIpcObject?.class ?? ""
            if (!cls)
                continue
            const fh = w.lastIpcObject?.focusHistoryID ?? Infinity
            if (fh < bestFh) {
                best = w
                bestFh = fh
            }
        }
        return best ? iconForClass(best.lastIpcObject.class)
                    : Quickshell.iconPath("application-x-executable")
    }

    Row {
        id: wsRow
        anchors.centerIn: parent
        spacing: root.slotSpacing

        Repeater {
            model: root.wsCount

            delegate: Item {
                id: slot
                required property int index
                readonly property int wsId: root.pageBase + index
                readonly property bool isActive: root.activeWsId === wsId

                readonly property var windowsHere: Hyprland.toplevels.values
                    .filter(t => (t.workspace?.id ?? -1) === wsId)
                readonly property bool isOccupied: windowsHere.length > 0
                readonly property string iconSource: isOccupied
                    ? root.iconForWindows(windowsHere)
                    : ""

                width: root.slotSize
                height: root.slotSize

                // Empty workspace: a small dot.
                Rectangle {
                    anchors.centerIn: parent
                    visible: !slot.isOccupied
                    width: 6
                    height: 6
                    radius: 3
                    color: Theme.textBright
                    opacity: slot.isActive ? 1.0 : 0.4
                    Behavior on color { ColorAnimation { duration: 200 } }
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                // Occupied workspace: the app icon. Dimmed unless active.
                IconImage {
                    anchors.centerIn: parent
                    visible: slot.isOccupied
                    width: 16
                    height: 16
                    source: slot.iconSource
                    opacity: slot.isActive ? 1.0 : 0.7
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Hyprland.dispatch(`workspace ${slot.wsId}`)
                }
            }
        }
    }
}
