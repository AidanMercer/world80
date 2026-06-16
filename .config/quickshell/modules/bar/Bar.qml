import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import Quickshell.Services.Pipewire
import "../common"

PanelWindow {
    id: bar
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-bar"

    anchors {
        top: true
        left: true
        right: true
    }
    implicitHeight: Theme.barHeight
    color: "transparent"

    readonly property int bubblePad: 14

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

    // Glass pill behind the centre cluster (workspaces + status button). Declared
    // before the content so it paints underneath.
    Bubble {
        id: centerBubble
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: workspaces.width + 8 + statusButton.width + bar.bubblePad * 2
    }

    // Glass pill behind the side readouts (CPU / RAM / battery).
    Bubble {
        id: rightBubble
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        width: resourceBubble.width + bar.bubblePad * 2
    }

    // Top-right: live CPU / RAM / GPU usage.
    ResourceBubble {
        id: resourceBubble
        anchors.horizontalCenter: rightBubble.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
    }

    Workspaces {
        id: workspaces
        monitor: Hyprland.monitorFor(bar.screen)
        x: centerBubble.x + bar.bubblePad
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
        onPopupToggleRequested: ControlBus.toggle(bar.screen ? bar.screen.name : "")
    }

    ControlPopup {
        id: controlPopup
        barWindow: bar
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
        barWindow: bar
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
