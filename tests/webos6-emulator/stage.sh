#!/bin/sh
# Runs as the first process on the TV's own system (webOS 6.5.3): stage 1
# installs Entware and an add-on, then restarts; stage 2 is the next boot:
# the boot script, an SSH-style login, status, then uninstall.
S=/mnt/lg/user/sim
export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/root
cd /home/root
say() { echo "SIM: $*"; echo "SIM: $*" >> $S/result.log; }
check() { if eval "$2" > /dev/null 2>&1; then say "PASS $1"; else say "FAIL $1"; fi; }
off() { sync; echo o > /proc/sysrq-trigger; sleep 5; }
I=$S/webos-entware-installer.sh
H=/var/lib/webos-entware/webos-entware-root
R=/tmp/.webos-entware-root
stage=$(cat $S/stage 2>/dev/null || echo 1)
# systemd doesn't run here, so a stand-in for the one systemctl call webOS's
# login profile makes: it answers, unless it's in a chroot (as systemctl
# does) and SYSTEMD_IGNORE_CHROOT isn't set
cat > $S/systemctl << 'SYSTEMCTL'
#!/bin/sh
[ "$1" = show-environment ] || exit 1
if [ "$(stat -c %d:%i /)" != "$(stat -c %d:%i /proc/1/root/.)" ] && [ -z "$SYSTEMD_IGNORE_CHROOT" ]; then
    echo "Running in chroot, ignoring request: show-environment" >&2; exit 0
fi
echo "LANG=en_US.UTF-8"
SYSTEMCTL
chmod 755 $S/systemctl && mount --bind $S/systemctl /bin/systemctl
say "stage $stage, $(cat /etc/starfish-release), kernel $(uname -r) $(uname -m)"
check "this firmware has no /opt" '[ ! -e /opt ]'
if [ "$stage" = 1 ]; then
    : > $S/result.log

    sh $I install -y > $S/install.log 2>&1
    tail -n 25 $S/install.log | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/  | /'
    check "install works" 'grep -q "Entware installed successfully" $S/install.log'
    check "Entware's own root is set up, a tmpfs in /tmp" 'grep -q " $R tmpfs " /proc/mounts'
    check "with Entware on its /opt" 'grep -q " $R/opt " /proc/mounts'
    check "the system still has no /opt" '[ ! -e /opt ]'
    check "app sandboxes aren't in it" '! grep -q "$R/var/palm/jail" /proc/mounts'
    check "the USB drive is in it" 'sh $H run cat /tmp/usb/sda/file.txt | grep -q hello'
    check "opkg runs in it" 'sh $H run /opt/bin/opkg --version | grep -q "opkg version"'
    sh $I add htop -y > $S/add.log 2>&1
    check "an add-on installs (htop, from bin.entware.net)" 'sh $H run /opt/bin/htop --version | grep -q htop'
    check "bash runs" 'sh $H run /opt/bin/bash -c "echo \$BASH_VERSION" | grep -q "^[45]\."'
    echo 2 > $S/stage
    say "restarting"
    off
fi
if [ "$stage" = 2 ]; then
    check "after a restart, the root is gone (it's in RAM)" '! grep -q " $R " /proc/mounts'
    # The Homebrew Channel runs its boot scripts
    for f in /var/lib/webosbrew/init.d/*; do sh "$f"; done
    n=0; while ! grep -qs "started Entware services" /tmp/webos-entware-boot.log && [ $n -lt 120 ]; do sleep 1; n=$((n + 1)); done
    sed 's/^/  | /' /tmp/webos-entware-boot.log
    check "the boot script sets it up again and starts Entware" 'grep -q "started Entware services" /tmp/webos-entware-boot.log && grep -q " $R/opt " /proc/mounts'
    printf 'echo "SHELL=$0 PATH=$PATH"; command -v opkg; htop --version; pwd; exit\n' | sh -l -i > $S/login.log 2>&1
    sed 's/^/  | /' $S/login.log
    check "an SSH login goes in, with bash and Entware on its PATH" 'grep -q "^/opt/bin/opkg" $S/login.log && grep -q "^htop" $S/login.log && grep -q "^/home/root$" $S/login.log'
    check "and doesn't list every variable (webOS's profile in a chroot)" '! grep -q "^export " $S/login.log'
    sh $I status > $S/status.log 2>&1
    sed 's/\x1b\[[0-9;]*m//g' $S/status.log | sed 's/^/  | /' | tail -n 30
    check "doctor sees no problems, and says why it's in its own root" 'grep -q "Everything looks right\|No problems" $S/status.log; grep -q "no /opt" $S/status.log'
    sh $I uninstall -y > $S/uninstall.log 2>&1
    tail -n 6 $S/uninstall.log | sed 's/\x1b\[[0-9;]*m//g' | sed 's/^/  | /'
    check "uninstall removes Entware and the helper" 'grep -q "Entware removed" $S/uninstall.log && [ ! -e /mnt/lg/appstore/entware ] && [ ! -e $H ] && [ ! -e /var/lib/webosbrew/init.d/S99entware ]'
    check "and takes Entware's own root apart, with nothing left in /tmp" '! grep -q "webos-entware-root" /proc/mounts && [ ! -e $R ] && [ ! -e $R.down ] && [ ! -e /var/lib/webos-entware ]'
    echo 3 > $S/stage
fi
say "done"
off
