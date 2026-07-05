import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "../common"

// The visual surface of the lock screen, reused by both the safe preview window
// and the real WlSessionLock. It draws the blurred wallpaper and then loads the
// *active theme's own* clock.qml on top — the exact same animated file the
// desktop uses (glitch, CRT scanlines, scan-beam and all) — so the lock matches
// the desktop clock instead of re-implementing it. A boxless dots passcode row
// sits near the bottom, fed by a hidden TextInput. Auth itself lives in the
// parent (PAM): this emits `submitted(password)` and exposes `failed`/`busy`.
Item {
    id: root

    property string screenName: ""   // monitor to query awww with ("" = primary)
    property bool failed: false       // parent sets true after a wrong password
    property bool busy: false         // parent sets true while PAM is checking
    // Bumping this clears the field (parent does it after a failed attempt).
    property int resetNonce: 0

    signal submitted(string password)

    readonly property int pwLength: pwInput.text.length

    onResetNonceChanged: pwInput.text = ""

    // ---- background: the live wallpaper, blurred + darkened ----------------
    property string wallpaper: ""
    Process {
        id: wallQuery
        command: ["bash", "-c",
            'name="$1"; ' +
            'if [ -n "$name" ]; then line=$(awww query 2>/dev/null | grep -m1 -- "$name:"); ' +
            'else line=$(awww query 2>/dev/null | head -1); fi; ' +
            'printf "%s" "$line" | sed -n "s/.*image: //p"',
            "_", root.screenName]
        stdout: StdioCollector { onStreamFinished: root.wallpaper = text.trim() }
    }

    Image {
        id: bgImage
        anchors.fill: parent
        source: root.wallpaper ? "file://" + root.wallpaper : ""
        fillMode: Image.PreserveAspectCrop
        visible: false
        asynchronous: true
        cache: true
    }
    MultiEffect {
        anchors.fill: parent
        source: bgImage
        blurEnabled: true
        blur: 1.0
        blurMax: 40
        // dark themes dim the wallpaper behind the clock; light themes keep it airy
        brightness: Theme.light ? 0.05 : -0.28
        saturation: 0.05
    }
    Rectangle { anchors.fill: parent; color: ThemeConfig.glass; opacity: 0.18 }

    // ---- the theme's own animated clock ------------------------------------
    function fileUrl(p) { return "file://" + p.split("/").map(encodeURIComponent).join("/") }
    property string clockPath: ""
    property bool wantsPal: false
    property int retriesLeft: 10

    property ThemePalette themePal: ThemePalette {
        themeDir: root.clockPath !== "" ? root.clockPath.replace(/\/[^/]*$/, "") : ""
    }

    Process {
        id: clockQuery
        command: ["bash", "-c",
            'name="$1"; ' +
            'if [ -n "$name" ]; then line=$(awww query 2>/dev/null | grep -m1 -- "$name:"); ' +
            'else line=$(awww query 2>/dev/null | head -1); fi; ' +
            'img=$(printf "%s" "$line" | sed -n "s/.*image: //p"); ' +
            '[ -n "$img" ] || exit 0; ' +
            'c="$(dirname "$img")/clock.qml"; [ -f "$c" ] || exit 0; ' +
            'printf "%s" "$c"; grep -q "property var pal" "$c" && printf "\\tPAL"; true',
            "_", root.screenName]
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const changed = parts[0] !== root.clockPath || (parts.length > 1) !== root.wantsPal
                root.wantsPal = parts.length > 1
                root.clockPath = parts[0]
                if (changed) root.remountClock()
            }
        }
    }
    Loader {
        id: clockLoader
        anchors.fill: parent
    }
    // setSource so the clock gets `pal` as an initial property, same as the
    // desktop loaders — its bindings never see pal undefined
    function remountClock() {
        if (root.clockPath === "") { clockLoader.source = ""; return }
        clockLoader.setSource(root.fileUrl(root.clockPath),
                              root.wantsPal ? { pal: root.themePal } : {})
    }
    Timer {
        interval: 1500; repeat: true
        running: root.clockPath === "" && root.retriesLeft > 0
        onTriggered: { root.retriesLeft--; clockQuery.running = true }
    }

    // ---- passcode input (hidden) + boxless dots ----------------------------
    TextInput {
        id: pwInput
        visible: false
        focus: true
        enabled: !root.busy
        echoMode: TextInput.Password
        Keys.onReturnPressed: if (text.length > 0) root.submitted(text)
        Keys.onEnterPressed: if (text.length > 0) root.submitted(text)
        Keys.onEscapePressed: text = ""
    }

    Column {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.round(parent.height * 0.15)
        spacing: 16

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 13
            opacity: root.pwLength > 0 ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            Repeater {
                model: Math.max(root.pwLength, 1)
                Rectangle {
                    width: 9; height: 9; radius: 4.5
                    color: Theme.textBright
                    opacity: index < root.pwLength ? 1 : 0
                    scale: root.busy ? 0.7 : 1
                    Behavior on scale { NumberAnimation { duration: 200 } }
                }
            }
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            opacity: root.pwLength === 0 ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: 140 } }
            text: root.failed ? "wrong" : "enter passcode"
            color: root.failed ? Theme.danger : Theme.textMuted
            font.family: Theme.mono
            font.italic: true
            font.pixelSize: 15
        }
    }

    Component.onCompleted: {
        wallQuery.running = true
        clockQuery.running = true
        pwInput.forceActiveFocus()
    }
}
