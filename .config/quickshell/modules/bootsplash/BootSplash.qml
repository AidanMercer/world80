import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../common"

// Cold-boot splash. Autologin means the desktop assembles in full view (black
// gap, wallpaper pop, bar mounting) — this veils every screen from qs's first
// frame and fades once awww reports a wallpaper. A runtime-dir marker tells a
// real boot from a qs restart, so reloads never replay it.
//   qs ipc call bootSplash demo   — replay it live
Scope {
    id: root

    // starts true so the veil windows are created during instantiation — the
    // very first surfaces committed (this module is declared first in shell.qml).
    // waiting for onCompleted creates them AFTER every other shell window and
    // the assembling desktop flashes through. warm restarts flip it off in
    // onCompleted below, which runs before the first frame renders — nothing
    // is ever presented.
    property bool showing: true
    property bool leaving: false
    property bool minHoldDone: false
    property bool wallReady: false

    function begin() {
        minHoldDone = false
        wallReady = false
        leaving = false
        showing = true
        minHold.restart()
        maxHold.restart()
    }
    // the splash owns the wallpaper restore, but firing it when the veil merely
    // EXISTS still loses the race — at cold boot the render thread is busy and
    // the veil's first frame lands after awww starts fading the wallpaper in
    // (a visible blink). presented flips on the veil's first frameSwapped, so
    // the restore can't start before the curtain is actually on screen.
    property bool presented: false
    onPresentedChanged: if (presented) restoreWall.running = true
    Process {
        id: restoreWall
        command: ["sh", Quickshell.env("HOME") + "/dotfiles/.config/hypr/restore-wallpaper.sh"]
    }
    function maybeFinish() {
        if (showing && !leaving && minHoldDone && wallReady) leaving = true
    }
    onLeavingChanged: if (leaving) teardown.restart()
    Timer { id: teardown; interval: 700; onTriggered: root.showing = false }

    // synchronous cold-boot check: an async probe mounts the veil a beat after
    // the rest of the shell, letting the assembling desktop flash through first
    FileView {
        id: bootMarker
        path: {
            const rt = Quickshell.env("XDG_RUNTIME_DIR")
            return ((rt && String(rt).length) ? String(rt) : "/tmp") + "/qs-booted"
        }
        blockLoading: true
        preload: true
        printErrors: false
    }
    Component.onCompleted: {
        let cold = true
        try { cold = bootMarker.text().trim() === "" } catch (e) {}
        if (cold) {
            bootMarker.setText("1\n")
            begin()
        } else {
            showing = false
        }
    }

    Timer {
        id: minHold; interval: 800
        onTriggered: { root.minHoldDone = true; root.maybeFinish() }
    }
    // never hold the desktop hostage if awww is being slow
    Timer {
        id: maxHold; interval: 6000
        onTriggered: { root.minHoldDone = true; root.wallReady = true; root.maybeFinish() }
    }
    Timer {
        interval: 300; repeat: true
        running: root.showing && !root.wallReady
        onTriggered: wallCheck.running = true
    }
    Process {
        id: wallCheck
        command: ["bash", "-c",
            'awww query 2>/dev/null | grep -q "image: /" && echo ok || true']
        stdout: StdioCollector {
            onStreamFinished: if (text.trim() === "ok") {
                root.wallReady = true
                root.maybeFinish()
            }
        }
    }

    Variants {
        model: root.showing ? Quickshell.screens : []

        PanelWindow {
            required property var modelData
            screen: modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell-bootsplash"
            WlrLayershell.layer: WlrLayer.Overlay
            color: "transparent"
            mask: Region {}   // purely visual — input falls through

            Rectangle {
                id: veil
                anchors.fill: parent
                color: "#050508"
                opacity: root.leaving ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 550; easing.type: Easing.InOutQuad } }

                Connections {
                    target: veil.Window.window
                    enabled: !root.presented
                    function onFrameSwapped() { root.presented = true }
                }

                Column {
                    anchors.centerIn: parent
                    spacing: 26
                    opacity: root.leaving ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 260 } }

                    Text {
                        id: mark
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: "world80"
                        color: Qt.rgba(1, 1, 1, 0.88)
                        font.family: Theme.mono
                        font.pixelSize: 24
                        font.letterSpacing: 12
                        opacity: 0
                        NumberAnimation on opacity {
                            running: root.showing
                            from: 0; to: 1; duration: 600; easing.type: Easing.OutQuad
                        }
                    }

                    Item {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: mark.width
                        height: 2
                        clip: true
                        Rectangle { anchors.fill: parent; color: Qt.rgba(1, 1, 1, 0.10) }
                        Rectangle {
                            id: sweep
                            width: Math.round(parent.width * 0.3)
                            height: parent.height
                            color: Theme.accent
                            SequentialAnimation on x {
                                loops: Animation.Infinite
                                running: root.showing
                                NumberAnimation { from: -sweep.width; to: mark.width; duration: 1100; easing.type: Easing.InOutSine }
                            }
                        }
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "bootSplash"
        function demo(): void { root.begin() }
        function dismiss(): void { if (root.showing) root.leaving = true }
    }
}
