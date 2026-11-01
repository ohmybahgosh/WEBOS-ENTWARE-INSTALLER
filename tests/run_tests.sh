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
for d in /mnt /tmp /var/lib/webosbrew /var/lib/opkg /var/cache/opkg /home/root; do
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
    update) [ -e /run/entware-fail-update ] && { echo "fake: update failed"; exit 1; }
        echo "Updated list of available packages" ;;
    install) shift
        for p in "$@"; do
            if grep -qx "$p" $DB; then echo "Package $p is up to date"; continue; fi
            echo "$p" >> $DB
            case "$p" in
                entware-opt) mkdir -p /opt/etc/init.d
                    printf '#!/bin/sh\necho "$1" >> /tmp/rc.unslung.log\n' > /opt/etc/init.d/rc.unslung
                    chmod 755 /opt/etc/init.d/rc.unslung ;;
                bash) printf '#!/bin/sh\nexec /bin/bash "$@"\n' > /opt/bin/bash; chmod 755 /opt/bin/bash ;;
                mlocate)
                    printf '#!/bin/sh\ngrep -q "^mlocate:" /etc/group || { echo "updatedb: can not find group mlocate"; exit 1; }\nmkdir -p /opt/var/mlocate; echo built > /opt/var/mlocate/mlocate.db\n' > /opt/bin/updatedb
                    printf '#!/bin/sh\necho locate\n' > /opt/bin/locate
                    chmod 755 /opt/bin/updatedb /opt/bin/locate ;;
                cron) mkdir -p /opt/sbin /opt/etc/init.d
                    printf '#!/bin/sh\n' > /opt/sbin/cron
                    printf '#!/bin/sh\nfor f in "$1"/*; do [ -x "$f" ] && "$f"; done\n' > /opt/bin/run-parts-vixie
                    printf '#!/bin/sh\necho "cron $1" >> /tmp/cron.log\n' > /opt/etc/init.d/S10cron
                    chmod 755 /opt/sbin/cron /opt/bin/run-parts-vixie /opt/etc/init.d/S10cron ;;
            esac
        done ;;
    remove) shift
        for p in "$@"; do
            grep -vx "$p" $DB > $DB.new; mv $DB.new $DB
            [ "$p" = mlocate ] && rm -f /opt/bin/updatedb /opt/bin/locate
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

