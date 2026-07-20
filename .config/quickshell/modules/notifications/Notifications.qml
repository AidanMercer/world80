import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import Quickshell.Services.Notifications
import "../common"

// Native notification daemon + on-theme popup stack. The server hands us each
// notification; we set tracked=true to keep it alive, push it onto our own list
// (newest on top, capped), and each card auto-dismisses on a timer unless it's
// Critical or being hovered. Popups stack top-right on the focused monitor, below
// the bar. Glass by default, neon chamfer on cyber themes — or the active theme's
// own card chrome when it ships a notif.qml (cardBg/cardBorder/cardRadius +
// optional per-card backdrop Component, same slot grammar as popup.qml).
// Also owns the history + do-not-disturb state and the center panel (Super+I).
Scope {
    id: scope

    // our own display list of live Notification objects (newest first, capped)
    property var popups: []
    readonly property int maxVisible: 5

    // popupModel mirrors popups row-for-row and is what the stack actually draws.
    // Handing the Repeater the plain array made Qt tear down and rebuild every
    // delegate on each arrival, so a burst restarted all the dismiss timers and
    // replayed every entrance; a ListModel insert only builds the new card. The
    // rows carry an id rather than the note itself — real Notifications are
    // QObjects that won't take an extra property and ListModel copies plain JS
    // objects, which is the identity trap that forced index-based removal here
    // in the first place. Cards resolve their note through noteById once, so
    // they keep pointing at the right one no matter how the indices shift.
    ListModel { id: popupModel }
    property var noteById: ({})
    property int popupSeq: 0

    function noteFor(pid) { return scope.noteById[pid] || null }

    function addPopup(n) {
        const pid = ++scope.popupSeq
        scope.noteById[pid] = n
        scope.popups = [n, ...scope.popups]
        popupModel.insert(0, { pid: pid })
        // whatever falls off the end is still tracked in the server — dismissing
        // it is what frees it (and its image payload)
        while (scope.popups.length > scope.maxVisible)
            scope.removeAt(scope.popups.length - 1)
    }

    function removeAt(i) {
        if (i < 0 || i >= popupModel.count) return
        const n = scope.popups[i]
        const pid = popupModel.get(i).pid
        popupModel.remove(i)
        delete scope.noteById[pid]
        scope.popups = scope.popups.filter((x, xi) => xi !== i)
        if (n && n.dismiss) n.dismiss()
    }

    function removeId(pid) {
        for (let i = 0; i < popupModel.count; i++)
            if (popupModel.get(i).pid === pid) { scope.removeAt(i); return }
    }

    function removeWhere(pred) {
        for (let i = scope.popups.length - 1; i >= 0; i--)
            if (pred(scope.popups[i])) scope.removeAt(i)
    }

    // ── history + do-not-disturb ────────────────────────────────────────
    // Every card that comes through — dbus, battery, portal — is snapshotted
    // into a plain list for the center panel. Live Notification objects die
    // with their popup; the snapshots persist in the state file, so history
    // rides out the constant restarts this tree gets while ricing. DND sends
    // everything straight to history — only Critical still pops.
    property var history: []
    property bool dnd: false
    readonly property int maxHistory: 60

    function record(n) {
        const snap = {
            appName: String(n.appName || "Notification"),
            appIcon: String(n.appIcon || ""),
            summary: String(n.summary || ""),
            body: String(n.body || "").slice(0, 500),
            urgency: n.urgency === undefined ? NotificationUrgency.Normal : n.urgency,
            ts: Date.now()
        }
        scope.history = [snap, ...scope.history].slice(0, scope.maxHistory)
        scope.saveState()
    }

    // synthetic cards (battery, portal) enter here; dbus ones in onNotification
    function push(note) {
        scope.record(note)
        if (scope.dnd && note.urgency !== NotificationUrgency.Critical) return
        scope.addPopup(note)
    }

    function setDnd(v) {
        if (scope.dnd === v) return
        scope.dnd = v
        // going quiet dismisses whatever's up right now too
        if (v) scope.removeWhere(() => true)
        scope.saveState()
    }

    function removeHistoryAt(i) {
        scope.history = scope.history.filter((x, xi) => xi !== i)
        scope.saveState()
    }
    function clearHistory() { scope.history = []; scope.saveState() }

    function saveState() {
        historyFile.setText(JSON.stringify({ dnd: scope.dnd, items: scope.history }) + "\n")
    }
    FileView {
        id: historyFile
        path: Quickshell.stateDir + "/notif-center.json"
        blockLoading: true
        preload: true
        printErrors: false
        onLoaded: {
            try {
                const s = JSON.parse(text())
                if (s && typeof s === "object") {
                    scope.dnd = s.dnd === true
                    if (Array.isArray(s.items)) scope.history = s.items
                }
            } catch (e) {}
        }
    }

    IpcHandler {
        target: "notifs"
        function toggle(): void { center.toggle() }
        function dnd(): string { scope.setDnd(!scope.dnd); return scope.dnd ? "on" : "off" }
        function clear(): void { scope.clearHistory() }
        function status(): string { return (scope.dnd ? "dnd" : "on") + " " + scope.history.length }
    }

    NotificationCenter { id: center; store: scope }

    // ── captive-portal watcher ──────────────────────────────────────────
    // NetworkManager already probes its check URI on every new connection
    // (/usr/lib/NetworkManager/conf.d/20-connectivity.conf); hotel/cafe wifi
    // hijacks that probe and NM flags connectivity 'portal'. Nothing else on
    // this system listens for that, so we do: raise a sticky card whose button
    // opens the login page in the browser (the portal hijacks that request too,
    // which is exactly what lands you on the sign-in form), then force rechecks
    // so the card clears moments after login instead of at NM's next 5-minute
    // probe. Synthetic note, not a real dbus Notification — same card shape.
    property string portalCheckUri: "http://ping.archlinux.org/nm-check.txt"
    // any portal card currently visible? (marker-scan, not identity tracking —
    // a single tracked reference goes stale across reloads and orphans cards)
    readonly property bool portalShowing: popups.some(x => x.portal === true)

    function onConnectivity(state) {
        if (state === "portal") {
            if (scope.portalShowing) return
            const note = {
                portal: true,
                appName: "Network",
                appIcon: "network-wireless",
                summary: "Wi-Fi needs a web sign-in",
                body: "This network blocks internet access until you log in on its portal page.",
                urgency: NotificationUrgency.Normal,
                sticky: true,
                actions: [{
                    text: "Open login page",
                    invoke: () => scope.openPortalPage()
                }],
                dismiss: () => {}
            }
            scope.push(note)
        } else if (state === "full" || state === "none") {
            // signed in (or left the network) — retire every portal card
            if (scope.portalShowing)
                scope.removeWhere(x => x.portal === true)
        }
    }

    // stream connectivity transitions from NM
    Process {
        id: nmMonitor
        command: ["env", "LC_ALL=C", "nmcli", "monitor"]
        running: true
        stdout: SplitParser {
            onRead: (line) => {
                const m = /^Connectivity is now '([a-z]+)'/.exec(line)
                if (m) scope.onConnectivity(m[1])
            }
        }
        onExited: nmMonitorRestart.start() // NM restarted; reattach
    }
    Timer { id: nmMonitorRestart; interval: 3000; onTriggered: nmMonitor.running = true }

    // startup: current state, plus whatever check URI NM is configured with
    Process {
        running: true
        command: ["bash", "-c",
            "nmcli -t -f CONNECTIVITY general status; " +
            "busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager " +
            "org.freedesktop.NetworkManager ConnectivityCheckUri 2>/dev/null | cut -d '\"' -f2"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                if (lines[1]) scope.portalCheckUri = lines[1]
                scope.onConnectivity(lines[0])
            }
        }
    }

    // The browser must never be pointed at the check URI itself: archlinux.org
    // is HSTS-preloaded, so the browser force-upgrades it to https, hits the
    // portal's own cert, and refuses with no override (SSL_ERROR_BAD_CERT_DOMAIN,
    // seen live on a datavalet portal). curl has no HSTS store — probe the check
    // URI over plain http, open the portal's actual redirect target; portals
    // that hijack with a 200 page instead of a 3xx get neverssl.com, which any
    // portal can intercept and no browser will upgrade.
    function openPortalPage() {
        // command built at call time, not bound — the one-behind trap again
        portalOpen.command = ["bash", "-c",
            'url=$(curl -sm 4 -o /dev/null -w "%{redirect_url}" "$1"); ' +
            'exec xdg-open "${url:-http://neverssl.com}"',
            "_", scope.portalCheckUri]
        portalOpen.running = true
    }
    Process { id: portalOpen }

    // while the card is up, poke NM so it notices the completed login fast
    Timer {
        running: scope.portalShowing
        interval: 10000
        repeat: true
        onTriggered: nmRecheck.running = true
    }
    Process {
        id: nmRecheck
        command: ["nmcli", "networking", "connectivity", "check"]
        stdout: StdioCollector { onStreamFinished: scope.onConnectivity(text.trim()) }
    }

    // preview/debug: `qs ipc call captivePortal simulate` / `clear`
    IpcHandler {
        target: "captivePortal"
        function simulate(): void { scope.onConnectivity("portal") }
        function clear(): void { scope.onConnectivity("full") }
    }

    // ── battery watcher ─────────────────────────────────────────────────
    // Polls the first BAT* under power_supply (same source as the bar's
    // ResourceBubble) and raises a low card at 20% and a critical one at 10%
    // while discharging. Plugging in silently clears them — no charge spam. The
    // desktop (no battery) reads empty and this stays silent.
    property int batLow: 20
    property int batCrit: 10
    property int batPercent: -1
    property string batStatus: ""        // "", Charging, Discharging, Full, Not charging…
    property bool warnedLow: false
    property bool warnedCrit: false

    // the warned latches survive shell reloads/restarts through a runtime flag
    // file — this tree hot-reloads on every edit and gets restarted constantly
    // while ricing, and an in-memory latch re-fired the low card on each one
    // (dismiss → straight back). Runtime dir = per-login lifetime, which is
    // exactly the scope the latch wants.
    FileView {
        id: batWarnFile
        path: {
            const rt = Quickshell.env("XDG_RUNTIME_DIR")
            return ((rt && String(rt).length) ? String(rt) : "/tmp") + "/qs-batwarn"
        }
        blockLoading: true
        preload: true
        printErrors: false
        onLoaded: {
            const t = text().trim()
            scope.warnedLow = t === "low" || t === "crit"
            scope.warnedCrit = t === "crit"
        }
    }

    function pushBattery(note) {
        note.battery = true
        note.appName = "Battery"
        note.actions = note.actions || []
        note.dismiss = () => {}
        scope.push(note)
    }

    function onBattery(percent, status) {
        if (percent < 0) { scope.batPercent = -1; scope.batStatus = ""; return }
        const charging = status === "Charging" || status === "Full"
        const wasCharging = scope.batStatus === "Charging" || scope.batStatus === "Full"
        const hadLow = scope.warnedLow, hadCrit = scope.warnedCrit

        // plugging in is the fix, so just clear any low/critical card silently.
        // no charging announcement — laptops flap Charging/Full/Not charging and
        // that flapping was firing a card every poll.
        if (charging && !wasCharging)
            scope.removeWhere(x => x.batteryWarn === true)

        // low / critical — only while actually running down
        if (status === "Discharging") {
            if (percent <= scope.batCrit && !scope.warnedCrit) {
                scope.pushBattery({ appIcon: "battery-caution", batteryWarn: true, sticky: true,
                    urgency: NotificationUrgency.Critical,
                    summary: "Battery critically low — " + percent + "%",
                    body: "Plug in now or the machine will suspend soon." })
                scope.warnedCrit = true; scope.warnedLow = true
            } else if (percent <= scope.batLow && !scope.warnedLow) {
                scope.pushBattery({ appIcon: "battery-caution", batteryWarn: true, sticky: true,
                    urgency: NotificationUrgency.Normal,
                    summary: "Battery low — " + percent + "%",
                    body: "Might want to grab the charger." })
                scope.warnedLow = true
            }
        }
        // clear the latches once we recover or plug in (a few % of hysteresis so
        // a value hovering on the line doesn't re-fire every poll)
        if (charging || percent >= scope.batLow + 5) scope.warnedLow = false
        if (charging || percent >= scope.batCrit + 5) scope.warnedCrit = false

        // mirror the latches only when they actually flip — not every 15s poll
        if (scope.warnedLow !== hadLow || scope.warnedCrit !== hadCrit)
            batWarnFile.setText(scope.warnedCrit ? "crit\n" : scope.warnedLow ? "low\n" : "\n")

        scope.batPercent = percent
        scope.batStatus = status
    }

    Process {
        id: batProc
        command: ["sh", "-c", "for b in /sys/class/power_supply/BAT*; do [ -e \"$b/capacity\" ] && { cat \"$b/capacity\" \"$b/status\"; break; }; done"]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split("\n")
                const cap = parseInt(lines[0], 10)
                if (lines[0] === "" || isNaN(cap)) { scope.onBattery(-1, ""); return }
                scope.onBattery(cap, (lines[1] || "").trim())
            }
        }
    }
    Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: batProc.running = true
    }

    // preview/debug: `qs ipc call battery test low|crit`
    IpcHandler {
        target: "battery"
        function test(kind: string): void {
            if (kind === "crit") scope.pushBattery({ appIcon: "battery-caution", batteryWarn: true, sticky: true,
                urgency: NotificationUrgency.Critical, summary: "Battery critically low — 7%", body: "Plug in now or the machine will suspend soon." })
            else scope.pushBattery({ appIcon: "battery-caution", batteryWarn: true, sticky: true,
                urgency: NotificationUrgency.Normal, summary: "Battery low — 18%", body: "Might want to grab the charger." })
        }
        function status(): string { return scope.batPercent + " " + scope.batStatus }
    }

    NotificationServer {
        id: server
        keepOnReload: false
        actionsSupported: true
        bodySupported: true
        bodyMarkupSupported: true
        imageSupported: true
        persistenceSupported: false

        onNotification: (n) => {
            n.tracked = true
            scope.record(n)
            if (scope.dnd && n.urgency !== NotificationUrgency.Critical) {
                n.dismiss()   // straight to history
                return
            }
            scope.addPopup(n)
        }
    }

    // ── theme chrome: the theme's notif.qml when it ships one ──
    // Scope-level so the popup stack and the center panel share one mount.
    property string themeDir: {
        const fm = Hyprland.focusedMonitor
        return ActiveTheme.dirFor(fm ? fm.name : "")
    }
    property string chromePath: ""
    property int chromeNonce: 0
    readonly property var chrome: chromeLoader.item
    property ThemePalette pal: ThemePalette { themeDir: scope.themeDir }

    function fileUrl(p) {
        return "file://" + p.split("/").map(encodeURIComponent).join("/")
    }
    Process {
        id: chromeProc
        stdout: StdioCollector {
            onStreamFinished: {
                const p = text.trim()
                if (p !== scope.chromePath) { scope.chromePath = p; scope.remountChrome() }
            }
        }
    }
    // command built at call time, not bound — the one-behind trap again
    function rescanChrome() {
        chromeProc.command = ["bash", "-c",
            'd="$1"; f="$d/notif.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; printf "%s" "$f"',
            "_", scope.themeDir]
        chromeProc.running = true
    }
    onThemeDirChanged: rescanChrome()
    function remountChrome() {
        if (scope.chromePath === "") { chromeLoader.source = ""; return }
        chromeLoader.setSource(scope.fileUrl(scope.chromePath) + "?v=" + scope.chromeNonce,
                               { pal: scope.pal })
    }
    onChromeNonceChanged: remountChrome()
    // non-visual provider object; the cards mount its backdrop themselves
    Loader { id: chromeLoader }
    FileView {
        path: scope.chromePath
        watchChanges: scope.chromePath !== ""
        printErrors: false
        onFileChanged: scope.chromeNonce++
    }
    Connections {
        target: ControlBus
        function onThemeReloadRequested() { scope.chromeNonce++; scope.rescanChrome() }
    }
    Component.onCompleted: rescanChrome()

    PanelWindow {
        id: win
        // the center replaces the stack while it's up — no double top-right
        visible: scope.popups.length > 0 && !center.open

        // ride along with whichever monitor has focus (no per-screen duplication)
        screen: {
            const fm = Hyprland.focusedMonitor
            if (fm) {
                for (const s of Quickshell.screens)
                    if (s.name === fm.name) return s
            }
            return null
        }

        WlrLayershell.namespace: "quickshell-notifications"
        WlrLayershell.layer: WlrLayer.Top
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors { top: true; right: true }
        margins {
            // only drop below the bar when there actually is one at the top
            top: (ThemeConfig.barPosition === "top" ? Theme.barHeight : 0) + 8
            right: (ThemeConfig.barPosition === "right" ? Theme.barHeight : 0) + 10
        }
        implicitWidth: 360
        implicitHeight: Math.max(1, col.implicitHeight)

        Column {
            id: col
            anchors.right: parent.right
            width: parent.width
            spacing: 8

            Repeater {
                model: popupModel

                delegate: Rectangle {
                    id: card
                    required property int pid
                    // resolved once at creation, so the card stays bound to its
                    // own notification as rows come and go around it
                    readonly property var notif: scope.noteFor(pid)
                    readonly property var chrome: scope.chrome
                    readonly property int urgency: notif.urgency
                    // synthetic notes (captive portal) can pin themselves open
                    readonly property bool sticky: urgency === NotificationUrgency.Critical
                                                || notif.sticky === true
                    readonly property bool hovered: cardHover.containsMouse
                    readonly property color accentCol:
                        urgency === NotificationUrgency.Critical ? Theme.danger
                        : urgency === NotificationUrgency.Low ? Theme.textMuted
                        : Theme.accent

                    width: parent.width
                    radius: chrome ? chrome.cardRadius : (Theme.cyber ? 3 : 14)
                    color: chrome ? chrome.cardBg
                         : Theme.cyber ? Qt.rgba(0.04, 0.04, 0.07, 0.96)
                                       : Qt.rgba(ThemeConfig.glass.r, ThemeConfig.glass.g, ThemeConfig.glass.b, 0.94)
                    border.width: chrome ? chrome.cardBorderWidth : 1
                    border.color: chrome ? chrome.cardBorder
                                : Theme.cyber ? Theme.neon : Theme.glassBorder
                    implicitHeight: layout.implicitHeight + 24

                    // entrance: fade + slide in from the right
                    opacity: 0
                    transform: Translate { id: slide; x: 24 }
                    Component.onCompleted: enter.start()
                    ParallelAnimation {
                        id: enter
                        NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
                        NumberAnimation { target: slide; property: "x"; from: 24; to: 0; duration: 220; easing.type: Easing.OutCubic }
                    }

                    // theme chassis behind the content (chrome.backdrop); its root
                    // gets this card injected as `note` (urgency/accentCol/hovered)
                    Loader {
                        id: cardBackdrop
                        anchors.fill: parent
                        active: !!(card.chrome && card.chrome.backdrop)
                        sourceComponent: active ? card.chrome.backdrop : undefined
                        onLoaded: if (item && item.hasOwnProperty("note")) item.note = card
                    }

                    // urgency stripe down the left edge — unless the theme opts out
                    Rectangle {
                        visible: !(card.chrome && card.chrome.cardSpine === false)
                        anchors { left: parent.left; top: parent.top; bottom: parent.bottom }
                        width: 3
                        radius: parent.radius
                        color: card.accentCol
                    }

                    // auto-dismiss unless sticky (critical / portal) or hovered
                    Timer {
                        interval: card.urgency === NotificationUrgency.Low ? 1800 : 2200
                        running: !card.sticky && !cardHover.containsMouse
                        repeat: false
                        onTriggered: scope.removeId(card.pid)
                    }

                    MouseArea {
                        id: cardHover
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.NoButton
                    }

                    Column {
                        id: layout
                        anchors {
                            left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                            leftMargin: 16; rightMargin: 12
                        }
                        spacing: 6

                        // header: app icon + app name + close
                        Item {
                            width: parent.width
                            height: 16

                            Row {
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 7

                                Image {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 13; height: 13
                                    sourceSize.width: 13; sourceSize.height: 13
                                    smooth: true
                                    visible: status === Image.Ready
                                    // local sources only — a remote appIcon URL would
                                    // fire a request just by the card rendering
                                    source: {
                                        const ai = card.notif.appIcon || ""
                                        if (!ai || /^(https?|ftp):/i.test(ai)) return ""
                                        return ai.includes("/") ? ai : Quickshell.iconPath(ai, true)
                                    }
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: (card.notif.appName || "Notification").toUpperCase()
                                    textFormat: Text.PlainText
                                    color: card.accentCol
                                    font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                                    font.pixelSize: 9
                                    font.weight: Font.Bold
                                    font.letterSpacing: 2
                                }
                            }

                            Text {
                                id: closeBtn
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: String.fromCodePoint(0xF0156) // mdi close
                                font.family: Theme.icon
                                font.pixelSize: 13
                                color: closeMa.containsMouse ? Theme.textBright : Theme.textMuted

                                MouseArea {
                                    id: closeMa
                                    anchors.fill: parent
                                    anchors.margins: -6
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: scope.removeId(card.pid)
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: card.notif.summary
                            textFormat: Text.PlainText
                            color: Theme.textBright
                            font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            maximumLineCount: 1
                        }

                        Text {
                            width: parent.width
                            visible: text.length > 0
                            // keep body markup (links, bold) but drop <img> —
                            // StyledText would happily fetch a remote src
                            text: (card.notif.body || "").replace(/<img[^>]*>/gi, "")
                            textFormat: Text.StyledText
                            color: Theme.textMuted
                            font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                            elide: Text.ElideRight
                            maximumLineCount: 4
                            onLinkActivated: (l) => Qt.openUrlExternally(l)
                        }

                        // action buttons (if the notification ships any)
                        Row {
                            width: parent.width
                            spacing: 6
                            visible: card.notif.actions.length > 0
                            topPadding: 2

                            Repeater {
                                model: card.notif.actions

                                delegate: Rectangle {
                                    required property var modelData
                                    height: 24
                                    width: actText.implicitWidth + 22
                                    radius: Theme.cyber ? 2 : 8
                                    color: actMa.containsMouse ? Theme.rowSelected : Theme.rowHover
                                    border.width: 1
                                    border.color: Theme.divider

                                    Text {
                                        id: actText
                                        anchors.centerIn: parent
                                        text: parent.modelData.text
                                        color: Theme.textTertiary
                                        font.family: Theme.cyber ? Theme.mono : "Noto Sans"
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        id: actMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            parent.modelData.invoke()
                                            scope.removeId(card.pid)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
