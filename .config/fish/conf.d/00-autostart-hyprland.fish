# Auto-start Hyprland on tty1 login (paired with getty autologin).
# Guards: only the local tty1 login shell, not SSH, not nested terminals.
if status is-login
    and test -z "$WAYLAND_DISPLAY"
    and test -z "$DISPLAY"
    and test "$XDG_VTNR" = 1
    # splash handoff: plymouth animates through the autologin (its quit units
    # are masked), so release the GPU and freeze its last frame right before
    # the compositor takes over. no-ops on warm relogins (daemon gone) and if
    # it ever fails, the root-side plymouth-quit-fallback unit cleans up.
    if command -q plymouth; and plymouth --ping 2>/dev/null
        plymouth deactivate 2>/dev/null
        plymouth quit --retain-splash 2>/dev/null
    end
    # start-hyprland (not raw Hyprland) — registers the session with
    # systemd/dbus and skips the in-session warning banner. tty output
    # silenced for the quiet boot — the real log lands in
    # $XDG_RUNTIME_DIR/hypr/<instance>/hyprland.log
    exec start-hyprland >/dev/null 2>&1
end
