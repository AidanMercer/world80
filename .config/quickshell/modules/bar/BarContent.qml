import QtQuick
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "../common"

// The default bar's contents, as a plain Item so Bar.qml can load either this or
// a theme's own bar.qml into its layer surface. `barWindow` is the wrapper
// PanelWindow, needed by the popups/tooltip for positioning and by Workspaces to
// find its Hyprland monitor. The full layout is the horizontal top bar; a theme
// that flips bar_position without shipping its own bar.qml gets a minimal
// vertical fallback (workspaces + status button) instead of sideways soup.
Item {
    id: root
    anchors.fill: parent

    required property var barWindow
    readonly property int bubblePad: 14
    readonly property bool vertical: barWindow.vertical === true

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

    Loader {
        anchors.fill: parent
        sourceComponent: root.vertical ? verticalLayout : horizontalLayout
    }

    Component {
        id: verticalLayout

        Item {
            Column {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                anchors.topMargin: 8
                spacing: 10

                StatusButton {
                    anchors.horizontalCenter: parent.horizontalCenter
                    active: ControlBus.openMonitor === (root.barWindow.screen ? root.barWindow.screen.name : "")
                    onPopupToggleRequested: ControlBus.toggle(root.barWindow.screen ? root.barWindow.screen.name : "")
                }

                Workspaces {
                    vertical: true
                    monitor: Hyprland.monitorFor(root.barWindow.screen)
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    Component {
        id: horizontalLayout

        Item {
            // Glass pill behind the centre cluster (workspaces + status button). Declared
            // before the content so it paints underneath.
            Bubble {
                id: centerBubble
                visible: ThemeConfig.bubbles
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
                width: workspaces.width + 8 + statusButton.width + root.bubblePad * 2
            }

            // Glass pill behind the side readouts (CPU / RAM / battery).
            Bubble {
                id: rightBubble
                visible: ThemeConfig.bubbles
                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: resourceBubble.width + root.bubblePad * 2
            }

            // Glass pill behind the now-playing widget on the left; hides with it.
            Bubble {
                id: leftBubble
                visible: ThemeConfig.bubbles && mediaWidget.active
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: mediaWidget.width + root.bubblePad * 2
            }

            // Top-left: now-playing (MPRIS). Bare unless a theme turns bubbles on.
            MediaWidget {
                id: mediaWidget
                anchors.left: parent.left
                anchors.leftMargin: 8 + (ThemeConfig.bubbles ? root.bubblePad : 6)
                anchors.verticalCenter: parent.verticalCenter
            }

            // Top-right: live CPU / RAM / GPU usage.
            ResourceBubble {
                id: resourceBubble
                occluded: root.barWindow.occluded === true
                anchors.horizontalCenter: rightBubble.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter
            }


            Workspaces {
                id: workspaces
                monitor: Hyprland.monitorFor(root.barWindow.screen)
                x: centerBubble.x + root.bubblePad
                anchors.verticalCenter: parent.verticalCenter
            }

            // Single status button just right of the workspaces. Toggles the ControlPopup
            // (which now lives in shell.qml, decoupled from the bar) via ControlBus.
            StatusButton {
                id: statusButton
                active: ControlBus.openMonitor === (root.barWindow.screen ? root.barWindow.screen.name : "")
                anchors.left: workspaces.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                onPopupToggleRequested: ControlBus.toggle(root.barWindow.screen ? root.barWindow.screen.name : "")
            }

            // Hover the ResourceBubble to see the breakdown behind the percentages
            // (load averages, core count, RAM in GB). Lives in its own layer-shell
            // overlay so it can spill below the bar.
            ResourceTooltip {
                barWindow: root.barWindow
                open: resourceBubble.hovered
                cpuPercent: resourceBubble.cpuPercent
                ramPercent: resourceBubble.ramPercent
                load1: resourceBubble.load1
                load5: resourceBubble.load5
                load15: resourceBubble.load15
                cpuCores: resourceBubble.cpuCores
                ramUsedGb: resourceBubble.ramUsedGb
                ramTotalGb: resourceBubble.ramTotalGb
            }
        }
    }
}
