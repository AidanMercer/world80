import QtQuick
import Quickshell
import Quickshell.Io
import "ThemeTokens.js" as Tokens

// The object a theme widget receives as `pal`. Widgets are loaded by file path
// so they can't import the repo modules — each loader owns one of these and
// passes it in as an initial property (widgets declare `property var pal`).
// Reads the theme's config.toml layered over themes/default/config.toml.
QtObject {
    id: pal

    property string themeDir: ""

    property color neon: Tokens.DEFAULTS.accent
    property color cyan: Tokens.DEFAULTS.accent2
    property color magenta: Tokens.DEFAULTS.accent3
    property color amber: Tokens.DEFAULTS.accent_warn
    property color dim: Tokens.DEFAULTS.accent_dim
    property color text: Tokens.DEFAULTS.text
    property color glass: Tokens.DEFAULTS.glass
    property string fontMono: Tokens.DEFAULTS.font_mono
    property string barPosition: Tokens.DEFAULTS.bar_position

    // per-machine shrink: the laptop's eDP-1 panel makes the desktop widgets
    // read too big; the desktop has no eDP-1 so it stays 1.0. On top of that
    // sits the user's global interface scale (Settings → Interface scale), so
    // sysinfo/clock/lyrics/cava all grow/shrink live when the slider moves.
    readonly property real uiScale: {
        const ss = Quickshell.screens
        let base = 1.0
        for (let i = 0; i < ss.length; i++)
            if (ss[i].name === "eDP-1") base = 0.85
        return base * UiScale.factor
    }

    // per-theme widget toggle (Super+Shift+/ → Settings): false while the
    // user has this theme's sysinfo turned off. Bars gate their hover
    // triggers on it (`visible: pal.sysinfoOn !== false`) so a disabled
    // readout doesn't leave a dead button behind. Re-evaluates live.
    readonly property bool sysinfoOn: ThemeSettings.on(pal.themeDir, "sysinfo")

    function apply(t) {
        neon = t.accent
        cyan = t.accent2
        magenta = t.accent3
        amber = t.accent_warn
        dim = t.accent_dim
        text = t.text
        glass = t.glass
        fontMono = t.font_mono
        barPosition = t.bar_position
    }

    // command built at call time, not bound — same one-behind trap as the loaders
    function reload() {
        reader.command = ["bash", "-c",
            'cat "$HOME/.config/themes/default/config.toml" "$1/config.toml" 2>/dev/null; true',
            "_", pal.themeDir]
        reader.running = true
    }
    onThemeDirChanged: reload()
    Component.onCompleted: reload()

    property Process _reader: Process {
        id: reader
        stdout: StdioCollector { onStreamFinished: pal.apply(Tokens.parse(text)) }
    }

    property Connections _bus: Connections {
        target: ControlBus
        function onThemeReloadRequested() { pal.reload() }
    }
}
