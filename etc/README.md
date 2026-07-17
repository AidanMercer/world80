# /etc files (manual apply — NOT symlinked)

These are tracked reference copies of files that live under `/etc`. Unlike the
`.config` files, they are **not** symlinked: `/etc` needs root and the contents
differ per machine, so apply them by hand with `sudo cp` after reviewing.

## plymouth/

Boot splash matching the quickshell cold-boot splash (same wordmark + sweeping
line), so kernel splash → shell splash reads as one animation. `themes/world80/`
is the plymouth theme; `setup.sh` installs it and makes the boot quiet:
GRUB_TIMEOUT=1 + hidden (hold ESC for the menu), `splash` on the kernel line,
`plymouth` hook after `systemd` in mkinitcpio HOOKS. It backs up grub config,
mkinitcpio.conf and the initramfs with timestamped .bak files before touching
anything, and every edit is guarded so rerunning is safe.

Apply (review setup.sh first):

    sudo pacman -S --needed plymouth
    sudo bash etc/plymouth/setup.sh

Rescue: hold ESC at boot for grub; `plymouth.enable=0` on the kernel line skips
the splash; restore the .bak files then `mkinitcpio -P && grub-mkconfig -o
/boot/grub/grub.cfg`.

## systemd/getty@tty1.service.d/autologin.conf

Silent autologin on tty1 — pairs with the fish autostart that execs Hyprland.
`--autologin aidan` skips the password prompt, `--skip-login --nonewline
--noissue` keep it from printing the login banner, so plymouth hands off to a
clean tty. `~/.hushlogin` (already in place) suppresses the "Last login" line.

Anyone who boots the SSD lands straight on the desktop — that's the deliberate
trade (no disk encryption anyway; lock is Super-key/hypridle only).

Apply:

    sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
    sudo cp etc/systemd/getty@tty1.service.d/autologin.conf /etc/systemd/system/getty@tty1.service.d/

Rescue: a broken tty1 doesn't take the others with it — Ctrl+Alt+F2 is a normal
login; delete the drop-in and `systemctl daemon-reload` to revert.

## systemd/plymouth-quit-fallback.service (+ quit-unit masks)

Splash handoff: normally systemd kills plymouth the moment getty starts, so the
boot animation dies early and the screen sits black until the qs veil. Masking
the two quit units lets plymouth animate through the whole autologin; the fish
autostart then freezes its last frame (`plymouth quit --retain-splash`) right
before launching Hyprland. The fallback unit is the safety net: if that handoff
ever fails (so plymouth would hold the GPU and block the compositor), it
force-quits the splash ~8s in — worst case is a slow boot, never a stuck one.

Apply:

    sudo systemctl mask plymouth-quit.service plymouth-quit-wait.service
    sudo cp etc/systemd/plymouth-quit-fallback.service /etc/systemd/system/
    sudo systemctl enable plymouth-quit-fallback.service

Rescue / revert: Ctrl+Alt+F2, then
`sudo systemctl unmask plymouth-quit.service plymouth-quit-wait.service`
and disable the fallback unit.

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
