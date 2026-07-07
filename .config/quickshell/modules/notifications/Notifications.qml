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
Scope {
    id: scope

    // our own display list of live Notification objects (newest first, capped)
    property var popups: []
    readonly property int maxVisible: 5

    function remove(n) {
        scope.popups = scope.popups.filter(x => x !== n)
        if (n) n.dismiss()
    }

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
            scope.popups = [note, ...scope.popups].slice(0, scope.maxVisible)
        } else if (state === "full" || state === "none") {
            // signed in (or left the network) — retire every portal card
            if (scope.portalShowing)
                scope.popups = scope.popups.filter(x => x.portal !== true)
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
            const next = [n, ...scope.popups]
            scope.popups = next.slice(0, scope.maxVisible)
            // whatever fell off the end is still tracked in the server — dismiss
            // it or it (and its image payload) is retained forever
            for (const x of next.slice(scope.maxVisible))
                if (x.dismiss) x.dismiss()
        }
    }

    PanelWindow {
        id: win
        visible: scope.popups.length > 0

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

        // ── theme chrome: the theme's notif.qml when it ships one ──
        property string themeDir: ActiveTheme.dirFor(win.screen ? win.screen.name : "")
        property string chromePath: ""
        property int chromeNonce: 0
        readonly property var chrome: chromeLoader.item
        property ThemePalette pal: ThemePalette { themeDir: win.themeDir }

        function fileUrl(p) {
            return "file://" + p.split("/").map(encodeURIComponent).join("/")
        }
        Process {
            id: chromeProc
            stdout: StdioCollector {
                onStreamFinished: {
                    const p = text.trim()
                    if (p !== win.chromePath) { win.chromePath = p; win.remountChrome() }
                }
            }
        }
        // command built at call time, not bound — the one-behind trap again
        function rescanChrome() {
            chromeProc.command = ["bash", "-c",
                'd="$1"; f="$d/notif.qml"; { [ -n "$d" ] && [ -f "$f" ]; } || exit 0; printf "%s" "$f"',
                "_", win.themeDir]
            chromeProc.running = true
        }
        onThemeDirChanged: rescanChrome()
        function remountChrome() {
            if (win.chromePath === "") { chromeLoader.source = ""; return }
            chromeLoader.setSource(win.fileUrl(win.chromePath) + "?v=" + win.chromeNonce,
                                   { pal: win.pal })
        }
        onChromeNonceChanged: remountChrome()
        // non-visual provider object; the cards mount its backdrop themselves
        Loader { id: chromeLoader }
        FileView {
            path: win.chromePath
            watchChanges: win.chromePath !== ""
            printErrors: false
            onFileChanged: win.chromeNonce++
        }
        Connections {
            target: ControlBus
            function onThemeReloadRequested() { win.chromeNonce++; win.rescanChrome() }
        }
        Component.onCompleted: rescanChrome()

        Column {
            id: col
            anchors.right: parent.right
            width: parent.width
            spacing: 8

            Repeater {
                model: scope.popups

                delegate: Rectangle {
                    id: card
                    required property var modelData
                    readonly property var chrome: win.chrome
                    readonly property int urgency: modelData.urgency
                    // synthetic notes (captive portal) can pin themselves open
                    readonly property bool sticky: urgency === NotificationUrgency.Critical
                                                || modelData.sticky === true
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
                        onTriggered: scope.remove(card.modelData)
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
                                    source: card.modelData.appIcon
                                        ? (card.modelData.appIcon.includes("/")
                                            ? card.modelData.appIcon
                                            : Quickshell.iconPath(card.modelData.appIcon, true))
                                        : ""
                                }

                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: (card.modelData.appName || "Notification").toUpperCase()
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
                                    onClicked: scope.remove(card.modelData)
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            text: card.modelData.summary
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
                            text: card.modelData.body
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
                            visible: card.modelData.actions.length > 0
                            topPadding: 2

                            Repeater {
                                model: card.modelData.actions

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
                                            scope.remove(card.modelData)
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