echo "== [$SH] 15. repair an install left by a 2025 version of the installer"
rm -rf /home/root/.[!.]* /home/root/* /mnt/lg/user/opt /var/lib/webosbrew/init.d/*
# Entware itself, with the old opkg wrapper and the real opkg renamed
mkdir -p /mnt/lg/user/opt/bin /mnt/lg/user/opt/etc /mnt/lg/user/opt/lib/opkg /mnt/lg/user/opt/tmp
cp "$W/fake-opkg" /mnt/lg/user/opt/bin/opkg.real
printf '#!/bin/sh\necho "Use entwrap instead of direct opkg."\nexec /opt/bin/entwrap "$@"\n' > /mnt/lg/user/opt/bin/opkg
chmod 755 /mnt/lg/user/opt/bin/opkg
printf 'src/gz entware http://bin.entware.net/aarch64-k3.10\ndest root /\n' > /mnt/lg/user/opt/etc/opkg.conf
printf 'set linenumbers\n' > /mnt/lg/user/opt/etc/nanorc
# Old shell files, an older .profile.bak, and ~/.nanorc linked into /opt
printf 'if [ -x /opt/bin/bash ]; then\n    exec /opt/bin/bash -l\nfi\n' > /home/root/.profile
echo "my old profile backup" > /home/root/.profile.bak
printf '# Source bashrc if it exists\nif [ -f ~/.bashrc ]; then\n    . ~/.bashrc\nfi\n' > /home/root/.bash_profile
cp "$HERE/legacy-bashrc-2025.txt" /home/root/.bashrc
printf "alias mine2025='echo kept'\nexport MYVAR=1\nalias ls='ls -la'\nexport PATH=\"\$PATH:/home/root/bin\"\n    echo indented-custom\n" >> /home/root/.bashrc
ln -s /opt/etc/nanorc /home/root/.nanorc
echo "old installer" > /home/root/webos-entware-installer.sh
# Leftovers from an early attempt, plus a list and an old boot hook that aren't Entware's
mkdir -p /var/lib/opkg/lists
printf 'Package: entware-opt\nVersion: 1\n' > /var/lib/opkg/lists/entware
printf 'Package: something-else\n' > /var/lib/opkg/lists/jacklul
printf 'Package: entware-opt\n' | gzip > /var/cache/opkg/aaa_Packages.gz
printf 'Package: other\n' | gzip > /var/cache/opkg/bbb_Packages.gz
echo "old log" > /mnt/lg/user/entware_boot.log
mkdir -p /mnt/lg/user/lib/opkg
printf '#!/bin/sh\n# old entware hook\nSRC=/mnt/lg/user/opt\nDST=/opt\nmount --bind $SRC $DST\n' > /var/lib/webosbrew/init.d/S98entware-old
printf '#!/bin/sh\n# mentions entware and /opt but mounts nothing\necho /opt\n' > /var/lib/webosbrew/init.d/S50notes
printf '#!/bin/sh\necho unrelated\n' > /var/lib/webosbrew/init.d/S01fix-eth
chmod 755 /var/lib/webosbrew/init.d/*
run status
ok "doctor lists the leftovers" 'grep -q "Leftovers from an earlier Entware setup" "$W/out" && grep -q "S98entware-old" "$W/out"'
ok "doctor mentions old installer copies" 'grep -q "Old installer copies" "$W/out"'
run install -y; ok "repair succeeds" 'grep -q "Entware installed successfully" "$W/out"'
ok "real opkg put back" '! grep -q entwrap /mnt/lg/user/opt/bin/opkg && [ ! -e /mnt/lg/user/opt/bin/opkg.real ]'
ok "older .profile.bak kept" 'grep -q "my old profile backup" /home/root/.profile.bak'
ok "old .profile saved under a new name" 'grep -q "exec /opt/bin/bash -l" /home/root/.profile.bak.1'
ok "old .bashrc saved" 'grep -q mine2025 /home/root/.bashrc.bak'
ok "your alias and export carried over" 'grep -q "alias mine2025" /home/root/.bashrc && grep -q "export MYVAR=1" /home/root/.bashrc'
ok "old template lines not carried over" '! grep -q -e "LS_OPTIONS=" -e "alias grep" -e "alias ll" -e "PATH=\"/opt/bin" /home/root/.bashrc'
ok "your own overrides carried over" 'grep -q "alias ls=.ls -la." /home/root/.bashrc && grep -q "/home/root/bin" /home/root/.bashrc'
ok "indented line listed, not moved" '! grep -q indented-custom /home/root/.bashrc && grep -q indented-custom "$W/out"'
ok "new .bashrc parses" 'bash -n /home/root/.bashrc'
ok "old .bash_profile backed up" 'grep -q "Source bashrc" /home/root/.bash_profile.pre-entware'
ok "Entware list removed from webOS opkg" '[ ! -e /var/lib/opkg/lists/entware ] && [ ! -e /var/cache/opkg/aaa_Packages.gz ]'
ok "other lists kept" '[ -e /var/lib/opkg/lists/jacklul ] && [ -e /var/cache/opkg/bbb_Packages.gz ]'
ok "old boot log and empty lib folder removed" '[ ! -e /mnt/lg/user/entware_boot.log ] && [ ! -e /mnt/lg/user/lib/opkg ]'
ok "old boot hook turned off, unrelated ones kept" '[ -e /var/lib/webosbrew/init.d/S98entware-old.entware-old ] && [ ! -e /var/lib/webosbrew/init.d/S98entware-old ] && [ -x /var/lib/webosbrew/init.d/S01fix-eth ] && [ -x /var/lib/webosbrew/init.d/S50notes ]'
ok "nanorc kept and link works" 'grep -q linenumbers /home/root/.nanorc'
ok "old installer copy left alone" '[ -e /home/root/webos-entware-installer.sh ]'
out=$(echo 'alias ll; alias mine2025; echo "V=$MYVAR"; exit' | timeout 10 $SH -l -i 2>&1)
ok "login shell has old and carried aliases" 'echo "$out" | grep -q "alias ll=" && echo "$out" | grep -q "alias mine2025=" && echo "$out" | grep -q "V=1"'
run status; ok "doctor is happy after repair" 'grep -q "Everything looks right" "$W/out" && ! grep -q "Leftovers" "$W/out"'
run install -y; ok "second repair changes nothing" '! grep -q -e "Saved the old" -e "Backed up" -e "Removed" "$W/out" && [ ! -e /home/root/.profile.bak.2 ]'
run uninstall -y
ok "uninstall removes the ~/.nanorc link" '[ ! -L /home/root/.nanorc ]'
ok "uninstall keeps carried settings" 'grep -q mine2025 /home/root/.bashrc.entware-saved'
ok "uninstall restores the old .bash_profile" 'grep -q "Source bashrc" /home/root/.bash_profile'

echo "== [$SH] 16. a fresh install that fails puts old shell files back exactly"
rm -rf /home/root/.[!.]* /home/root/* /mnt/lg/user/opt
printf 'if [ -x /opt/bin/bash ]; then\n    exec /opt/bin/bash -l\nfi\nexport MYVAR=1\n' > /home/root/.profile
printf '# Entware SSH Environment for WebOS\nalias x=y\n' > /home/root/.bashrc
cp /home/root/.profile "$W/p16"; cp /home/root/.bashrc "$W/b16"
touch /run/entware-fail-update
run install -y; rm -f /run/entware-fail-update
ok "install failed and rolled back" 'grep -q "being undone" "$W/out" && [ ! -e /mnt/lg/user/opt ] && ! mounted'
ok "old .profile and .bashrc put back as they were" 'cmp -s /home/root/.profile "$W/p16" && cmp -s /home/root/.bashrc "$W/b16"'
ok "no .bash_profile, backups or snapshots left behind" '[ -z "$(ls -A /home/root | grep -v -x -e .profile -e .bashrc)" ]'

echo "== [$SH] 17. your own .profile that starts bash doesn't loop"
rm -rf /home/root/.[!.]* /home/root/*
printf 'exec /opt/bin/bash --login\n' > /home/root/.profile
run install -y; ok "install succeeds" 'grep -q "Entware installed successfully" "$W/out"'
ok "it was kept as .profile.pre-entware" 'grep -q -- "--login" /home/root/.profile.pre-entware'
out=$(echo 'echo "BASH=[$BASH_VERSION]"; exit' | timeout 10 $SH -l -i 2>&1)
ok "login ends in bash without looping" 'echo "$out" | grep -q "BASH=\[[0-9]"'
run uninstall -y
ok "your .profile restored" 'grep -q -- "--login" /home/root/.profile'

echo "== [$SH] 18. uninstall won't delete a drive mounted inside Entware's folder"
rm -rf /home/root/.[!.]* /home/root/*
run install -y
mkdir -p /mnt/lg/user/opt/share/usb && mount -t tmpfs tmpfs /mnt/lg/user/opt/share/usb && echo precious > /mnt/lg/user/opt/share/usb/file
run uninstall -y
ok "folder kept and the mounted drive untouched" 'grep -q "Something is still mounted" "$W/out" && grep -q precious /mnt/lg/user/opt/share/usb/file'
umount /mnt/lg/user/opt/share/usb; run uninstall -y
ok "uninstall finishes once it's unmounted" '[ ! -e /mnt/lg/user/opt ]'

echo "== [$SH] 19. ent install mlocate sets up locate for webOS"
rm -rf /home/root/.[!.]* /home/root/*
run install -y
md5sum /etc/group > "$W/group.md5"
(cd /tmp && $SH /opt/bin/entwrap install mlocate) > "$W/out" 2>&1
ok "setup ran and said it's ready" 'grep -q "locate is ready" "$W/out"'
ok "cron installed for the refresh" 'grep -qx cron /opt/lib/opkg/fake-installed'
ok "settings written with the excludes" 'grep -q "^PRUNEPATHS.*/var/palm/jail.*/mnt/lg/cmn_data" /opt/etc/updatedb.conf'
ok "database built through the wrapper" 'grep -q built /opt/var/mlocate/mlocate.db'
ok "plain updatedb fails, as on a real TV" '! /opt/bin/updatedb >/dev/null 2>&1'
ok "system group file untouched, nothing left mounted" 'md5sum -c --status "$W/group.md5" && ! grep -q " /etc/group " /proc/mounts'
ok "hourly job written, run-parts linked, cron started" '[ -x /opt/etc/cron.hourly/updatedb ] && [ -L /opt/bin/run-parts ] && grep -q "cron start" /tmp/cron.log'
rm -f /opt/var/mlocate/mlocate.db; /opt/bin/run-parts /opt/etc/cron.hourly
ok "the hourly job rebuilds the database" 'grep -q built /opt/var/mlocate/mlocate.db'
out=$(echo 'alias updatedb; exit' | timeout 10 $SH -l -i 2>&1)
ok "updatedb is an alias for the wrapper at login" 'echo "$out" | grep -q "updatedb-webos"'
run status
ok "doctor shows locate ready" 'grep -q "locate (mlocate):.*ready, database from" "$W/out" && grep -q "Everything looks right" "$W/out"'

