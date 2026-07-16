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

    property bool showing: false
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
    function maybeFinish() {
        if (showing && !leaving && minHoldDone && wallReady) leaving = true
    }
    onLeavingChanged: if (leaving) teardown.restart()
    Timer { id: teardown; interval: 900; onTriggered: root.showing = false }

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
        }
    }

    Timer {
        id: minHold; interval: 1500
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
                Behavior on opacity { NumberAnimation { duration: 700; easing.type: Easing.InOutQuad } }

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
