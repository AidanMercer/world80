pragma Singleton
import QtQuick

QtObject {
    readonly property color glassBg: Qt.rgba(0.10, 0.10, 0.14, 0.22)
    readonly property color glassBorder: Qt.rgba(1, 1, 1, 0.18)
    readonly property color glassHighlight: Qt.rgba(1, 1, 1, 0.10)

    readonly property color rowHover: Qt.rgba(1, 1, 1, 0.04)
    readonly property color rowSelected: Qt.rgba(1, 1, 1, 0.09)
    readonly property color divider: Qt.rgba(1, 1, 1, 0.06)
    readonly property color dotBorder: Qt.rgba(1, 1, 1, 0.22)
    readonly property color occupiedFill: Qt.rgba(1, 1, 1, 0.08)
    readonly property color subtleDivider: Qt.rgba(1, 1, 1, 0.15)
    readonly property color trackBg: Qt.rgba(1, 1, 1, 0.08)
    readonly property color trackBg2: Qt.rgba(1, 1, 1, 0.10)

    readonly property color textPrimary: "#e6e6f0"
    readonly property color textBright: "#ffffff"
    readonly property color textSecondary: "#a8a8b8"
    readonly property color textTertiary: "#c0c0c8"
    readonly property color textMuted: "#6a6a78"
    readonly property color textDim: "#7a7a88"

    readonly property color accent: "#a8b5e8"
    readonly property color volGradStart: "#8a99e8"
    readonly property color volGradEnd: "#c8a5e8"
    readonly property color volGradMuteStart: "#555"
    readonly property color volGradMuteEnd: "#666"
    readonly property color thumbBorder: Qt.rgba(0, 0, 0, 0.25)

    readonly property int barHeight: 44
    readonly property int bubbleHeight: 32
    readonly property int bubbleRadius: 16
    readonly property int popupRadius: 20

    readonly property string mono: "monospace"
    readonly property string icon: "Symbols Nerd Font"
}
