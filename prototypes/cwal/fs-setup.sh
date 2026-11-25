#!/usr/bin/env bash
# Mount loop-backed ext4, XFS and NTFS (ntfs3) filesystems for torture.py.
# Run with sudo; the mounts are owned by the calling user.
#   sudo ./fs-setup.sh          create (if needed) and mount
#   sudo ./fs-setup.sh --down   unmount
set -euo pipefail
user=${SUDO_USER:?run with sudo}
group=$(id -gn "$user")
base=/home/$user/.cache/cwal-fs
size=3G

for fs in ext4 xfs ntfs3; do
	img=$base/img/$fs.img
	mnt=$base/mnt/$fs
	if [ "${1:-}" = --down ]; then
		mountpoint -q "$mnt" && umount "$mnt"
		continue
	fi
	mkdir -p "$base/img" "$mnt"
	chattr +C "$base/img" 2>/dev/null || true # no copy-on-write under the loop file
	mountpoint -q "$mnt" && continue
	if [ ! -e "$img" ]; then
		truncate -s "$size" "$img"
		case $fs in
		ext4) mkfs.ext4 -q -F "$img" ;;
		xfs) mkfs.xfs -q -f "$img" ;;
		ntfs3) mkfs.ntfs -q -Q -F "$img" ;;
		esac
	fi
	if [ "$fs" = ntfs3 ]; then
		mount -t ntfs3 -o loop,uid="$(id -u "$user")",gid="$(id -g "$user")" "$img" "$mnt"
	else
		mount -o loop "$img" "$mnt"
		chown "$user:$group" "$mnt"
	fi
	echo "$fs: $mnt"
done
chown -R "$user:$group" "$base/img"
