#!/bin/bash
# End-to-end tests for webos-entware-installer.sh on a Linux PC (not a TV).
# Needs root and unshare. Runs in a private mount namespace, with tmpfs over
# the TV paths and fake wget/opkg/uname, so nothing is downloaded and the PC
# is left as it was, apart from empty mount points it may create.
# Usage: sudo tests/run_tests.sh [shell]   (default: busybox sh, like webOS)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../webos-entware-installer.sh"
SH=${1:-"busybox sh"}

if [ "${INSIDE_NS:-}" != 1 ]; then
    [ "$(id -u)" = 0 ] || { echo "Run as root (needs mount namespaces)."; exit 1; }
    exec env INSIDE_NS=1 unshare -m --propagation private bash "$0" "$@"
fi

W=$(mktemp -d /run/entware-test.XXXXXX)
cp "$SCRIPT" "$W/installer.sh"
for d in /mnt /tmp /var/lib/webosbrew /home/root; do
    mkdir -p "$d" && mount -t tmpfs tmpfs "$d"
done
mkdir -p /mnt/lg/user /var/lib/webosbrew/init.d

# --- fakes ---
mkdir -p "$W/bin"
cat > "$W/bin/uname" << 'F'
#!/bin/sh
[ "$1" = -m ] && { echo aarch64; exit 0; }
exec /usr/bin/uname "$@"
F
cat > "$W/fake-opkg" << 'F'
#!/bin/sh
DB=/opt/lib/opkg/fake-installed
mkdir -p /opt/lib/opkg; touch $DB
case "$1" in
    print-architecture) echo "arch all 1"; echo "arch aarch64-3.10 10" ;;
    update) echo "Updated list of available packages" ;;
    install) shift
        for p in "$@"; do
            if grep -qx "$p" $DB; then echo "Package $p is up to date"; continue; fi
            echo "$p" >> $DB
            case "$p" in
                entware-opt) mkdir -p /opt/etc/init.d
                    printf '#!/bin/sh\necho "$1" >> /tmp/rc.unslung.log\n' > /opt/etc/init.d/rc.unslung
                    chmod 755 /opt/etc/init.d/rc.unslung ;;
                bash) printf '#!/bin/sh\nexec /bin/bash "$@"\n' > /opt/bin/bash; chmod 755 /opt/bin/bash ;;
            esac
        done ;;
    list-installed) sed 's/$/ - 1/' $DB ;;
    list) echo "bash - 5.3"; echo "nano-full - 8.7" ;;
    *) echo "fake opkg: $*" ;;
esac
F
cat > "$W/bin/wget" << F
#!/bin/sh
while [ \$# -gt 1 ]; do [ "\$1" = -O ] && OUT=\$2; shift; done
case "\$1" in
    */installer/opkg) cp $W/fake-opkg "\$OUT" ;;
    */webos-entware-installer.sh) cp $W/installer.sh "\$OUT" ;;
    */installer/opkg.conf) printf 'src/gz entware http://bin.entware.net/aarch64-k3.10\ndest root /\nlists_dir ext /opt/var/opkg-lists\n' > "\$OUT" ;;
    *) [ "\$OUT" = /dev/null ] || : > "\$OUT" ;;
esac
F
chmod 755 "$W/bin/"* "$W/fake-opkg"
export PATH="$W/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME=/home/root

