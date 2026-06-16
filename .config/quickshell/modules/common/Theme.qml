pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    // Auto-generated palette, pulled from the wallpaper by scripts/gen-colors.sh
    // (written to ~/.cache/quickshell/colors.json). Empty until the first read;
    // every colour below falls back to its hand-picked default when a key is
    // missing, so the bar still looks right before the first generation / if the
    // file is gone. Because these are bindings on `pal`, a wallpaper swap re-tints
    // everything live — and the colour Behaviors animate the change.
    property var pal: ({})
    function reloadColors() { palFile.reload() }
    function _c(key, fallback) { return pal[key] !== undefined ? pal[key] : fallback }

    property FileView palFile: FileView {
        path: (Quickshell.env("HOME") || "") + "/.cache/quickshell/colors.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: {
            try { root.pal = JSON.parse(palFile.text()) }
            catch (e) { root.pal = ({}) }
        }
        onLoadFailed: root.pal = ({})
    }

    readonly property color glassBg: _c("glassBg", Qt.rgba(0.08, 0.08, 0.10, 0.45))
    readonly property color glassBorder: _c("glassBorder", Qt.rgba(1, 1, 1, 0.18))
    readonly property color glassHighlight: Qt.rgba(1, 1, 1, 0.10)

    readonly property color rowHover: Qt.rgba(1, 1, 1, 0.04)
    readonly property color rowSelected: Qt.rgba(1, 1, 1, 0.09)
    readonly property color divider: Qt.rgba(1, 1, 1, 0.06)
    readonly property color dotBorder: Qt.rgba(1, 1, 1, 0.22)
    readonly property color occupiedFill: Qt.rgba(1, 1, 1, 0.08)
    readonly property color subtleDivider: Qt.rgba(1, 1, 1, 0.15)
    readonly property color trackBg: Qt.rgba(1, 1, 1, 0.08)
    readonly property color trackBg2: Qt.rgba(1, 1, 1, 0.10)

    readonly property color textPrimary: _c("textPrimary", "#e6e6f0")
    readonly property color textBright: _c("textBright", "#ffffff")
    readonly property color textSecondary: _c("textSecondary", "#c4c4d0")
    readonly property color textTertiary: _c("textTertiary", "#d4d4dc")
    readonly property color textMuted: _c("textMuted", "#a0a4b0")
    readonly property color textDim: _c("textDim", "#a8acb6")
    // Contrast halo painted behind the bar's bare elements so they stay legible
    // over high-variance wallpapers (bright clouds with dark gaps).
    readonly property color textShadow: _c("textShadow", Qt.rgba(0, 0, 0, 0.55))

    readonly property color accent: _c("accent", "#a8b5e8")
    readonly property color danger: "#e8919b"
    readonly property color warning: "#e8c89b"
    readonly property color dangerHover: Qt.rgba(0.91, 0.45, 0.50, 0.13)
    readonly property color volGradStart: _c("volGradStart", "#8a99e8")
    readonly property color volGradEnd: _c("volGradEnd", "#c8a5e8")
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
