import QtQuick
import QtQuick.Effects
import Quickshell.Io
import "../common"

// The default center visualizer: a white Arch logo wrapped in an audio-reactive
// triangle outline. Fed by `cava` in raw-ascii mode (cava.conf) — one frame per
// line, N values 0..1000 — bent around the three edges of the triangle.
//
// This is just the *visual* (a plain Item); ArchLogo.qml owns the layer surface
// and decides whether to load this or a theme's own cava.qml. The glow color
// follows ThemeConfig.accent, so a theme's config.toml can recolor it.
Item {
    id: root
    anchors.fill: parent

    readonly property int barCount: 40
    property var levels: []                      // raw cava frame, barCount values 0..1
    property var display: []                     // eased copy we actually draw

    // triangle geometry (px). triR = center → vertex; amp = loudest outward push.
    readonly property real triR: 135
    readonly property real amp: 26

    readonly property color glowColor: ThemeConfig.accent
    readonly property color coreColor: ThemeConfig.text

    Component.onCompleted: {
        const z = []
        for (let i = 0; i < barCount; i++) z.push(0)
        display = z
    }

    Process {
        id: cava
        running: true
        command: ["cava", "-p", Qt.resolvedUrl("cava.conf").toString().replace("file://", "")]
        stdout: SplitParser {
            onRead: line => root.parseFrame(line)
        }
        onRunningChanged: if (!running) cavaRestart.start()
    }

    Timer {
        id: cavaRestart
        interval: 2000
        onTriggered: cava.running = true
    }

    function parseFrame(line) {
        const parts = line.split(";")
        const out = []
        for (let i = 0; i < parts.length; i++) {
            if (parts[i] === "") continue
            out.push(Math.min(1, parseInt(parts[i]) / 1000))
        }
        if (out.length) root.levels = out
    }

    // 30fps is plenty for a visualizer and halves paint cost. We ease toward the
    // latest frame and only repaint when the outline actually moved — at silence
    // everything settles and we stop painting, so the idle widget costs nothing.
    // The deadzone floors cava's amplified noise floor to zero so "silence" really
    // is silent (autosens cranks gain with no signal and would jitter forever).
    Timer {
        interval: 33
        running: true
        repeat: true
        onTriggered: {
            const d = root.display
            const l = root.levels
            let moved = 0
            for (let i = 0; i < root.barCount; i++) {
                let t = l[i] || 0
                if (t < 0.05) t = 0
                const nv = d[i] + (t - d[i]) * 0.4
                moved += Math.abs(nv - d[i])
                d[i] = nv
            }
            if (moved > 0.002) {
                root.display = d
                canvas.requestPaint()
            }
        }
    }

    // overall loudness, used for the logo's gentle bass pulse
    readonly property real pulse: {
        const d = display
        if (!d.length) return 0
        return (d[0] + d[1] + d[2]) / 3
    }

    Item {
        id: stage
        width: 460
        height: 460
        anchors.centerIn: parent

        // GPU glow: a blurred, tinted copy of the crisp outline below, declared
        // first so it sits behind. The blur runs on the scene-graph (GPU), not as
        // a per-frame software gaussian, so it's cheap even while reacting.
        MultiEffect {
            source: canvas
            anchors.fill: canvas
            autoPaddingEnabled: true
            blurEnabled: true
            blur: 1.0
            blurMax: 28
            colorization: 1.0
            colorizationColor: root.glowColor
            brightness: 0.15
            opacity: 0.85
        }

        Canvas {
            id: canvas
            anchors.fill: parent
            renderStrategy: Canvas.Threaded

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const cx = width / 2, cy = height / 2
                const R = root.triR, amp = root.amp
                const d = root.display, n = root.barCount

                // upward equilateral triangle: apex top, then the two base corners
                const verts = [
                    { x: cx,                       y: cy - R },           // top
                    { x: cx - R * 0.8660254,       y: cy + R * 0.5 },     // bottom-left
                    { x: cx + R * 0.8660254,       y: cy + R * 0.5 }      // bottom-right
                ]

                const pts = []
                const samples = n                  // points per edge = one per bar
                for (let e = 0; e < 3; e++) {
                    const P = verts[e], Q = verts[(e + 1) % 3]
                    const dx = Q.x - P.x, dy = Q.y - P.y
                    // outward normal: perpendicular pointing away from center
                    let nx = dy, ny = -dx
                    const len = Math.hypot(nx, ny)
                    nx /= len; ny /= len
                    const mx = (P.x + Q.x) / 2 - cx, my = (P.y + Q.y) / 2 - cy
                    if (nx * mx + ny * my < 0) { nx = -nx; ny = -ny }

                    for (let s = 0; s < samples; s++) {
                        const p = s / samples       // 0..1 along this edge
                        const idx = Math.min(n - 1, Math.floor(p * (n - 1)))
                        const win = Math.sin(p * Math.PI)   // taper to 0 at corners
                        const push = amp * (d[idx] || 0) * win
                        pts.push({ x: P.x + dx * p + nx * push,
                                   y: P.y + dy * p + ny * push })
                    }
                }

                // one crisp stroke; the glow is the GPU MultiEffect behind us
                ctx.beginPath()
                ctx.moveTo(pts[0].x, pts[0].y)
                for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y)
                ctx.closePath()
                ctx.lineJoin = "round"
                ctx.lineCap = "round"
                ctx.lineWidth = 2.4
                ctx.strokeStyle = root.coreColor
                ctx.stroke()
            }
        }

        Image {
            id: logo
            source: Qt.resolvedUrl("arch.svg")
            visible: false                         // source only; MultiEffect draws it
            width: 170
            height: 170
            sourceSize.width: 340
            sourceSize.height: 340
            fillMode: Image.PreserveAspectFit
            anchors.centerIn: parent
            // the arch ink is centered in its box, but the triangle's centroid sits
            // below its bbox center — lift the logo so its bbox lines up with the
            // triangle's, giving equal gaps top and bottom. offset = -triR/4.
            anchors.verticalCenterOffset: -34
            scale: 1 + root.pulse * 0.06
        }

        MultiEffect {
            source: logo
            anchors.fill: logo
            x: logo.x
            y: logo.y
            scale: logo.scale
            autoPaddingEnabled: true
            // the svg ink is white; tint it to the theme's text so it survives
            // light wallpapers
            colorization: 1.0
            colorizationColor: ThemeConfig.text
            shadowEnabled: true
            shadowColor: root.glowColor
            shadowBlur: 0.7
            shadowScale: 1.05
            blurMax: 40
        }
    }
}
