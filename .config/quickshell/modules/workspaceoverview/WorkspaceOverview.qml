import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Widgets
import "../common"

// Workspace overview / radial exposé. The focused window sits dead-center;
// every other open window fans out around it on a ring, one tile per window,
// evenly spaced at all angles. Click a tile (or the center) to focus that
// window — focusing jumps to its workspace, so this doubles as a switch-
// anywhere. Toggled via `qs ipc call workspaceOverview toggle` (Super+Tab).
//
// The active theme can ship an overview.qml next to its wallpaper to replace
// the chrome — an invisible Item declaring `pal`/`overview` (both injected)
// plus optional scalars (scrim/card/title/hint colors, radii, hint text) and
// optional Components: backdrop (above the scrim, below the ring), overlay
// (above everything), tileUnderlay/tileOverlay (per tile; the root may declare
// `property var tile` to receive the live tile — index/isCenter/hot/win).
// No overview.qml → the glass tiles below, unchanged.
PanelWindow {
    id: root

    property bool open: false
    property bool closing: false

    // Captured at open() so a follow-mouse cursor can't remap the window mid-use.
    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-workspaceoverview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || closing

    // ---- geometry ----
    readonly property int tileW: 280
    readonly property int tileH: 180
    readonly property int centerW: 380
    readonly property int centerH: 240
    readonly property int footerH: 30
    // how far the surrounding tiles sit from center. 0.38 is the sweet spot on a
    // 16:10 panel: the diagonal tiles still clear the (bigger) center tile, and
    // the 6-o'clock tile stays off the bottom edge.
    readonly property real ringRadius: Math.min(width, height) * 0.38

    // keyboard/hover cursor: index into `tiles`. Shared by arrow-key nav and the
    // mouse, so there's only ever one highlight.
    property int selected: -1

    // ── theme chrome: the theme's overview.qml when it ships one, glass otherwise ──
    // Follows the focused monitor's theme so the chrome is already mounted when
    // the exposé opens there.
    property string themeDir: ActiveTheme.focusedDir
    property string chromePath: ""
    property int chromeNonce: 0
    property ThemePalette pal: ThemePalette { themeDir: root.themeDir }
    readonly property var chrome: chromeLoader.item
    // optional chrome property with a glass fallback (NotificationCenter's cp)
    function cp(name, dflt) {
        const c = root.chrome
        return (c && c[name] !== undefined) ? c[name] : dflt
    }

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }
    Process {
        id: chromeProc
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim()
                if (p !== root.chromePath) { root.chromePath = p; root.remountChrome() }
            }
        }
    }
    // command built at call time, not bound — the one-behind trap again
    function rescanChrome() {
        chromeProc.command = ["bash", "-c",
            'd="$1"; f="$d/overview.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; printf "%s" "$f"',
            "_", root.themeDir]
        chromeProc.running = true
    }
    onThemeDirChanged: rescanChrome()
    function remountChrome() {
        if (root.chromePath === "") { chromeLoader.source = ""; return }
        chromeLoader.setSource(root.fileUrl(root.chromePath) + "?v=" + root.chromeNonce,
                               { pal: root.pal, overview: root })
    }
    onChromeNonceChanged: remountChrome()
    // non-visual provider object; the slots below mount its Components
    Loader { id: chromeLoader }
    FileView {
        path: root.chromePath
        watchChanges: root.chromePath !== ""
        printErrors: false
        onFileChanged: root.chromeNonce++
    }
    Connections {
        target: ControlBus
        function onThemeReloadRequested() { root.chromeNonce++; root.rescanChrome() }
    }
    Component.onCompleted: rescanChrome()

    // 0 closed, 1 open. Every tile eases its position out from the center and
    // scales up off this — that's the zoom-out pop. OutBack overshoots on the
    // way in so the ring fans slightly past its rest and settles.
    property real reveal: open ? 1 : 0
    Behavior on reveal {
        NumberAnimation {
            duration: root.open ? 300 : 200
            // InOutQuad out: InCubic held the tiles at full size then snapped,
            // OutCubic dumped them then trailed a faint smear for ~180ms. This
            // one leaves evenly and is actually gone when it says it is.
            easing.type: root.open ? Easing.OutBack : Easing.InOutQuad
        }
    }

    // ---- window model ----
    // liveWindows tracks hyprland while the exposé is up; `windows` is what the
    // Repeater actually sees. On close we stop copying, so the last snapshot
    // (same array, so no delegate churn) survives the collapse animation —
    // closeHold clears it afterwards, which is what releases the captures.
    readonly property var liveWindows: root.open ? root.buildWindows() : []
    property var windows: []
    onLiveWindowsChanged: if (root.open) root.windows = root.liveWindows
    function buildWindows() {
        return Hyprland.toplevels.values.map(t => {
            const o = t.lastIpcObject || {}
            return {
                address: o.address || "",
                title: o.title || "",
                cls: o.class || "",
                active: o.focusHistoryID === 0,
                // the hyprland toplevel's wayland handle — what ScreencopyView captures
                wayland: t.wayland ?? null,
            }
        }).filter(w => w.address)   // freshly-opened windows arrive address-less
    }
    readonly property var activeWin: root.windows.find(w => w.active) ?? null
    readonly property var ringWins: root.windows.filter(w => !w.active)

    // Once the ring gets busy the tiles would start colliding with each other,
    // so shrink them to whatever arc each one actually gets. ~8 windows still
    // ride at full size; past that they scale down instead of piling up.
    readonly property real tileScale: {
        const n = Math.max(1, root.ringWins.length)
        const arc = 2 * Math.PI * root.ringRadius / n - 18   // width available per tile
        return Math.max(0.5, Math.min(1, arc / root.tileW))
    }

    // one flat list — center first, then the ring — so a single Repeater + one
    // delegate lays them all out. Each entry carries its rest offset from center.
    readonly property var tiles: root.layoutTiles()
    function layoutTiles() {
        const out = []
        if (root.activeWin)
            out.push({ win: root.activeWin, w: centerW, h: centerH, rx: 0, ry: 0, center: true })
        const ring = root.ringWins
        const n = ring.length
        for (let i = 0; i < n; i++) {
            const ang = -Math.PI / 2 + i * 2 * Math.PI / n   // first tile at 12 o'clock
            out.push({
                win: ring[i],
                w: Math.round(tileW * root.tileScale),
                h: Math.round(tileH * root.tileScale),
                rx: Math.cos(ang) * ringRadius,
                ry: Math.sin(ang) * ringRadius,
                center: false,
            })
        }
        return out
    }

    function iconForClass(cls) {
        if (!cls) return Quickshell.iconPath("application-x-executable")
        const entry = DesktopEntries.heuristicLookup(cls)
        const name = (entry && entry.icon) ? entry.icon : cls.toLowerCase()
        return Quickshell.iconPath(name, "application-x-executable")
    }

    function focusWindow(addr) {
        if (!addr) return
        Hyprland.dispatch("focuswindow address:" + addr)
        root.closeMenu()
    }

    // Spatial arrow-key nav: the tiles sit at real angles, so an arrow moves to
    // the tile that's physically in that direction from the current one. dx/dy
    // is the pressed direction (up = 0,-1). We score candidates by how well they
    // line up with it (cosine of the angle between) and prefer the nearer one.
    function moveSel(dx, dy) {
        const ts = root.tiles
        if (ts.length === 0) return
        const cur = (root.selected >= 0 && root.selected < ts.length) ? root.selected : 0
        const c = ts[cur]
        let best = -1, bestScore = -Infinity
        for (let i = 0; i < ts.length; i++) {
            if (i === cur) continue
            const vx = ts[i].rx - c.rx
            const vy = ts[i].ry - c.ry
            const len = Math.hypot(vx, vy)
            if (len < 1) continue
            const align = (vx * dx + vy * dy) / len   // 1 = dead-on, <0 = behind
            if (align < 0.35) continue                // ignore anything not roughly ahead
            const score = align * 1000 - len          // aligned first, then closest
            if (score > bestScore) { bestScore = score; best = i }
        }
        if (best >= 0) root.selected = best
    }
    function focusSelected() {
        const ts = root.tiles
        if (root.selected >= 0 && root.selected < ts.length)
            root.focusWindow(ts[root.selected].win.address)
    }

    // keep the ring fresh if windows open/close/move while the overview is up
    Connections {
        target: Hyprland
        enabled: root.open
        function onRawEvent(event) {
            switch (event.name) {
            case "openwindow":
            case "closewindow":
            case "movewindow":
            case "movewindowv2":
            case "activewindowv2":
                Hyprland.refreshToplevels()
            }
        }
    }

    function openMenu() {
        if (!OverviewSettings.enabled) return
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        closeHold.stop()        // reopened mid-fade: don't let the old hold clear us
        closing = false
        selected = 0            // start on the center (current) window
        Hyprland.refreshToplevels()
        open = true
        Qt.callLater(() => keyCatcher.forceActiveFocus())
    }
    function closeMenu() {
        if (!open) return
        open = false
        closing = true
        closeHold.restart()
    }
    Timer {
        id: closeHold
        interval: 300
        onTriggered: {
            if (root.open) return
            root.closing = false
            root.windows = []
        }
    }

    IpcHandler {
        target: "workspaceOverview"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
        // same nav the arrow keys drive, exposed for the command palette / headless use
        function nav(dir: string): void {
            if (!root.open) return
            if (dir === "left") root.moveSel(-1, 0)
            else if (dir === "right") root.moveSel(1, 0)
            else if (dir === "up") root.moveSel(0, -1)
            else if (dir === "down") root.moveSel(0, 1)
        }
        function select(): void { if (root.open) root.focusSelected() }
        function get(): string { return root.selected + "/" + root.tiles.length }
    }

    // darker than the theme switcher's gallery scrim — an exposé wants the
    // wallpaper pushed back so the tiles read.
    Rectangle {
        anchors.fill: parent
        color: root.cp("scrimColor", "#000000")
        opacity: root.open ? root.cp("scrimOpacity", 0.42) : 0
        Behavior on opacity { NumberAnimation { duration: 200 } }
    }

    // click-outside to dismiss
    MouseArea {
        anchors.fill: parent
        enabled: root.open
        onClicked: root.closeMenu()
    }

    // theme scenery above the scrim, below the ring (chrome.backdrop). Mounted
    // only while the exposé is up, so a closed overview costs nothing. Visual
    // only by contract — no input handlers, clicks fall through to the scrim.
    Loader {
        anchors.fill: parent
        active: (root.open || root.closing) && !!(root.chrome && root.chrome.backdrop)
        sourceComponent: active ? root.chrome.backdrop : undefined
    }

    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            switch (e.key) {
            case Qt.Key_Escape: root.closeMenu(); e.accepted = true; break
            case Qt.Key_Left:   root.moveSel(-1, 0); e.accepted = true; break
            case Qt.Key_Right:  root.moveSel(1, 0);  e.accepted = true; break
            case Qt.Key_Up:     root.moveSel(0, -1); e.accepted = true; break
            case Qt.Key_Down:   root.moveSel(0, 1);  e.accepted = true; break
            case Qt.Key_Return:
            case Qt.Key_Enter:  root.focusSelected(); e.accepted = true; break
            }
        }
    }

    // ---- the radial field ----
    Repeater {
        model: root.tiles

        delegate: Item {
            id: tile
            required property var modelData
            required property int index
            readonly property var win: modelData.win
            readonly property bool isCenter: modelData.center
            readonly property bool hot: root.selected === index

            width: modelData.w
            height: modelData.h
            // rest position eased out from center by `reveal`; hover raises z
            x: root.width / 2 + modelData.rx * root.reveal - width / 2
            y: root.height / 2 + modelData.ry * root.reveal - height / 2
            scale: 0.55 + 0.45 * root.reveal
            opacity: root.reveal
            z: hot ? 20 : (isCenter ? 5 : 1)

            // lift each tile off the busy desktop behind it
            RectangularShadow {
                anchors.fill: parent
                visible: root.cp("shadowOn", true)
                radius: root.cp("cardRadius", Theme.popupRadius)
                blur: 40
                offset: Qt.vector2d(0, 16)
                color: root.cp("shadowColor", Qt.rgba(0, 0, 0, 0.5))
                opacity: root.reveal
            }

            // theme chassis behind the card (chrome.tileUnderlay); its root may
            // declare `property var tile` to receive this delegate live —
            // index / isCenter / hot / win / width / height. Item doesn't clip,
            // so brackets and glows may paint outside the tile bounds.
            Loader {
                anchors.fill: parent
                active: !!(root.chrome && root.chrome.tileUnderlay)
                sourceComponent: active ? root.chrome.tileUnderlay : undefined
                onLoaded: if (item && item.hasOwnProperty("tile")) item.tile = tile
            }

            Rectangle {
                id: card
                anchors.fill: parent
                radius: root.cp("cardRadius", Theme.popupRadius)
                color: root.cp("cardBg", Theme.menuBg)
                border.color: tile.hot ? root.cp("cardBorderHot", Theme.accent)
                           : (tile.isCenter ? root.cp("cardBorderCenter",
                                  Qt.rgba(Theme.accent.r, Theme.accent.g, Theme.accent.b, 0.55))
                                            : root.cp("cardBorder", Theme.glassBorder))
                border.width: tile.hot ? root.cp("cardBorderWidthHot", 2)
                           : (tile.isCenter ? root.cp("cardBorderWidthCenter", 2)
                                            : root.cp("cardBorderWidth", 1))
                Behavior on border.color { ColorAnimation { duration: 120 } }

                scale: tile.hot ? 1.04 : 1
                Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

                Rectangle {
                    anchors.top: parent.top
                    anchors.topMargin: 1
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: parent.radius
                    anchors.rightMargin: parent.radius
                    height: 1
                    color: root.cp("cardHighlight", Theme.glassHighlight)
                }

                // live thumbnail of the real window
                ClippingRectangle {
                    id: shot
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.margins: 8
                    height: tile.height - root.footerH - 12
                    radius: root.cp("thumbRadius", 9)
                    color: root.cp("thumbBg", Theme.insetBg)

                    ScreencopyView {
                        id: thumb
                        anchors.centerIn: parent
                        captureSource: tile.win.wayland ?? null
                        live: root.open
                        property bool hadContent: false
                        onHasContentChanged: if (hasContent) hadContent = true
                        visible: hasContent && !root.closing
                        // letterbox to the window's real aspect instead of stretching
                        readonly property real ar: sourceSize.height > 0
                            ? sourceSize.width / sourceSize.height : 16 / 9
                        width: Math.min(parent.width, parent.height * ar)
                        height: Math.min(parent.height, parent.width / ar)
                    }

                    // the last captured frame, held. the screencopy goes empty the
                    // instant the exposé closes no matter how `live` is gated, so
                    // without this the tiles fade out as blank cards.
                    ShaderEffectSource {
                        anchors.centerIn: parent
                        width: thumb.width
                        height: thumb.height
                        sourceItem: thumb
                        live: root.open       // stops updating on close, keeps the texture
                        hideSource: false
                        visible: root.closing && thumb.hadContent
                    }

                    // until the first frame lands (and for anything that won't
                    // capture), fall back to the app icon
                    IconImage {
                        anchors.centerIn: parent
                        width: tile.isCenter ? 56 : 40
                        height: width
                        source: root.iconForClass(tile.win.cls)
                        // a tile that had a preview must not swap to the icon while
                        // it's fading out — that swap is the visible glitch
                        visible: !thumb.hasContent && !(root.closing && thumb.hadContent)
                    }
                }

                Item {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 8
                    height: root.footerH - 8

                    IconImage {
                        id: footIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16
                        source: root.iconForClass(tile.win.cls)
                    }

                    Text {
                        anchors.left: footIcon.right
                        anchors.leftMargin: 7
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: tile.win.title || tile.win.cls || "window"
                        textFormat: Text.PlainText
                        color: tile.hot ? root.cp("titleHotColor", Theme.textBright)
                                        : root.cp("titleColor", Theme.textSecondary)
                        font.family: {
                            const f = root.cp("titleFont", "")
                            return f !== "" ? f : Application.font.family
                        }
                        font.pixelSize: tile.isCenter ? 13 : 12
                        elide: Text.ElideRight
                        maximumLineCount: 1
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.selected = tile.index
                    onClicked: root.focusWindow(tile.win.address)
                }
            }

            // theme decoration above the card (chrome.tileOverlay) — reticles,
            // tags, glints. Same `tile` injection as tileUnderlay; visual only
            // by contract so the card's MouseArea keeps working underneath.
            Loader {
                anchors.fill: parent
                z: 10
                active: !!(root.chrome && root.chrome.tileOverlay)
                sourceComponent: active ? root.chrome.tileOverlay : undefined
                onLoaded: if (item && item.hasOwnProperty("tile")) item.tile = tile
            }
        }
    }

    // empty state
    Text {
        anchors.centerIn: parent
        visible: root.open && root.windows.length === 0 && text !== ""
        text: root.cp("emptyText", "No open windows")
        color: root.cp("hintColor", Theme.textMuted)
        font.family: root.cp("hintFont", Theme.mono)
        font.pixelSize: 15
        opacity: root.reveal
    }

    // hint
    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 72
        visible: root.windows.length > 0 && text !== ""
        text: root.cp("hintText", "arrows to move    enter / click to switch    esc to close")
        color: root.cp("hintColor", Theme.textMuted)
        font.family: root.cp("hintFont", Theme.mono)
        font.pixelSize: 11
        font.letterSpacing: 1
        opacity: root.reveal * 0.8
    }

    // theme layer above everything (chrome.overlay — scanlines, vignettes,
    // HUD readouts). Mounted only while up; no input handlers by contract.
    Loader {
        anchors.fill: parent
        active: (root.open || root.closing) && !!(root.chrome && root.chrome.overlay)
        sourceComponent: active ? root.chrome.overlay : undefined
    }
}
