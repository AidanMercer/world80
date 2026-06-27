import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import "../common"

// Native notification daemon + on-theme popup stack. The server hands us each
// notification; we set tracked=true to keep it alive, push it onto our own list
// (newest on top, capped), and each card auto-dismisses on a timer unless it's
// Critical or being hovered. Popups stack top-right on the focused monitor, below
// the bar. Glass by default, neon chamfer on cyber themes.
Scope {
    id: scope

    // our own display list of live Notification objects (newest first, capped)
    property var popups: []
    readonly property int maxVisible: 5

    function remove(n) {
        scope.popups = scope.popups.filter(x => x !== n)
        if (n) n.dismiss()
    }

    NotificationServer {
        id: server
        keepOnReload: false
        actionsSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        imageSupported: true
        persistenceSupported: false

        onNotification: (n) => {
            n.tracked = true
            scope.popups = [n, ...scope.popups].slice(0, scope.maxVisible)
        }
    }

    PanelWindow {
        id: win
        visible: scope.popups.length > 0

        // ride along with whichever monitor has focus (no per-screen duplication)
        screen: {
            const fm = Hyprland.focusedMonitor
            if (fm) {
                for (const s of Quickshell.screens)
                    if (s.name === fm.name) return s
            }
            return null
        }

        WlrLayershell.namespace: "quickshell-notifications"
        WlrLayershell.layer: WlrLayer.Top
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors { top: true; right: true }
        margins { top: Theme.barHeight + 8; right: 10 }
        implicitWidth: 360
        implicitHeight: Math.max(1, col.implicitHeight)

        Column {
            id: col
            anchors.right: parent.right
            width: parent.width
            spacing: 8

            Repeater {
                model: scope.popups

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property int urgency: modelData.urgency
                    readonly property color accentCol:
                        urgency === NotificationUrgency.Critical ? Theme.danger
                        : urgency === NotificationUrgency.Low ? Theme.textMuted
                        : Theme.accent

                    width: parent.width
                    radius: Theme.cyber ? 3 : 14
                    color: Theme.cyber ? Qt.rgba(0.04, 0.04, 0.07, 0.96)
                                       : Qt.rgba(0.10, 0.10, 0.13, 0.94)
                    border.width: 1
                    border.color: Theme.cyber ? Theme.neon : Theme.glassBorder
                    implicitHeight: layout.implicitHeight + 24

                    // entrance: fade + slide in from the right
                    opacity: 0
                    transform: Translate { id: slide; x: 24 }
                    Component.onCompleted: enter.start()
                    ParallelAnimation {
                        id: enter
                        NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
                        NumberAnimation { target: slide; property: "x"; from: 24; to: 0; duration: 220; easing.type: Easing.OutCubic }
                    }

                    // urgency stripe down the left edge
                    Rectangle {
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: 3
                        radius: parent.radius
                        color: card.accentCol
                    }

                    // auto-dismiss unless critical or hovered
                    Timer {
                        interval: card.urgency === NotificationUrgency.Low ? 1800 : 2200
                        running: card.urgency !== NotificationUrgency.Critical && !cardHover.containsMouse
                        repeat: false
                        onTriggered: scope.remove(card.modelData)
                    }

                    MouseArea {
                        id: cardHover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }

                    Column {
                        id: layout
                        anchors {
                            left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                            leftMargin: 16; rightMargin: 12
                        }
                        spacing: 6

                        // header: app icon + app name + close
                        Item {
                            width: parent.width
                            height: 16

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 7

                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 13; height: 13
                                    sourceSize.width: 13; sourceSize.height: 13
                                    smooth: true
                                    visible: status === Image.Ready
                                    source: card.modelData.appIcon
                                        ? (card.modelData.appIcon.includes("/")
                                            ? card.modelData.appIcon
                                            : Quickshell.iconPath(card.modelData.appIcon, true))
                                        : ""
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: (card.modelData.appName || "Notification").toUpperCase()
                                    color: card.accentCol
                                    font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                    font.letterSpacing: 2
                                }
                            }

                            Text {
                                id: closeBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: String.fromCodePoint(0xF0156) // mdi close
                                font.family: Theme.icon
                                font.pixelSize: 13
                                color: closeMa.containsMouse ? Theme.textBright : Theme.textMuted

                                MouseArea {
                                    id: closeMa
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: scope.remove(card.modelData)
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: card.modelData.summary
                            color: Theme.textBright
                            font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Text {
                            width: parent.width
                            visible: text.length > 0
                            text: card.modelData.body
                            textFormat: Text.StyledText
                            color: Theme.textMuted
                            font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                            maximumLineCount: 4
                            onLinkActivated: (l) => Qt.openUrlExternally(l)
                        }

                        // action buttons (if the notification ships any)
                        Row {
                            width: parent.width
                            spacing: 6
                            visible: card.modelData.actions.length > 0
                            topPadding: 2

                            Repeater {
                                model: card.modelData.actions

                                delegate: Rectangle {
                                    required property var modelData
                                    height: 24
                                    width: actText.implicitWidth + 22
                                    radius: Theme.cyber ? 2 : 8
                                    color: actMa.containsMouse ? Theme.rowSelected : Theme.rowHover
                                    border.width: 1
                                    border.color: Theme.divider

                                    Text {
                                        id: actText
                                        anchors.centerIn: parent
                                        text: parent.modelData.text
                                        color: Theme.textTertiary
                                        font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        id: actMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            parent.modelData.invoke()
                                            scope.remove(card.modelData)
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