echo "== [$SH] 20. repair keeps locate working, and your own updatedb.conf"
rm -f /opt/bin/updatedb-webos
printf 'PRUNEPATHS = "/mine"\n' > /opt/etc/updatedb.conf
run status
ok "doctor flags the missing wrapper" 'grep -q "mlocate is installed but not set up" "$W/out"'
run install -y
ok "repair puts the wrapper back" '[ -x /opt/bin/updatedb-webos ] && grep -q "locate is ready" "$W/out"'
ok "your own updatedb.conf kept" 'grep -q mine /opt/etc/updatedb.conf && grep -q "Kept your own /opt/etc/updatedb.conf" "$W/out"'
rm -f /opt/etc/updatedb.conf; run locate
ok "webos-entware locate writes the settings again" 'grep -q webos-entware-installer /opt/etc/updatedb.conf'
run install -y
ok "repair rewrites its own updatedb.conf without a message" '! grep -q "Kept your own" "$W/out"'

echo "== [$SH] 21. removing mlocate leaves nothing that errors"
(cd /tmp && $SH /opt/bin/entwrap remove mlocate) > /dev/null 2>&1
ok "wrapper exits quietly" '/opt/bin/updatedb-webos < /dev/null > "$W/w" 2>&1 && [ ! -s "$W/w" ]'
run status
ok "doctor says not installed, nothing to fix" 'grep -q "locate (mlocate):   not installed" "$W/out" && grep -q "Everything looks right" "$W/out"'
out=$(echo 'alias updatedb || echo NOALIAS; exit' | timeout 10 $SH -l -i 2>&1)
ok "no updatedb alias without mlocate" 'echo "$out" | grep -q NOALIAS'
run uninstall -y

echo "== [$SH] 22. install --with-locate"
rm -rf /home/root/.[!.]* /home/root/*
run install -y --with-locate
ok "install sets up locate too" 'grep -q "Entware installed successfully" "$W/out" && grep -q "locate is ready" "$W/out" && [ -x /opt/bin/updatedb-webos ]'
run uninstall -y
ok "uninstall removes it with Entware" '[ ! -e /mnt/lg/user/opt ]'

echo "== [$SH] $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
