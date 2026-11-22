#!/bin/sh
# Builds an emulator of a TV with no /opt: the TV's own system (webOS 6, from
# an unpacked firmware) as a read-only squashfs, and a small initramfs that
# sets it up the way webOS does, then hands over to the TV's own /bin/sh.
# Needs no root: mksquashfs, cpio, xz, dpkg-deb, curl.
#
#   ROOTFS=/path/to/unpacked/rootfs sh build.sh
#
# The firmware tested is LM21A 03.53.45 (webOS 6.5.3), unpacked with
# epk2extract and unsquashfs.  A Debian armhf kernel and static busybox run
# it in qemu-system-arm.
set -e
cd "$(dirname "$0")"
[ -d "${ROOTFS:-}" ] || { echo "Set ROOTFS to the unpacked rootfs of a webOS 4 to 6 firmware." >&2; exit 2; }
W=work; mkdir -p "$W"
if [ ! -f "$W/vmlinuz" ]; then
    curl -fsSL https://deb.debian.org/debian/dists/trixie/main/binary-armhf/Packages.xz | xz -dc > "$W/Packages"
    k=$(awk '/^Package: linux-image-[0-9.]+\+deb13-armmp$/ {p = 1} p && /^Filename:/ {f = $2} /^$/ {p = 0} END {print f}' "$W/Packages")
    b=$(awk '/^Package: busybox-static$/ {p = 1} p && /^Filename:/ {print $2; exit}' "$W/Packages")
    curl -fsSL "https://deb.debian.org/debian/$k" -o "$W/kernel.deb"
    curl -fsSL "https://deb.debian.org/debian/$b" -o "$W/bb.deb"
    rm -rf "$W/k" "$W/bb"; dpkg-deb -x "$W/kernel.deb" "$W/k"; dpkg-deb -x "$W/bb.deb" "$W/bb"
    cp "$W"/k/boot/vmlinuz-* "$W/vmlinuz"
fi
# The modules for the disks, the filesystems and the network, with what each needs
find "$W/k" -name '*.ko*' > "$W/allmods"
resolve() (
    f=$(grep -E "/$1\.ko(\.xz)?$" "$W/allmods" | head -n 1)
    [ -n "$f" ] || exit 0
    for d in $(xz -dc "$f" | strings | sed -n 's/^depends=//p' | head -n 1 | tr ',' ' '); do resolve "$d"; done
    echo "$f"
)
for m in virtio_blk squashfs crc32c_generic crc32_generic ext4 virtio_net; do resolve "$m"; done | awk '!s[$0]++' > "$W/order"
[ -f "$W/rootfs.sqfs" ] || mksquashfs "$ROOTFS" "$W/rootfs.sqfs" -all-root -comp lz4 -noappend -no-progress -quiet
rm -rf "$W/ir" && mkdir -p "$W/ir/bin" "$W/ir/mods" "$W/ir/proc" "$W/ir/sys" "$W/ir/dev" "$W/ir/newroot"
cp "$W/bb/usr/bin/busybox" "$W/ir/bin/busybox"
: > "$W/ir/mods/order"
while read -r f; do n=$(basename "$f" .xz); xz -dc "$f" > "$W/ir/mods/$n"; echo "$n" >> "$W/ir/mods/order"; done < "$W/order"
cp init "$W/ir/init" && chmod 755 "$W/ir/init" "$W/ir/bin/busybox"
(cd "$W/ir" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9) > "$W/initrd.gz"
echo "Built $W/rootfs.sqfs and $W/initrd.gz.  Now: sh run.sh"
