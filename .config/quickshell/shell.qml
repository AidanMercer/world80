import Quickshell
import "modules/bar"
import "modules/launcher"
import "modules/themeswitcher"

ShellRoot {
    Variants {
        model: Quickshell.screens
        Bar {}
    }

    // Single app launcher window; toggled over IPC from the Super keybind.
    Launcher {}

    // Theme switcher overlay; toggled via `qs ipc call themeSwitcher toggle`
    // (Super+Shift+T in hyprland.conf).
    ThemeSwitcher {}
}
