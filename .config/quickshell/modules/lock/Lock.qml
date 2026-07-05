import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Pam
import "../common"

// The real session lock. Idle (locked=false) until something calls
//   qs ipc call lock lock
// (hypridle's lock_cmd / loginctl lock-session, same triggers hyprlock used).
// WlSessionLock engages the ext-session-lock protocol and spawns one
// WlSessionLockSurface per monitor; each shows LockContent (blurred wallpaper +
// the theme's animated clock + passcode dots). Typing a password and pressing
// Enter runs it through PAM using the existing /etc/pam.d/hyprlock stack; on
// success we drop the lock. If this ever wedges, recover from a TTY with
// `loginctl unlock-session`.
Scope {
    id: root

    property bool locked: false
    onLockedChanged: ControlBus.sessionLocked = locked
    property bool authBusy: false
    property bool authFailed: false
    property int resetNonce: 0
    property string pending: ""

    // auth succeeded, exit animation playing; the lock drops when the stage
    // reports outDone (or the fallback timer fires, so a broken animation can
    // never hold the session hostage)
    property bool unlocking: false
    onUnlockingChanged: if (unlocking) unlockFallback.start()
    function finishUnlock() {
        if (!root.unlocking) return
        root.unlocking = false
        unlockFallback.stop()
        root.locked = false               // tears down the lock surfaces
    }
    Timer { id: unlockFallback; interval: 800; onTriggered: root.finishUnlock() }

    function tryAuth(pw) {
        if (authBusy || pw.length === 0) return
        pending = pw
        authFailed = false
        authBusy = true
        if (!pam.start()) {       // couldn't even start the conversation
            authBusy = false
            authFailed = true
            resetNonce++
        }
    }

    PamContext {
        id: pam
        config: "hyprlock"        // reuse hyprlock's known-good PAM stack

        // PAM drives the conversation through pamMessage; when it wants input
        // (responseRequired) we feed our pending password.
        onPamMessage: if (responseRequired) respond(root.pending)

        onCompleted: function(result) {
            root.authBusy = false
            root.pending = ""
            if (result === PamResult.Success) {
                root.authFailed = false
                root.unlocking = true      // play the exit, then drop the lock
            } else {
                root.authFailed = true
                root.resetNonce++          // clear the field, show "wrong"
            }
        }
        onError: {
            root.authBusy = false
            root.pending = ""
            root.authFailed = true
            root.resetNonce++
        }
    }

    WlSessionLock {
        id: session
        locked: root.locked

        WlSessionLockSurface {
            id: surface
            // pre-wallpaper flash frame — match the theme instead of always black
            color: ThemeConfig.glass

            LockStage {
                anchors.fill: parent
                screenName: surface.screen ? surface.screen.name : ""
                failed: root.authFailed
                busy: root.authBusy
                resetNonce: root.resetNonce
                unlocking: root.unlocking
                onSubmitted: pw => root.tryAuth(pw)
                onOutDone: root.finishUnlock()
            }
        }
    }

    // non-locking preview of the lock look on the focused output — same stage,
    // no WlSessionLock/PAM. `lock preview` opens it; Enter or `lock previewClose`
    // plays the unlock exit and closes. (qs -p can't resolve ../common types, so
    // this replaces it for iterating on the transition.)
    property bool previewOpen: false
    Loader {
        id: previewLoader
        active: root.previewOpen
        sourceComponent: PanelWindow {
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.namespace: "quickshell-lockpreview"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
            color: "transparent"
            function playExit() { pstage.unlocking = true }
            LockStage {
                id: pstage
                anchors.fill: parent
                screenName: ""
                onSubmitted: pstage.unlocking = true
                onOutDone: root.previewOpen = false
            }
        }
    }

    IpcHandler {
        target: "lock"
        function lock(): void { root.locked = true }
        function isLocked(): bool { return root.locked }
        function preview(): void { root.previewOpen = true }
        function previewClose(): void { if (previewLoader.item) previewLoader.item.playExit() }
    }
}
