#!/bin/bash
# shellcheck disable=SC2034  # variables are read inside the checks that ok() evals
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
            mkdir -p /opt/lib/opkg/info; touch /opt/lib/opkg/info/$p.control
            case "$p" in
                entware-opt) mkdir -p /opt/etc/init.d
                    printf '#!/bin/sh\necho "$1" >> /tmp/rc.unslung.log\n' > /opt/etc/init.d/rc.unslung
                    chmod 755 /opt/etc/init.d/rc.unslung ;;
                bash) printf '#!/bin/sh\nexec /bin/bash "$@"\n' > /opt/bin/bash; chmod 755 /opt/bin/bash
                    echo /opt/bin/bash > /opt/lib/opkg/info/bash.list ;;
                nano-full) printf '#!/bin/sh\n' > /opt/bin/nano; chmod 755 /opt/bin/nano
                    echo /opt/bin/nano > /opt/lib/opkg/info/nano-full.list
                    [ -f /opt/etc/nanorc ] || printf '## stock nanorc\n# set linenumbers\n# include "/opt/share/nano/*.nanorc"\n' > /opt/etc/nanorc ;;
                wget-ssl) touch /opt/lib/opkg/info/libopenssl.control ;;
                ca-bundle) mkdir -p /opt/etc/ssl/certs; echo CERTS > /opt/etc/ssl/certs/ca-certificates.crt ;;
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
            case "$p" in -*) continue ;; esac
            if [ "$p" = git ] && grep -qx git-http $DB; then echo "Package git is depended upon by git-http"; FAILED=1; continue; fi
            echo "$p" >> /tmp/opkg-removed.log
            grep -vx "$p" $DB > $DB.new; mv $DB.new $DB
            rm -f /opt/lib/opkg/info/$p.control
            [ "$p" = mlocate ] && rm -f /opt/bin/updatedb /opt/bin/locate
            [ "$p" = ca-bundle ] && rm -f /opt/etc/ssl/certs/ca-certificates.crt
        done
        exit ${FAILED:-0} ;;
    list-installed) sed 's/$/ - 1/' $DB ;;
    search) for l in /opt/lib/opkg/info/*.list; do
            [ -f "$l" ] && grep -qx "$2" "$l" && { n=${l##*/}; echo "${n%.list} - 1"; }
        done ;;
    list) echo "bash - 5.3 - The GNU Bourne Again SHell"; echo "nano-full - 8.7 - An enhanced clone of Pico" ;;
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
cat > "$W/bin/luna-send" << 'F'
#!/bin/sh
echo "$*" >> /tmp/luna.log
case "$*" in
    *createToast*) echo '{"returnValue": true}' ;;
    *appInstallService/dev/install*)
        ipk=$(echo "$*" | sed -n 's/.*"ipkUrl":"\([^"]*\)".*/\1/p'); d=$(mktemp -d)
        (cd "$d" && ar x "$ipk" control.tar.gz && tar xzf control.tar.gz)
        v=$(sed -n 's/^Version: //p' "$d"/control "$d"/./control 2>/dev/null | head -n 1); rm -rf "$d"
        sed -i "s/\"version\": *\"[^\"]*\"/\"version\": \"$v\"/" /media/developer/apps/usr/palm/applications/org.ohmybahgosh.entware/appinfo.json
        echo '{"subscribed": true, "returnValue": true}' ;;
    *applicationManager/launch*)
        case "$*" in
            *x.not.real*) printf '{\n    "errorCode": -101,\n    "returnValue": false,\n    "errorText": "not exist"\n}\n' ;;
            *) echo '{"returnValue": true}' ;;
        esac ;;
    *applicationManager/closeByAppId*)
        case "$*" in
            *netflix*) echo '{"returnValue": true}' ;;
            *) printf '{\n    "errorCode": 1,\n    "returnValue": false,\n    "errorText": "no valid life handler"\n}\n' ;;
        esac ;;
    *applicationManager/close*) printf '{\n    "errorCode": 1,\n    "returnValue": false,\n    "errorText": "no app matched by pid"\n}\n' ;;
    *listApps*) echo '{"returnValue":true,"apps":[{"id":"netflix","title":"Netflix","type":"native"},{"id":"app.tivibro.tv","title":"TiviBro","type":"web"},{"id":"com.hidden.svc","title":"Hidden","type":"web","visible":false}]}' ;;
    *applicationManager/running*) printf '{\n    "returnValue": true,\n    "running": [\n        {\n            "id": "netflix"\n        }\n    ]\n}\n' ;;
    *executeOneShot*) p=$(echo "$*" | sed -n 's/.*"path":"\([^"]*\)".*/\1/p'); echo PNG > "$p"; echo '{"returnValue": true}' ;;
