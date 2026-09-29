pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// low power mode over power-profiles-daemon. busctl, not powerprofilesctl
// (python, ~50ms cpu a call). auto: unplug → power-saver, plug in → back to
// what you had; hitting lowPct on battery forces saver once per discharge.
// "on battery" = BAT Discharging, so usb-c charging / charge limit count as AC.
QtObject {
    id: pm

    // "power-saver" | "balanced" | "performance" | "" (daemon missing)
    property string profile: ""
    readonly property bool available: profile !== ""
    readonly property bool lowPower: profile === "power-saver"

    property bool hasBattery: false
    property bool onBattery: false
    property int batteryPercent: -1

    property bool auto: true
    readonly property int lowPct: 20

    // persisted so a qs restart mid-discharge still restores on plug-in
    property string restore: ""
    property bool lowLatched: false

    property bool _primed: false   // first read done — before that, no transitions

    // reason: manual | unplugged | plugged | low | external
    signal changed(string profile, string reason)
    property string _pendingReason: ""
    property string _pendingFor: ""   // profile the pending reason belongs to

    readonly property var _cycle: ["power-saver", "balanced", "performance"]

    function set(p, reason) {
        if (!pm.available || pm._cycle.indexOf(p) < 0 || p === pm.profile) return
        pm._pendingReason = reason || "manual"
        pm._pendingFor = p
        setProc.command = ["busctl", "set-property", "org.freedesktop.UPower.PowerProfiles",
            "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles",
            "ActiveProfile", "s", p]
        setProc.running = true
    }
    // a manual choice on battery beats auto: picking a non-saver profile means
    // plug-in has nothing to undo; picking saver remembers what to go back to
    function setManual(p) {
        if (pm.onBattery)
            pm._saveAuto(p === "power-saver" ? (pm.restore || (pm.lowPower ? "" : pm.profile)) : "",
                         pm.lowLatched)
        pm.set(p)
    }
    function toggle() { pm.setManual(pm.lowPower ? (pm.restore || "balanced") : "power-saver") }

    function setAuto(v) {
        pm.auto = v
        autoFile.setText(v ? "1\n" : "0\n")
        if (!v) pm._saveAuto("", false)
    }

    function _saveAuto(r, l) {
        pm.restore = r
        pm.lowLatched = l
        engagedFile.setText(JSON.stringify({ restore: r, low: l }) + "\n")
    }

    function refresh() { if (!readProc.running) readProc.running = true }

    function _apply(raw) {
        const lines = raw.split("\n")
        const m = /"([a-z-]+)"/.exec(lines[0] || "")
        const prof = m ? m[1] : ""
        const cap = parseInt(lines[1])
        const status = (lines[2] || "").trim()

        const wasOnBattery = pm.onBattery
        pm.hasBattery = !isNaN(cap)
        pm.batteryPercent = isNaN(cap) ? -1 : cap
        pm.onBattery = pm.hasBattery && status === "Discharging"

        if (prof !== pm.profile) {
            const first = !pm._primed
            pm.profile = prof
            if (!first && prof !== "")
                pm.changed(prof, prof === pm._pendingFor ? pm._pendingReason : "external")
        }
        if (prof === pm._pendingFor) { pm._pendingReason = ""; pm._pendingFor = "" }

        if (!pm._primed) {
            pm._primed = true
            // plugged in while qs was down: finish the restore we owe
            if (pm.auto && pm.available && !pm.onBattery && pm.restore !== "") {
                const back = pm.restore
                pm._saveAuto("", false)
                if (pm.lowPower) pm.set(back, "plugged")
            }
            return
        }
        if (!pm.auto || !pm.available || !pm.hasBattery) return

        if (!wasOnBattery && pm.onBattery) {
            if (!pm.lowPower) {
                pm._saveAuto(pm.profile, false)
                pm.set("power-saver", "unplugged")
            }
        } else if (wasOnBattery && !pm.onBattery) {
            const back = pm.restore
            pm._saveAuto("", false)
            if (back !== "" && pm.lowPower) {
                pm.set(back, "plugged")
            }
        } else if (pm.onBattery && !pm.lowLatched && pm.batteryPercent >= 0
                   && pm.batteryPercent <= pm.lowPct) {
            pm._saveAuto(pm.restore || (pm.lowPower ? "" : pm.profile), true)
            if (!pm.lowPower) {
                pm.set("power-saver", "low")
            }
        }
    }

    property Process _read: Process {
        id: readProc
        command: ["sh", "-c",
            "busctl get-property org.freedesktop.UPower.PowerProfiles /org/freedesktop/UPower/PowerProfiles " +
            "org.freedesktop.UPower.PowerProfiles ActiveProfile 2>/dev/null || echo; " +
            "for b in /sys/class/power_supply/BAT*; do [ -e \"$b/capacity\" ] && { cat \"$b/capacity\" \"$b/status\"; exit; }; done"]
        stdout: StdioCollector { onStreamFinished: pm._apply(text) }
    }

    property Process _set: Process {
        id: setProc
        onExited: (code) => {
            if (code !== 0) { pm._pendingReason = ""; pm._pendingFor = "" }
            pm.refresh()
        }
    }

    property Process _dbusWatch: Process {
        running: true
        command: ["gdbus", "monitor", "--system", "--dest", "org.freedesktop.UPower.PowerProfiles"]
        stdout: SplitParser {
            onRead: (line) => { if (line.indexOf("ActiveProfile") >= 0) pm.refresh() }
        }
    }

    property Process _udevWatch: Process {
        running: true
        command: ["udevadm", "monitor", "--kernel", "--subsystem-match=power_supply"]
        stdout: SplitParser {
            onRead: (line) => { if (line.indexOf("change") >= 0) settle.restart() }
        }
    }
    // one plug = several uevents, and BAT status lags the AC line a beat
    property Timer _settle: Timer { id: settle; interval: 700; onTriggered: pm.refresh() }

    property Timer _poll: Timer {
        interval: 60000; running: true; repeat: true
        onTriggered: pm.refresh()
    }

    property FileView _autoFile: FileView {
        id: autoFile
        path: Quickshell.stateDir + "/power-auto"
        blockLoading: true
        preload: true
        printErrors: false
    }
    property FileView _engagedFile: FileView {
        id: engagedFile
        path: Quickshell.stateDir + "/power-auto-engaged.json"
        blockLoading: true
        preload: true
        printErrors: false
    }

    Component.onCompleted: {
        const t = autoFile.text().trim()
        if (t !== "") pm.auto = t === "1"
        try {
            const e = JSON.parse(engagedFile.text())
            if (e && typeof e === "object") {
                pm.restore = e.restore || ""
                pm.lowLatched = e.low === true
            }
        } catch (err) {}
        pm.refresh()
    }
}
