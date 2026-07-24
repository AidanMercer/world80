import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// The only thing split mode draws: a hairline down the seam, so a single panel
// reads as two screens. Which space each half is on is the bar's job — the theme
// decks say it already. One instance per monitor (Variants in shell.qml), but
// only the split monitor ever shows anything. Fully click-through.
PanelWindow {
    id: hud
    required property var modelData
    screen: modelData

    // keyed off modelData, not screen: PanelWindow re-evaluates `screen` when
    // visibility changes, and reading it here loops back through `visible`
    readonly property bool mine: SplitBus.on && modelData && modelData.name === SplitBus.monitor

    // don't float over a fullscreen window
    readonly property bool covered: {
        const w = Hyprland.focusedWorkspace
        return !!(w && w.lastIpcObject && w.lastIpcObject.hasfullscreen)
    }
    Connections {
        target: Hyprland
        function onRawEvent(event) {
            if (event.name === "fullscreen")
                Hyprland.refreshWorkspaces()
        }
    }

    visible: hud.mine && !hud.covered

    WlrLayershell.namespace: "quickshell-split"
    WlrLayershell.layer: WlrLayer.Top
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}

    readonly property color seamColor: Qt.rgba(Theme.textBright.r, Theme.textBright.g, Theme.textBright.b, 0.16)

    Rectangle {
        x: Math.round(SplitBus.seam) - 1
        width: 2
        height: parent.height
        gradient: Gradient {
            GradientStop { position: 0.00; color: "transparent" }
            GradientStop { position: 0.08; color: hud.seamColor }
            GradientStop { position: 0.92; color: hud.seamColor }
            GradientStop { position: 1.00; color: "transparent" }
        }
        Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }
}
