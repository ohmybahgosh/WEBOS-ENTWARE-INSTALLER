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
# Node.js for the phone dashboard, found before /opt is covered
NODE=$(command -v node || true)
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
# A service: a copy of sleep with the daemon's name, and an init script
# like Entware's (ENABLED, start and stop)
fake_daemon() { # process, init script
    mkdir -p /opt/etc/init.d /opt/lib/fake
    cp -L /bin/sleep "/opt/lib/fake/$1"
    printf '#!/bin/sh\nENABLED=yes\ncase "$1" in\n  start) [ "$ENABLED" = yes ] || exit 0; pidof %s >/dev/null || (/opt/lib/fake/%s 300 </dev/null >/dev/null 2>&1 &) ;;\n  stop) pkill -x %s ;;\nesac\nexit 0\n' "$1" "$1" "$1" > "/opt/etc/init.d/$2"
    chmod 755 "/opt/etc/init.d/$2"
}
# Another opkg holding the lock: everything but --version gives up
[ "$1" != --version ] && [ -e /run/opkg-locked ] && { echo " * opkg_conf_load: Could not lock /opt/tmp/opkg.lock: Resource temporarily unavailable."; exit 255; }
case "$1" in
    --version) echo "opkg version fake (2025-11-05)" ;;
    print-architecture) echo "arch all 1"; echo "arch aarch64-3.10 10" ;;
    update) [ -e /run/entware-fail-update ] && { echo "fake: update failed"; exit 1; }
        mkdir -p /opt/var/opkg-lists; touch /opt/var/opkg-lists/entware
        echo "Updated list of available packages" ;;
    list-upgradable) cat /opt/lib/opkg/fake-upgradable 2>/dev/null ;;
    upgrade) shift
        if [ $# -eq 0 ]; then : > /opt/lib/opkg/fake-upgradable
        else for p in "$@"; do grep -v "^$p - " /opt/lib/opkg/fake-upgradable > /opt/lib/opkg/fake-up.new; mv /opt/lib/opkg/fake-up.new /opt/lib/opkg/fake-upgradable; done
        fi ;;
    install) shift
        for p in "$@"; do
            if grep -qx "$p" $DB; then echo "Package $p is up to date"; continue; fi
            echo "$p" >> $DB
            mkdir -p /opt/lib/opkg/info
            printf 'Package: %s\nVersion: 1.0-1\nSection: utils\nInstalled-Size: 102400\nDescription:  The %s package, "quoted"\n second line\n' "$p" "$p" > /opt/lib/opkg/info/$p.control
            { echo "Package: $p"; echo "Version: 1.0-1"; [ "$p" = git-http ] && echo "Depends: libc, git (>= 2.0)"
              echo "Status: install user installed"; echo "Installed-Time: 1762200000"; echo; } >> /opt/lib/opkg/status
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
                tailscale) fake_daemon tailscaled S06tailscaled
                    cat > /opt/bin/tailscale << 'T'
#!/bin/sh
case "$1" in
    status) pidof tailscaled > /dev/null || { echo "failed to connect to local tailscaled"; exit 1; }
        st=NeedsLogin url=""
        [ -e /tmp/ts-up ] && url=https://login.tailscale.com/a/fake123
        [ -e /tmp/ts-in ] && { st=Running; url=""; }
        printf '{\n  "Version": "1.96.1",\n  "BackendState": "%s",\n  "AuthURL": "%s",\n  "TailscaleIPs": null\n}\n' "$st" "$url" ;;
    up) echo "$*" > /tmp/ts-up ;;
    ip) echo 100.101.102.103 ;;
    logout) rm -f /tmp/ts-in; echo logout >> /tmp/ts.log ;;
esac
T
                    chmod 755 /opt/bin/tailscale ;;
                samba4-server) fake_daemon smbd S91smb
                    mkdir -p /opt/etc/samba; printf '[global]\n    guest ok = yes\n' > /opt/etc/samba/smb.conf
                    cat > /opt/bin/smbpasswd << 'T'
#!/bin/sh
[ -e /run/fail-smbpasswd ] && exit 1
read -r a; read -r b
[ "$a" = "$b" ] || exit 1
echo "$* $a" >> /tmp/smbpasswd.log
echo "root:0:$a" > /opt/etc/samba/smbpasswd
T
                    chmod 755 /opt/bin/smbpasswd ;;
                wsdd2) fake_daemon wsdd2 S99wsdd2 ;;
                filebrowser) fake_daemon filebrowser S99filebrowser
                    mkdir -p /opt/etc/filebrowser /opt/sbin
                    printf 'ADDR="-a 192.168.1.1"\nPORT="-p 8080"\n' > /opt/etc/filebrowser/filebrowser.conf
                    cat > /opt/sbin/filebrowser << 'T'
#!/bin/sh
echo "$*" >> /tmp/fb.log
db=$(echo "$*" | sed -n 's/.*-d \([^ ]*\).*/\1/p')
case "$1 $2" in
    "config init") : > "$db" ;;
    "users update") grep -q "^$3 " /tmp/fb-users 2>/dev/null || exit 1; sed -i "s/^$3 .*/$3 $5/" /tmp/fb-users ;;
    "users add") echo "$3 $4" >> /tmp/fb-users ;;
esac
T
                    chmod 755 /opt/sbin/filebrowser ;;
                minidlna) fake_daemon minidlnad S90minidlna; echo "media_dir=/opt/media" > /opt/etc/minidlna.conf ;;
                transmission-daemon) fake_daemon transmission-daemon S88transmission
                    mkdir -p /opt/etc/transmission
                    printf '{\n    "download-dir": "/opt/downloads/torrent",\n    "incomplete-dir": "/opt/downloads/torrent/incomplete",\n    "incomplete-dir-enabled": false,\n    "rpc-authentication-required": false,\n    "rpc-password": "",\n    "rpc-port": 9091,\n    "rpc-username": "root",\n    "watch-dir": "/opt/etc/transmission/watchdir",\n    "watch-dir-enabled": true\n}\n' > /opt/etc/transmission/settings.json ;;
                syncthing) mkdir -p /opt/etc/init.d /opt/lib/fake; cp -L /bin/sleep /opt/lib/fake/syncthing
                    printf '#!/bin/sh\nENABLED=yes\nPROCS=syncthing\n. /opt/etc/init.d/rc.func\n' > /opt/etc/init.d/S92syncthing; chmod 755 /opt/etc/init.d/S92syncthing
                    [ -f /opt/etc/init.d/rc.func ] || cat > /opt/etc/init.d/rc.func << 'T'
