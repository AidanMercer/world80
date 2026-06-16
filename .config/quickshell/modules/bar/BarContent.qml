import QtQuick
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "../common"

// The default bar's contents, as a plain Item so Bar.qml can load either this or
// a theme's own bar.qml into its layer surface. `barWindow` is the wrapper
// PanelWindow, needed by the popups/tooltip for positioning and by Workspaces to
// find its Hyprland monitor.
Item {
    id: root
    anchors.fill: parent

    required property var barWindow
    readonly property int bubblePad: 14

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

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

    // Top-right: live CPU / RAM / GPU usage.
    ResourceBubble {
        id: resourceBubble
        anchors.horizontalCenter: rightBubble.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
    }

    Workspaces {
        id: workspaces
        monitor: Hyprland.monitorFor(root.barWindow.screen)
        x: centerBubble.x + root.bubblePad
        anchors.verticalCenter: parent.verticalCenter
    }

    // Single status button just right of the workspaces. Opens the ControlPopup
    // (network / sound / bluetooth / power) and owns the uptime + network status
    // the popup displays.
    StatusButton {
        id: statusButton
        active: controlPopup.open
        anchors.left: workspaces.right
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        onPopupToggleRequested: ControlBus.toggle(root.barWindow.screen ? root.barWindow.screen.name : "")
    }

    ControlPopup {
        id: controlPopup
        barWindow: root.barWindow
        anchorCenterX: statusButton.x + statusButton.width / 2
        connType: statusButton.connType
        connName: statusButton.connName
        uptimeText: statusButton.uptimeText
        onConnectionChanged: statusButton.refresh()
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
