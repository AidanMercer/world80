import QtQuick
import Quickshell
import Quickshell.Hyprland
import "../common"

Item {
    id: root
    width: wsRow.width
    height: Theme.bubbleHeight

    // The Hyprland monitor this bar lives on; each bar passes its own.
    required property var monitor

    // A strip of `wsCount` workspaces that PAGES in blocks of 10: page 1 is
    // 1..10, page 2 is 11..20, etc.
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

    // Hyprland.toplevels stays empty until refreshToplevels() is called. At
    // login the bar starts with windows already open and no event incoming, so
    // without this kick every workspace reads as unoccupied. We re-query on each
    // window lifecycle event to keep occupancy in sync.
    Component.onCompleted: Hyprland.refreshToplevels()
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindow":
            case "movewindowv2":
                Hyprland.refreshToplevels()
            }
        }
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

                readonly property bool isOccupied: Hyprland.toplevels.values
                    .some(t => (t.workspace?.id ?? -1) === wsId)

                width: root.slotSize
                height: root.slotSize

                Rectangle {
                    anchors.centerIn: parent
                    width: 6
                    height: 6
                    radius: 3
                    color: slot.isActive ? Theme.textBright
                         : slot.isOccupied ? Theme.textMuted
                         : Theme.textMuted
                    opacity: slot.isActive ? 1.0
                           : slot.isOccupied ? 0.9
                           : 0.4
                    Behavior on color { ColorAnimation { duration: 200 } }
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