case "$1" in
    start) [ "$ENABLED" = yes ] || exit 0; for PROC in $PROCS; do pidof $PROC > /dev/null || ($PREARGS $PROC $ARGS < /dev/null > /dev/null 2>&1 &); done ;;
    stop) for PROC in $PROCS; do pkill -x $PROC; done ;;
esac
T
                    cat > /opt/bin/syncthing << 'T'
#!/bin/sh
echo "$* STNODEFAULTFOLDER=$STNODEFAULTFOLDER" >> /tmp/st.log
case "$1" in
    generate) h=$(echo "$*" | sed -n 's/.*--home=\([^ ]*\).*/\1/p'); read -r pw; mkdir -p "$h"; echo "<gui user=tv password=$pw>" > "$h/config.xml" ;;
    serve) exec /opt/lib/fake/syncthing 300 ;;
esac
T
                    chmod 755 /opt/bin/syncthing ;;
                fd) mkdir -p /opt/usr/bin; printf '#!/bin/sh\n' > /opt/usr/bin/fd; chmod 755 /opt/usr/bin/fd ;;
            esac
        done ;;
    remove) shift
        for p in "$@"; do
            case "$p" in -*) continue ;; esac
            if [ "$p" = git ] && grep -qx git-http $DB; then echo "Package git is depended upon by git-http"; FAILED=1; continue; fi
            echo "$p" >> /tmp/opkg-removed.log
            grep -vx "$p" $DB > $DB.new; mv $DB.new $DB
            rm -f /opt/lib/opkg/info/$p.control
            awk -v p="$p" 'BEGIN { RS = ""; ORS = "\n\n" } $2 != p' /opt/lib/opkg/status > /opt/lib/opkg/status.new && mv /opt/lib/opkg/status.new /opt/lib/opkg/status
            [ "$p" = mlocate ] && rm -f /opt/bin/updatedb /opt/bin/locate
            [ "$p" = ca-bundle ] && rm -f /opt/etc/ssl/certs/ca-certificates.crt
        done
        exit ${FAILED:-0} ;;
    list-installed) sed 's/$/ - 1/' $DB ;;
    search) for l in /opt/lib/opkg/info/*.list; do
            [ -f "$l" ] && grep -qx "$2" "$l" && { n=${l##*/}; echo "${n%.list} - 1"; }
        done ;;
    list) if [ -f /opt/lib/opkg/fake-list ]; then cat /opt/lib/opkg/fake-list
        else echo "bash - 5.3 - The GNU Bourne Again SHell"; echo "nano-full - 8.7 - An enhanced clone of Pico"; fi ;;
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
case "$NODE" in
    '') ;;
    /opt/*) cp "$NODE" "$W/bin/node" ;;
    *) ln -s "$NODE" "$W/bin/node" ;;
esac
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
ok "add installs an add-on" 'grep -q "Added htop." "$W/out" && [ -f /opt/lib/opkg/info/htop.control ]'
run add git -y
ok "add git brings HTTPS certificates with it" '[ -f /opt/lib/opkg/info/git-http.control ] && [ -s /opt/etc/ssl/certs/ca-certificates.crt ]'
run add locate -y
ok "add locate sets locate up" 'grep -q "locate is ready" "$W/out" && [ -x /opt/bin/updatedb-webos ] && [ -f /opt/etc/updatedb.conf ]'
run addons
ok "addons lists states for people too" 'grep -q "htop.*installed" "$W/out" && grep -q "tmux.*not installed" "$W/out"'
! run add "htop;reboot" -y
ok "add refuses a name that isn't in the catalog" 'grep -q "Unknown add-on" "$W/out"'
! run add emacs -y
ok "add refuses packages outside the catalog" 'grep -q "Unknown add-on: emacs" "$W/out"'
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
assert any(\"Added tmux\" in l for l in d[\"log\"]), d
" "$W/out" && [ -f /opt/lib/opkg/info/tmux.control ]'
(cd /tmp && $SH /tmp/webos-entware-installer.sh job remove tmux) > "$W/out" 2>&1
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
ok "job remove removes without asking" '[ ! -f /opt/lib/opkg/info/tmux.control ] && grep -q "Removed tmux" /tmp/webos-entware-job/log'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job add "x y") > "$W/out" 2>&1
ok "job add refuses names outside the catalog" 'grep -q "Unknown add-on" "$W/out"'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job install htop) > "$W/out" 2>&1
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
app_check() { (cd /tmp && $SH $AD/assets/webos-entware-installer.sh app-update --check --json) > "$W/out" 2>&1; }
jq_ok() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$W/out"; }
app_check
ok "app-update --check --json says when the app is up to date" 'jq_ok "d[\"current\"] == \"2.9.1\" and d[\"latest\"] == \"2.9.1\" and d[\"newer\"] is False and d[\"error\"] == \"\""'
app_up
ok "app-update says when the app is up to date" 'grep -q "The app is up to date (v2.9.1)" "$W/out" && [ "$(appv)" = 2.9.1 ]'
sed -i 's/^VERSION=.*/VERSION="2.9.0"/' /opt/bin/webos-entware
app_up
ok "and still brings an older webos-entware command up to the release" 'grep -q "^VERSION=\"2.9.1\"" /opt/bin/webos-entware && grep -q "Updated the webos-entware command to v2.9.1" "$W/out"'
app_up
ok "but leaves it alone once it's current" '! grep -q "Updated the webos-entware command" "$W/out"'
rm -rf "$W/rel"
! app_check
ok "app-update --check --json says when GitHub can't be reached" 'jq_ok "d[\"latest\"] == \"\" and d[\"newer\"] is False and \"GitHub\" in d[\"error\"]"'
! app_up
ok "app-update says when GitHub can't be reached" 'grep -q "Couldn.t reach GitHub" "$W/out" && [ "$(appv)" = 2.9.1 ]'
fake_release 9.9.9 org.ohmybahgosh.entware
mkdir /tmp/webos-entware.lock && echo $$ > /tmp/webos-entware.lock/pid
app_check
rm -rf /tmp/webos-entware.lock
ok "app-update --check --json finds a newer release, even while a task runs" 'jq_ok "d[\"latest\"] == \"9.9.9\" and d[\"newer\"] is True and d[\"notes\"].endswith(\"/tag/v9.9.9\")"'
ok "and changes nothing" '[ "$(appv)" = 2.9.1 ] && [ -z "$(ls -d /tmp/.webos-entware-update.* 2>/dev/null)" ]'
(cd /tmp && $SH $AD/assets/webos-entware-installer.sh app-update --check) > "$W/out" 2>&1
ok "app-update --check says so in words too" 'grep -q "Version 9.9.9 is out (the app is v2.9.1)" "$W/out"'
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

