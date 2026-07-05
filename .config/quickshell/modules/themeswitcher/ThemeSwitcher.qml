import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../common"

// Fullscreen, transparent layer-shell overlay holding a diagonal coverflow of
// "themes" along the BOTTOM of the screen. A theme is a folder under
// ~/.config/themes/<name>/ containing a wallpaper.<ext>. Browse with
// arrows/scroll, hit Enter (or click a card) to swap the wallpaper via `awww`.
// No Apply button, no screen dimming — selection is the commit.
//
// Layout is a PathView (not a ListView) for two reasons: it positions cards
// along a path instead of reflowing a layout, so resizing the focused card
// stays smooth; and it is circular by default, giving an infinite carousel.
//
// Each card's FRAME is sheared into a parallelogram (clip:true), while the
// wallpaper image inside is counter-sheared by the opposite amount about the
// same centre — the two shears cancel, so the picture renders perfectly
// upright inside the slanted, clipped window. The current card is wide; the
// rest are thin slivers, all driven by per-stop Path attributes.
//
// Opened/closed over IPC:
//   qs ipc call themeSwitcher toggle   (wired to Super+Shift+T in hyprland.conf)
//
// First increment is deliberately wallpaper-only — no colour regeneration.
PanelWindow {
    id: root

    property bool open: false
    property bool applying: false      // Enter/click → close; fades strip out
    property bool closing: false       // keep mapped through the close fade

    property var targetScreen: null
    screen: targetScreen

    WlrLayershell.namespace: "quickshell-themeswitcher"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "transparent"
    visible: open || closing

    // ---- card geometry -------------------------------------------------
    readonly property real centreWidth: 450    // focused card width
    readonly property real sideWidth: 150       // sliver width
    readonly property real centreHeight: 390
    readonly property real sideHeight: 360
    readonly property real skewFactor: -0.32    // leans the frame like "/"
    // Carousel spans a FIXED pixel width centred on screen, so the gap between
    // cards is identical on every monitor. (Previously the path ran the full
    // view.width, so slivers flew apart on the ultrawide and bunched on small
    // screens — spacing was view.width / pathItemCount.)
    readonly property real pathSpan: 1300       // tight enough that every card overlaps its
                                                 // neighbour. With no background showing through,
                                                 // each card exposes an equal-width slice → even
                                                 // rhythm, while the wide centre card (highest z)
                                                 // sits on top and overlaps both its neighbours.
    // Image is oversized so the counter-shear never exposes an edge.
    readonly property real imgW: centreWidth + (centreHeight * Math.abs(skewFactor)) + 60
    readonly property real imgH: centreHeight

    // ---- data ----------------------------------------------------------
    ListModel { id: themeModel }

    Process {
        id: scanProc
        running: false
        command: ["bash", "-c",
            'shopt -s nullglob; for d in "$HOME"/.config/themes/*/; do ' +
            'name=$(basename "$d"); ' +
            'for f in "$d"wallpaper.jpg "$d"wallpaper.jpeg "$d"wallpaper.png "$d"wallpaper.webp "$d"wallpaper.gif "$d"wallpaper.mp4; do ' +
            // video themes can't render in an Image — card shows the still instead
            '[ -e "$f" ] && { t="$f"; case "$f" in *.mp4) [ -e "${d}still.png" ] && t="${d}still.png";; esac; ' +
            'printf "%s\\t%s\\t%s\\n" "$name" "$f" "$t"; break; }; done; done']
        stdout: StdioCollector {
            onStreamFinished: root.loadThemes(text)
        }
    }

    function loadThemes(out) {
        themeModel.clear()
        const lines = (out || "").trim().split("\n").filter(l => l.length)
        for (const line of lines) {
            const parts = line.split("\t")
            if (parts.length >= 2)
                themeModel.append({ name: parts[0], wallpaper: parts[1],
                                    thumb: parts[2] || parts[1] })
        }
    }

    // Encode each path segment so spaces ("your name/") survive the file URL.
    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }

    // ---- lifecycle -----------------------------------------------------
    function openMenu() {
        const m = Hyprland.focusedMonitor
        targetScreen = m ? (Quickshell.screens.find(s => s.name === m.name) ?? null) : null
        applying = false
        closing = false
        open = true
        scanProc.running = true            // rescan each open so new folders show
        Qt.callLater(() => { view.currentIndex = 0; keyCatcher.forceActiveFocus() })
    }
    function closeMenu() {
        if (!open) return
        open = false
        closing = true
        closeHold.restart()
    }
    Timer { id: closeHold; interval: 260; onTriggered: root.closing = false }

    // Wrapping increment/decrement → infinite carousel.
    function moveSel(delta) {
        if (themeModel.count === 0) return
        if (delta > 0) view.incrementCurrentIndex()
        else view.decrementCurrentIndex()
    }

    function applyTheme() {
        if (applying || themeModel.count === 0) return
        const i = view.currentIndex
        if (i < 0 || i >= themeModel.count) return
        const t = themeModel.get(i)
        if (!t || !t.wallpaper) return
        applying = true
        applyWallpaper(t.wallpaper)
    }

    // Swap to a wallpaper path — shared by the overlay and the `theme` IPC. The
    // applyProc.onExited handler fans out to the per-theme widgets + retints apps.
    // awww can't animate video, so an mp4 theme is applied as its first frame
    // (still.png, generated on first switch) — query/lock/loaders all keep
    // working off the still, and VideoWall plays the actual video over it.
    function applyWallpaper(wallpaper) {
        if (!wallpaper) return
        root.pendingThemeDir = wallpaper.substring(0, wallpaper.lastIndexOf("/"))
        if (wallpaper.endsWith(".mp4")) {
            applyProc.command = ["bash", "-c",
                'v="$1"; s="${v%/*}/still.png"; ' +
                '[ -f "$s" ] || ffmpeg -y -v error -i "$v" -frames:v 1 "$s"; ' +
                'awww img --transition-type fade --transition-duration 0.7 "$s"',
                "_", wallpaper]
        } else {
            applyProc.command = ["awww", "img",
                "--transition-type", "fade",
                "--transition-duration", "0.7",
                wallpaper]
        }
        applyProc.running = true
    }

    property string pendingThemeDir: ""

    // --- headless theme switching over IPC (no overlay) -----------------
    // qs ipc call theme next | prev | apply <name> | current
    // "Current" is whatever awww is actually showing on the focused monitor
    // (via ActiveTheme), so next/prev cycle relative to reality, not the carousel.
    function _indexOfDir(dir) {
        for (let i = 0; i < themeModel.count; i++) {
            const w = themeModel.get(i).wallpaper
            if (w && w.substring(0, w.lastIndexOf("/")) === dir) return i
        }
        return -1
    }
    function cycleTheme(delta) {
        if (applying || themeModel.count === 0) return
        let i = _indexOfDir(ActiveTheme.focusedDir)
        i = (i < 0) ? 0 : ((i + delta) % themeModel.count + themeModel.count) % themeModel.count
        const t = themeModel.get(i)
        if (t && t.wallpaper) applyWallpaper(t.wallpaper)
    }
    function applyByName(name) {
        if (applying) return
        for (let i = 0; i < themeModel.count; i++) {
            const t = themeModel.get(i)
            if (t.name === name) { applyWallpaper(t.wallpaper); return }
        }
    }

    Process {
        id: applyProc
        running: false
        onExited: (code, status) => {
            ControlBus.notifyWallpaperChanged()   // let per-theme widgets reload
            colorProc.command = ["bash", "-c",
                '"$HOME/dotfiles/.config/hypr/theme-colors.sh" "$1"', "_", root.pendingThemeDir]
            colorProc.running = true              // re-tint kitty/fuzzel/hyprlock
            root.closeMenu()
        }
    }

    // regenerates the per-theme app palettes once the wallpaper has swapped
    Process { id: colorProc; running: false }

    IpcHandler {
        target: "themeSwitcher"
        function toggle(): void { root.open ? root.closeMenu() : root.openMenu() }
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

    // scan once at startup so the `theme` IPC has the list before the overlay opens
    Component.onCompleted: scanProc.running = true

    // ---- keyboard ------------------------------------------------------
    Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: (e) => {
            if (root.applying) { e.accepted = true; return }
            if (e.key === Qt.Key_Left || e.key === Qt.Key_Up) { root.moveSel(-1); e.accepted = true }
            else if (e.key === Qt.Key_Right || e.key === Qt.Key_Down) { root.moveSel(1); e.accepted = true }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) { root.applyTheme(); e.accepted = true }
            else if (e.key === Qt.Key_Escape) { root.closeMenu(); e.accepted = true }
        }
    }

    // ---- transparent click-outside-to-cancel (no dimming) --------------
    MouseArea {
        anchors.fill: parent
        onClicked: if (!root.applying) root.closeMenu()
    }

    // ---- the bottom filmstrip ------------------------------------------
    Item {
        id: content
        anchors.fill: parent
        opacity: root.open && !root.applying ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: parent.height * 0.22
            visible: themeModel.count === 0
            horizontalAlignment: Text.AlignHCenter
            color: Theme.textSecondary
            font.pixelSize: 15
            text: "No themes found.\nDrop a folder with a wallpaper.<ext> into ~/.config/themes/"
        }

        PathView {
            id: view
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Math.round(parent.height * 0.09)
            height: root.centreHeight + 70
            visible: themeModel.count > 0

            model: themeModel
            // Never exceed the theme count: if pathItemCount > model count,
            // PathView reserves an empty slot for the "missing" item, leaving a
            // gap in the carousel (looks like uneven spacing). Cap at 7.
            pathItemCount: Math.min(themeModel.count, 7)
            preferredHighlightBegin: 0.5
            preferredHighlightEnd: 0.5
            highlightRangeMode: PathView.StrictlyEnforceRange
            snapMode: PathView.SnapToItem
            highlightMoveDuration: 320
            interactive: false                 // driven by keys / wheel

            // Straight horizontal path; cards interpolate width/height/opacity
            // between the dim thin edges and the wide bright centre.
            path: Path {
                startX: view.width / 2 - root.pathSpan / 2; startY: view.height / 2
                PathAttribute { name: "iwide"; value: root.sideWidth }
                PathAttribute { name: "ihigh"; value: root.sideHeight }
                PathAttribute { name: "iz";    value: 0 }
                PathLine { x: view.width / 2; y: view.height / 2 }
                PathAttribute { name: "iwide"; value: root.centreWidth }
                PathAttribute { name: "ihigh"; value: root.centreHeight }
                PathAttribute { name: "iz";    value: 10 }
                PathLine { x: view.width / 2 + root.pathSpan / 2; y: view.height / 2 }
                PathAttribute { name: "iwide"; value: root.sideWidth }
                PathAttribute { name: "ihigh"; value: root.sideHeight }
                PathAttribute { name: "iz";    value: 0 }
            }

            // Scroll wheel without swallowing clicks (NoButton).
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                property int accum: 0
                onWheel: (wheel) => {
                    if (root.applying) { wheel.accepted = true; return }
                    if (wheelThrottle.running) { wheel.accepted = true; return }
                    const dy = wheel.angleDelta.y
                    const dx = wheel.angleDelta.x
                    const delta = Math.abs(dx) > Math.abs(dy) ? dx : dy
                    accum += delta
                    if (Math.abs(accum) >= 120) {
                        root.moveSel(accum > 0 ? -1 : 1)
                        accum = 0
                        wheelThrottle.start()
                    }
                    wheel.accepted = true
                }
            }
            Timer { id: wheelThrottle; interval: 130 }

            delegate: Item {
                id: card
                required property string name
                required property string wallpaper
                required property string thumb
                required property int index
                // PathView positions us by our centre; size/opacity come from
                // the interpolated path attributes (no layout reflow → smooth).
                width: PathView.iwide ?? root.sideWidth
                height: PathView.ihigh ?? root.sideHeight
                z: PathView.iz ?? 0

                // Sheared parallelogram frame; clip masks the upright image to it.
                Item {
                    id: frame
                    anchors.fill: parent
                    clip: true
                    transform: Matrix4x4 {
                        // Centred shear: x' = x + s*(y - h/2).
                        readonly property real s: root.skewFactor
                        matrix: Qt.matrix4x4(1, s, 0, -s * frame.height / 2,
                                             0, 1, 0, 0,
                                             0, 0, 1, 0,
                                             0, 0, 0, 1)
                    }

                    Image {
                        anchors.centerIn: parent
                        width: root.imgW
                        height: root.imgH
                        fillMode: Image.PreserveAspectCrop
                        source: root.fileUrl(card.thumb)
                        // Decode each wallpaper ONCE at display size. Without this
                        // Qt keeps the full multi-megapixel image in memory and
                        // re-samples it through the shear every frame → stutter.
                        sourceSize: Qt.size(root.imgW, root.imgH)
                        asynchronous: true
                        cache: true
                        smooth: true
                        transform: Matrix4x4 {
                            // Opposite shear about the image centre → cancels
                            // the frame shear, so the picture stays upright.
                            readonly property real s: -root.skewFactor
                            matrix: Qt.matrix4x4(1, s, 0, -s * root.imgH / 2,
                                                 0, 1, 0, 0,
                                                 0, 0, 1, 0,
                                                 0, 0, 0, 1)
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (card.PathView.isCurrentItem) root.applyTheme()
                            else view.currentIndex = card.index
                        }
                    }
                }
            }
        }
    }
}
