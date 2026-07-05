import QtQuick
import Quickshell
import Quickshell.Io
import "../common"

// LockContent plus the lock/unlock transition. `progress` runs 0→1 as the lock
// engages and back 1→0 once auth succeeds — Lock.qml keeps the session locked
// until outDone fires, so the exit can actually be seen. The content fades and
// settles with progress as a default that works for any theme; a theme can
// additionally ship a lock.qml overlay next to its wallpaper, drawn above the
// content. The overlay must declare `property var pal` and `property var host`
// (both injected via setSource) and bind whatever it draws to host.progress /
// host.unlocking. An overlay containing the marker `bareLock` takes over all
// the chrome: the default blur/tint/clock/dots stand down, and host grows
// pwLength/failed/busy + backgroundItem (the sharp wallpaper/video, for the
// overlay's own blur regions).
Item {
    id: stage

    property string screenName: ""
    property bool failed: false
    property bool busy: false
    property int resetNonce: 0
    property bool unlocking: false
    signal submitted(string password)
    signal outDone()

    property real progress: 0

    Component.onCompleted: { inAnim.start(); rescan() }
    onUnlockingChanged: if (unlocking) { inAnim.stop(); outAnim.start() }

    NumberAnimation {
        id: inAnim
        target: stage; property: "progress"
        from: 0; to: 1
        duration: 550; easing.type: Easing.OutCubic
    }
    SequentialAnimation {
        id: outAnim
        NumberAnimation {
            target: stage; property: "progress"
            to: 0
            duration: 380; easing.type: Easing.InCubic
        }
        ScriptAction { script: stage.outDone() }
    }

    LockContent {
        id: content
        anchors.fill: parent
        screenName: stage.screenName
        failed: stage.failed
        busy: stage.busy
        resetNonce: stage.resetNonce
        bare: stage.bareOverlay
        onSubmitted: pw => stage.submitted(pw)
        opacity: stage.progress
        scale: 1.012 - 0.012 * stage.progress
    }

    // surface for bare overlays: password state + the raw background to blur
    readonly property int pwLength: content.pwLength
    readonly property Item backgroundItem: content.backgroundItem

    // ---- theme overlay (lock.qml in the theme folder) -----------------------
    readonly property string themeDir: {
        const n = stage.screenName
            || (Quickshell.screens.length ? Quickshell.screens[0].name : "")
        return ActiveTheme.dirFor(n)
    }
    property string overlayPath: ""
    // overlay carries the `bareLock` marker → it owns all the lock chrome
    property bool bareOverlay: false
    property ThemePalette pal: ThemePalette { themeDir: stage.themeDir }

    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const p = parts[0] || ""
                const bare = parts.length > 1
                if (p !== stage.overlayPath || bare !== stage.bareOverlay) {
                    stage.overlayPath = p
                    stage.bareOverlay = bare
                    stage.remount()
                }
            }
        }
    }
    // command built at call time, not bound — the one-behind trap again
    function rescan() {
        existProc.command = ["bash", "-c",
            'd="$1"; f="$d/lock.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; ' +
            'printf "%s" "$f"; grep -q "bareLock" "$f" && printf "\\tBARE"; true',
            "_", stage.themeDir]
        existProc.running = true
    }
    onThemeDirChanged: rescan()

    function fileUrl(p) { return "file://" + p.split("/").map(encodeURIComponent).join("/") }
    Loader {
        id: overlayLoader
        anchors.fill: parent
    }
    function remount() {
        if (stage.overlayPath === "") { overlayLoader.source = ""; return }
        overlayLoader.setSource(stage.fileUrl(stage.overlayPath),
                                { pal: stage.pal, host: stage })
    }
}
