import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Wayland
import "../common"

// Theme-switch cover, one per monitor. On freeze it grabs a single screencopy
// frame of the whole output and holds it on the overlay layer; the wipe then
// peels that frame into the INCOMING wallpaper (ControlBus.transitionTarget,
// the exact image awww is about to paint) — two static textures, so nothing
// the swap does mid-flight can flash or pop inside the revealed strip. awww,
// theme-colors and every widget loader finish fully hidden beneath, and once
// the wipe lands the cover fades itself off in a beat: chrome and windows
// bloom back in over an identical wallpaper. Empty target (the dry-run test)
// wipes to the live desktop instead.
//
// Click-through and unmapped while idle; capture + image textures only exist
// for the ~1.5s a switch takes. If screencopy never delivers, hardStop resets
// to idle — a frozen screen must never outlive its swap. Skipped entirely
// while the session is locked: the locker owns the screen.
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
    // don't map until the captured frame is actually in hand — a cover that
    // appears before its content flashes black for the frames in between.
    // Until then the live desktop simply stays on screen, which is invisible.
    visible: phase !== 0 && stage.item !== null && stage.item.ready

    // 0 idle · 1 frozen (textures loading) · 2 wiping · 3 fading off
    property int phase: 0
    property real progress: 0       // 0 = frozen frame fully opaque, 1 = wiped
    property real coverOpacity: 1
    property string targetWall: ""  // what the wipe reveals ("" = live desktop)

    Connections {
        target: ControlBus
        function onTransitionFreeze() {
            if (ControlBus.sessionLocked) return
            // a fresh freeze captures on its own when captureSource flips on
            // (asking earlier logs a not-ready warning) — only a re-freeze
            // landing mid-wipe, where the context is already live, re-arms
            const rearm = root.phase >= 2
            revealSeq.stop()
            root.progress = 0
            root.coverOpacity = 1
            root.targetWall = ControlBus.transitionTarget
            root.phase = 1
            if (rearm && stage.item) stage.item.recapture()
            hardStop.restart()
        }
    }

    // the wipe starts once BOTH textures are in hand: the frozen frame and
    // the incoming wallpaper it lands on. Starting on the frame alone would
    // snap the image into the already-revealed strip when its decode lands.
    readonly property bool covered: phase === 1
        && stage.item !== null && stage.item.ready && stage.item.landReady
    onCoveredChanged: {
        if (!covered) return
        phase = 2
        revealSeq.restart()
    }

    // wipe the old frame into the incoming image, then fade the whole cover
    // off — the swap finished long before under it (a compile stall pauses
    // these animations together with the swap, so the fade can't land early)
    SequentialAnimation {
        id: revealSeq
        NumberAnimation {
            target: root; property: "progress"
            from: 0; to: 1
            duration: 1100
            easing.type: Easing.InOutCubic
        }
        ScriptAction { script: root.phase = 3 }
        NumberAnimation {
            target: root; property: "coverOpacity"
            from: 1; to: 0
            duration: 220
            easing.type: Easing.InCubic
        }
        ScriptAction {
            script: { root.phase = 0; root.progress = 0; root.coverOpacity = 1 }
        }
    }

    // screencopy or the image never delivered (no wipe possible — the cover
    // may not even have mapped): fall back to idle so the machinery re-arms
    Timer {
        id: hardStop
        interval: 6000
        onTriggered: if (root.phase === 1) { root.phase = 0; root.progress = 0 }
    }

    // instantiated once at startup, not on first freeze — building this tree
    // mid-gallery-animation was a visible hitch right before the wipe. Idle
    // cost stays ~0: the window is unmapped, the layer texture is gated on
    // phase and null captureSource / empty image sources hold no buffers.
    Loader {
        id: stage
        anchors.fill: parent
        active: true

        sourceComponent: Item {
            id: comp
            anchors.fill: parent
            opacity: root.coverOpacity

            readonly property bool ready: frozen.hasContent
            readonly property bool landReady: root.targetWall === ""
                || incoming.status === Image.Ready
            function recapture() { frozen.captureFrame() }

            function fileUrl(p) {
                return "file://" + p.split("/").map(encodeURIComponent).join("/")
            }

            // slab geometry: diag covers the screen at any tilt, the feather is
            // the soft band the wipe front carries. MultiEffect reads the mask
            // through smoothstep(0, 0.5, alpha), so only the lower half of the
            // gradient ramp feathers — hence the generous 0.30.
            readonly property real diag: width + height
            readonly property real feather: diag * 0.30
            readonly property real slabW: diag * 2 + feather

            // where the wipe lands: the incoming wallpaper, center-cropped the
            // same way awww paints it, so the end fade changes nothing but
            // chrome. Idle/dry-run: empty source, no texture.
            Image {
                id: incoming
                anchors.fill: parent
                source: root.phase !== 0 && root.targetWall !== ""
                    ? comp.fileUrl(root.targetWall) : ""
                fillMode: Image.PreserveAspectCrop
                sourceSize: Qt.size(comp.width, comp.height)
                asynchronous: true
                cache: false   // regenerated stills must not show stale frames
                visible: status === Image.Ready
            }

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
