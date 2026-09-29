import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire
import "../common"

// On-screen display for volume / mic / brightness. The XF86 media keys in
// hyprland.conf don't change anything themselves — they call into here over IPC
// (`qs ipc call osd volumeUp` etc). This module owns the action AND the popup,
// so there's one source of truth: volume goes through the Pipewire service (same
// as the Sound tab), brightness through brightnessctl.
//
// The card is a click-through overlay anchored to the bottom of whichever
// monitor has focus, frosted by the `blur` layerrule on quickshell-osd.
Scope {
    id: root

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var source: Pipewire.defaultAudioSource

    // what the popup is currently showing
    property string kind: "volume"   // "volume" | "mic" | "brightness" | "power"
    property real value: 0           // 0..1
    property bool muted: false

    // keep the default sink/source bound so .audio updates live
    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource].filter(o => o)
    }

    function flash() {
        win.visible = true
        hideTimer.restart()
    }

    function showVolume() {
        const a = sink ? sink.audio : null
        root.kind = "volume"
        root.value = a ? a.volume : 0
        root.muted = a ? a.muted : false
        flash()
    }
    function volumeUp(): void {
        const a = sink ? sink.audio : null
        if (a) { a.muted = false; a.volume = Volume.clamp(a.volume + Volume.step) }
        showVolume()
    }
    function volumeDown(): void {
        const a = sink ? sink.audio : null
        if (a) a.volume = Volume.clamp(a.volume - Volume.step)
        showVolume()
    }
    function muteToggle(): void {
        const a = sink ? sink.audio : null
        if (a) a.muted = !a.muted
        showVolume()
    }
    function micMuteToggle(): void {
        const a = source ? source.audio : null
        if (a) a.muted = !a.muted
        root.kind = "mic"
        root.value = a ? a.volume : 0
        root.muted = a ? a.muted : false
        flash()
    }

    // brightnessctl, scoped to the backlight class so it doesn't grab a stray
    // LED (keyboard, NIC). No backlight device (this desktop) → empty output →
    // we just don't pop the OSD.
    function brightnessUp(): void { setBrightness("5%+") }
    function brightnessDown(): void { setBrightness("5%-") }
    function setBrightness(arg) {
        bright.command = ["brightnessctl", "-c", "backlight", "-m", "set", arg]
        bright.running = true
    }

    Process {
        id: bright
        stdout: StdioCollector {
            id: brightOut
            onStreamFinished: {
                const line = brightOut.text.trim().split("\n")[0]
                if (!line) return
                const f = line.split(",")
                if (f.length < 4) return
                const pct = parseInt(f[3])
                if (isNaN(pct)) return
                root.kind = "brightness"
                root.value = pct / 100
                root.muted = false
                root.flash()
            }
        }
    }

    Timer {
        id: hideTimer
        interval: 1500
        onTriggered: win.visible = false
    }

    property string powerLabel: ""
    Connections {
        target: PowerMode
        function onChanged(profile, reason) {
            const name = profile === "power-saver" ? "Low power" : profile === "performance" ? "Performance" : "Balanced"
            const why = reason === "unplugged" ? " · on battery"
                      : reason === "plugged" ? " · plugged in"
                      : reason === "low" ? " · battery " + PowerMode.batteryPercent + "%"
                      : ""
            root.kind = "power"
            root.value = 0
            root.muted = false
            root.powerLabel = name + why
            root.flash()
        }
    }

    IpcHandler {
        target: "osd"
        function volumeUp(): void { root.volumeUp() }
        function volumeDown(): void { root.volumeDown() }
        function muteToggle(): void { root.muteToggle() }
        function micMuteToggle(): void { root.micMuteToggle() }
        function brightnessUp(): void { root.brightnessUp() }
        function brightnessDown(): void { root.brightnessDown() }
    }

    PanelWindow {
        id: win
        visible: false

        // follow the focused monitor so the OSD shows where you're looking
        screen: {
            const fm = Hyprland.focusedMonitor
            if (!fm) return null
            return Quickshell.screens.find(s => s.name === fm.name) ?? null
        }

        WlrLayershell.namespace: "quickshell-osd"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        // Full-output transparent overlay (a one-edge anchored PanelWindow never
        // gets a render surface). The visible card is centred near the bottom;
        // the rest is alpha 0 → click-through and not blurred.
        anchors { top: true; bottom: true; left: true; right: true }
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"
        mask: Region {}   // fully click-through

        // Volume runs past unity (software gain on a maxed-out codec); mic and
        // brightness stop at 1, so the gauge is scaled per kind and marks unity.
        readonly property real gaugeMax: root.kind === "volume" ? Volume.max : 1
        readonly property bool boosted: root.kind === "volume" && root.value > 1.001

        readonly property color fillColor: root.kind === "brightness" ? Theme.warning
                                         : root.muted ? Theme.volGradMuteStart
                                         : win.boosted ? Theme.warning
                                         : Theme.accent

        readonly property string glyph: {
            if (root.kind === "brightness") return String.fromCodePoint(0xF00E0)        // brightness
            if (root.kind === "power")
                return String.fromCodePoint(PowerMode.lowPower ? 0xF032A                // leaf
                                          : PowerMode.profile === "performance" ? 0xF0463  // rocket
                                          : 0xF04C5)                                    // speedometer
            if (root.kind === "mic")
                return String.fromCodePoint(root.muted ? 0xF036D : 0xF036C)             // mic / mic-off
            if (root.muted || root.value < 0.001) return String.fromCodePoint(0xF075F)  // volume mute
            if (root.value < 0.5) return String.fromCodePoint(0xF057F)                  // volume low
            return String.fromCodePoint(0xF057E)                                        // volume high
        }

        Rectangle {
            id: card
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 90
            width: 340
            height: 64
            radius: Theme.popupRadius
            color: Theme.glassBg
            border.color: Theme.glassBorder
            border.width: 1

            // subtle slide-up + fade each time the OSD appears
            opacity: win.visible ? 1 : 0
            transform: Translate { y: win.visible ? 0 : 12 }
            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

            Text {
                id: ico
                anchors.left: parent.left
                anchors.leftMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                width: 26
                font.family: Theme.icon
                font.pixelSize: 22
                color: Theme.textBright
                text: win.glyph
            }

            Text {
                id: pct
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                width: 44
                font.family: Theme.mono
                font.pixelSize: 14
                color: Theme.textPrimary
                text: Math.round(root.value * 100) + "%"
                visible: root.kind !== "power"
            }

            Text {
                visible: root.kind === "power"
                anchors.left: ico.right
                anchors.leftMargin: 14
                anchors.right: parent.right
                anchors.rightMargin: 18
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: 15
                font.weight: Font.DemiBold
                color: Theme.textBright
                elide: Text.ElideRight
                text: root.powerLabel
            }

            Rectangle {
                visible: root.kind !== "power"
                anchors.left: ico.right
                anchors.leftMargin: 14
                anchors.right: pct.left
                anchors.rightMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                height: 8
                radius: 4
                color: Theme.trackBg

                Rectangle {
                    height: parent.height
                    radius: 4
                    width: Math.max(0, Math.min(1, root.value / win.gaugeMax)) * parent.width
                    color: win.fillColor
                    Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutQuad } }
                }

                // 100% mark — past it you're on software gain, not the speakers
                Rectangle {
                    visible: win.gaugeMax > 1
                    x: parent.width / win.gaugeMax - width / 2
                    width: 2
                    height: parent.height
                    color: Theme.textDim
                    opacity: 0.8
                }
            }
        }
    }
}
