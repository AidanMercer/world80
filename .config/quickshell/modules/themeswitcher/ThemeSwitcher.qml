import QtQuick
import QtQuick.Effects
import QtMultimedia
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Hyprland
import "../common"

// "Vernissage" — themes hang as matted plates on a horizontal picture rail;
// the focused plate stays dead-center and the rail slides under it. A theme's
// wallpaper variants (wallpaper.jpg, wallpaper2.mp4, ...) are a portfolio
// stack: unchosen sheets peek out as thin paper lips above/below the plate
// (real slivers of the real wallpapers — count and position read at a
// glance), Up/Down leafs through them. Enter hangs the sheet; the gallery
// red dot marks what's actually on the desktop. Focus is size and light;
// active is the dot. Toggled via `qs ipc call themeSwitcher toggle`.
PanelWindow {
    id: root

    property bool open: false
    property bool applying: false
    property bool closing: false

    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-themeswitcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || closing

    readonly property int imgW: 880
    readonly property int imgH: 550
    readonly property int mat: 14
    readonly property int cardW: imgW + mat * 2
    readonly property int cardH: imgH + mat * 2
    readonly property int smallW: 352 + mat * 2
    readonly property int smallH: 220 + mat * 2
    readonly property int railGap: 28
    readonly property real hangY: height * 0.46
    readonly property int lipH: 12
    readonly property int lipStep: 13
    readonly property int lipInset: 24

    // themes: [{ name, dir, accent, accent2, accent3, walls: [{path, thumb, video}] }]
    property var themes: []
    property int cur: 0
    property var varSel: []        // per-theme selected variant
    property int activeTheme: -1   // what's on the desktop (the red dot)
    property int activeVar: -1
    property int navMs: 260        // key-repeat compresses this
    property real bounceX: 0
    property real bounceY: 0

    // the whole rail is driven by this one animated scalar: plate sizes and
    // positions derive from it per-frame, so gaps stay exact mid-flight
    // instead of separate x/width Behaviors retargeting each other
    property real railPos: 0
    onCurChanged: railPos = cur
    Behavior on railPos {
        id: railBeh
        NumberAnimation { duration: root.navMs; easing.type: Easing.OutQuint }
    }

    // one scan finds each theme's wallpaper*.* variants (skipping *.still.png
    // extractions), makes missing video stills, and grabs the theme's own
    // accents from config.toml so plates can carry their own palette
    Process {
        id: scanProc
        running: false
        command: ["bash", "-c",
            'shopt -s nullglob; ' +
            'get() { grep -m1 -oiP "^\\s*$1\\s*=\\s*[\\"\']?#\\K[0-9a-fA-F]{6}" "$cfg" 2>/dev/null; true; }; ' +
            'for d in "$HOME"/.config/themes/*/; do ' +
            '  name=$(basename "$d"); ' +
            '  walls=$(ls "$d" 2>/dev/null | grep -E "^wallpaper[0-9]*\\.(jpg|jpeg|png|webp|gif|mp4)$" | sort -V); ' +
            '  [ -n "$walls" ] || continue; ' +
            '  cfg="$d/config.toml"; ' +
            '  printf "T\\t%s\\t%s\\t%s\\t%s\\t%s\\n" "$name" "${d%/}" "$(get accent)" "$(get accent2)" "$(get accent3)"; ' +
            '  while IFS= read -r w; do f="$d$w"; case "$f" in ' +
            '    *.mp4) s="${f%.mp4}.still.png"; ' +
            '           [ -f "$s" ] || ffmpeg -y -v error -i "$f" -frames:v 1 "$s" </dev/null; ' +
            '           printf "V\\t%s\\t%s\\t1\\n" "$f" "$s";; ' +
            '    *)     printf "V\\t%s\\t%s\\t0\\n" "$f" "$f";; ' +
            '  esac; done <<< "$walls"; ' +
            'done']
        stdout: StdioCollector {
            onStreamFinished: root.loadThemes(text)
        }
    }

    property string _fingerprint: ""
    property string _pendingApply: ""
    function loadThemes(out) {
        const hadNone = themes.length === 0
        const arr = []
        let t = null
        for (const line of (out || "").split("\n")) {
            const p = line.split("\t")
            if (p[0] === "T" && p.length >= 3) {
                t = { name: p[1], dir: p[2], accent: p[3] || "", accent2: p[4] || "",
                      accent3: p[5] || "", walls: [] }
                arr.push(t)
            } else if (p[0] === "V" && p.length >= 4 && t) {
                t.walls.push({ path: p[1], thumb: p[2], video: p[3] === "1" })
            }
        }
        // don't recreate delegates (and replay their entrance) when disk is unchanged
        const fp = JSON.stringify(arr)
        if (fp !== _fingerprint) {
            _fingerprint = fp
            themes = arr
        }
        syncActive()
        if (cur >= themes.length) cur = Math.max(0, themes.length - 1)
        if (hadNone && open && activeTheme >= 0) cur = activeTheme
        if (_pendingApply !== "") {
            const n = _pendingApply
            _pendingApply = ""
            applyByName(n)
        }
    }

    // awww holds either the image itself or a video's extracted still — match both
    function syncActive() {
        const mon = targetScreen ? targetScreen.name
                  : (Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "")
        const img = ActiveTheme.imgFor(mon)
        activeTheme = -1
        activeVar = -1
        for (let i = 0; i < themes.length; i++)
            for (let j = 0; j < themes[i].walls.length; j++) {
                const w = themes[i].walls[j]
                if (w.path === img || w.thumb === img) { activeTheme = i; activeVar = j }
            }
        if (varSel.length !== themes.length) {
            const sel = themes.map(() => 0)
            if (activeTheme >= 0) sel[activeTheme] = activeVar
            varSel = sel
        }
    }

    Connections {
        target: ActiveTheme
        function onMapChanged() { if (!root.applying) root.syncActive() }
    }

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }
    function pad2(n) { return (n < 10 ? "0" : "") + n }
    function roman(n) {
        return ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"][n - 1] || String(n)
    }

    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        applying = false
        closing = false
        varSel = []                // rest every stack on its active sheet
        syncActive()
        open = true
        cur = activeTheme >= 0 ? activeTheme : 0
        railBeh.enabled = false    // land on the plate, don't slide to it
        railPos = cur
        railBeh.enabled = true
        scanProc.running = true    // rescan each open so new folders show
        Qt.callLater(() => keyCatcher.forceActiveFocus())
    }
    function closeMenu() {
        if (!open) return
        open = false
        closing = true
        applying = false   // or the theme IPC stays dead until the next open
        closeHold.restart()
    }
    Timer { id: closeHold; interval: 300; onTriggered: root.closing = false }

    // no wrap: the ends answer with a refusal bounce
    function moveTheme(d) {
        if (themes.length === 0) return
        const n = cur + d
        if (n < 0 || n >= themes.length) { railRefusal.dir = d; railRefusal.restart(); return }
        cur = n
    }
    function moveVar(d) {
        if (themes.length === 0) return
        const v = (varSel[cur] ?? 0) + d
        if (v < 0 || v >= themes[cur].walls.length) { stackRefusal.dir = d; stackRefusal.restart(); return }
        const s = varSel.slice()
        s[cur] = v
        varSel = s
    }
    SequentialAnimation {
        id: railRefusal
        property int dir: 1
        NumberAnimation { target: root; property: "bounceX"; to: -railRefusal.dir * 10; duration: 80; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "bounceX"; to: 0; duration: 140; easing.type: Easing.OutBack }
    }
    SequentialAnimation {
        id: stackRefusal
        property int dir: 1
        NumberAnimation { target: root; property: "bounceY"; to: stackRefusal.dir * 8; duration: 80; easing.type: Easing.OutCubic }
        NumberAnimation { target: root; property: "bounceY"; to: 0; duration: 140; easing.type: Easing.OutBack }
    }

    function applyTheme() {
        if (applying || themes.length === 0) return
        const t = themes[cur]
        const w = t.walls[varSel[cur] ?? 0]
        if (!w) return
        applying = true
        activeTheme = cur          // the sticker is pressed on optimistically
        activeVar = varSel[cur] ?? 0
        applyWatchdog.restart()
        applyWallpaper(w.path)
    }
    Timer {
        id: applyWatchdog
        interval: 6000
        onTriggered: if (root.applying) { ControlBus.revealScreens(); root.closeMenu() }
    }

    // awww can't animate video, so an mp4 variant is applied as its extracted
    // still — loaders/lock/query keep working off it, VideoWall plays the real
    // video on top. Command built at call time, not bound (one-behind trap).
    //
    // The switch itself hides under the transition: every monitor freezes on a
    // frozen frame first (ControlBus → ThemeTransition), awww flips with no
    // transition of its own since nobody can see it, and revealHold wipes to
    // the finished desktop once the loaders have remounted. A second call
    // inside the freeze window just retargets pendingWall — freezeHold fires
    // once with whatever was last asked for.
    function applyWallpaper(wallpaper) {
        if (!wallpaper) return
        if (applyProc.running) return   // don't clobber pendingThemeDir mid-flight
        root.pendingThemeDir = wallpaper.substring(0, wallpaper.lastIndexOf("/"))
        // what awww actually shows (the still for an mp4) — persisted so login
        // restores this wallpaper instead of a hardcoded file
        root.lastAwwwTarget = wallpaper.endsWith(".mp4")
            ? wallpaper.replace(/\.mp4$/, ".still.png") : wallpaper
        root.pendingWall = wallpaper
        ControlBus.freezeScreens()
        freezeHold.restart()
    }
    // let every monitor's capture land before anything visibly changes
    Timer { id: freezeHold; interval: 180; onTriggered: root.kickApply() }
    function kickApply() {
        const wallpaper = root.pendingWall
        if (wallpaper === "") return
        if (wallpaper.endsWith(".mp4")) {
            applyProc.command = ["bash", "-c",
                'v="$1"; s="${v%.mp4}.still.png"; ' +
                '[ -f "$s" ] || ffmpeg -y -v error -i "$v" -frames:v 1 "$s"; ' +
                'awww img --transition-type none "$s"',
                "_", wallpaper]
        } else {
            applyProc.command = ["awww", "img", "--transition-type", "none", wallpaper]
        }
        applyProc.running = true
    }

    property string pendingThemeDir: ""
    property string lastAwwwTarget: ""
    property string pendingWall: ""

    Process {
        id: applyProc
        running: false
        onExited: (code, status) => {
            applyWatchdog.stop()
            revealHold.restart()
            ControlBus.notifyWallpaperChanged()
            // remember this wallpaper so restore-wallpaper.sh brings it back at login
            if (root.lastAwwwTarget !== "")
                Quickshell.execDetached(["sh", "-c",
                    'd="${XDG_CACHE_HOME:-$HOME/.cache}/world80"; mkdir -p "$d"; printf "%s\\n" "$1" > "$d/last-wallpaper"',
                    "_", root.lastAwwwTarget])
            colorProc.command = ["bash", "-c",
                '"$HOME/dotfiles/.config/hypr/theme-colors.sh" "$1"', "_", root.pendingThemeDir]
            colorProc.running = true
            applyHold.restart()    // let the dot pop land before leaving
        }
    }
    Timer { id: applyHold; interval: 200; onTriggered: root.closeMenu() }

    // wipe once the swap has settled under the freeze: ActiveTheme's re-query
    // and the widget loaders' remounts (incl. first-visit QML compiles, which
    // stall the main thread and so also stall this timer) all fit inside this
    Timer { id: revealHold; interval: 750; onTriggered: ControlBus.revealScreens() }

    Process { id: colorProc; running: false }

    // headless: qs ipc call theme next | prev | apply <name> | current
    function _indexOfDir(dir) {
        for (let i = 0; i < themes.length; i++)
            if (themes[i].dir === dir) return i
        return -1
    }
    function cycleTheme(delta) {
        if (applying || themes.length === 0) return
        let i = _indexOfDir(ActiveTheme.focusedDir)
        i = (i < 0) ? 0 : ((i + delta) % themes.length + themes.length) % themes.length
        const w = themes[i].walls[0]
        if (w) applyWallpaper(w.path)
    }
    function applyByName(name) {
        if (applying) return
        if (themes.length === 0) {      // login race: scan hasn't landed yet
            _pendingApply = name
            scanProc.running = true
            return
        }
        for (const t of themes)
            if (t.name === name) {
                if (t.walls[0]) applyWallpaper(t.walls[0].path)
                return
            }
    }

    IpcHandler {
        target: "themeSwitcher"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
        function nav(dir: string): void {
            if (!root.open || root.applying) return
            root.navMs = 260
            if (dir === "left") root.moveTheme(-1)
            else if (dir === "right") root.moveTheme(1)
            else if (dir === "up") root.moveVar(-1)
            else if (dir === "down") root.moveVar(1)
        }
        function select(): void { if (root.open) root.applyTheme() }
    }

    IpcHandler {
        target: "theme"
        function next(): void { root.cycleTheme(1) }
        function prev(): void { root.cycleTheme(-1) }
        function apply(name: string): void { root.applyByName(name) }
        function current(): string {
            const d = ActiveTheme.focusedDir
            return d ? d.substring(d.lastIndexOf("/") + 1) : ""
        }
    }

    Component.onCompleted: scanProc.running = true

    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            // escape works even mid-apply so a wedged awww can't trap the grab
            if (e.key === Qt.Key_Escape) { root.closeMenu(); e.accepted = true; return }
            if (root.applying) { e.accepted = true; return }
            root.navMs = e.isAutoRepeat ? 140 : 260
            if (e.key === Qt.Key_Left) { root.moveTheme(-1); e.accepted = true }
            else if (e.key === Qt.Key_Right) { root.moveTheme(1); e.accepted = true }
            else if (e.key === Qt.Key_Up) { root.moveVar(-1); e.accepted = true }
            else if (e.key === Qt.Key_Down) { root.moveVar(1); e.accepted = true }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.applyTheme(); e.accepted = true }
        }
    }

    // gallery lighting, not frost: 0.08 stays under hyprland's 0.1 blur threshold
    Rectangle {
        anchors.fill: parent
        color: Theme.light ? "#ffffff" : "#000000"
        opacity: root.open ? 0.08 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: if (!root.applying) root.closeMenu()
        // wheel over the focused plate leafs its stack; anywhere else, the rail
        property int accum: 0
        onWheel: (wheel) => {
            if (root.applying || !root.open) { wheel.accepted = true; return }
            if (wheelThrottle.running) { wheel.accepted = true; return }
            const dy = wheel.angleDelta.y
            const dx = wheel.angleDelta.x
            const delta = Math.abs(dx) > Math.abs(dy) ? dx : dy
            accum += delta
            if (Math.abs(accum) >= 120) {
                const overPlate =
                    Math.abs(wheel.x - root.width / 2) < root.cardW / 2 &&
                    Math.abs(wheel.y - root.hangY) < root.cardH / 2 + 60
                root.navMs = 200
                if (overPlate && root.themes.length > 0
                        && root.themes[root.cur].walls.length > 1)
                    root.moveVar(accum > 0 ? -1 : 1)
                else
                    root.moveTheme(accum > 0 ? -1 : 1)
                accum = 0
                wheelThrottle.restart()
            }
            wheel.accepted = true
        }
        Timer { id: wheelThrottle; interval: 150 }
    }

    Item {
        id: content
        anchors.fill: parent
        opacity: root.open ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: root.open ? 200 : 250; easing.type: root.open ? Easing.OutCubic : Easing.InCubic } }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: root.hangY - font.pixelSize
            visible: root.themes.length === 0
            horizontalAlignment: Text.AlignHCenter
            color: Theme.textSecondary
            font.family: Theme.mono
            font.pixelSize: 15
            text: "The collection is empty.\nDrop a folder with a wallpaper.<ext> into ~/.config/themes/"
        }

        Repeater {
            model: root.themes

            delegate: Item {
                id: plate
                required property var modelData
                required property int index

                readonly property int offset: index - root.cur
                readonly property bool focusedPlate: offset === 0
                readonly property bool activePlate: index === root.activeTheme
                readonly property int varIdx: root.varSel[index] ?? 0
                readonly property var wall: modelData.walls[varIdx] ?? modelData.walls[0]
                readonly property color ownAccent: modelData.accent !== ""
                                                   ? "#" + modelData.accent : Theme.accent

                // proximity to the rail cursor: 1 = focused, 0 = a full slot away.
                // size and x both derive from railPos, so a plate grows exactly
                // as fast as its neighbors are pushed aside — constant gaps, no
                // Behaviors chasing each other's moving targets
                readonly property real prox: Math.max(0, 1 - Math.abs(index - root.railPos))
                width: root.smallW + (root.cardW - root.smallW) * prox
                height: root.smallH + (root.cardH - root.smallH) * prox

                readonly property real railX: {
                    const p = root.railPos
                    const slot = root.smallW + root.railGap
                    const extra = root.cardW - root.smallW
                    const lo = Math.floor(p), hi = Math.ceil(p), f = p - lo
                    const eLo = extra * Math.max(0, 1 - (p - lo))
                    const eHi = hi === lo ? 0 : extra * Math.max(0, 1 - (hi - p))
                    // center of slot i: base spacing, shifted by the half-widths
                    // the (up to two) swelling plates push outward
                    const C = (i) => i * slot
                        + (lo === i ? 0 : (lo < i ? 0.5 : -0.5) * eLo)
                        + (hi === i || hi === lo ? 0 : (hi < i ? 0.5 : -0.5) * eHi)
                    return C(index) - (C(lo) * (1 - f) + (hi === lo ? 0 : C(hi) * f))
                }
                x: root.width / 2 + railX + root.bounceX - width / 2
                y: root.hangY - height / 2 + (focusedPlate ? root.bounceY : 0)

                z: focusedPlate ? 10 : (5 - Math.abs(offset))
                visible: Math.abs(offset) <= 4
                opacity: Math.abs(offset) >= 2 ? 0.25 : 1
                Behavior on opacity { NumberAnimation { duration: 200 } }

                // entrance: plates rise into place, focused first, outward stagger
                transform: Translate {
                    y: root.open ? 0 : 14
                    Behavior on y {
                        SequentialAnimation {
                            PauseAnimation { duration: root.open ? Math.min(Math.abs(plate.offset), 3) * 30 : 0 }
                            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                        }
                    }
                }

                scale: root.applying && focusedPlate ? 1.03 : 1
                Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }

                RectangularShadow {
                    anchors.fill: matRect
                    radius: matRect.radius
                    blur: 48
                    offset: Qt.vector2d(0, 24)
                    color: Qt.rgba(0, 0, 0, 0.30)
                    opacity: plate.focusedPlate ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 200 } }
                }

                // paper lips: sheets tucked behind the plate. lips above = variants
                // above you; each is a real sliver of that variant's wallpaper
                Repeater {
                    model: root.visible && plate.focusedPlate ? plate.modelData.walls.length : 0
                    delegate: Item {
                        id: lip
                        required property int index
                        readonly property var lipWall: plate.modelData.walls[index]
                        readonly property bool above: index < plate.varIdx
                        readonly property int depth: above ? plate.varIdx - index
                                                           : index - plate.varIdx
                        visible: index !== plate.varIdx
                        width: plate.width - root.lipInset * 2
                        height: root.lipH
                        x: root.lipInset
                        y: above ? -(depth * root.lipStep)
                                 : plate.height + depth * root.lipStep - root.lipH
                        z: -depth
                        Behavior on y { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                        Item {
                            anchors.fill: parent
                            clip: true
                            Image {
                                width: lip.width
                                height: Math.max(1, lip.width * root.imgH / root.imgW)
                                y: lip.above ? 0 : root.lipH - height
                                source: lip.lipWall ? root.fileUrl(lip.lipWall.thumb) : ""
                                // same sourceSize as the plate → shared texture
                                sourceSize: Qt.size(root.imgW, root.imgH)
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: false   // regenerated stills must not show stale frames
                            }
                            Rectangle {
                                anchors.fill: parent
                                color: "transparent"
                                border.color: Theme.glassBorder
                                border.width: 1
                            }
                            Text {
                                visible: lip.lipWall ? lip.lipWall.video : false
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                text: "▶"
                                font.pixelSize: 7
                                color: Theme.textBright
                                style: Text.Outline
                                styleColor: Qt.rgba(0, 0, 0, 0.5)
                            }
                            // the red dot rides the exact sheet that's on view
                            Rectangle {
                                visible: plate.activePlate && lip.index === root.activeVar
                                anchors.left: parent.left
                                anchors.leftMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                width: 6; height: 6; radius: 3
                                color: plate.ownAccent
                                border.color: Qt.rgba(0, 0, 0, 0.4)
                                border.width: 1
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.navMs = 260
                                const s = root.varSel.slice()
                                s[plate.index] = lip.index
                                root.varSel = s
                            }
                        }
                    }
                }

                Rectangle {
                    id: matRect
                    anchors.fill: parent
                    radius: 20
                    color: Theme.glassBg
                    border.color: Theme.glassBorder
                    border.width: 1

                    Rectangle {
                        anchors.top: parent.top
                        anchors.topMargin: 1
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.leftMargin: parent.radius
                        anchors.rightMargin: parent.radius
                        height: 1
                        color: Theme.glassHighlight
                    }

                    ClippingRectangle {
                        anchors.fill: parent
                        anchors.margins: root.mat
                        radius: 8
                        color: "transparent"

                        // two-image leaf: the incoming sheet drops in from the side
                        // it was tucked on while the old one fades under it
                        Item {
                            id: sheets
                            anchors.fill: parent
                            property string shown: ""
                            property Image front: imgA
                            property Image back: imgB
                            property int lastVar: -1

                            function syncSheet() {
                                if (!plate.wall || !root.visible) return
                                const dir = lastVar < 0 ? 0 : (plate.varIdx < lastVar ? -1 : 1)
                                lastVar = plate.varIdx
                                leaf(root.fileUrl(plate.wall.thumb), dir)
                            }
                            // drop the decoded pixmaps while the room is closed
                            function unload() {
                                shown = ""
                                lastVar = -1
                                imgA.source = ""
                                imgB.source = ""
                            }
                            function leaf(src, dir) {
                                if (src === shown) return
                                shown = src
                                if (leafAnim.running) leafAnim.complete()
                                const f = front
                                front = back
                                back = f
                                front.z = 1
                                back.z = 0
                                front.source = src
                                leafAnim.dir = dir
                                leafAnim.restart()
                            }
                            ParallelAnimation {
                                id: leafAnim
                                property int dir: 0
                                NumberAnimation {
                                    target: sheets.front; property: "y"
                                    from: leafAnim.dir * 40; to: 0
                                    duration: root.navMs; easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: sheets.front; property: "opacity"
                                    from: 0; to: 1
                                    duration: root.navMs; easing.type: Easing.OutCubic
                                }
                                NumberAnimation {
                                    target: sheets.back; property: "opacity"
                                    from: 1; to: 0
                                    duration: Math.round(root.navMs * 0.75)
                                }
                            }

                            Image {
                                id: imgA
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                height: parent.height
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(root.imgW, root.imgH)
                                asynchronous: true
                                cache: false   // regenerated stills must not show stale frames
                                smooth: true
                            }
                            Image {
                                id: imgB
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width
                                height: parent.height
                                fillMode: Image.PreserveAspectCrop
                                sourceSize: Qt.size(root.imgW, root.imgH)
                                asynchronous: true
                                cache: false   // regenerated stills must not show stale frames
                                smooth: true
                            }

                            Connections {
                                target: plate
                                function onWallChanged() { sheets.syncSheet() }
                            }
                            Connections {
                                target: root
                                function onVisibleChanged() { root.visible ? sheets.syncSheet() : sheets.unload() }
                            }
                            Component.onCompleted: syncSheet()
                        }

                        // a focused motion study starts moving under your gaze:
                        // one muted player, mounted only after a 400ms dwell.
                        // NOT gated on applying: killing an active MediaPlayer
                        // is a main-thread hitch, visible right at Enter — let
                        // it play on and die when the menu closes, hidden
                        // under the transition's frozen frame
                        Loader {
                            anchors.fill: parent
                            active: plate.focusedPlate && plate.wall && plate.wall.video
                                    && root.open && dwell.settled
                            sourceComponent: Item {
                                anchors.fill: parent
                                MediaPlayer {
                                    source: root.fileUrl(plate.wall.path)
                                    videoOutput: previewOut
                                    loops: MediaPlayer.Infinite
                                    Component.onCompleted: play()
                                }
                                VideoOutput {
                                    id: previewOut
                                    anchors.fill: parent
                                    fillMode: VideoOutput.PreserveAspectCrop
                                    opacity: 0
                                    NumberAnimation on opacity { to: 1; duration: 300 }
                                }
                            }
                        }
                    }

                    // glassine veil: resting prints sleep under tissue
                    Rectangle {
                        anchors.fill: parent
                        radius: parent.radius
                        color: Theme.light ? Qt.rgba(0.06, 0.05, 0.09, 0.10)
                                           : Qt.rgba(1, 1, 1, 0.10)
                        opacity: plate.focusedPlate ? 0 : 1
                        Behavior on opacity { NumberAnimation { duration: 200 } }
                    }

                    // the collector's dot: this theme is on the desktop
                    Rectangle {
                        visible: plate.activePlate
                        anchors.left: parent.left
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: 16
                        anchors.bottomMargin: 16
                        width: 9; height: 9; radius: 4.5
                        color: plate.ownAccent
                        border.color: Qt.rgba(0, 0, 0, 0.4)
                        border.width: 1
                        scale: root.applying && plate.focusedPlate ? 1.6 : 1
                        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }
                    }

                    // press-proof swatches: the theme's own palette
                    Row {
                        visible: plate.focusedPlate && plate.modelData.accent !== ""
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: 16
                        anchors.bottomMargin: 16
                        spacing: 1
                        Repeater {
                            model: [plate.modelData.accent, plate.modelData.accent2,
                                    plate.modelData.accent3].filter(c => c !== "")
                            Rectangle {
                                required property string modelData
                                width: 10; height: 10
                                color: "#" + modelData
                                border.color: Qt.rgba(0, 0, 0, 0.35)
                                border.width: 1
                            }
                        }
                    }

                    Rectangle {
                        visible: plate.focusedPlate && plate.wall && plate.wall.video
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.rightMargin: 16
                        anchors.topMargin: 16
                        width: 20; height: 20; radius: 10
                        color: Qt.rgba(0, 0, 0, 0.35)
                        border.color: Theme.glassBorder
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: 1
                            text: "▶"
                            font.pixelSize: 8
                            color: "#ffffff"
                        }
                    }
                }

                MouseArea {
                    anchors.fill: matRect
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (root.applying) return
                        root.navMs = 260
                        if (plate.focusedPlate) root.applyTheme()
                        else root.cur = plate.index
                    }
                }
            }
        }

        Timer { id: dwell; interval: 400; property bool settled: false; onTriggered: settled = true }
        Connections {
            target: root
            function onCurChanged() { dwell.settled = false; dwell.restart() }
            function onVarSelChanged() { dwell.settled = false; dwell.restart() }
            function onOpenChanged() { dwell.settled = false; if (root.open) dwell.restart() }
        }

        // the wall label: left-set under the plate like a gallery placard
        Item {
            id: wallLabel
            x: root.width / 2 - root.cardW / 2
            y: root.hangY + root.cardH / 2 + 64   // clears a 4-deep lip stack
            width: root.cardW
            height: 92
            visible: root.themes.length > 0

            property int shownCur: 0
            Connections {
                target: root
                function onCurChanged() { labelSwap.restart() }
                function onThemesChanged() {
                    wallLabel.shownCur = Math.min(wallLabel.shownCur, Math.max(0, root.themes.length - 1))
                }
            }
            SequentialAnimation {
                id: labelSwap
                ParallelAnimation {
                    NumberAnimation { target: labelCol; property: "opacity"; to: 0; duration: 100; easing.type: Easing.InCubic }
                    NumberAnimation { target: labelCol; property: "y"; to: 8; duration: 100; easing.type: Easing.InCubic }
                }
                ScriptAction { script: wallLabel.shownCur = root.cur }
                ParallelAnimation {
                    NumberAnimation { target: labelCol; property: "opacity"; to: 1; duration: 140; easing.type: Easing.OutCubic }
                    NumberAnimation { target: labelCol; property: "y"; from: -8; to: 0; duration: 140; easing.type: Easing.OutCubic }
                }
            }

            readonly property var shownTheme: root.themes[shownCur] ?? null
            readonly property int shownVar: root.varSel[shownCur] ?? 0
            readonly property var shownWall: shownTheme ? (shownTheme.walls[shownVar] ?? null) : null

            // raised style keeps the placard readable over busy desktops
            readonly property color emboss: Theme.light ? Qt.rgba(1, 1, 1, 0.6) : Qt.rgba(0, 0, 0, 0.6)

            Column {
                id: labelCol
                spacing: 7

                Text {
                    text: {
                        if (!wallLabel.shownTheme) return ""
                        let s = "COLLECTION · " + root.pad2(wallLabel.shownCur + 1)
                              + " / " + root.pad2(root.themes.length)
                        if (wallLabel.shownCur === root.activeTheme
                                && (root.varSel[wallLabel.shownCur] ?? 0) === root.activeVar)
                            s += " · ON VIEW"
                        return s
                    }
                    font.family: Theme.mono
                    font.pixelSize: 11
                    font.letterSpacing: 2.2
                    color: Theme.textMuted
                    style: Text.Raised
                    styleColor: wallLabel.emboss
                }
                Column {
                    spacing: 5
                    Text {
                        id: nameText
                        text: wallLabel.shownTheme ? wallLabel.shownTheme.name : ""
                        font.family: Theme.mono
                        font.pixelSize: 30
                        font.weight: Font.Medium
                        font.letterSpacing: -0.5
                        color: Theme.textBright
                        style: Text.Raised
                        styleColor: wallLabel.emboss
                    }
                    Rectangle {
                        width: nameText.paintedWidth
                        height: 2
                        color: wallLabel.shownTheme && wallLabel.shownTheme.accent !== ""
                               ? "#" + wallLabel.shownTheme.accent : Theme.accent
                    }
                }
                Text {
                    visible: wallLabel.shownTheme ? wallLabel.shownTheme.walls.length > 1 : false
                    text: {
                        if (!wallLabel.shownTheme || !wallLabel.shownWall) return ""
                        return "Plate " + root.roman(wallLabel.shownVar + 1)
                             + " / " + root.roman(wallLabel.shownTheme.walls.length)
                             + " · " + (wallLabel.shownWall.video ? "motion" : "still")
                    }
                    font.family: Theme.mono
                    font.pixelSize: 13
                    color: Theme.textSecondary
                    style: Text.Raised
                    styleColor: wallLabel.emboss
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 84
            visible: root.themes.length > 0
            text: "←→ works    ↑↓ plates    ↵ hang    esc leave"
            font.family: Theme.mono
            font.pixelSize: 10
            font.letterSpacing: 1
            color: Theme.textMuted
            style: Text.Raised
            styleColor: Theme.light ? Qt.rgba(1, 1, 1, 0.6) : Qt.rgba(0, 0, 0, 0.6)
            opacity: 0.8
        }
    }
}
