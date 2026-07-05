import QtQuick
import Quickshell.Io
import "../common"

// Display tab: a little drag-to-arrange canvas, Windows-style. Reads the live
// monitor layout from `hyprctl monitors -j`, draws each screen as a box scaled
// to fit, and lets you drag them around (edges snap to neighbours). Apply tries
// the arrangement live via `hyprctl --batch`; Save writes it to a per-machine
// monitors.conf that hyprland.conf sources.
//
// Positions/sizes use Hyprland's *layout* coordinates: a monitor occupies
// width/scale × height/scale in the global layout, so a scaled display takes up
// proportionally less room — same as the real arrangement. We store those as
// lx/ly/lw/lh on each box and only translate to/from canvas pixels through one
// shared mapping (viewScale + viewOff + viewMin), recomputed on every relayout.
Item {
    id: root
    implicitHeight: col.implicitHeight

    property bool active: false
    property var monitors: []     // [{name,w,h,rr,scale,lx,ly,lw,lh}]
    property int selected: -1
    property bool dirty: false     // arrangement changed since last apply/save

    // ControlPopup drives Up/Down/Enter on the other tabs; this one is mouse-only.
    property int navIndex: -1
    readonly property int navCount: 0
    function activateNav() {}

    // shared canvas mapping (logical layout px → canvas px)
    readonly property int pad: 12
    property real viewScale: 1
    property real viewMinX: 0
    property real viewMinY: 0
    property real viewOffX: 0
    property real viewOffY: 0

    onActiveChanged: if (active) readProc.running = true
    Component.onCompleted: readProc.running = true

    function parseMonitors(raw) {
        let list = []
        try {
            for (const m of JSON.parse(raw)) {
                if (m.disabled) continue
                const scale = m.scale || 1
                list.push({
                    name: m.name,
                    w: m.width, h: m.height,
                    rr: m.refreshRate || 60,
                    scale: scale,
                    lx: m.x, ly: m.y,
                    lw: Math.round(m.width / scale),
                    lh: Math.round(m.height / scale)
                })
            }
        } catch (e) { return }
        selected = -1
        dirty = false
        monitors = list
        Qt.callLater(relayout)
    }

    // Recompute the mapping from the boxes' current logical positions so the
    // whole arrangement fits the canvas, centred, then snap every box to it.
    function relayout() {
        if (rep.count === 0) return
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity
        for (let i = 0; i < rep.count; i++) {
            const b = rep.itemAt(i)
            if (!b) return
            minX = Math.min(minX, b.lx);          minY = Math.min(minY, b.ly)
            maxX = Math.max(maxX, b.lx + b.lw);    maxY = Math.max(maxY, b.ly + b.lh)
        }
        const spanW = Math.max(1, maxX - minX)
        const spanH = Math.max(1, maxY - minY)
        const innerW = canvas.width - 2 * pad
        const innerH = canvas.height - 2 * pad
        viewScale = Math.min(innerW / spanW, innerH / spanH)
        viewMinX = minX; viewMinY = minY
        viewOffX = (canvas.width - spanW * viewScale) / 2
        viewOffY = (canvas.height - spanH * viewScale) / 2
        for (let i = 0; i < rep.count; i++) rep.itemAt(i).syncFromLogical()
    }

    // Snap the just-dragged box to its neighbours: align edges and sit flush
    // beside them when within a few on-screen pixels, then shove out of any
    // leftover overlap so Hyprland gets a clean, gap-free layout.
    function snap(idx) {
        const d = rep.itemAt(idx)
        if (!d) return
        const tol = 14 / viewScale   // ~14px on screen, in logical units
        let bestX = d.lx, bestY = d.ly, dX = tol, dY = tol
        for (let i = 0; i < rep.count; i++) {
            if (i === idx) continue
            const o = rep.itemAt(i)
            for (const cx of [o.lx, o.lx + o.lw - d.lw, o.lx - d.lw, o.lx + o.lw]) {
                if (Math.abs(cx - d.lx) < dX) { dX = Math.abs(cx - d.lx); bestX = cx }
            }
            for (const cy of [o.ly, o.ly + o.lh - d.lh, o.ly - d.lh, o.ly + o.lh]) {
                if (Math.abs(cy - d.ly) < dY) { dY = Math.abs(cy - d.ly); bestY = cy }
            }
        }
        d.lx = bestX; d.ly = bestY

        for (let i = 0; i < rep.count; i++) {
            if (i === idx) continue
            const o = rep.itemAt(i)
            const overlap = d.lx < o.lx + o.lw && d.lx + d.lw > o.lx
                         && d.ly < o.ly + o.lh && d.ly + d.lh > o.ly
            if (overlap) { d.lx = o.lx + o.lw; d.ly = o.ly }
        }
    }

    // Collect the current arrangement, normalised so the top-left sits at 0,0.
    function getLayout() {
        let minX = Infinity, minY = Infinity
        for (let i = 0; i < rep.count; i++) {
            minX = Math.min(minX, rep.itemAt(i).lx)
            minY = Math.min(minY, rep.itemAt(i).ly)
        }
        let arr = []
        for (let i = 0; i < rep.count; i++) {
            const b = rep.itemAt(i)
            arr.push({
                name: b.name, w: b.w, h: b.h,
                rr: Math.round(b.rr * 100) / 100,
                scale: b.scale,
                x: Math.round(b.lx - minX),
                y: Math.round(b.ly - minY)
            })
        }
        return arr
    }

    function monitorRule(m) {
        return `${m.name},${m.w}x${m.h}@${m.rr},${m.x}x${m.y},${m.scale}`
    }

    function applyLive() {
        const cmds = getLayout().map(m => "keyword monitor " + monitorRule(m))
        applyProc.command = ["hyprctl", "--batch", cmds.join(";")]
        applyProc.running = true
        dirty = false
    }

    // After a monitor reconfig the layer-shell surfaces on each output (the
    // quickshell bars, the awww wallpaper) sit there blank until something forces
    // a frame — that's why you had to open a window on each screen. Kick them:
    // reload the renderer so hyprland recommits every layer, then have awww
    // repaint each output's wallpaper at its new geometry.
    function nudgeSurfaces() {
        nudgeProc.command = ["sh", "-c",
            "hyprctl dispatch forcerendererreload; sleep 0.3; awww restore"]
        nudgeProc.running = true
    }

    function saveToConfig() {
        applyLive()
        const body = getLayout().map(m => "monitor=" + monitorRule(m)).join("\n")
        saveProc.command = ["sh", "-c",
            "cat > \"$HOME/.config/hypr/monitors.conf\" <<'HYPRMON'\n"
            + "# written by the quickshell Display tab — per-machine, not in the repo\n"
            + body + "\nHYPRMON"]
        saveProc.running = true
        dirty = false
    }

    Process {
        id: readProc
        command: ["hyprctl", "monitors", "-j"]
        running: false
        stdout: StdioCollector { onStreamFinished: root.parseMonitors(text) }
    }

    Process {
        id: applyProc
        running: false
        onRunningChanged: if (!running) { root.nudgeSurfaces(); readProc.running = true }   // re-sync to actual
    }

    Process { id: nudgeProc; running: false }

    Process { id: saveProc; running: false }

    Column {
        id: col
        width: parent.width
        spacing: 12

        // ── the drag-to-arrange canvas ──
        Rectangle {
            id: canvas
            width: parent.width
            height: 156
            radius: 14
            color: Theme.insetBg
            border.color: Theme.divider
            border.width: 1
            clip: true

            onWidthChanged: root.relayout()
            onHeightChanged: root.relayout()

            Text {
                anchors.centerIn: parent
                visible: root.monitors.length === 0
                text: "Reading displays…"
                color: Theme.textMuted
                font.pixelSize: 12
                font.italic: true
            }

            Repeater {
                id: rep
                model: root.monitors

                delegate: Rectangle {
                    id: mon
                    required property var modelData
                    required property int index

                    readonly property string name: modelData.name
                    readonly property int w: modelData.w
                    readonly property int h: modelData.h
                    readonly property real rr: modelData.rr
                    readonly property real scale: modelData.scale
                    readonly property int lw: modelData.lw
                    readonly property int lh: modelData.lh
                    // live logical position — seeded from the model, then mutated by drags
                    property real lx: modelData.lx
                    property real ly: modelData.ly
                    property bool dragging: false
                    readonly property bool isSelected: root.selected === index

                    function syncFromLogical() {
                        x = root.viewOffX + (lx - root.viewMinX) * root.viewScale
                        y = root.viewOffY + (ly - root.viewMinY) * root.viewScale
                        width = lw * root.viewScale
                        height = lh * root.viewScale
                    }

                    radius: 8
                    color: isSelected ? Theme.rowSelected : Theme.glassBg
                    border.width: isSelected || ma.containsMouse ? 2 : 1
                    border.color: isSelected ? Theme.accent : Theme.glassBorder

                    Behavior on x { enabled: !mon.dragging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on y { enabled: !mon.dragging; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on width  { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                    Behavior on color  { ColorAnimation { duration: 150 } }
                    Behavior on border.color { ColorAnimation { duration: 150 } }

                    Column {
                        anchors.centerIn: parent
                        spacing: 1
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: mon.name
                            color: mon.isSelected ? Theme.textBright : Theme.textTertiary
                            font.pixelSize: 12
                            font.weight: Font.Medium
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: mon.height > 28
                            text: mon.w + "×" + mon.h
                            color: Theme.textMuted
                            font.pixelSize: 9
                        }
                    }

                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.SizeAllCursor
                        drag.target: mon
                        drag.minimumX: 0
                        drag.maximumX: canvas.width - mon.width
                        drag.minimumY: 0
                        drag.maximumY: canvas.height - mon.height
                        onPressed: {
                            root.selected = mon.index
                            mon.dragging = true
                            ControlBus.identify(mon.name)   // flash the badge on the real screen
                        }
                        onReleased: {
                            mon.lx = root.viewMinX + (mon.x - root.viewOffX) / root.viewScale
                            mon.ly = root.viewMinY + (mon.y - root.viewOffY) / root.viewScale
                            root.snap(mon.index)
                            mon.dragging = false
                            root.dirty = true
                            root.relayout()
                            ControlBus.clearIdentify()
                        }
                        onCanceled: { mon.dragging = false; ControlBus.clearIdentify() }
                    }
                }
            }
        }

        // ── Apply / Save buttons ──
        Row {
            width: parent.width
            spacing: 8

            Rectangle {
                id: applyBtn
                width: (parent.width - parent.spacing) / 2
                height: 34
                radius: 11
                color: applyMa.containsMouse ? Theme.rowSelected : Theme.rowHover
                border.width: 1
                border.color: root.dirty ? Theme.accent : Theme.glassBorder
                Behavior on color { ColorAnimation { duration: 150 } }
                Behavior on border.color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: "Apply"
                    color: root.dirty ? Theme.textBright : Theme.textTertiary
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
                MouseArea {
                    id: applyMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.applyLive()
                }
            }

            Rectangle {
                id: saveBtn
                width: (parent.width - parent.spacing) / 2
                height: 34
                radius: 11
                color: saveMa.containsMouse ? Theme.rowSelected : Theme.rowHover
                border.width: 1
                border.color: Theme.glassBorder
                Behavior on color { ColorAnimation { duration: 150 } }

                Text {
                    anchors.centerIn: parent
                    text: "Save to config"
                    color: Theme.textTertiary
                    font.pixelSize: 12
                    font.weight: Font.Medium
                }
                MouseArea {
                    id: saveMa
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.saveToConfig()
                }
            }
        }

        Text {
            width: parent.width
            text: "Drag a screen to rearrange. Apply tries it now; Save writes it to monitors.conf so it sticks."
            color: Theme.textMuted
            font.pixelSize: 10
            wrapMode: Text.WordWrap
        }
    }
}
