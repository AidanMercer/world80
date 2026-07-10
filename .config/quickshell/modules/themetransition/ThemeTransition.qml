import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../common"

// Theme-switch cover, one per monitor. On freeze it grabs a single screencopy
// frame of the whole output (wallpaper, chrome, windows, even an open theme
// gallery) and holds it on the overlay layer while the switch happens under
// it — awww, theme-colors and every widget loader land out of sight. On
// reveal the frozen frame wipes away along a soft canted front and the new
// desktop is just *there*, instead of each piece popping on its own beat.
//
// Click-through and unmapped while idle; the capture and its textures only
// exist for the couple of seconds a switch takes. If the reveal never comes
// (wedged apply), hardStop wipes anyway — a frozen screen must never outlive
// its swap. Skipped entirely while the session is locked: the locker owns the
// screen and nothing here would be visible.
PanelWindow {
    id: root
    required property var modelData
    screen: modelData

    WlrLayershell.namespace: "quickshell-themetransition"
    WlrLayershell.layer: WlrLayer.Overlay

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    mask: Region {}                 // never eat a click
    visible: phase !== 0

    // 0 idle · 1 frozen (swap running underneath) · 2 wiping away
    property int phase: 0
    property real progress: 0       // 0 = frozen frame fully opaque, 1 = gone

    Connections {
        target: ControlBus
        function onTransitionFreeze() {
            if (ControlBus.sessionLocked) return
            // a fresh freeze captures on its own when captureSource flips on
            // (asking earlier logs a not-ready warning) — only a re-freeze
            // landing mid-wipe, where the context is already live, re-arms
            const rearm = root.phase === 2
            revealAnim.stop()
            root.progress = 0
            root.phase = 1
            if (rearm && stage.item) stage.item.recapture()
            hardStop.restart()
        }
        function onTransitionReveal() {
            if (root.phase !== 1) return
            root.phase = 2
            revealAnim.restart()
        }
    }

    NumberAnimation {
        id: revealAnim
        target: root
        property: "progress"
        from: 0; to: 1
        duration: 850
        easing.type: Easing.InOutCubic
        onFinished: root.phase = 0
    }

    Timer {
        id: hardStop
        interval: 6000
        onTriggered: if (root.phase === 1) { root.phase = 2; revealAnim.restart() }
    }

    // instantiated once at startup, not on first freeze — building this tree
    // mid-gallery-animation was a visible hitch right before the wipe. Idle
    // cost stays ~0: the window is unmapped, the layer texture is gated on
    // phase, and a null captureSource holds no capture buffers.
    Loader {
        id: stage
        anchors.fill: parent
        active: true

        sourceComponent: Item {
            id: comp
            anchors.fill: parent

            function recapture() { frozen.captureFrame() }

            // slab geometry: diag covers the screen at any tilt, the feather is
            // the soft band the wipe front carries. MultiEffect reads the mask
            // through smoothstep(0, 0.5, alpha), so only the lower half of the
            // gradient ramp feathers — hence the generous 0.30.
            readonly property real diag: width + height
            readonly property real feather: diag * 0.30
            readonly property real slabW: diag * 2 + feather

            Item {
                id: held
                anchors.fill: parent
                scale: 1 + 0.012 * root.progress   // barely lifts off as it goes
                layer.enabled: root.phase !== 0
                layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: maskSrc
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 0.5
                    brightness: -0.05 * root.progress
                }
                ScreencopyView {
                    id: frozen
                    anchors.fill: parent
                    captureSource: root.phase !== 0 ? root.screen : null
                    live: false
                    paintCursor: false
                }
            }

            // the wipe: a canted opaque→transparent slab sliding off; the frozen
            // frame survives wherever the slab is still opaque. Lives OUTSIDE
            // `held` or it would be painted into the very layer it masks.
            Item {
                id: wipeMask
                anchors.fill: parent
                visible: false
                Item {
                    anchors.centerIn: parent
                    width: comp.diag
                    height: comp.diag
                    rotation: -12
                    Rectangle {
                        width: comp.slabW
                        height: parent.height
                        x: -(comp.diag + comp.feather) * root.progress
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0; color: "#ffffff" }
                            GradientStop { position: comp.diag / comp.slabW; color: "#ffffff" }
                            GradientStop { position: (comp.diag + comp.feather) / comp.slabW; color: "transparent" }
                            GradientStop { position: 1; color: "transparent" }
                        }
                    }
                }
            }
            ShaderEffectSource {
                id: maskSrc
                sourceItem: wipeMask
                visible: false
                // a smooth ramp doesn't need full res
                textureSize: Qt.size(Math.max(1, Math.round(comp.width / 4)),
                                     Math.max(1, Math.round(comp.height / 4)))
            }
        }
    }
}