PASS=0 FAIL=0
ok() { if eval "$2"; then echo "  PASS $1"; PASS=$((PASS + 1)); else echo "  FAIL $1"; FAIL=$((FAIL + 1)); fi; }
run() { cp "$W/installer.sh" /tmp/webos-entware-installer.sh; (cd /tmp && $SH /tmp/webos-entware-installer.sh "$@") > "$W/out" 2>&1; }
mounted() { grep -qs " /opt " /proc/mounts; }
reboot_tv() { # /opt and /tmp are lost, the Homebrew Channel runs its boot scripts unless told not to
    umount /opt 2>/dev/null; rm -rf /tmp/* /tmp/.[!.]*
    if [ "${1:-}" != skip-hbc ]; then
        busybox run-parts /var/lib/webosbrew/init.d
        for _ in $(seq 1 20); do grep -qs "started Entware services" /tmp/webos-entware-boot.log && break; sleep 0.2; done
    fi
}
login() { $SH -l -c true < /dev/null > /dev/null 2>&1; }

echo "== [$SH] 1. fresh install, with your own .bashrc already there"
echo "export MINE=1" > /home/root/.bashrc
run install -y; ok "install succeeds" 'grep -q "Entware installed successfully" "$W/out"'
ok "/opt mounted" 'mounted'
ok "boot script written and parses" '[ -x /var/lib/webosbrew/init.d/S99entware ] && sh -n /var/lib/webosbrew/init.d/S99entware'
ok "your .bashrc backed up" 'grep -q MINE /home/root/.bashrc.pre-entware'
ok "saved copy of the installer" '[ -f /mnt/lg/user/opt/bin/webos-entware ]'

echo "== [$SH] 2. reboot: boot script remounts /opt"
reboot_tv
ok "/opt mounted after reboot" 'mounted'
ok "boot log written" 'grep -q "mounted /opt" /tmp/webos-entware-boot.log'
ok "Entware services started" 'grep -q start /tmp/rc.unslung.log'
run status; ok "doctor is happy" 'grep -q "Everything looks right" "$W/out"'
ok "doctor shows boot log" 'grep -q "Boot script log:.*started Entware services" "$W/out"'

echo "== [$SH] 3. your .bashrc edits survive a repair (issue #2)"
echo "alias mine='echo hi'" >> /home/root/.bashrc
run install -y; ok "repair succeeds" 'grep -q "Entware installed successfully" "$W/out"'
ok "edit kept" 'grep -q "alias mine" /home/root/.bashrc'
ok "says it kept it" 'grep -q "Kept your /home/root/.bashrc" "$W/out"'

echo "== [$SH] 4. an edited .profile is saved before it's rewritten"
echo "export PROFILE_EDIT=1" >> /home/root/.profile
run install -y
ok ".profile.bak holds the edit" 'grep -q PROFILE_EDIT /home/root/.profile.bak'
ok ".profile is the current version" '! grep -q PROFILE_EDIT /home/root/.profile && grep -q "issue #2" /home/root/.profile'
cp /home/root/.profile "$W/p1"; run install -y
ok "unchanged files aren't rewritten or backed up again" 'cmp -s /home/root/.profile "$W/p1" && ! grep -q "Saved the old" "$W/out"'

echo "== [$SH] 5. reboot where the boot script doesn't run, then SSH login"
reboot_tv skip-hbc
ok "/opt not mounted yet" '! mounted'
run status
ok "doctor says the boot script didn't run" 'grep -q "boot script didn.t run at this boot" "$W/out"'
ok "doctor fix uses the saved copy" 'grep -q "sh /mnt/lg/user/opt/bin/webos-entware install" "$W/out"'
login
ok "login mounted /opt" 'mounted'
ok "login noted it in the boot log" 'grep -q "at login" /tmp/webos-entware-boot.log'
ok "login started services" 'grep -q start /tmp/rc.unslung.log'
run status; ok "doctor notes the login fallback" 'grep -q "your SSH login mounted /opt instead" "$W/out"'
login; ok "second login doesn't mount again" '[ "$(grep -c " /opt " /proc/mounts)" = 1 ]'

echo "== [$SH] 6. interactive login switches to bash once, no loop (issue #1)"
out=$(echo 'echo "BASH=[$BASH_VERSION]"; exit' | timeout 10 $SH -l -i 2>&1)
ok "ends in bash" 'echo "$out" | grep -q "BASH=\[[0-9]"'

echo "== [$SH] 7. boot script waits for Entware's folder"
mv /mnt/lg/user/opt/bin/opkg /mnt/lg/user/opt/bin/opkg.hold
umount /opt; rm -f /tmp/webos-entware-boot.log /tmp/rc.unslung.log
t0=$(date +%s); sh /var/lib/webosbrew/init.d/S99entware; t1=$(date +%s)
ok "boot script returns at once" '[ $((t1 - t0)) -lt 2 ]'
sleep 3; mv /mnt/lg/user/opt/bin/opkg.hold /mnt/lg/user/opt/bin/opkg
for _ in $(seq 1 25); do grep -qs "started Entware" /tmp/webos-entware-boot.log && break; sleep 0.2; done
ok "mounted once it appeared" 'mounted'

echo "== [$SH] 8. upgrade from a 2.1 install with an edited .bashrc"
printf '%s\n' '# Entware bash settings (webos-entware-installer)' \
    '[ -f "$HOME/.bashrc.pre-entware" ] && . "$HOME/.bashrc.pre-entware"' \
    '[ -f /opt/etc/webos-entware/bashrc ] && . /opt/etc/webos-entware/bashrc' "alias old21='x'" > /home/root/.bashrc
run install -y; ok "2.1 .bashrc edit kept" 'grep -q old21 /home/root/.bashrc'

echo "== [$SH] 9. uninstall"
run uninstall -y
ok "uninstall succeeds" 'grep -q "Entware removed" "$W/out"'
ok "/opt unmounted" '! mounted'
ok "Entware folder removed" '[ ! -e /mnt/lg/user/opt ]'
ok "boot script removed" '[ ! -e /var/lib/webosbrew/init.d/S99entware ]'
ok "edited .bashrc saved" 'grep -q old21 /home/root/.bashrc.entware-saved'
ok "your original .bashrc restored" 'grep -q MINE /home/root/.bashrc'
ok "installer's .profile removed" '[ ! -e /home/root/.profile ]'
login; ok "login after uninstall does nothing" '! mounted'

echo "== [$SH] 10. unedited .bashrc leaves nothing behind on uninstall"
rm -f /home/root/.bashrc* /home/root/.profile*
run install -y; run uninstall -y
ok "no .entware-saved file" '[ ! -e /home/root/.bashrc.entware-saved ]'
ok "no .bashrc left" '[ ! -e /home/root/.bashrc ]'

echo "== [$SH] 11. after a reboot, repair with the hint doctor gives"
rm -f /home/root/.bashrc* /home/root/.profile*
run install -y; reboot_tv skip-hbc
(cd / && $SH /mnt/lg/user/opt/bin/webos-entware install -y) > "$W/out" 2>&1
ok "repair from the saved copy works" 'grep -q "Entware installed successfully" "$W/out" && mounted'

echo "== [$SH] 12. uninstall clears a second mount stacked on /opt"
mount --bind /mnt/lg/user/opt /opt
ok "two mounts on /opt" '[ "$(grep -c " /opt " /proc/mounts)" = 2 ]'
run uninstall -y
ok "both unmounted" '! mounted'
ok "Entware folder removed" '[ ! -e /mnt/lg/user/opt ]'

echo "== [$SH] 13. piped install still saves a copy of the installer"
(cd /tmp && $SH -s -- install -y < "$W/installer.sh") > "$W/out" 2>&1
ok "piped install succeeds" 'grep -q "Entware installed successfully" "$W/out"'
ok "copy saved" 'grep -q webos-entware-installer /mnt/lg/user/opt/bin/webos-entware'
run uninstall -y

echo "== [$SH] 14. no Homebrew Channel: SSH login mounts /opt"
umount /var/lib/webosbrew; mount -t tmpfs tmpfs /var/lib
run install -y
ok "install succeeds without a boot script" 'grep -q "Entware installed successfully" "$W/out" && [ ! -e /var/lib/webosbrew ]'
ok "says logins will mount it" 'grep -q "mounted when you log in over SSH" "$W/out"'
reboot_tv skip-hbc; login
ok "login mounted /opt" 'mounted'
run status; ok "doctor notes it, nothing to fix" 'grep -q "mounted when you log in over SSH, not at boot" "$W/out" && grep -q "Everything looks right" "$W/out"'
run uninstall -y; umount /var/lib

echo "== [$SH] $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