echo "== [$SH] 34. package updates: list them, update one or all"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run install -y
run updates
ok "updates says when every package is up to date" 'grep -q "Every package is up to date" "$W/out"'
printf 'htop - 3.4.1-1 - 3.4.2-1\ncurl - 8.11.1-1 - 8.12.0-1\n' > /opt/lib/opkg/fake-upgradable
run updates
ok "updates lists each package with its versions" 'grep -q "2 package updates" "$W/out" && grep -q "htop .*3.4.1-1 -> 3.4.2-1" "$W/out"'
run updates --json --refresh
ok "updates --json --refresh refreshes the list and reports it" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert [p[\"name\"] for p in d[\"packages\"]] == [\"htop\", \"curl\"] and d[\"packages\"][1][\"available\"] == \"8.12.0-1\", d
assert d[\"checked\"] and d[\"ageHours\"] == 0 and d[\"refreshFailed\"] is False, d
" "$W/out"'
run status --json
ok "status --json counts the updates" 'grep -q "\"updates\":2," "$W/out"'
run status
ok "doctor mentions them" 'grep -q "2 package updates are available" "$W/out"'
! run upgrade "htop;reboot" -y
ok "upgrade refuses something that isn't a package name" 'grep -q "isn.t a package name" "$W/out"'
! run upgrade vim -y
ok "upgrade says when a package has no update" 'grep -q "vim has no update" "$W/out"'
run upgrade htop -y
ok "upgrade <name> updates just that package" 'grep -q "htop is now 3.4.2-1" "$W/out" && ! grep -q "^htop" /opt/lib/opkg/fake-upgradable && grep -q "^curl" /opt/lib/opkg/fake-upgradable'
(cd /tmp && $SH /tmp/webos-entware-installer.sh job upgrade curl) > "$W/out" 2>&1
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
ok "job upgrade <name> runs in the background" '[ "$(cat /tmp/webos-entware-job/exit)" = 0 ] && grep -q "curl is now 8.12.0-1" /tmp/webos-entware-job/log && [ ! -s /opt/lib/opkg/fake-upgradable ]'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job upgrade "x y") > "$W/out" 2>&1
ok "job upgrade refuses something that isn't a package name" 'grep -q "isn.t a package name" "$W/out"'
printf 'htop - 3.4.1-1 - 3.4.2-1\n' > /opt/lib/opkg/fake-upgradable
run upgrade -y
ok "upgrade with no name updates everything" 'grep -q "Packages upgraded" "$W/out" && [ ! -s /opt/lib/opkg/fake-upgradable ]'
run uninstall -y

echo "== [$SH] 35. the login banner add-on"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run install -y
mkdir -p "$W/rel"
printf '#!/usr/bin/env bash\nversion=7.1.0\necho "FAKE NEOFETCH $*"\n' > "$W/rel/neofetch"
cp "$W/installer.sh" "$W/installer.orig"
sed -i "s/^NEOFETCH_SHA=.*/NEOFETCH_SHA=\"$(sha256sum "$W/rel/neofetch" | awk '{print $1}')\"/" "$W/installer.sh"
BANNER=/opt/etc/webos-entware/banner
hooks() { grep -c "Login banner add-on" /opt/etc/webos-entware/bashrc; }
ssh_login() { (cd /home/root && HOME=/home/root /opt/bin/bash -l "$@" -c true < /dev/null 2> /dev/null); }
run add banner -y
ok "add banner downloads neofetch, checks it, and runs it with Entware's bash" 'grep -q "login banner is ready" "$W/out" && [ "$(head -n 1 /opt/bin/neofetch)" = "#!/opt/bin/bash" ] && grep -q "^# neofetch 7.1.0, checked" /opt/bin/neofetch && grep -q "FAKE NEOFETCH" /opt/bin/neofetch && [ -z "$(ls -d /opt/tmp/.webos-entware-neofetch.* 2>/dev/null)" ]'
ok "it writes the wordmark, the settings and one hook" '[ -s $BANNER/wordmark.ans ] && grep -q print_info $BANNER/config.conf && [ "$(hooks)" = 1 ]'
out=$(ssh_login -i)
ok "an SSH login shows the wordmark, then neofetch with its settings" 'echo "$out" | grep -q "▀" && echo "$out" | grep -q "FAKE NEOFETCH --config $BANNER/config.conf"'
out=$(ssh_login)
ok "commands over SSH don't show it" '! echo "$out" | grep -q FAKE'
touch /home/root/.hushlogin
out=$(ssh_login -i)
ok "a .hushlogin file hides it" '! echo "$out" | grep -q FAKE'
rm -f /home/root/.hushlogin
run addons --json
ok "addons --json shows it installed" 'python3 -c "
import json,sys; d={a[\"id\"]: a for a in json.load(open(sys.argv[1]))}
assert d[\"banner\"][\"state\"] == \"installed\" and d[\"banner\"][\"packages\"] == \"neofetch\" and d[\"banner\"][\"removable\"] is True, d[\"banner\"]
" "$W/out"'
echo "# mine" >> $BANNER/config.conf
run add banner -y
ok "adding it again keeps your settings and the one hook" 'grep -q "login banner is ready" "$W/out" && grep -q "# mine" $BANNER/config.conf && [ "$(hooks)" = 1 ]'
run install -y
ok "a repair keeps it hooked up, once" '[ "$(hooks)" = 1 ] && [ -f $BANNER/login.sh ]'
run remove banner -y
ok "remove banner takes neofetch and its files, and leaves bash" 'grep -q "Removed Login banner" "$W/out" && [ ! -e /opt/bin/neofetch ] && [ ! -e $BANNER ] && [ -x /opt/bin/bash ]'
out=$(ssh_login -i)
ok "after that, logins are quiet again" '! echo "$out" | grep -q "FAKE\|▀"'
printf 'not neofetch\n' > "$W/rel/neofetch"
! run add banner -y
ok "a download that doesn't match the checksum isn't used" 'grep -q "didn.t match neofetch 7.1.0" "$W/out" && [ ! -e /opt/bin/neofetch ] && [ -z "$(ls -d /opt/tmp/.webos-entware-neofetch.* 2>/dev/null)" ]'
rm -f "$W/rel/neofetch"
! run add banner -y
ok "add banner says when GitHub can't be reached" 'grep -q "Couldn.t download neofetch" "$W/out" && [ ! -e $BANNER/login.sh ]'
cp "$W/installer.orig" "$W/installer.sh"
run uninstall -y

echo "== [$SH] 36. packages: installed, search, add and remove one, and logs"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run install -y
printf '%s\n' "htop - 3.4.1-1 - Interactive processes viewer" "btop - 1.4.5-1 - Resource monitor" "tmux - 3.5a-1 - Terminal multiplexer" "git - 2.51.0-1 - Version control" "git-http - 2.51.0-1 - Git HTTP support" "nethogs - 0.8.7-1 - Shows bandwidth per process, like top" > /opt/lib/opkg/fake-list
run installed --json
ok "installed --json lists packages, marking the ones Entware needs" 'python3 -c "
import json,sys; d={p[\"name\"]: p for p in json.load(open(sys.argv[1]))}
assert d[\"bash\"][\"base\"] is True and d[\"bash\"][\"version\"] == \"1.0-1\" and isinstance(d[\"bash\"][\"sizeKB\"], int), d[\"bash\"]
assert d[\"nano-full\"][\"addon\"] == \"nano\" and d[\"nano-full\"][\"addonTitle\"] == \"nano with syntax colors\", d[\"nano-full\"]
" "$W/out"'
ok "with each one's section, size, whole description and when it was installed" 'python3 -c "
import json,sys; d={p[\"name\"]: p for p in json.load(open(sys.argv[1]))}
b = d[\"bash\"]
assert b[\"section\"] == \"utils\" and b[\"sizeKB\"] == 100 and b[\"description\"] == \"The bash package, \\\"quoted\\\" second line\" and b[\"installed\"] == 1762200000, b
" "$W/out"'
run search top --json
ok "search puts name matches first, then the description, and marks what's installed" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); n=[p[\"name\"] for p in d]
assert n == [\"btop\", \"htop\", \"nethogs\"], n
assert d[1][\"installed\"] is False and d[1][\"version\"] == \"3.4.1-1\", d
" "$W/out"'
! run search "x;reboot" --json
ok "search refuses anything that isn't a plain word" 'grep -q "Search for a word" "$W/out"'
run pkg-add htop -y
ok "pkg-add installs a package" 'grep -q "htop is installed" "$W/out" && [ -f /opt/lib/opkg/info/htop.control ]'
run installed --json
ok "and it shows up as installed, not part of Entware" 'python3 -c "
import json,sys; d={p[\"name\"]: p for p in json.load(open(sys.argv[1]))}
assert d[\"htop\"][\"base\"] is False and d[\"htop\"][\"neededBy\"] == \"\", d[\"htop\"]
" "$W/out"'
run search htop --json
ok "search then marks it installed" 'grep -q "\"name\":\"htop\",\"version\":\"3.4.1-1\",\"description\":\"Interactive processes viewer\",\"installed\":true" "$W/out"'
! run pkg-add "../etc" -y
ok "pkg-add refuses something that isn't a package name" 'grep -q "isn.t a package name" "$W/out"'
run pkg-add git -y; run pkg-add git-http -y
! run pkg-remove git -y
ok "pkg-remove says what still needs a package" 'grep -q "git is needed by git-http" "$W/out" && [ -f /opt/lib/opkg/info/git.control ]'
! run pkg-remove bash -y
ok "pkg-remove keeps what Entware and the shell need" 'grep -q "bash is part of Entware" "$W/out" && [ -x /opt/bin/bash ]'
run pkg-remove htop -y
ok "pkg-remove removes a package" 'grep -q "Removed htop" "$W/out" && [ ! -f /opt/lib/opkg/info/htop.control ]'
(cd /tmp && $SH /tmp/webos-entware-installer.sh job pkg-add tmux) > "$W/out" 2>&1
for _ in $(seq 1 50); do [ -f /tmp/webos-entware-job/exit ] && break; sleep 0.2; done
sleep 1
ok "job pkg-add runs in the background" '[ "$(cat /tmp/webos-entware-job/exit)" = 0 ] && grep -q "tmux is installed" /tmp/webos-entware-job/log'
run logs --json
ok "logs --json lists the boot log and the task that just ran" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"current\"] == \"done\" and isinstance(d[\"boot\"], list), d
t=d[\"tasks\"][0]; assert t[\"name\"] == \"pkg-add tmux\" and t[\"exit\"] == 0 and t[\"when\"], t
open(\"/tmp/logid\",\"w\").write(t[\"id\"])
" "$W/out"'
run log "$(cat /tmp/logid)" --json
ok "log <id> shows that task's log" 'grep -q "tmux is installed" "$W/out"'
! run log "../../etc/passwd" --json
ok "log refuses a name that isn't a log" 'grep -q "isn.t a log name" "$W/out"'
run logs
ok "logs reads well for people too" 'grep -q "Boot log" "$W/out" && grep -q "pkg-add tmux *done" "$W/out"'
! (cd /tmp && $SH /tmp/webos-entware-installer.sh job pkg-add "x y") > "$W/out" 2>&1
ok "job pkg-add refuses names that aren't packages" 'grep -q "isn.t a package name" "$W/out"'
rm -f /opt/lib/opkg/fake-list /tmp/logid
run uninstall -y

echo "== [$SH] 36c. browsing: the package list and one package's page"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run install -y
mkdir -p /opt/var/opkg-lists
cat > /opt/var/opkg-lists/entware << 'L'
Package: htop
Version: 3.4.1-1
Depends: libc, libncurses
Section: admin
Architecture: aarch64-3.10
Installed-Size: 296960
Size: 132957
Description:  Htop is an ncursed-based process viewer similar to top, but
 it allows to scroll the list.

Package: libncurses
Version: 6.4-3
Depends: libc, terminfo
Section: libs
Installed-Size: 300000
Size: 150000
Description:  Terminal handling library

Package: terminfo
Version: 6.4-3
Section: utils
Installed-Size: 20480
Size: 10240
Description:  Terminal Info Database (ncurses)

Package: rclone
Version: 1.73.2-1
Section: net
Installed-Size: 70983680
Size: 23454249
Description:  Rclone is a command line program to sync files and directories to and from:
 Google Drive
 Dropbox
 .
 And more.

Package: python3-yaml
Version: 6.0-1
Depends: python3-light
Section: lang
Size: 1000
Description:  YAML for Python

Package: python3-pip
Version: 23.3.1-1
Depends: python3-light
Section: lang
Size: 2000
Description:  The Python package installer

Package: python3-light
Version: 3.13.9-2
Provides: python3-base
Depends: libc
Section: lang
Size: 3000
Description:  Python, light

Package: myapp
Version: 1.0
Depends: python3-base, libc (>= 1.0), wget-ssl | wget-nossl, myapp
Section: utils
Installed-Size: 4096
Size: 2048
Description:  An app that "quotes" \ things	with a tab

Package: bash
Version: 5.3-2
Section: utils
Size: 700000
Description:  The GNU Bourne Again SHell
L
run catalog --json
ok "catalog --json lists what a person would pick, not libraries or modules" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); n=[p[\"n\"] for p in d]
assert n == [\"htop\", \"rclone\", \"python3-pip\", \"myapp\", \"bash\"], n
" "$W/out"'
ok "each with its version, section, sizes in KB, description, add-on and whether webOS has it" 'python3 -c "
import json,sys; d={p[\"n\"]: p for p in json.load(open(sys.argv[1]))}
h = d[\"htop\"]
import os; sysh = int(any(os.path.exists(x + \"/htop\") for x in (\"/bin\", \"/sbin\", \"/usr/bin\", \"/usr/sbin\")))
assert h == {\"n\": \"htop\", \"v\": \"3.4.1-1\", \"s\": \"admin\", \"z\": 130, \"i\": 290, \"d\": \"Htop is an ncursed-based process viewer similar to top, but it allows to scroll the list.\", \"a\": \"htop\", \"w\": sysh}, h
assert d[\"rclone\"][\"a\"] == \"rclone\" and d[\"bash\"][\"w\"] == 1, d
assert d[\"myapp\"][\"d\"].startswith(\"An app that \\\"quotes\\\" \\\\ things\"), d[\"myapp\"]
" "$W/out"'
run catalog --json --all
ok "catalog --all lists libraries and modules too" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); assert len(d) == 9 and \"libncurses\" in [p[\"n\"] for p in d], d
" "$W/out"'
run pkginfo htop --json
ok "pkginfo --json: the whole description, sizes, and everything it would add, all the way down" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"name\"] == \"htop\" and d[\"installed\"] is False and d[\"sizeKB\"] == 130 and d[\"isizeKB\"] == 290, d
assert d[\"description\"] == \"Htop is an ncursed-based process viewer similar to top, but\nit allows to scroll the list.\", d[\"description\"]
assert [x[\"name\"] for x in d[\"needs\"]] == [\"libncurses\", \"terminfo\"] and d[\"needsKB\"] == 157 and d[\"needsIKB\"] == 313, d[\"needs\"]
assert d[\"addon\"] == \"htop\" and d[\"addonTitle\"] == \"htop\" and d[\"addonState\"] == \"notInstalled\" and d[\"freeKB\"] > 0, d
" "$W/out"'
run pkginfo rclone --json
ok "a description keeps its lines and paragraph breaks" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"description\"] == \"Rclone is a command line program to sync files and directories to and from:\nGoogle Drive\nDropbox\n\nAnd more.\", d[\"description\"]
" "$W/out"'
run pkginfo myapp --json
ok "a need met by another package (Provides), a version and alternatives are understood" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert [x[\"name\"] for x in d[\"needs\"]] == [\"python3-light\"], d[\"needs\"]
assert d[\"description\"] == \"An app that \\\"quotes\\\" \\\\ things with a tab\", d[\"description\"]
" "$W/out"'
run pkginfo bash --json
ok "an installed package says so, with its version and that Entware needs it" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
assert d[\"installed\"] is True and d[\"installedVersion\"] == \"1.0-1\" and d[\"base\"] is True and d[\"commands\"] == [\"bash\"], d
" "$W/out"'
run pkg-add htop -y
run pkginfo htop --json
ok "after installing it, pkginfo says it's installed and adds nothing" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); assert d[\"installed\"] is True and d[\"version\"] == \"3.4.1-1\" and d[\"installedVersion\"] == \"1.0-1\", d
" "$W/out"'
run pkginfo htop
ok "pkginfo reads well for people too" 'head -n 1 "$W/out" | grep -q "^htop  3.4.1-1" && grep -q "^it allows to scroll the list.$" "$W/out"'
! run pkginfo nosuch --json
ok "pkginfo says when there's no such package" 'grep -q "no package called nosuch" "$W/out"'
! run pkginfo "../etc" --json
ok "pkginfo refuses something that isn't a package name" 'grep -q "isn.t a package name" "$W/out"'
gzip -n /opt/var/opkg-lists/entware && mv /opt/var/opkg-lists/entware.gz /opt/var/opkg-lists/entware
run catalog --json
ok "the package list works gzipped too, as opkg keeps it on the TV" 'python3 -c "
import json,sys; d=json.load(open(sys.argv[1])); assert [p[\"n\"] for p in d] == [\"htop\", \"rclone\", \"python3-pip\", \"myapp\", \"bash\"], d
" "$W/out"'
run pkginfo rclone --json
ok "and pkginfo reads it" 'grep -q "\"sizeKB\":22905," "$W/out" && grep -q "Google Drive" "$W/out"'
rm -f /opt/var/opkg-lists/entware
run uninstall -y

echo "== [$SH] 36b. while another opkg holds its lock"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock
run install -y
N=$(grep -c '^Package:' /opt/lib/opkg/status)
touch /run/opkg-locked
run status --json
ok "status still counts the packages (issue #3: null packages)" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"packages\"] == int(sys.argv[2]) and d[\"opkg\"] is True else 1)" "$W/out" "$N"'
run status
ok "and the full check says opkg runs, with the count" 'grep -q "opkg runs:          .*yes" "$W/out" && grep -q "Packages installed: $N" "$W/out" && ! grep -q "opkg doesn.t run" "$W/out"'
rm -f /run/opkg-locked
run uninstall -y

echo "== [$SH] 37. network services: set up with a password before they start, and removed cleanly"
rm -rf /home/root/.[!.]* /home/root/* /tmp/webos-entware-job /tmp/webos-entware.lock /tmp/ts-* /tmp/fb-users /tmp/fb.log /tmp/st.log /tmp/smbpasswd.log
run install -y
jq_ok() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($1) else 1)" "$W/out"; }
pw_of() { sed -n 's/^password=//p' "/opt/etc/webos-entware/credentials/$1"; }
ok "the boot script gives Entware's services a PATH, and a session of their own" 'grep -q "export PATH HOME" /var/lib/webosbrew/init.d/S99entware && grep -q "then setsid /opt/etc/init.d/rc.unslung start; else" /var/lib/webosbrew/init.d/S99entware'
sed -i -e 's|^\( *\)if command -v setsid.*$|\1/opt/etc/init.d/rc.unslung start >/dev/null 2>\&1|' -e '/export PATH HOME/d' /var/lib/webosbrew/init.d/S99entware
run add filebrowser -y
ok "adding a service brings an older boot script up to date" 'grep -q "export PATH HOME" /var/lib/webosbrew/init.d/S99entware && grep -q "then setsid /opt/etc/init.d/rc.unslung start; else" /var/lib/webosbrew/init.d/S99entware && sh -n /var/lib/webosbrew/init.d/S99entware && grep -q "Updated the boot script" "$W/out"'
ok "add filebrowser sets it up on port 8090 for /opt/files, and starts it" 'grep -q "File Browser is at http://.*:8090" "$W/out" && grep -q "^# File Browser add-on (webos-entware-installer)" /opt/etc/filebrowser/filebrowser.conf && grep -q "ROOT=\"-r /opt/files\"" /opt/etc/filebrowser/filebrowser.conf && pidof filebrowser > /dev/null'
ok "it keeps the stock settings it replaced" 'grep -q 192.168.1.1 /opt/etc/filebrowser/filebrowser.conf.bak'
ok "with a new 16-character password, saved for root only" 'p=$(pw_of filebrowser) && [ ${#p} -eq 16 ] && grep -q "^admin $p" /tmp/fb-users && [ "$(stat -c %a /opt/etc/webos-entware/credentials/filebrowser)" = 600 ] && [ "$(stat -c %a /opt/etc/webos-entware/credentials)" = 700 ]'
ok "and makes the shared folders, with USB drives in USB" '[ -d /opt/files/Downloads/Watch ] && [ -d /opt/files/Media ] && [ "$(readlink /opt/files/USB)" = /tmp/usb ]'
FBPW=$(pw_of filebrowser)
run info filebrowser --json
ok "info --json gives its address and login" 'jq_ok "d[\"state\"] == \"installed\" and d[\"service\"] is True and d[\"url\"].endswith(\":8090\") and d[\"user\"] == \"admin\" and d[\"password\"] == \"$FBPW\""'
run add filebrowser -y
ok "adding it again keeps the password" '[ "$(pw_of filebrowser)" = "$FBPW" ] && grep -q "users update admin -p $FBPW" /tmp/fb.log'
pkill -x filebrowser; sleep 0.3
run addons --json
ok "a service that stopped needs setup again" 'jq_ok "[a for a in d if a[\"id\"] == \"filebrowser\"][0][\"state\"] == \"needsSetup\""'

run add samba -y
ok "add samba shares /opt/files with a password, and no guests" 'grep -q "Samba is sharing /opt/files" "$W/out" && grep -q "map to guest = Never" /opt/etc/samba/smb.conf && grep -q "restrict anonymous = 2" /opt/etc/samba/smb.conf && ! grep -q "guest ok" /opt/etc/samba/smb.conf && grep -q "path = /opt/files" /opt/etc/samba/smb.conf && pidof smbd > /dev/null && pidof wsdd2 > /dev/null'
ok "you sign in as tv, root's Samba user" 'grep -qx "root = tv" /opt/etc/samba/users.map && grep -q "^-s -a root $(pw_of samba)" /tmp/smbpasswd.log && grep -q "guest ok = yes" /opt/etc/samba/smb.conf.bak'

run add transmission -y
ok "add transmission turns on its password and saves to /opt/files/Downloads" 'grep -q "Transmission is at http://.*:9091" "$W/out" && grep -q "\"rpc-authentication-required\": true," /opt/etc/transmission/settings.json && grep -q "\"rpc-password\": \"$(pw_of transmission)\"," /opt/etc/transmission/settings.json && grep -q "\"rpc-username\": \"tv\"," /opt/etc/transmission/settings.json && grep -q "\"watch-dir-enabled\": true$" /opt/etc/transmission/settings.json && pidof transmission-daemon > /dev/null'
ok "and leaves its settings file valid JSON, for root only" 'python3 -c "import json; json.load(open(\"/opt/etc/transmission/settings.json\"))" && [ "$(stat -c %a /opt/etc/transmission/settings.json)" = 600 ]'

run add syncthing -y
ok "add syncthing gives it a home, a password (on stdin, not the command line) and no default folder" 'grep -q "Syncthing is at http://.*:8384" "$W/out" && grep -q "password=$(pw_of syncthing)>" /opt/etc/syncthing/config.xml && ! grep -q "$(pw_of syncthing)" /tmp/st.log && grep -q "generate --home=/opt/etc/syncthing --gui-user=tv --gui-password=- .*STNODEFAULTFOLDER=1" /tmp/st.log'
ok "and runs it from its own start script instead of the package's" 'pidof syncthing > /dev/null && grep -q "serve --home=/opt/etc/syncthing --no-browser --no-upgrade --gui-address=http://0.0.0.0:8384" /tmp/st.log && [ -x /opt/etc/init.d/S91webos-syncthing ] && [ ! -x /opt/etc/init.d/S92syncthing ] && grep -q "^ENABLED=no" /opt/etc/init.d/S92syncthing'

run password filebrowser -y
ok "password makes a new one, sets it in the service and saves it" 'p=$(pw_of filebrowser) && [ "$p" != "$FBPW" ] && [ ${#p} -eq 16 ] && grep -q "users update admin -p $p" /tmp/fb.log && grep -q "Changed the password for File Browser" "$W/out" && pidof filebrowser > /dev/null'
printf 'Mine_pass#2026x\n' | run password transmission --stdin -y
ok "password --stdin takes your own, off the command line" '[ "$(pw_of transmission)" = "Mine_pass#2026x" ] && grep -q "\"rpc-password\": \"Mine_pass#2026x\"," /opt/etc/transmission/settings.json && pidof transmission-daemon > /dev/null'
! printf 'mine with spaces 1\n' | run password transmission --stdin -y
ok "a password with a space is refused, and nothing changes" 'grep -q "Use 12 to 64 characters" "$W/out" && [ "$(pw_of transmission)" = "Mine_pass#2026x" ]'
! printf -- '-starts-with-a-dash\n' | run password transmission --stdin -y
ok "and so is one starting with -" 'grep -q "not starting with -" "$W/out" && [ "$(pw_of transmission)" = "Mine_pass#2026x" ]'
cat > /tmp/pwx << 'P'
My$own&pass|"2026"\!
P
run password transmission --stdin -y < /tmp/pwx
ok "symbols are fine, even ones JSON and sed treat specially" 'python3 -c "import json,sys; d=json.load(open(\"/opt/etc/transmission/settings.json\")); sys.exit(0 if d[\"rpc-password\"] == open(\"/tmp/pwx\").read().strip() else 1)" && [ "$(pw_of transmission)" = "$(cat /tmp/pwx)" ]'
run password samba --stdin -y < /tmp/pwx
ok "Samba takes them too" 'grep -qF -- "-s -a root $(cat /tmp/pwx)" /tmp/smbpasswd.log'
rm -f /tmp/pwx
! printf 'short-1\n' | run password samba --stdin -y
ok "and so is a short one" 'grep -q "Use 12 to 64" "$W/out"'
! run password minidlna -y
ok "a service without a login has no password to change" 'grep -q "has no password" "$W/out"'
! run password tailscale -y
ok "and Tailscale's sign-in isn't a password either" 'grep -q "has no password" "$W/out"'

run add minidlna -y
ok "add minidlna serves /opt/files" 'grep -q "^media_dir=/opt/files$" /opt/etc/minidlna.conf && grep -q "^wide_links=yes" /opt/etc/minidlna.conf && pidof minidlnad > /dev/null'

run add tailscale -y
ok "add tailscale starts it and gives the sign-in link" 'grep -q "https://login.tailscale.com/a/fake123" "$W/out" && grep -q "up --accept-dns=false --netfilter-mode=off" /tmp/ts-up && pidof tailscaled > /dev/null'
run info tailscale --json
ok "until you sign in, it needs setup, and info has the link for a QR code" 'jq_ok "d[\"state\"] == \"needsSetup\" and d[\"url\"] == \"https://login.tailscale.com/a/fake123\""'
touch /tmp/ts-in
run info tailscale
ok "signed in, info shows the TV's tailnet address" 'grep -q "Connected to your tailnet as 100.101.102.103" "$W/out" && grep -q "ssh root@100.101.102.103" "$W/out"'
run addons --json
ok "and every service shows as running" 'jq_ok "all(a[\"state\"] == \"installed\" for a in d if a[\"service\"] and a[\"id\"] != \"filebrowser\")"'

run remove tailscale -y
ok "remove tailscale signs the TV out and deletes its state" 'grep -q logout /tmp/ts.log && ! pidof tailscaled > /dev/null && [ ! -e /opt/var/lib/tailscale ] && [ ! -f /opt/lib/opkg/info/tailscale.control ]'
echo hi > /opt/files/Media/movie.mkv
run remove samba -y
ok "remove samba stops it, deletes its settings and password, and keeps your files" '! pidof smbd > /dev/null && ! pidof wsdd2 > /dev/null && [ ! -e /opt/etc/samba/smb.conf ] && [ ! -e /opt/etc/samba/smbpasswd ] && [ ! -e /opt/etc/webos-entware/credentials/samba ] && [ -f /opt/files/Media/movie.mkv ] && grep -q "files in /opt/files are kept" "$W/out"'
run remove transmission -y
ok "remove transmission deletes its settings, which hold the password" '! pidof transmission-daemon > /dev/null && [ ! -e /opt/etc/transmission/settings.json ]'
run remove syncthing -y; run remove minidlna -y; run remove filebrowser -y
ok "remove syncthing, minidlna and filebrowser clean up too" '! pidof syncthing > /dev/null && ! pidof minidlnad > /dev/null && [ ! -e /opt/etc/init.d/S91webos-syncthing ] && [ ! -e /opt/etc/syncthing ] && [ ! -e /opt/etc/filebrowser/filebrowser.db ] && [ -z "$(ls /opt/etc/webos-entware/credentials)" ]'

python3 -c "
import socket, time, os
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind((\"0.0.0.0\", 8090)); s.listen(1)
open(\"/tmp/listener.pid\", \"w\").write(str(os.getpid())); time.sleep(30)" &
for _ in $(seq 1 20); do [ -s /tmp/listener.pid ] && break; sleep 0.1; done
/opt/bin/opkg install filebrowser > /dev/null
! run add filebrowser -y
ok "a service won't start when something else has its port" 'grep -q "already uses port 8090" "$W/out" && ! pidof filebrowser > /dev/null'
kill "$(cat /tmp/listener.pid)"; rm -f /tmp/listener.pid
run remove filebrowser -y

touch /run/fail-smbpasswd
! run add samba -y
rm -f /run/fail-smbpasswd
ok "if a setup fails, the service is stopped and kept from starting at boot" 'grep -q "Couldn.t set Samba.s password" "$W/out" && ! pidof smbd > /dev/null && [ ! -x /opt/etc/init.d/S91smb ] && [ ! -x /opt/etc/init.d/S99wsdd2 ]'
run add samba -y
ok "and adding it again turns it back on" '[ -x /opt/etc/init.d/S91smb ] && pidof smbd > /dev/null'
run remove samba -y
/opt/bin/opkg install transmission-daemon > /dev/null
run post-install transmission-daemon
ok "installed on its own, a service waits to be set up with a password" '[ ! -x /opt/etc/init.d/S88transmission ] && grep -q "won.t start until it.s set up with a password: webos-entware add transmission" "$W/out"'
/opt/bin/opkg remove transmission-daemon > /dev/null

/opt/bin/opkg install htop > /dev/null
run add htop -y
ok "an add-on that's already installed isn't downloaded again" 'grep -q "htop already installed. Checking its setup" "$W/out" && grep -q "Added htop" "$W/out"'
/opt/bin/opkg install ripgrep > /dev/null
run add find -y
ok "and only the missing packages of one are" 'grep -q "Already installed: ripgrep. Installing: fd fzf" "$W/out"'
run remove find -y
run addons --json
ok "addons --json says when webOS already has a command, and which have a password" 'jq_ok "d[[a[\"id\"] for a in d].index(\"python\")][\"system\"] == \"$(PATH=/usr/sbin:/usr/bin:/sbin:/bin; command -v python3)\" and d[[a[\"id\"] for a in d].index(\"htop\")][\"system\"] == \"$(PATH=/usr/sbin:/usr/bin:/sbin:/bin; command -v htop)\" and d[[a[\"id\"] for a in d].index(\"samba\")][\"password\"] is True"'

if [ -x "$W/bin/node" ]; then
    rm -rf /tmp/web; cp -R "$HERE/../webos-app/web" /tmp/web
    run web start --json
    ok "web start runs the phone dashboard and gives its address and code" 'jq_ok "d[\"running\"] is True and d[\"port\"] >= 8095 and len(d[\"code\"]) == 8 and d[\"url\"].startswith(\"http://\")" && [ "$(stat -c %a /tmp/webos-entware-web)" = 700 ] && [ "$(stat -c %a /tmp/webos-entware-web/code)" = 600 ]'
    WPORT=$(cat /tmp/webos-entware-web/port) WCODE=$(cat /tmp/webos-entware-web/code)
    ok "signed in with the code, it lists the add-ons through the installer" 'python3 -c "
import json, sys, urllib.request
base = \"http://127.0.0.1:\" + sys.argv[1]
r = urllib.request.urlopen(urllib.request.Request(base + \"/api/login\", json.dumps({\"code\": sys.argv[2]}).encode(), {\"Content-Type\": \"application/json\"}))
tok = json.load(r)[\"token\"]
s = json.load(urllib.request.urlopen(urllib.request.Request(base + \"/api/state\", headers={\"X-Token\": tok})))
assert any(a[\"id\"] == \"samba\" for a in s[\"addons\"]), s
" "$WPORT" "$WCODE"'
    run web start --json
    ok "starting it again keeps the one that runs" '[ "$(cat /tmp/webos-entware-web/code)" = "$WCODE" ] && jq_ok "d[\"code\"] == \"$WCODE\""'
    run web stop
    ok "web stop stops it and forgets the code" '! [ -e /tmp/webos-entware-web ] && grep -q "Stopped the phone dashboard" "$W/out"'
    run web status --json
    ok "and status says it isn't running" 'jq_ok "d[\"running\"] is False"'
else
    echo "  (Node.js isn't installed, so the phone dashboard isn't started here)"
fi

run add find -y
ok "add find puts fd on the PATH" '[ "$(readlink /opt/bin/fd)" = /opt/usr/bin/fd ] && grep -q "Added Search tools" "$W/out"'
run remove find -y
ok "and remove takes the link away" '[ ! -e /opt/bin/fd ] && [ ! -L /opt/bin/fd ]'
run add nettools -y
ok "a tool bundle installs every package in it" '[ -z "$(for p in iperf3 nmap tcpdump iftop bind-dig; do [ -f /opt/lib/opkg/info/$p.control ] || echo "$p"; done)" ]'
pkill -f /opt/lib/fake/ 2>/dev/null
run uninstall -y

echo "== [$SH] $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
