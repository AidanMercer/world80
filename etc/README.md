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
