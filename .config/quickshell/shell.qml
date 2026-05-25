import Quickshell
import "modules/bar"
import "modules/launcher"

ShellRoot {
    Variants {
        model: Quickshell.screens
        Bar {}
    }

    // Single app launcher window; toggled over IPC from the Super keybind.
    Launcher {}
}
