import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland

ShellRoot {
    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: bar
            property var modelData
            screen: modelData

            WlrLayershell.namespace: "quickshell-bar"

            anchors {
                top: true
                left: true
                right: true
            }
            height: 44
            color: "transparent"

            component Bubble: Rectangle {
                height: 32
                radius: 16
                color: Qt.rgba(0.1, 0.1, 0.14, 0.22)
                border.color: Qt.rgba(1, 1, 1, 0.18)
                border.width: 1
            }


            Bubble {
                id: wsBubble
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: wsRow.width + 10

                readonly property int wsPerPage: 5
                readonly property int focusedWsId: Hyprland.focusedWorkspace?.id ?? 1
                readonly property int wsPageStart: Math.floor((focusedWsId - 1) / wsPerPage) * wsPerPage + 1

                Row {
                    id: wsRow
                    anchors.centerIn: parent
                    spacing: 4

                    Repeater {
                        model: wsBubble.wsPerPage

                        delegate: Rectangle {
                            id: wsItem
                            required property int index
                            readonly property int wsId: wsBubble.wsPageStart + index
                            readonly property bool isActive: Hyprland.focusedWorkspace?.id === wsId
                            readonly property bool isOccupied: Hyprland.workspaces.values.some(ws => ws.id === wsId)

                            width: 26
                            height: 22
                            radius: 11
                            color: isActive
                                ? "#a8b5e8"
                                : (isOccupied ? Qt.rgba(1, 1, 1, 0.12) : "transparent")

                            Behavior on color { ColorAnimation { duration: 200 } }

                            Text {
                                anchors.centerIn: parent
                                text: wsItem.wsId
                                color: wsItem.isActive
                                    ? "#1a1a2e"
                                    : (wsItem.isOccupied ? "#e6e6f0" : "#6a6a78")
                                font.pixelSize: 11
                                font.weight: Font.Bold

                                Behavior on color { ColorAnimation { duration: 200 } }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Hyprland.dispatch(`workspace ${wsItem.wsId}`)
                            }
                        }
                    }
                }
            }

            Bubble {
                id: dateBubble
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                width: dateRow.width + 24

                Row {
                    id: dateRow
                    anchors.centerIn: parent
                    spacing: 10

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(clock.date, "HH:mm")
                        color: "#e6e6f0"
                        font.pixelSize: 14
                        font.family: "monospace"
                        font.weight: Font.Medium
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 1
                        height: 14
                        color: Qt.rgba(1, 1, 1, 0.15)
                    }

                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Qt.formatDateTime(clock.date, "ddd, MMM d")
                        color: "#a8a8b8"
                        font.pixelSize: 13
                    }
                }
            }
        }
    }
}
