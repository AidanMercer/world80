pragma Singleton
import QtQuick

// Shared design tokens for the repo's own chrome (popup tabs, default bar, osd).
// Accents come straight from ThemeConfig; the text ramp and glass are derived
// from the `text` / `glass` tokens, so a theme's config.toml can restyle the
// shared surfaces without any per-tab edits. With the stock tokens the derived
// ramp lands on the old hand-picked hexes (±1/255). `cyber` still gates the
// HUD-flavored tinting on the popup.
QtObject {
    id: root

    readonly property bool cyber: ThemeConfig.cyber
    readonly property color neon: ThemeConfig.accent
    readonly property color cyan: ThemeConfig.accent2
    readonly property color magenta: ThemeConfig.accent3
    readonly property color amber: ThemeConfig.accentWarn

    function mix(a, b, t) {
        return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
    }
    readonly property color _white: "#ffffff"

    // light glass flips the overlay direction: white-alpha borders/hovers are
    // invisible on a near-white panel, so everything derives ink-based instead
    readonly property bool light: (0.299 * ThemeConfig.glass.r + 0.587 * ThemeConfig.glass.g + 0.114 * ThemeConfig.glass.b) > 0.5
    readonly property color _boost: light ? Qt.rgba(0, 0, 0, 1) : _white

    readonly property color glassBg: Qt.rgba(ThemeConfig.glass.r, ThemeConfig.glass.g, ThemeConfig.glass.b, 0.62)
    readonly property color glassBorder: light ? Qt.rgba(0, 0, 0, 0.13) : Qt.rgba(1, 1, 1, 0.24)
    readonly property color glassHighlight: Qt.rgba(1, 1, 1, light ? 0.50 : 0.10)

    readonly property color rowHover: cyber ? Qt.rgba(cyan.r, cyan.g, cyan.b, 0.07) : light ? Qt.rgba(0, 0, 0, 0.05) : Qt.rgba(1, 1, 1, 0.04)
    readonly property color rowSelected: cyber ? Qt.rgba(neon.r, neon.g, neon.b, 0.15) : light ? Qt.rgba(0, 0, 0, 0.09) : Qt.rgba(1, 1, 1, 0.09)
    readonly property color divider: cyber ? Qt.rgba(cyan.r, cyan.g, cyan.b, 0.22) : light ? Qt.rgba(0, 0, 0, 0.10) : Qt.rgba(1, 1, 1, 0.06)
    readonly property color dotBorder: cyber ? Qt.rgba(cyan.r, cyan.g, cyan.b, 0.45) : light ? Qt.rgba(0, 0, 0, 0.30) : Qt.rgba(1, 1, 1, 0.22)
    readonly property color subtleDivider: cyber ? Qt.rgba(cyan.r, cyan.g, cyan.b, 0.35) : light ? Qt.rgba(0, 0, 0, 0.20) : Qt.rgba(1, 1, 1, 0.15)
    readonly property color trackBg: cyber ? Qt.rgba(neon.r, neon.g, neon.b, 0.10) : light ? Qt.rgba(0, 0, 0, 0.09) : Qt.rgba(1, 1, 1, 0.08)
    readonly property color trackBg2: cyber ? Qt.rgba(cyan.r, cyan.g, cyan.b, 0.14) : light ? Qt.rgba(0, 0, 0, 0.12) : Qt.rgba(1, 1, 1, 0.10)

    // near-opaque elevated surface (context menus) and recessed well, glass-derived
    readonly property color menuBg: {
        const m = mix(ThemeConfig.glass, _boost, 0.04)
        return Qt.rgba(m.r, m.g, m.b, 0.98)
    }
    readonly property color insetBg: Qt.rgba(0, 0, 0, light ? 0.07 : 0.18)
    // text that sits ON an accent fill (selections) — picked by accent luminance
    readonly property color onAccent: (0.299 * neon.r + 0.587 * neon.g + 0.114 * neon.b) > 0.62 ? "#1a1a22" : "#ffffff"

    readonly property color textPrimary: ThemeConfig.text
    readonly property color textBright: mix(ThemeConfig.text, _boost, 0.8)
    readonly property color textSecondary: mix(ThemeConfig.text, ThemeConfig.glass, 0.16)
    readonly property color textTertiary: mix(ThemeConfig.text, ThemeConfig.glass, 0.08)
    readonly property color textMuted: mix(ThemeConfig.text, ThemeConfig.glass, 0.32)
    readonly property color textDim: mix(ThemeConfig.text, ThemeConfig.glass, 0.27)

    readonly property color accent: ThemeConfig.accent
    readonly property color danger: magenta
    readonly property color warning: amber
    readonly property color dangerHover: Qt.rgba(magenta.r, magenta.g, magenta.b, cyber ? 0.16 : 0.13)
    readonly property color volGradStart: cyber ? neon : ThemeConfig.accent
    readonly property color volGradEnd: cyan
    readonly property color volGradMuteStart: light ? "#a9a6b2" : "#555"
    readonly property color volGradMuteEnd: light ? "#9b97a7" : "#666"
    readonly property color thumbBorder: cyber ? Qt.rgba(0, 0, 0, 0.55) : Qt.rgba(0, 0, 0, 0.25)

    readonly property int barHeight: 44
    readonly property int bubbleHeight: 32
    readonly property int bubbleRadius: 16
    readonly property int popupRadius: 20

    readonly property string mono: ThemeConfig.fontMono
    readonly property string icon: "Symbols Nerd Font"
}