esac
F
cat > "$W/bin/curl" << F
#!/bin/sh
# Serves files from a fake GitHub release in $W/rel
while [ \$# -gt 1 ]; do [ "\$1" = -o ] && OUT=\$2; shift; done
f=\${1##*/}
[ -f "$W/rel/\$f" ] || exit 22
cp "$W/rel/\$f" "\$OUT"
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
# Put the Homebrew Channel folder back for the scenarios after this one
mkdir -p /var/lib/webosbrew && mount -t tmpfs tmpfs /var/lib/webosbrew && mkdir -p /var/lib/webosbrew/init.d

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

echo "== [$SH] 23. nano gets syntax colors on install"
rm -rf /home/root/.[!.]* /home/root/*
run install -y
ok "nanorc written with the syntax includes" 'grep -q "^include \"/opt/share/nano/\*.nanorc\"" /opt/etc/nanorc && grep -q "^set linenumbers" /opt/etc/nanorc && grep -q webos-entware-installer /opt/etc/nanorc'
ok "nano history folder made" '[ -d /home/root/.local/share/nano ]'
ok "GNU ls installed with the shell setup" 'grep -qx coreutils-ls /opt/lib/opkg/fake-installed'
run status
ok "doctor shows nano colors on, certificates not needed" 'grep -q "nano colors:.*on" "$W/out" && grep -q "HTTPS certificates: not needed yet" "$W/out" && grep -q "Everything looks right" "$W/out"'

echo "== [$SH] 24. your own nanorc is kept, a stock one is replaced"
printf 'set mouse\n' > /opt/etc/nanorc
run install -y
ok "your nanorc kept" '[ "$(cat /opt/etc/nanorc)" = "set mouse" ] && grep -q "Kept your own /opt/etc/nanorc" "$W/out"'
run status
ok "doctor says colors are off in your own file, not an issue" 'grep -q "nano colors:.*off (your own" "$W/out" && grep -q "Everything looks right" "$W/out"'
printf '# only comments\n\n#set linenumbers\n' > /opt/etc/nanorc
run status
ok "doctor flags a stock nanorc" 'grep -q "nano has no settings" "$W/out"'
(cd /tmp && $SH /opt/bin/entwrap install nano-full) > "$W/out" 2>&1
ok "ent install nano-full sets it up" 'grep -q "nano set up with syntax colors" "$W/out" && grep -q webos-entware-installer /opt/etc/nanorc'

echo "== [$SH] 25. HTTPS certificates come with OpenSSL programs"
(cd /tmp && $SH /opt/bin/entwrap install htop) > "$W/out" 2>&1
ok "a package without OpenSSL doesn't pull in ca-bundle" '! grep -qx ca-bundle /opt/lib/opkg/fake-installed'
(cd /tmp && $SH /opt/bin/entwrap install wget-ssl) > "$W/out" 2>&1
ok "ent install wget-ssl adds ca-bundle" 'grep -qx ca-bundle /opt/lib/opkg/fake-installed && [ -s /opt/etc/ssl/certs/ca-certificates.crt ] && grep -q "HTTPS certificates installed" "$W/out"'
run status
ok "doctor shows certificates" 'grep -q "HTTPS certificates: .*yes" "$W/out" && grep -q "Everything looks right" "$W/out"'
(cd /tmp && $SH /opt/bin/entwrap remove ca-bundle) > /dev/null 2>&1
run status
ok "doctor flags missing certificates" 'grep -q "HTTPS certificates are missing" "$W/out"'
run install -y
ok "repair puts them back" '[ -s /opt/etc/ssl/certs/ca-certificates.crt ] && grep -q "HTTPS certificates installed" "$W/out"'
run uninstall -y

echo "== [$SH] 26. webOS helpers"
rm -rf /home/root/.[!.]* /home/root/*
run install -y
ok "helper and its commands installed" '[ -x /opt/bin/webos-tv ] && for c in toast launch close apps applog tvshot; do [ "$(readlink /opt/bin/$c)" = webos-tv ] || exit 1; done'
/opt/bin/toast 'Build "1.2" done' > "$W/out" 2>&1
ok "toast sends an escaped message as webosbrew" 'grep -q -- "-a webosbrew luna://com.webos.notification/createToast" /tmp/luna.log && grep -qF "\"message\":\"Build \\\"1.2\\\" done\"" /tmp/luna.log'
/opt/bin/launch netflix > "$W/out" 2>&1
ok "launch starts an app" 'grep -q "Started netflix" "$W/out" && grep -q "applicationManager/launch {\"id\":\"netflix\"}" /tmp/luna.log'
/opt/bin/launch app.tivibro.tv '{"channel":5}' > /dev/null 2>&1
ok "launch passes parameters" 'grep -qF "{\"id\":\"app.tivibro.tv\",\"params\":{\"channel\":5}}" /tmp/luna.log'
! /opt/bin/launch x.not.real > "$W/out" 2>&1
ok "launch explains an unknown app" 'grep -q "No app has the ID x.not.real" "$W/out"'
! /opt/bin/launch 'bad;id' > "$W/out" 2>&1
ok "launch refuses an invalid ID" 'grep -q "isn.t a valid app ID" "$W/out"'
! /opt/bin/close app.tivibro.tv > "$W/out" 2>&1
/opt/bin/close netflix > "$W/c" 2>&1
ok "close uses closeByAppId, which works from a root shell" 'grep -q "Closed netflix" "$W/c" && grep -q "closeByAppId {\"id\":\"netflix\"}" /tmp/luna.log'
ok "close explains an app that isn't running" 'grep -q "app.tivibro.tv isn.t running" "$W/out"'
/opt/bin/apps > "$W/out" 2>&1
ok "apps lists visible apps and marks running ones (no node here, so the fallback parser)" 'grep -q "^\* netflix" "$W/out" && grep -q "app.tivibro.tv.*TiviBro" "$W/out" && ! grep -q com.hidden.svc "$W/out"'
ok "apps -a includes hidden apps, and filters" '/opt/bin/apps -a | grep -q com.hidden.svc && [ "$(/opt/bin/apps tivi | grep -c tivibro)" = 1 ]'
ok "apps --ids lists IDs for tab completion" '[ "$(/opt/bin/webos-tv apps --ids | wc -l)" = 3 ]'
printf 'line one netflix\nline two app.tivibro.tv started\n' > "$W/messages"
WEBOS_TV_LOG="$W/messages" timeout 2 /opt/bin/applog tivibro > "$W/out" 2>&1
ok "applog follows the log, filtered" 'grep -q "app.tivibro.tv started" "$W/out" && ! grep -q "line one" "$W/out"'
sleep 1
ok "applog stopped from outside leaves no tail or grep running" '! pgrep -f "tail -n 200 -F $W/messages" >/dev/null'
/opt/bin/tvshot /tmp/shot.png > "$W/out" 2>&1
ok "tvshot saves a screenshot and says how to copy it" '[ -s /tmp/shot.png ] && grep -q "Saved /tmp/shot.png" "$W/out" && grep -q "scp root@" "$W/out"'
ok "webos-tv help lists the commands" '/opt/bin/webos-tv help | grep -q "tvshot"'
run status
ok "doctor shows the helpers and free space" 'grep -q "webOS helpers:.*yes" "$W/out" && grep -q "Free space:" "$W/out" && grep -q "Everything looks right" "$W/out"'

echo "== [$SH] 27. a package's command isn't replaced by a helper"
rm -f /opt/bin/toast; printf '#!/bin/sh\necho package toast\n' > /opt/bin/toast; chmod 755 /opt/bin/toast
run install -y
ok "the package's toast is kept" 'grep -q "package toast" /opt/bin/toast && grep -q "Skipped the toast command" "$W/out"'

echo "== [$SH] 28. ent owns and ent du"
out=$(cd /tmp && PATH="/opt/bin:$PATH" $SH /opt/bin/entwrap owns nano /opt/bin/nano /bin/sh no-such-cmd 2>&1)
ok "ent owns finds the package for a command and a path" 'echo "$out" | grep -q "^nano: nano-full" && echo "$out" | grep -q "^/opt/bin/nano: nano-full"'
ok "ent owns says when a file is part of webOS or missing" 'echo "$out" | grep -q "^/bin/sh: part of webOS" && echo "$out" | grep -q "no-such-cmd: not found"'
out=$(cd /tmp && $SH /opt/bin/entwrap du 5 2>&1)
touch /opt/lib/opkg/info/meta-only.list
out=$(cd /tmp && $SH /opt/bin/entwrap du 50 2>&1)
ok "ent du counts a package with no files as empty, not the current folder" 'echo "$out" | grep -q "0.0 MB  meta-only"'
ok "ent du lists packages and free space" 'echo "$out" | grep -q "MB  nano-full" && echo "$out" | grep -q "Free where Entware lives"'
run uninstall -y

echo "== [$SH] 29. status --json, background tasks and the lock (for the TV app)"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run status --json
ok "status --json before install is valid JSON and says not installed" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"installed\"] is False and d[\"version\"]" "$W/out"'
run install -y
run status --json
ok "status --json after install has the checks and no issues" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"installed\"] and d[\"mounted\"] and d[\"opkg\"] and d[\"bootScript\"] and d[\"tvHelpers\"], d
assert d[\"issues\"] == [] and d[\"nano\"] == \"on\" and d[\"job\"] == \"none\", d
" "$W/out"'
(cd /tmp && $SH /tmp/webos-entware-installer.sh job upgrade) > "$W/out" 2>&1
ok "job starts a task in the background" 'grep -q "Started: upgrade" "$W/out"'
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
(cd /tmp && $SH /tmp/webos-entware-installer.sh job-status --json) > "$W/out" 2>&1
ok "job-status --json reports it finished, with its log" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"state\"] == \"done\" and d[\"name\"] == \"upgrade\" and d[\"exit\"] == 0, d
assert any(\"up to date\" in l or \"Packages upgraded\" in l for l in d[\"log\"]), d
" "$W/out"'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job rm-everything) > "$W/out" 2>&1
ok "job refuses unknown tasks" 'grep -q "Unknown task" "$W/out" && [ "$(cat /tmp/webos-entware-job/name)" = upgrade ]'
sleep 30 & HOLDER=$!
mkdir -p /tmp/webos-entware.lock; echo $HOLDER > /tmp/webos-entware.lock/pid
! run install -y
ok "install waits its turn while another task holds the lock" 'grep -q "Another install, repair or uninstall is running (process $HOLDER)" "$W/out"'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job install) > "$W/out" 2>&1
ok "the app can't start a task while SSH holds the lock" 'grep -q "running from SSH" "$W/out"'
kill $HOLDER; wait $HOLDER 2>/dev/null
run install -y
ok "a lock left by a stopped task is cleared" 'grep -q "Entware installed successfully" "$W/out" && [ ! -d /tmp/webos-entware.lock ]'
rm -rf /tmp/webos-entware-job
(cd /tmp && $SH /tmp/webos-entware-installer.sh job upgrade) > "$W/j1" 2>&1 &
(cd /tmp && $SH /tmp/webos-entware-installer.sh job upgrade) > "$W/j2" 2>&1 &
wait
ok "two tasks started at the same moment: only one runs" '[ "$(cat "$W/j1" "$W/j2" | grep -c "Started:")" = 1 ]'
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
mkdir -p /tmp/webos-entware.lock
! run install -y
ok "a lock taken a moment ago, with no pid yet, is respected" 'grep -q "just starting" "$W/out"'
touch -d "2 minutes ago" /tmp/webos-entware.lock
run install -y
ok "a lock with no pid from minutes ago is cleared" 'grep -q "Entware installed successfully" "$W/out"'
run uninstall -y
ok "uninstall restarting itself from /tmp keeps and then releases the lock" 'grep -q "Entware removed" "$W/out" && [ ! -d /tmp/webos-entware.lock ]'

echo "== [$SH] 30. add-ons"
out=$(cd /tmp && $SH /tmp/webos-entware-installer.sh install -y >/dev/null 2>&1; PATH="/opt/bin:$PATH" $SH /opt/bin/entwrap search bash 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
ok "ent search shows name, version and description once each" '[ "$out" = "bash - 5.3 - The GNU Bourne Again SHell" ]'
out=$(cd /tmp && PATH="/opt/bin:$PATH" COLUMNS=44 ENT_FORMAT=pretty $SH /opt/bin/entwrap search a 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
ok "ent search in a terminal: a count, then name and version, marked installed" 'echo "$out" | head -n 1 | grep -q "^2 packages match \"a\"" && echo "$out" | grep -q "^bash  5.3  \[installed\]$" && echo "$out" | grep -q "^    The GNU Bourne Again SHell$"'
ok "ent search in a terminal fits the screen" '[ -z "$(echo "$out" | grep -v "^More about" | awk "length > 44")" ]'
out=$(cd /tmp && PATH="/opt/bin:$PATH" ENT_FORMAT=pretty $SH /opt/bin/entwrap search n 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
ok "ent search lists description-only matches after name matches" 'echo "$out" | grep -q "^2 packages match" && [ "$(echo "$out" | grep -n "^nano-full\|^Also\|^bash" | cut -d: -f2 | cut -c1-4 | tr "\n" " ")" = "nano Also bash " ] && echo "$out" | grep -q "^Also mentioned in the description" && echo "$out" | grep -q "^nano-full  8.7"'
! (cd /tmp && $SH /opt/bin/entwrap search) > "$W/out" 2>&1
ok "ent search with nothing to search for says so" 'grep -q "Name something to search for" "$W/out"'

rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run install -y
run addons --json
ok "addons --json lists the catalog with each one's state" 'python3 -c "
import json,sys; d={a[\"id\"]: a for a in json.load(open(sys.argv[1]))}
assert d[\"nano\"][\"state\"] == \"installed\" and d[\"nano\"][\"removable\"] is False, d[\"nano\"]
assert d[\"htop\"][\"state\"] == \"notInstalled\" and d[\"git\"][\"packages\"] == \"git git-http\", d
assert d[\"locate\"][\"state\"] == \"notInstalled\" and len(d) >= 10, d
" "$W/out"'
run add htop -y
ok "add installs an add-on" 'grep -q "htop is ready" "$W/out" && [ -f /opt/lib/opkg/info/htop.control ]'
run add git -y
ok "add git brings HTTPS certificates with it" '[ -f /opt/lib/opkg/info/git-http.control ] && [ -s /opt/etc/ssl/certs/ca-certificates.crt ]'
run add locate -y
ok "add locate sets locate up" 'grep -q "locate is ready" "$W/out" && [ -x /opt/bin/updatedb-webos ] && [ -f /opt/etc/updatedb.conf ]'
run addons
ok "addons lists states for people too" 'grep -q "htop.*installed" "$W/out" && grep -q "tmux.*not installed" "$W/out"'
! run add "htop;reboot" -y
ok "add refuses a name that isn't in the catalog" 'grep -q "Unknown add-on" "$W/out"'
! run add vim -y
ok "add refuses packages outside the catalog" 'grep -q "Unknown add-on: vim" "$W/out"'
! run remove nano -y
ok "remove keeps the base setup" 'grep -q "part of the base setup" "$W/out" && [ -x /opt/bin/nano ]'
rm -f /tmp/opkg-removed.log
run remove locate -y
ok "remove locate takes its settings and cron job with it" 'grep -q "Removed locate" "$W/out" && [ ! -e /opt/bin/updatedb-webos ] && [ ! -e /opt/etc/cron.hourly/updatedb ] && [ ! -e /opt/etc/updatedb.conf ] && grep -qx mlocate /tmp/opkg-removed.log'
printf '# my own\n' > /opt/etc/updatedb.conf
run add locate -y; run remove locate -y
ok "remove locate keeps an updatedb.conf you wrote" 'grep -q "my own" /opt/etc/updatedb.conf'
rm -f /opt/etc/updatedb.conf
run remove git -y
ok "remove git takes git-http off first, and leaves the certificates" 'grep -q "Removed git" "$W/out" && [ ! -f /opt/lib/opkg/info/git.control ] && [ ! -f /opt/lib/opkg/info/git-http.control ] && [ -s /opt/etc/ssl/certs/ca-certificates.crt ]'
! run add htop clean -y
ok "add with another action after it is refused" '[ -f /opt/lib/opkg/info/htop.control ] && [ -x /opt/bin/opkg ]'
(cd /tmp && $SH /tmp/webos-entware-installer.sh job add tmux) > "$W/out" 2>&1
ok "job add starts in the background" 'grep -q "Started: add tmux" "$W/out"'
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
(cd /tmp && $SH /tmp/webos-entware-installer.sh job-status --json) > "$W/out" 2>&1
ok "job add finishes and reports its name" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"state\"] == \"done\" and d[\"name\"] == \"add tmux\" and d[\"exit\"] == 0, d
assert any(\"tmux is ready\" in l for l in d[\"log\"]), d
" "$W/out" && [ -f /opt/lib/opkg/info/tmux.control ]'
(cd /tmp && $SH /tmp/webos-entware-installer.sh job remove tmux) > "$W/out" 2>&1
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
ok "job remove removes without asking" '[ ! -f /opt/lib/opkg/info/tmux.control ] && grep -q "Removed tmux" /tmp/webos-entware-job/log'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job add "x y") > "$W/out" 2>&1
ok "job add refuses names outside the catalog" 'grep -q "Unknown add-on" "$W/out"'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job upgrade htop) > "$W/out" 2>&1
ok "job refuses a name on tasks that take none" 'grep -q "takes no name" "$W/out"'
run uninstall -y
! run add htop -y
ok "add says what to do when Entware isn't installed" 'grep -q "isn.t mounted on /opt" "$W/out"'

echo "== [$SH] 31. Entware on app storage, moving it, and only using a folder that's root's alone"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
mkdir -p /mnt/lg/appstore && mount -t tmpfs tmpfs /mnt/lg/appstore
APP=/mnt/lg/appstore/entware
run install --location=appstore -y
ok "install --location=appstore puts Entware on app storage" 'grep -q "Entware installed successfully" "$W/out" && [ /opt -ef $APP ] && [ ! -e /mnt/lg/user/opt/bin/opkg ]'
ok "the boot script names the folder" 'grep -q "^ *SRC=$APP$" /var/lib/webosbrew/init.d/S99entware'
ok "install.info records it" 'grep -q "^location=appstore $APP$" /opt/etc/webos-entware/install.info'
run status; sed -i 's/\x1b\[[0-9;]*m//g' "$W/out"
ok "doctor shows where Entware is, that it's root's alone, and both free spaces" 'grep -q "Location: *app storage ($APP)" "$W/out" && grep -q "Root.s alone: *yes" "$W/out" && grep -q "MB user data, [0-9]* MB app storage" "$W/out" && grep -q "Everything looks right" "$W/out"'
run status --json
ok "status --json has the location, safety and both free spaces" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"location\"] == \"appstore\" and d[\"srcSafe\"] is True, d
assert isinstance(d[\"appFreeMB\"], int) and isinstance(d[\"userFreeMB\"], int) and d[\"freeMB\"] == d[\"appFreeMB\"], d
" "$W/out"'
! run install --location=user -y
ok "install --location=user on an app storage install says to move it" 'grep -q "already installed on app storage" "$W/out" && grep -q "move user" "$W/out"'
run install -y
ok "a repair keeps it on app storage" 'grep -q "Entware installed successfully" "$W/out" && [ /opt -ef $APP ]'
reboot_tv
ok "after a reboot the boot script mounts it from app storage" '[ /opt -ef $APP ] && grep -q "started Entware services" /tmp/webos-entware-boot.log'
reboot_tv skip-hbc; login
ok "the SSH login fallback mounts it from app storage" '[ /opt -ef $APP ] && grep -q "at login" /tmp/webos-entware-boot.log'

PKGS=$(cat /opt/lib/opkg/fake-installed)
run move user -y
ok "move user moves it to user data" 'grep -q "now runs from user data" "$W/out" && [ /opt -ef /mnt/lg/user/opt ] && [ ! -e $APP ]'
ok "the packages came along" '[ "$(cat /opt/lib/opkg/fake-installed)" = "$PKGS" ] && /opt/bin/opkg print-architecture | grep -q aarch64'
ok "the boot script and install.info follow" 'grep -q "^ *SRC=/mnt/lg/user/opt$" /var/lib/webosbrew/init.d/S99entware && grep -q "^location=user " /opt/etc/webos-entware/install.info'
run move user -y
ok "moving to where it already is changes nothing" 'grep -q "already on user data" "$W/out" && [ /opt -ef /mnt/lg/user/opt ]'
mkdir -p $APP/leftover
! run move appstore -y
ok "move won't overwrite a folder that's already there" 'grep -q "already exists" "$W/out" && [ /opt -ef /mnt/lg/user/opt ] && [ -d $APP/leftover ]'
rm -rf $APP
umount /mnt/lg/appstore
! run move appstore -y
ok "move says when app storage isn't mounted, and changes nothing" 'grep -q "isn.t mounted" "$W/out" && [ /opt -ef /mnt/lg/user/opt ]'
mount -t tmpfs tmpfs /mnt/lg/appstore
mount -o remount,size=1m /mnt/lg/appstore
dd if=/dev/zero of=/opt/big bs=1024 count=2048 2>/dev/null
! run move appstore -y
ok "move checks for space first, and changes nothing" 'grep -q "Not enough space on app storage" "$W/out" && [ /opt -ef /mnt/lg/user/opt ] && [ ! -e $APP ]'
rm -f /opt/big; mount -o remount,size=512m /mnt/lg/appstore
(cd /tmp && $SH /tmp/webos-entware-installer.sh job move appstore) > "$W/out" 2>&1
for _ in $(seq 1 100); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
ok "job move appstore runs in the background" '[ "$(cat /tmp/webos-entware-job/exit)" = 0 ] && [ /opt -ef $APP ] && [ ! -e /mnt/lg/user/opt ]'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job move /etc) > "$W/out" 2>&1
ok "job move refuses any other place" 'grep -q "Move it where" "$W/out"'

chmod 777 $APP
run status; sed -i 's/\x1b\[[0-9;]*m//g' "$W/out"
ok "doctor flags a folder others can write to" 'grep -q "Root.s alone: *no" "$W/out" && grep -q "isn.t root.s alone" "$W/out"'
reboot_tv
ok "the boot script refuses to mount a folder others can write to" '! mounted && grep -q "refused to mount" /tmp/webos-entware-boot.log'
login
ok "so does the SSH login fallback" '! mounted'
run install -y
ok "a repair makes it root's alone again" 'grep -q "It.s root.s alone now" "$W/out" && grep -q "Entware installed successfully" "$W/out" && [ "$(stat -c %a $APP)" = 755 ]'
chown 65534 $APP
umount /opt
! run install -y
ok "install refuses a folder root doesn't own" 'grep -q "isn.t a folder owned by root" "$W/out" && ! mounted'
chown 0 $APP
run install -y
ok "the login profile records where Entware lives" 'grep -q "^ENTWARE_SRC=$APP$" /home/root/.profile'
chmod 777 /opt/etc
run status; sed -i 's/\x1b\[[0-9;]*m//g' "$W/out"
ok "doctor flags a folder inside Entware that others can write to" 'grep -q "Root.s alone: *no" "$W/out" && grep -q "chmod go-w /opt/etc" "$W/out"'
reboot_tv
ok "the boot script checks inside Entware after mounting, and unmounts it" '! mounted && grep -q "refused to mount $APP: /opt/etc isn.t root.s alone" /tmp/webos-entware-boot.log'
mount --bind $APP /opt
out=$($SH -l -c 'echo "PATH=$PATH"' < /dev/null 2>&1)
ok "a login doesn't use an /opt that isn't root's alone (no PATH, no bash)" 'echo "$out" | grep -q "this login doesn.t use it" && ! echo "$out" | grep -q "^PATH=.*/opt/bin"'
chmod 755 /opt/etc
out=$($SH -l -c 'echo "PATH=$PATH"' < /dev/null 2>&1)
ok "and does once it's root's alone again" 'echo "$out" | grep -q "^PATH=/opt/bin"' 
(exec 9>> /opt/etc/busy-file; sleep 15) & BUSY=$!
sleep 0.3
! run move user -y
ok "move waits while a program has files open in Entware, and changes nothing" 'grep -q "still using Entware" "$W/out" && [ /opt -ef $APP ] && [ ! -e /mnt/lg/user/opt ]'
kill $BUSY 2>/dev/null; wait $BUSY 2>/dev/null; rm -f /opt/etc/busy-file
run move user -y
ok "then the move goes through" 'grep -q "now runs from user data" "$W/out" && [ /opt -ef /mnt/lg/user/opt ] && [ ! -e $APP ] && grep -q "^ENTWARE_SRC=/mnt/lg/user/opt$" /home/root/.profile'
run move appstore -y
ok "and back" '[ /opt -ef $APP ] && [ ! -e /mnt/lg/user/opt ] && [ "$(stat -c %a /opt/tmp)" = 1777 ]'
run uninstall -y
ok "uninstall removes Entware from app storage" 'grep -q "Entware removed" "$W/out" && [ ! -e $APP ] && [ ! -e /var/lib/webosbrew/init.d/S99entware ]'
mkdir -p /mnt/lg/user/opt/keep; echo mine > /mnt/lg/user/opt/keep/file
run uninstall -y
ok "uninstall won't delete a folder that isn't root's Entware" '[ -f /mnt/lg/user/opt/keep/file ] && grep -q "Couldn.t confirm" "$W/out"'
rm -rf /mnt/lg/user/opt
umount /mnt/lg/appstore

echo "== [$SH] 32. app storage is the default, and older installs move there on a repair"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
mkdir -p /mnt/lg/appstore && mount -t tmpfs -o size=64g tmpfs /mnt/lg/appstore
APP=/mnt/lg/appstore/entware
run install -y
ok "a new install goes on app storage" 'grep -q "Entware goes in $APP, on app storage" "$W/out" && [ /opt -ef $APP ] && [ ! -e /mnt/lg/user/opt ]'
ok "and records no fixed choice" 'grep -q "^location_choice=auto$" /opt/etc/webos-entware/install.info'
run uninstall -y
umount /mnt/lg/appstore
run install -y
ok "without app storage, a new install goes on user data" '[ /opt -ef /mnt/lg/user/opt ] && grep -q "Entware installed successfully" "$W/out"'
sed -i '/^location_choice=/d' /opt/etc/webos-entware/install.info    # as an older version left it
mount -t tmpfs -o size=64g tmpfs /mnt/lg/appstore
run status; sed -i 's/\x1b\[[0-9;]*m//g' "$W/out"
ok "doctor says a repair moves it to app storage" 'grep -q "A repair moves it there" "$W/out"'
(exec 9>> /opt/etc/busy-file; sleep 15) & BUSY=$!
sleep 0.3
run install -y
ok "if it can't move now, the repair still succeeds and Entware stays put" 'grep -q "Entware installed successfully" "$W/out" && grep -q "stays on user data for now" "$W/out" && [ /opt -ef /mnt/lg/user/opt ] && [ ! -e $APP ]'
kill $BUSY 2>/dev/null; wait $BUSY 2>/dev/null; rm -f /opt/etc/busy-file
notice() { bash -c '. /opt/etc/webos-entware/bashrc' < /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
ok "an SSH login says Entware can move to app storage" 'notice | grep -q "Entware is on user data" && notice | grep -q "webos-entware move appstore"'
run move user -y
ok "move user on user data keeps it there for good" 'grep -q "It stays there" "$W/out" && grep -q "^location_choice=user$" /opt/etc/webos-entware/install.info'
ok "and the login notice is gone" '! notice | grep -q "Entware is on user data"'
sed -i 's/^location_choice=.*/location_choice=auto/' /opt/etc/webos-entware/install.info
PKGS=$(cat /opt/lib/opkg/fake-installed)
run install -y
ok "the next repair moves an older install to app storage" 'grep -q "now runs from app storage" "$W/out" && [ /opt -ef $APP ] && [ ! -e /mnt/lg/user/opt ] && [ "$(cat /opt/lib/opkg/fake-installed)" = "$PKGS" ]'
ok "with the boot script and login following" 'grep -q "^ *SRC=$APP$" /var/lib/webosbrew/init.d/S99entware && grep -q "^ENTWARE_SRC=$APP$" /home/root/.profile'
reboot_tv
ok "and it comes back after a reboot" '[ /opt -ef $APP ] && grep -q "started Entware services" /tmp/webos-entware-boot.log'
ok "on app storage there's no login notice" '! notice | grep -q "Entware is on user data"'
run move user -y
run install -y
ok "a repair keeps it on user data when you chose that" '[ /opt -ef /mnt/lg/user/opt ] && ! grep -q "Move Entware to app storage\|now runs from app storage" "$W/out" && grep -q "^location_choice=user$" /opt/etc/webos-entware/install.info'
run status
ok "and doctor doesn't nag about it" '! grep -q "A repair moves it there" "$W/out"'
run status --json
ok "status --json says you chose it" 'grep -q "\"locationChoice\":\"user\"" "$W/out"'
run uninstall -y
umount /mnt/lg/appstore; mount -t tmpfs -o size=10m tmpfs /mnt/lg/appstore
run install -y
ok "when app storage has less room, a new install goes on user data, and stays" '[ /opt -ef /mnt/lg/user/opt ] && ! grep -q "Move Entware to app storage\|now runs from" "$W/out"'
run uninstall -y
umount /mnt/lg/appstore

echo "== [$SH] 33. the TV app updates itself from the newest release"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
mkdir -p /media/developer && mount -t tmpfs tmpfs /media/developer
AD=/media/developer/apps/usr/palm/applications/org.ohmybahgosh.entware
run install -y
! run app-update -y
ok "app-update says when the app isn't installed" 'grep -q "TV app isn.t installed" "$W/out"'
mkdir -p $AD/assets
printf '{\n    "id": "org.ohmybahgosh.entware",\n    "version": "2.9.1"\n}\n' > $AD/appinfo.json
cp "$W/installer.sh" $AD/assets/webos-entware-installer.sh
fake_release() { # version, package id
    rm -rf "$W/rel" "$W/pk"; mkdir -p "$W/rel" "$W/pk"
    printf 'Package: %s\nVersion: %s\nArchitecture: all\n' "$2" "$1" > "$W/pk/control"
    echo 2.0 > "$W/pk/debian-binary"
    (cd "$W/pk" && tar czf control.tar.gz ./control && tar czf data.tar.gz ./control && ar rc "$W/rel/org.ohmybahgosh.entware_$1_all.ipk" debian-binary control.tar.gz data.tar.gz)
    sed "s/^VERSION=.*/VERSION=\"$1\"/" "$W/installer.sh" > "$W/rel/webos-entware-installer.sh"
    (cd "$W/rel" && sha256sum webos-entware-installer.sh "org.ohmybahgosh.entware_$1_all.ipk" > SHA256SUMS)
}
app_up() { (cd /tmp && $SH $AD/assets/webos-entware-installer.sh app-update -y) > "$W/out" 2>&1; }
appv() { sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' $AD/appinfo.json; }
fake_release 2.9.1 org.ohmybahgosh.entware
app_up
ok "app-update says when the app is up to date" 'grep -q "The app is up to date (v2.9.1)" "$W/out" && [ "$(appv)" = 2.9.1 ]'
rm -rf "$W/rel"
! app_up
ok "app-update says when GitHub can't be reached" 'grep -q "Couldn.t reach GitHub" "$W/out" && [ "$(appv)" = 2.9.1 ]'
fake_release 9.9.9 org.ohmybahgosh.entware
echo tampered >> "$W/rel/org.ohmybahgosh.entware_9.9.9_all.ipk"
! app_up
ok "app-update refuses a download that doesn't match the checksum" 'grep -q "didn.t match the release.s checksum" "$W/out" && [ "$(appv)" = 2.9.1 ]'
fake_release 9.9.9 com.someone.else
! app_up
ok "app-update refuses a download that isn't this app" 'grep -q "isn.t version 9.9.9 of this app" "$W/out" && [ "$(appv)" = 2.9.1 ]'
fake_release 9.9.9 org.ohmybahgosh.entware
: > /tmp/luna.log
app_up
ok "app-update installs the newest release" 'grep -q "The app is now v9.9.9" "$W/out" && [ "$(appv)" = 9.9.9 ]'
ok "it checked the download first" 'grep -q "checked it against the release" "$W/out"'
ok "the webos-entware command follows" 'grep -q "^VERSION=\"9.9.9\"" /opt/bin/webos-entware && grep -q "Updated the webos-entware command to v9.9.9" "$W/out"'
ok "it shows a toast and reopens the app" 'grep -q "createToast.*updated to v9.9.9" /tmp/luna.log && grep -q "applicationManager/launch.*org.ohmybahgosh.entware" /tmp/luna.log'
ok "and leaves nothing behind in /tmp" '[ -z "$(ls -d /tmp/.webos-entware-update.* /tmp/webos-entware-app-update.sh 2>/dev/null)" ] && [ ! -d /tmp/webos-entware.lock ]'
sed -i 's/"version": "9.9.9"/"version": "2.9.1"/' $AD/appinfo.json
rm -rf /tmp/webos-entware-job
(cd /tmp && $SH $AD/assets/webos-entware-installer.sh job app-update) > "$W/out" 2>&1
for _ in $(seq 1 100); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
ok "job app-update runs in the background" '[ "$(cat /tmp/webos-entware-job/exit)" = 0 ] && [ "$(appv)" = 9.9.9 ] && grep -q "The app is now v9.9.9" /tmp/webos-entware-job/log'
run uninstall -y
umount /media/developer

echo "== [$SH] $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
