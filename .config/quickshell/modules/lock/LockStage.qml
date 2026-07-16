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

    // cold-boot intro: on a fresh boot the lock is the first thing on screen, so
    // instead of the usual chrome-assemble we play a "power-on" first. bootReveal
    // holds at 1 (black tube warming) then falls to 0 as the curtain lifts; only
    // then does progress ramp and the normal chrome come in. A theme whose
    // lock.qml carries the `coldBootOwner` marker draws its own boot sequence
    // (reading host.coldBoot / host.bootReveal) and the generic curtain below
    // stands down — same idea as bareLock.
    property bool coldBoot: false
    property real bootReveal: 0

    // defer one tick so a Loader-injected coldBoot binding is settled before we
    // pick the intro — otherwise onCompleted reads coldBoot=false and we fall
    // through to the plain fade, skipping the power-on
    property bool introStarted: false
    function startIntro() {
        if (introStarted || unlocking) return
        introStarted = true
        if (coldBoot) bootSeq.start()
        else inAnim.start()
    }
    Component.onCompleted: { rescan(); Qt.callLater(startIntro) }
    onUnlockingChanged: if (unlocking) { inAnim.stop(); bootSeq.stop(); outAnim.start() }

    SequentialAnimation {
        id: bootSeq
        PropertyAction { target: stage; property: "bootReveal"; value: 1 }
        PauseAnimation { duration: 460 }
        NumberAnimation {
            target: stage; property: "bootReveal"
            to: 0; duration: 900; easing.type: Easing.OutCubic
        }
        ScriptAction { script: inAnim.start() }
    }

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
    // overlay carries the `coldBootOwner` marker → it draws its own cold-boot
    // power-on and the generic CRT curtain below stands down
    property bool coldOwned: false
    property ThemePalette pal: ThemePalette { themeDir: stage.themeDir }

    Process {
        id: existProc
        stdout: StdioCollector {
            onStreamFinished: {
                const parts = text.trim().split("\t")
                const p = parts[0] || ""
                const bare = parts.indexOf("BARE") >= 0
                const cold = parts.indexOf("COLD") >= 0
                if (p !== stage.overlayPath || bare !== stage.bareOverlay
                        || cold !== stage.coldOwned) {
                    stage.overlayPath = p
                    stage.bareOverlay = bare
                    stage.coldOwned = cold
                    stage.remount()
                }
            }
        }
    }
    // command built at call time, not bound — the one-behind trap again
    function rescan() {
        existProc.command = ["bash", "-c",
            'd="$1"; f="$d/lock.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; ' +
            'printf "%s" "$f"; grep -q "bareLock" "$f" && printf "\\tBARE"; ' +
            'grep -q "coldBootOwner" "$f" && printf "\\tCOLD"; true',
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

    // ── generic cold-boot power-on (CRT curtain) ─────────────────────────────
    // default reveal for themes that don't own the cold boot: two black halves
    // retract from a bright seam, like a tube warming up. Topmost, so it covers
    // whatever chrome is assembling underneath.
    Item {
        anchors.fill: parent
        z: 100
        visible: stage.coldBoot && !stage.coldOwned && stage.bootReveal > 0.001

        Rectangle {
            width: parent.width
            anchors.top: parent.top
            height: parent.height * 0.5 * stage.bootReveal
            color: "black"
        }
        Rectangle {
            width: parent.width
            anchors.bottom: parent.bottom
            height: parent.height * 0.5 * stage.bootReveal
            color: "black"
        }
        Rectangle {
            anchors.centerIn: parent
            width: parent.width
            height: 2
            color: "#e6ecff"
            opacity: Math.max(0, (stage.bootReveal - 0.25) / 0.75)
        }
    }
}
