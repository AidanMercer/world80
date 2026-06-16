import QtQuick
import QtQuick.Effects
import Quickshell.Io
import "../common"

// Top-right: live CPU / RAM (and battery, on the laptop) as little icon + percent
// groups. No glass pill — these float bare on the bar like the workspaces in the
// centre, neutral white dimmed right down. CPU and RAM turn amber over 60% and red
// over 85%; battery does the inverse — amber under 30%, red under 15% — so load and
// a dying battery still stand out at a glance.
//
//   • CPU — % busy over the last poll, from the delta of two /proc/stat samples
//   • RAM — used / total, from /proc/meminfo (MemTotal vs MemAvailable)
//   • BAT — capacity + charging state from /sys/class/power_supply/BAT*; the whole
//           group hides itself on machines with no battery (the desktop)
Item {
    id: root
    height: Theme.bubbleHeight
    width: statRow.width + 12

    // Each metric: 0–100, or -1 when not yet sampled (renders "—").
    property int cpuPercent: -1
    property int ramPercent: -1
    property int batteryPercent: -1
    property bool batteryCharging: false
    property bool hasBattery: false

    // Extras shown in the hover tooltip — not on the bubble face itself.
    property real load1: 0
    property real load5: 0
    property real load15: 0
    property int cpuCores: 0
    property real ramUsedGb: 0
    property real ramTotalGb: 0

    // Hover state, consumed by the ResourceTooltip in Bar.qml. Uses a
    // MouseArea (not HoverHandler) — matches the StatusButton pattern and
    // reliably receives events on the bar's layer-shell surface.
    property alias hovered: hoverArea.containsMouse

    // CPU% needs two samples, so we keep the previous /proc/stat totals and diff.
    property real prevTotal: 0
    property real prevIdle: 0

    readonly property int pollInterval: 2000

    function pct(v) { return v < 0 ? "—" : v + "%" }

    // acceptedButtons: NoButton — we only want hover, not to swallow clicks.
    MouseArea {
        id: hoverArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
    }

    // Core count is static — read once at startup via nproc.
    Component.onCompleted: coreProc.running = true
    Process {
        id: coreProc
        command: ["nproc"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.cpuCores = parseInt(text.trim()) || 0
        }
    }

    // ── one tick drives all reads ──
    Timer {
        interval: root.pollInterval
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            cpuProc.running = true
            ramProc.running = true
            loadProc.running = true
            batProc.running = true
        }
    }

    // ── CPU: busy fraction between consecutive /proc/stat samples ──
    Process {
        id: cpuProc
        command: ["cat", "/proc/stat"]
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseCpu(text) }
    }
    function parseCpu(raw) {
        // first line: "cpu  user nice system idle iowait irq softirq steal …"
        const f = raw.split("\n")[0].trim().split(/\s+/).slice(1).map(Number)
        if (f.length < 5) return
        const idle = f[3] + f[4]                       // idle + iowait
        const total = f.reduce((a, b) => a + b, 0)
        const dTotal = total - root.prevTotal
        const dIdle = idle - root.prevIdle
        // Skip the very first sample (prevTotal still 0) so we report an
        // instantaneous figure, not the average since boot.
        if (root.prevTotal > 0 && dTotal > 0)
            root.cpuPercent = Math.round(100 * (dTotal - dIdle) / dTotal)
        root.prevTotal = total
        root.prevIdle = idle
    }

    // ── RAM: used = total - available ──
    Process {
        id: ramProc
        command: ["cat", "/proc/meminfo"]
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseRam(text) }
    }
    function parseRam(raw) {
        let total = 0, avail = 0
        for (const line of raw.split("\n")) {
            if (line.startsWith("MemTotal:")) total = parseInt(line.replace(/\D+/g, ""))
            else if (line.startsWith("MemAvailable:")) avail = parseInt(line.replace(/\D+/g, ""))
        }
        if (total > 0) {
            root.ramPercent = Math.round(100 * (total - avail) / total)
            // /proc/meminfo values are in KiB → MiB → GiB
            root.ramTotalGb = total / 1024 / 1024
            root.ramUsedGb = (total - avail) / 1024 / 1024
        }
    }

    // ── load average: 1 / 5 / 15 minute, from /proc/loadavg ──
    Process {
        id: loadProc
        command: ["cat", "/proc/loadavg"]
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseLoad(text) }
    }
    function parseLoad(raw) {
        const p = raw.trim().split(/\s+/)
        if (p.length >= 3) {
            root.load1 = parseFloat(p[0])
            root.load5 = parseFloat(p[1])
            root.load15 = parseFloat(p[2])
        }
    }

    // ── battery: capacity + status from the first BAT* under power_supply ──
    // sh -c so we can glob BAT0/BAT1; prints "<capacity>\n<status>". Empty output
    // (desktop, no battery) leaves hasBattery false and the group stays hidden.
    Process {
        id: batProc
        command: ["sh", "-c", "for b in /sys/class/power_supply/BAT*; do [ -e \"$b/capacity\" ] && { cat \"$b/capacity\" \"$b/status\"; break; }; done"]
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseBattery(text) }
    }
    function parseBattery(raw) {
        const lines = raw.trim().split("\n")
        const cap = parseInt(lines[0])
        if (lines[0] === "" || isNaN(cap)) { root.hasBattery = false; return }
        root.hasBattery = true
        root.batteryPercent = cap
        root.batteryCharging = (lines[1] || "").trim() === "Charging"
    }

    // Material Design battery glyphs: a bolt when charging, otherwise a level
    // bucket (battery_10 … battery_90), full near the top, alert near empty.
    function batteryGlyph(level, charging) {
        if (charging) return String.fromCodePoint(0xF0084)      // battery-charging
        if (level >= 95) return String.fromCodePoint(0xF0079)   // battery (full)
        if (level < 10) return String.fromCodePoint(0xF0083)    // battery-alert
        return String.fromCodePoint(0xF0079 + Math.floor(level / 10)) // _10 … _90
    }

    // ── one icon + percentage pair; fixed-width number so the bar never jiggles
    //    as values change (1% → 100%) ──
    component Stat: Row {
        id: stat
        property string glyph: ""
        property int value: -1
        // Thresholds default to "high is bad" (CPU/RAM): amber over 60, red over
        // 85. Battery flips lowIsBad and uses the values as floors instead.
        property int warnAt: 60
        property int critAt: 85
        property bool lowIsBad: false
        // charging suppresses the warn/red colours (no point alarming on a battery
        // that's already plugged in) and tints the glyph with the accent instead.
        property bool charging: false
        readonly property bool crit: value >= 0 && !charging
            && (lowIsBad ? value <= critAt : value >= critAt)
        readonly property bool warn: value >= 0 && !charging && !crit
            && (lowIsBad ? value <= warnAt : value >= warnAt)
        // any non-normal state (warn/crit/charging) drops the dimming so the
        // colour actually reads; normal state stays faint and neutral.
        readonly property bool lit: crit || warn || charging
        spacing: 4

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: stat.glyph
            font.family: Theme.icon
            font.pixelSize: 13
            color: stat.crit ? Theme.danger : stat.warn ? Theme.warning
                 : stat.charging ? Theme.accent : Theme.textBright
            opacity: stat.lit ? 1.0 : 0.4
            Behavior on color { ColorAnimation { duration: 200 } }
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            width: 28
            horizontalAlignment: Text.AlignRight
            text: root.pct(stat.value)
            color: stat.crit ? Theme.danger : stat.warn ? Theme.warning : Theme.textBright
            opacity: (stat.crit || stat.warn) ? 1.0 : 0.7
            font.pixelSize: 12
            font.family: Theme.mono
            Behavior on color { ColorAnimation { duration: 200 } }
            Behavior on opacity { NumberAnimation { duration: 200 } }
        }
    }

    Row {
        id: statRow
        anchors.centerIn: parent
        spacing: 10

        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Theme.textShadow
            shadowBlur: 0.6
            shadowVerticalOffset: 0
            shadowHorizontalOffset: 0
        }

        Stat { glyph: String.fromCodePoint(0xF0EE0); value: root.cpuPercent } // nf-md-cpu_64_bit
        Stat { glyph: String.fromCodePoint(0xF035B); value: root.ramPercent } // nf-md-memory
        Stat {
            visible: root.hasBattery
            glyph: root.batteryGlyph(root.batteryPercent, root.batteryCharging)
            value: root.batteryPercent
            lowIsBad: true
            warnAt: 30
            critAt: 15
            charging: root.batteryCharging
        }
    }
}
