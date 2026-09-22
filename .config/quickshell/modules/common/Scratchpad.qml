pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

// The Super+` scratchpad — Hyprland's `special:scratchpad` — tracked once for
// every bar: which windows live in it, its workspace id, and whether it's up on
// a given monitor. The default bar reads it directly; theme bars get it as
// `pal.scratchpad` (ThemePalette) since they can't import the shell tree.
//
// Quickshell 0.3 models the special workspace and its windows (negative id,
// toplevel.workspace resolves to it) but not it being shown or hidden —
// monitor.activeWorkspace stays the regular one. So `shown` is kept from
// Hyprland's raw `activespecial` events, seeded from hyprctl at startup.
Singleton {
    id: root

    readonly property string wsName: "special:scratchpad"

    // the special workspace only exists while it has windows or is showing
    readonly property var workspace: Hyprland.workspaces.values.find(w => w.name === root.wsName) ?? null
    readonly property int id: workspace ? workspace.id : 0
    readonly property var windows: Hyprland.toplevels.values
        .filter(t => t.workspace && t.workspace.name === root.wsName)
    readonly property int count: windows.length

    // monitor name → true while the scratchpad is up on it. Reassigned whole on
    // every change so bindings that index into it re-evaluate.
    property var shown: ({})
    function shownOn(monName) { return root.shown[monName] === true }
    function toggle() { Hyprland.dispatch("togglespecialworkspace scratchpad") }

    function setShown(mon, on) {
        if (!mon) return
        const next = Object.assign({}, root.shown)
        if (on) next[mon] = true
        else delete next[mon]
        root.shown = next
    }

    Connections {
        target: Hyprland
        function onRawEvent(event) {
            // activespecial>>WORKSPACENAME,MONNAME — the name is empty on close
            if (event.name !== "activespecial") return
            const i = event.data.lastIndexOf(",")
            if (i < 0) return
            root.setShown(event.data.slice(i + 1), event.data.slice(0, i) === root.wsName)
        }
    }

    // seed: it may already be up when the shell (re)starts
    Process {
        running: true
        command: ["hyprctl", "monitors", "-j"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const next = {}
                    for (const m of JSON.parse(text))
                        if (m.specialWorkspace && m.specialWorkspace.name === root.wsName)
                            next[m.name] = true
                    root.shown = next
                } catch (e) {}
            }
        }
    }
}
