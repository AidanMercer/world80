import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// The only thing split mode draws: a hairline down the seam and one small pill
// per half showing that half's spaces, so a single panel reads as two screens.
// One instance per monitor (Variants in shell.qml), but only the split monitor
// ever shows anything. Fully click-through — it's a readout, not a control.
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

    Repeater {
        model: [
            { side: "l", centre: SplitBus.seam / 2, cur: SplitBus.left },
            { side: "r", centre: SplitBus.seam + (hud.width - SplitBus.seam) / 2, cur: SplitBus.right }
        ]

        delegate: Rectangle {
            id: pill
            required property var modelData
            readonly property bool focused: SplitBus.zone === modelData.side

            x: Math.round(modelData.centre - width / 2)
            y: Theme.barHeight + 12
            width: 26
            height: 24
            radius: 12

            color: Qt.rgba(ThemeConfig.glass.r, ThemeConfig.glass.g, ThemeConfig.glass.b, pill.focused ? 0.82 : 0.72)
            border.width: 1
            border.color: pill.focused
                ? Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55)
                : Theme.glassBorder
            opacity: pill.focused ? 1.0 : 0.8

            Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 160 } }
            Behavior on border.color { ColorAnimation { duration: 160 } }

            Text {
                anchors.centerIn: parent
                text: String(pill.modelData.cur)
                font.pixelSize: 12
                font.family: Theme.mono
                font.weight: Font.Bold
                color: pill.focused ? Theme.accent : Theme.textSecondary

                Behavior on color { ColorAnimation { duration: 160 } }
            }
        }
    }
}
