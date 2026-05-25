# /etc files (manual apply — NOT symlinked)

These are tracked reference copies of files that live under `/etc`. Unlike the
`.config` files, they are **not** symlinked: `/etc` needs root and the contents
differ per machine, so apply them by hand with `sudo cp` after reviewing.

## pam.d/hyprlock

Custom PAM stack for hyprlock. Identical to the system `system-auth` auth block
(keeps `pam_faillock` lockout protection and `systemd_home` support) but adds
`nodelay` to `pam_unix`, removing the ~2s delay PAM imposes after a wrong
password. Without this, the lockscreen waits ~2s before showing "wrong".

Apply:

    sudo cp -n /etc/pam.d/hyprlock /etc/pam.d/hyprlock.bak   # back up first
    sudo cp etc/pam.d/hyprlock /etc/pam.d/hyprlock

Then test in a recoverable way (keep a TTY open, Ctrl+Alt+F2) before logging
out: `hyprlock`, confirm your real password unlocks and a wrong one says
"wrong" instantly. Restore with the `.bak` if anything breaks.
