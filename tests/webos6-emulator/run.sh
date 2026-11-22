#!/bin/sh
# Runs the test on the emulated TV: stage 1 installs Entware with the
# installer from this repository, adds htop and restarts; stage 2 checks the
# boot script, an SSH login and doctor, then uninstalls.  Each line starting
# "SIM: PASS" or "SIM: FAIL" is a check.  Needs qemu-system-arm, mke2fs and
# the network (Entware's packages come from bin.entware.net).
#
#   sh build.sh && sh run.sh
set -e
cd "$(dirname "$0")"
W=work
MKE2FS=$(command -v mke2fs || echo /sbin/mke2fs)
rm -rf "$W/data" && mkdir -p "$W/data/sim"
cp ../../webos-entware-installer.sh stage.sh "$W/data/sim/"
rm -f "$W/data.img" && "$MKE2FS" -q -t ext4 -d "$W/data" -E root_owner=0:0 "$W/data.img" 2G
boot() {
    timeout 3000 qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 2 -m 1536 -nographic -no-reboot \
        -kernel "$W/vmlinuz" -initrd "$W/initrd.gz" -append "console=ttyAMA0 rdinit=/init quiet" \
        -drive if=none,id=r,file="$W/rootfs.sqfs",format=raw,readonly=on -device virtio-blk-pci,drive=r \
        -drive if=none,id=d,file="$W/data.img",format=raw -device virtio-blk-pci,drive=d \
        -netdev user,id=n -device virtio-net-pci,netdev=n > "$W/boot$1.log" 2>&1 || true
}
boot 1
boot 2
grep -ah "^SIM: " "$W/boot1.log" "$W/boot2.log" | tr -d '\r'
! grep -aqh "^SIM: FAIL" "$W/boot1.log" "$W/boot2.log"
