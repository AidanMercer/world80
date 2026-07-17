#!/usr/bin/env bash
# plymouth boot splash setup — review before running, needs root.
# backs up grub config, mkinitcpio.conf and the current initramfs first;
# every edit is guarded so rerunning is safe.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
command -v plymouth-set-default-theme >/dev/null || { echo "install plymouth first: pacman -S plymouth"; exit 1; }

here="$(cd "$(dirname "$0")" && pwd)"
ts="$(date +%Y%m%d-%H%M%S)"

cp -a /etc/default/grub "/etc/default/grub.bak-$ts"
cp -a /etc/mkinitcpio.conf "/etc/mkinitcpio.conf.bak-$ts"
cp -a /boot/initramfs-linux.img "/boot/initramfs-linux.img.bak-$ts"
echo "backups stamped .bak-$ts"

mkdir -p /usr/share/plymouth/themes/world80
cp "$here"/themes/world80/* /usr/share/plymouth/themes/world80/

sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=0/' /etc/default/grub
sed -i 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=hidden/' /etc/default/grub
grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=.*splash' /etc/default/grub || \
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 splash"/' /etc/default/grub

grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf || \
    sed -i 's/^HOOKS=(base systemd /HOOKS=(base systemd plymouth /' /etc/mkinitcpio.conf
grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf || { echo "HOOKS edit failed — line not in expected shape, aborting before regen"; exit 1; }

plymouth-set-default-theme world80
mkinitcpio -P
grub-mkconfig -o /boot/grub/grub.cfg
# grub-mkconfig bakes "echo 'Loading Linux...'" lines into the entries and has
# no knob for it — strip them so the hidden boot stays silent
sed -i "/echo[[:space:]]*'Loading/d" /boot/grub/grub.cfg

echo
echo "== result =="
grep -E '^(GRUB_TIMEOUT|GRUB_TIMEOUT_STYLE|GRUB_CMDLINE_LINUX_DEFAULT)' /etc/default/grub
grep '^HOOKS' /etc/mkinitcpio.conf
echo "theme: $(plymouth-set-default-theme)"
echo
echo "rescue notes:"
echo "  - hold ESC during boot for the grub menu"
echo "  - add plymouth.enable=0 to the kernel line to skip the splash"
echo "  - restore the .bak-$ts files, then: mkinitcpio -P && grub-mkconfig -o /boot/grub/grub.cfg"
