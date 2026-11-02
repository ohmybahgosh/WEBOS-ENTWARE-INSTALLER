#!/bin/sh

###############################################################################
# WebOS Minimal Entware Installer/Uninstaller                                 #
# Author: OhMyBahgosh                                                         #
# https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER                      #
###############################################################################
#
# Usage: sh webos-entware-installer.sh [install|uninstall|status|doctor] [options]
#        Run with no arguments for the menu, or with --help for options.

VERSION="2.8.0"

# === Color Codes ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Paths and URLs ===
BIND_SRC="/mnt/lg/user/opt"
HOME_DIR="/home/root"
INIT_SCRIPT="/var/lib/webosbrew/init.d/S99entware"
BOOT_LOG="/tmp/webos-entware-boot.log"
ENV_FILE="/opt/etc/webos-entware/bashrc"
INFO_FILE="/opt/etc/webos-entware/install.info"
MANAGER="/opt/bin/webos-entware"
UPDATEDB_CONF="/opt/etc/updatedb.conf"
UPDATEDB_WRAPPER="/opt/bin/updatedb-webos"
LOCATE_DB="/opt/var/mlocate/mlocate.db"
LOCATE_CRON="/opt/etc/cron.hourly/updatedb"
NANORC="/opt/etc/nanorc"
TV_HELPER="/opt/bin/webos-tv"
TV_COMMANDS="toast launch close apps applog tvshot"
CA_FILE="/opt/etc/ssl/certs/ca-certificates.crt"
ENTWARE_BASE="http://bin.entware.net"
SCRIPT_URL="https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh"
MARKER="webos-entware-installer"
BACKUP_SUFFIX=".pre-entware"
OS_INFO="/var/run/nyx/os_info.json"
HBC_DIR="/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service"
TELNET_OFF="/var/luna/preferences/webosbrew_telnet_disabled"
# Left by early versions of this installer and early manual setups
LEGACY_BOOT_LOG="/mnt/lg/user/entware_boot.log"
LEGACY_LIB="/mnt/lg/user/lib/opkg"
ASSUME_YES=0
SETUP_SHELL=1
WITH_LOCATE=0
JSON=0
LOCKED=0
# One install, repair or uninstall at a time, from SSH or the TV app
LOCK_DIR="/tmp/webos-entware.lock"
# Tasks the TV app starts in the background: name, pid, log, exit code
JOB_DIR="/tmp/webos-entware-job"
FORCE_ARCH=""
ROLLBACK=0
SNAPSHOT=0
NEW_BACKUPS=""

# Full path to this script, for saving a copy after we cd elsewhere
case "$0" in /*) SELF="$0" ;; *) SELF="$(pwd)/$0" ;; esac

# Entware ships its own libc, so webOS preload libraries must not leak into it
unset LD_PRELOAD LD_LIBRARY_PATH

# === Helper Functions ===
log() { printf '%b%s%b\n' "$1" "$2" "$NC"; }
error_exit() { log "$RED" "[ERROR] $1"; exit 1; }
success() { log "$GREEN" "[SUCCESS] $1"; }
warn() { log "$YELLOW" "[WARNING] $1"; }
info() { log "$CYAN" "[INFO] $1"; }
# Read one answer into ANSWER. Uses the terminal even when the script is
# piped in (wget -O- ... | sh), and fails when there is no terminal at all.
read_answer() {
    ANSWER=""
    printf '%b%s%b' "$YELLOW" "$1" "$NC"
    if [ -t 0 ]; then
        read -r ANSWER
    elif ( : < /dev/tty ) 2>/dev/null; then
        read -r ANSWER < /dev/tty
    else
        echo
        return 1
    fi
}
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    if ! read_answer "$1 [y/N]: "; then
        warn "No terminal to answer on. Add -y to answer yes."
        return 1
    fi
    [ "$ANSWER" = "y" ] || [ "$ANSWER" = "Y" ]
}

usage() {
    echo "WebOS Entware Installer v$VERSION"
    echo "Usage: sh webos-entware-installer.sh [install|uninstall|status|doctor|locate|upgrade|addons|add|remove] [options]"
    echo "  install        Install Entware, or repair an existing install (packages are kept)"
    echo "  uninstall      Remove Entware, its packages and the shell setup it added"
    echo "  status         Check the TV and the install, and say what to fix (alias: doctor)"
    echo "  locate         Set up locate/updatedb (mlocate) for webOS, with an hourly refresh"
    echo "  upgrade        Refresh the package list and upgrade every Entware package"
    echo "  addons         List the add-ons: packages with the setup they need on webOS"
    echo "  add <name>     Install an add-on (nano, locate, certs, git, python, htop, tmux, ...)"
    echo "  remove <name>  Uninstall an add-on"
    echo "  job <task>     Run install, uninstall, locate, upgrade, add <name> or remove <name>"
    echo "                 in the background (the TV app uses this)"
    echo "  job-status     Show the background task's progress"
    echo "Options:"
    echo "  -y, --yes      Don't ask; use the recommended build and answer yes"
    echo "  --no-shell     Install Entware only, leave .profile/.bashrc and the shell alone"
    echo "  --with-locate  Also set up locate (same as running locate after install)"
    echo "  --json         With status, addons or job-status: print JSON (the TV app reads this)"
    echo "  --arch=ARCH    Use aarch64-k3.10 (64-bit) or armv7sf-k3.2 (32-bit) without asking"
}

# True when /opt is our bind mount
# test -ef isn't in POSIX, but busybox sh (the TV) and dash both have it
# shellcheck disable=SC3013
opt_ours() { [ /opt -ef "$BIND_SRC" ]; }
opt_mounted() { grep -qs " /opt " /proc/mounts; }

# True when a file was written by this installer (any version)
is_ours() {
    grep -qs -e "^#.*$MARKER" -e "exec /opt/bin/bash -l" -e "^# Entware SSH Environment for WebOS" "$1"
}

# First free name based on $1: $1, then $1.1, $1.2... so an older backup
# is never overwritten
free_name() {
    b="$1" n=1
    while [ -e "$b" ] || [ -L "$b" ]; do
        b="$1.$n"
        n=$((n + 1))
    done
    echo "$b"
}
backup_name() { free_name "$1.bak"; }

# Write stdin to a shell file. Your own file is backed up first, and so is
# one of ours that changed since it was written (your edits, or an older
# version), so a repair never throws anything away. LAST_BACKUP is set to
# the backup it made, if any, and NEW_BACKUPS collects every backup this
# run made, so a rollback can remove them. Call it with a redirect, not in a
# pipeline, or those variables are lost in a subshell.
write_managed() {
    LAST_BACKUP=""
    if ! cat > "$1.entware-new"; then
        rm -f "$1.entware-new"
        warn "Couldn't write $1 (is the disk full?). It was left as it was."
        return 1
    fi
    if [ -f "$1" ] && cmp -s "$1.entware-new" "$1"; then
        rm -f "$1.entware-new"
        return 0
    fi
    if [ -f "$1" ] && ! is_ours "$1" && [ ! -e "$1$BACKUP_SUFFIX" ]; then
        LAST_BACKUP="$1$BACKUP_SUFFIX"
        cp -p "$1" "$LAST_BACKUP" && info "Backed up $1 to $LAST_BACKUP"
        NEW_BACKUPS="$NEW_BACKUPS $LAST_BACKUP"
    elif [ -f "$1" ]; then
        LAST_BACKUP=$(backup_name "$1")
        cp -p "$1" "$LAST_BACKUP" && info "Saved the old $1 as $LAST_BACKUP before updating it"
        NEW_BACKUPS="$NEW_BACKUPS $LAST_BACKUP"
    fi
    mv -f "$1.entware-new" "$1"
}

# ~/.bashrc as the installer writes it. Anything added below it is yours.
bashrc_template() {
    cat << 'BASHRC'
# Entware bash settings (webos-entware-installer)
# Add your own settings below. Repairing Entware keeps this file.
[ -f "$HOME/.bashrc.pre-entware" ] && . "$HOME/.bashrc.pre-entware"
[ -f /opt/etc/webos-entware/bashrc ] && . /opt/etc/webos-entware/bashrc
BASHRC
}

# True when ~/.bashrc has lines the installer didn't write
bashrc_edited() {
    bashrc_template > /tmp/.webos-entware-bashrc.$$
    grep -v '^#' "$1" | grep -vxF -f /tmp/.webos-entware-bashrc.$$ | grep -q '[^[:space:]]'
    set -- $?
    rm -f /tmp/.webos-entware-bashrc.$$
    return "$1"
}

# === Leftovers from older installers and early setups ===
# Lines that older versions of this installer wrote to ~/.bashrc and that
# the current environment file doesn't have word for word
legacy_bashrc_lines() {
    cat << 'LEGACY'
# Entware SSH Environment for WebOS
#eval "`dircolors`"
export PATH="/opt/bin:/opt/sbin:$PATH"
export LS_OPTIONS='--color=auto'
alias grep='grep --color=auto'
echo -e "${CYAN}Entware:${NC}      ${GREEN}entup entlist entfix entwrap help${NC}"
find . -iname "*$1*" 2>/dev/null | grep --color=auto "$1"
LEGACY
}

# Sorts the lines you added to a .bashrc from an older installer. One-line
# settings at the top level (alias, export, NAME=) go to $2: they can move
# to the new .bashrc as they are, below the line that loads the aliases, so
# yours still win. Anything else goes to $3, since it may only make sense
# next to the lines around it. Only lines an installer wrote word for word
# are left out.
legacy_custom_lines() {  # old_bashrc simple_out other_out
    known=/tmp/.webos-entware-known.$$
    { cat "$ENV_FILE" 2>/dev/null; legacy_bashrc_lines; } |
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$known"
    : > "$2"
    : > "$3"
    while IFS= read -r raw || [ -n "$raw" ]; do
        line=$(printf '%s\n' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$line" in ''|'#'*) continue ;; esac
        grep -qxF -- "$line" "$known" && continue
        name=""
        case "$raw" in
            [[:space:]]*) ;;
            *) name=$(printf '%s\n' "$line" | sed -n \
                -e 's/^alias[[:space:]][[:space:]]*\([^=[:space:]]*\)=.*/alias \1=/p' \
                -e 's/^export[[:space:]][[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)=.*/export \1=/p' \
                -e 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1=/p') ;;
        esac
        if [ -n "$name" ]; then
            printf '%s\n' "$line" >> "$2"
        else
            printf '%s\n' "$line" >> "$3"
        fi
    done < "$1"
    rm -f "$known"
}

# Boot scripts from older installers or manual setups that also mount
# Entware. Two scripts racing to mount /opt can stack mounts at boot.
old_boot_hooks() {
    for f in /var/lib/webosbrew/init.d/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        [ "$f" = "$INIT_SCRIPT" ] && continue
        # run-parts only runs names made of letters, digits, _ and -
        case "${f##*/}" in *[!A-Za-z0-9_-]*) continue ;; esac
        grep -qsi entware "$f" && grep -qsE '^[^#]*mount[[:space:]]' "$f" &&
            grep -qsE '^[^#]*/opt([/[:space:]"]|$)' "$f" && echo "$f"
    done
}

# True when a package list (plain or gzipped) is Entware's
entware_list() {
    if command -v zcat >/dev/null 2>&1 && zcat "$1" > /dev/null 2>&1; then
        zcat "$1" 2>/dev/null | grep -q '^Package: entware-opt$'
    else
        grep -qs '^Package: entware-opt$' "$1"
    fi
}

# Entware package lists in webOS's own opkg folders. They come from running
# Entware's opkg before /opt was set up, and webOS never reads them. Only
# lists that hold Entware's packages are picked, and only when webOS's own
# opkg setup has no feed named entware.
stray_opkg_files() {
    f=/var/lib/opkg/lists/entware
    if [ -f "$f" ] && entware_list "$f" &&
        ! grep -qs '^src.*[[:space:]]entware[[:space:]]' /etc/opkg.conf /etc/opkg/*.conf; then
        echo "$f"
    fi
    for f in /var/cache/opkg/*_Packages.gz; do
        [ -f "$f" ] && entware_list "$f" && echo "$f"
    done
}

# Everything legacy_cleanup tidies, one path per line
legacy_items() {
    old_boot_hooks
    stray_opkg_files
    [ -f "$LEGACY_BOOT_LOG" ] && echo "$LEGACY_BOOT_LOG"
    [ -d "$LEGACY_LIB" ] && [ -z "$(ls -A "$LEGACY_LIB" 2>/dev/null)" ] && echo "$LEGACY_LIB"
    return 0
}

# Old boot scripts are renamed, not deleted: run-parts skips names with a
# dot, so they stop running but you can still look at them
legacy_cleanup() {
    legacy_items | while IFS= read -r f; do
        case "$f" in
            /var/lib/webosbrew/init.d/*)
                old=$(free_name "$f.entware-old")
                mv "$f" "$old" &&
                    info "Turned off an old Entware boot script that also mounted /opt: $f (kept as $old)" ;;
            "$LEGACY_LIB")
                rmdir "$f" 2>/dev/null && info "Removed the empty folder $f left by an earlier setup" ;;
            *)
                rm -f "$f" && info "Removed $f, left by an earlier Entware setup" ;;
        esac
    done
}

# Links in your home folder that point into Entware, like ~/.nanorc
opt_links() {
    for f in "$HOME_DIR"/.[!.]* "$HOME_DIR"/*; do
        [ -L "$f" ] || continue
        case "$(readlink "$f")" in /opt/*|"$BIND_SRC"/*) echo "$f" ;; esac
    done
}

# Old copies of Entware installers in your home folder, for doctor to mention
old_installer_copies() {
    for f in "$HOME_DIR"/*.sh "$HOME_DIR"/*/*.sh; do
        [ -f "$f" ] || continue
        case "${f##*/}" in *[Ee]ntware*) echo "$f" ;; esac
    done
}

# === One task at a time ===
lock_pid() { cat "$LOCK_DIR/pid" 2>/dev/null; }
# Seconds since a file or folder last changed (large if unknown)
age_of() {
    t=$(date -r "$1" +%s 2>/dev/null)
    case "$t" in ''|*[!0-9]*) echo 999999 ;; *) echo $(( $(date +%s) - t )) ;; esac
}

# Install, repair, uninstall, locate and upgrade take this lock, so the TV
# app and an SSH session can never change things at the same time
take_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        lp=$(lock_pid)
        if [ "$lp" = "$$" ]; then
            # This process again, after uninstall restarted itself from /tmp
            LOCKED=1
            return 0
        fi
        if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then
            error_exit "Another install, repair or uninstall is running (process $lp). Wait for it to finish, then try again."
        fi
        if [ -z "$lp" ] && [ "$(age_of "$LOCK_DIR")" -lt 30 ]; then
            # Taken a moment ago; its owner hasn't written its pid yet
            error_exit "Another install, repair or uninstall is just starting. Try again in a moment."
        fi
        # Left by a task that was killed or a TV that rebooted
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR" 2>/dev/null || error_exit "Couldn't take the lock $LOCK_DIR."
    fi
    echo $$ > "$LOCK_DIR/pid"
    LOCKED=1
}
release_lock() {
    [ "$LOCKED" = 1 ] && [ "$(lock_pid)" = "$$" ] && rm -rf "$LOCK_DIR"
    LOCKED=0
}

# === JSON output, for the TV app ===
ESC=$(printf '\033')
# A JSON string: colors removed, quotes and backslashes escaped, line breaks as \n
json_str() {
    printf '"%s"' "$(printf '%s' "$1" | sed -e "s/$ESC\[[0-9;?]*[A-Za-z]//g" -e 's/\\/\\\\/g' -e 's/"/\\"/g' |
        tr '\t' ' ' | tr -d '\000-\010\013-\037' | awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }')"
}
json_bool() { if "$@" >/dev/null 2>&1; then printf true; else printf false; fi; }
# Lines on stdin as a JSON array of strings, in one pass (the app polls
# this every second, so it has to be cheap on a TV)
json_lines() {
    sed -e "s/$ESC\[[0-9;?]*[A-Za-z]//g" | tr '\t' ' ' | tr -d '\000-\010\013-\037' | awk '
        BEGIN { printf "[" }
        length($0) > 0 {
            gsub(/\\/, "\\\\")
            gsub(/"/, "\\\"")
            printf "%s\"%s\"", (n++ ? "," : ""), $0
        }
        END { printf "]" }'
}
json_num() { case "$1" in ''|*[!0-9]*) printf null ;; *) printf '%s' "$1" ;; esac; }

# === Background tasks, for the TV app ===
# The app starts a task and checks on it every second or so. It runs
# detached (setsid), so closing the app doesn't stop it halfway.
job_state() {
    if [ ! -f "$JOB_DIR/name" ]; then
        echo none
    elif [ -f "$JOB_DIR/exit" ]; then
        echo "done"
    else
        jp=$(cat "$JOB_DIR/pid" 2>/dev/null)
        lp=$(lock_pid)
        if [ -n "$jp" ] && kill -0 "$jp" 2>/dev/null; then
            echo running
        elif [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then
            echo running    # the task itself still holds the lock
        elif [ -z "$jp" ] && [ "$(age_of "$JOB_DIR/started")" -lt 10 ]; then
            echo running    # just started
        else
            echo lost       # stopped without finishing: killed, or the TV restarted
        fi
    fi
}

start_job() {
    case "$1" in
        install|uninstall|locate|upgrade) [ -z "${2:-}" ] || error_exit "$1 takes no name." ;;
        add|remove) addon_find "${2:-}" || error_exit "Unknown add-on: ${2:-none}. See: webos-entware addons" ;;
        *) error_exit "Unknown task: ${1:-none}. Use install, uninstall, locate, upgrade, add or remove." ;;
    esac
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    # Only one start at a time: two at once would share one log and exit code
    if ! mkdir "$JOB_DIR.start" 2>/dev/null; then
        [ "$(age_of "$JOB_DIR.start")" -lt 30 ] || { rm -rf "$JOB_DIR.start"; mkdir "$JOB_DIR.start" 2>/dev/null; } ||
            error_exit "Another task is starting. Try again in a moment."
        [ -d "$JOB_DIR.start" ] && [ "$(age_of "$JOB_DIR.start")" -lt 30 ] && [ ! -f "$JOB_DIR.start/mine" ] &&
            error_exit "Another task is starting. Try again in a moment."
    fi
    : > "$JOB_DIR.start/mine"
    trap 'rm -rf "$JOB_DIR.start"' EXIT
    [ "$(job_state)" = running ] && error_exit "Another task is running: $(cat "$JOB_DIR/name")."
    lp=$(lock_pid)
    if [ -n "$lp" ] && kill -0 "$lp" 2>/dev/null; then
        error_exit "An install, repair or uninstall is running from SSH (process $lp)."
    fi
    [ -f "$SELF" ] || error_exit "Can't find this script ($SELF) to run it in the background."
    rm -rf "$JOB_DIR"
    mkdir -p "$JOB_DIR"
    echo "$1${2:+ $2}" > "$JOB_DIR/name"
    date +%s > "$JOB_DIR/started"
    DETACH=""
    if command -v setsid >/dev/null 2>&1; then DETACH="setsid"
    elif command -v nohup >/dev/null 2>&1; then DETACH="nohup"
    fi
    # shellcheck disable=SC2016
    # $0 is this script, $1 the job folder, then the task and its name
    $DETACH sh -c 'trap "" HUP; d=$1; shift; echo $$ > "$d/pid"; sh "$0" "$@" -y; echo $? > "$d/exit"' \
        "$SELF" "$JOB_DIR" "$1" ${2:+"$2"} < /dev/null > "$JOB_DIR/log" 2>&1 &
    # Hold the start until the task has written its pid
    n=0
    while [ ! -s "$JOB_DIR/pid" ] && [ $n -lt 50 ]; do sleep 0.1 2>/dev/null || sleep 1; n=$((n + 1)); done
    echo "Started: $1${2:+ $2}. Follow it with: sh $SELF job-status"
}

job_status() {
    st=$(job_state)
    name=$(cat "$JOB_DIR/name" 2>/dev/null)
    code=$(cat "$JOB_DIR/exit" 2>/dev/null)
    if [ "$JSON" = 1 ]; then
        printf '{"state":%s,"name":%s,"exit":%s,"started":%s,"log":' "$(json_str "$st")" "$(json_str "$name")" \
            "$(json_num "$code")" "$(json_num "$(cat "$JOB_DIR/started" 2>/dev/null)")"
        tail -n 60 "$JOB_DIR/log" 2>/dev/null | json_lines
        printf '}\n'
        return 0
    fi
    case "$st" in
        none) echo "No task has run since the TV started." ;;
        running) echo "Running: $name"; tail -n 20 "$JOB_DIR/log" 2>/dev/null ;;
        done) echo "Finished: $name (exit code $code)"; tail -n 20 "$JOB_DIR/log" 2>/dev/null ;;
        lost) echo "Stopped before finishing: $name"; tail -n 20 "$JOB_DIR/log" 2>/dev/null ;;
    esac
}

# === Upgrade packages ===
upgrade_packages() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    info "Refreshing the package list..."
    /opt/bin/opkg update || error_exit "Couldn't refresh the package list. Check the TV's internet connection."
    /opt/bin/opkg list 2>/dev/null | awk '{print $1}' > /opt/tmp/entpkg-cache.txt
    UPGRADABLE=$(/opt/bin/opkg list-upgradable 2>/dev/null)
    if [ -z "$UPGRADABLE" ]; then
        success "Every package is up to date."
        return 0
    fi
    info "Upgrading:"
    echo "$UPGRADABLE"
    /opt/bin/opkg upgrade || error_exit "Some packages didn't upgrade. Run it again, or 'ent upgrade' to see why."
    ensure_ca
    success "Packages upgraded."
}

# How to run this installer again from a shell. The copy saved in Entware's
# folder works even after a reboot, when /opt isn't mounted and /tmp was
# wiped. When the script was piped in there's no file to point to.
run_cmd() {
    if [ -f "$BIND_SRC/bin/webos-entware" ]; then
        echo "sh $BIND_SRC/bin/webos-entware"
    elif [ -f "$SELF" ] && grep -qs "$MARKER" "$SELF"; then
        echo "sh $SELF"
    else
        echo "wget -O - $SCRIPT_URL | sh -s --"
    fi
}
fix_cmd() { echo "$(run_cmd) install"; }

# Unmount /opt, including a second mount stacked on top of ours
unmount_opt() {
    n=0
    while opt_ours && [ $n -lt 5 ]; do
        umount /opt 2>/dev/null || umount -l /opt 2>/dev/null || break
        n=$((n + 1))
    done
    ! opt_ours
}

opkg_works() { /opt/bin/opkg print-architecture 2>/dev/null | grep -q '^arch '; }

# === TV details ===
# Value of "key": "value" in a small JSON file or text (no jq on the TV)
json_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${2:--}" 2>/dev/null | head -n 1
}

# Run a command with a time limit when busybox timeout is there
limited() {
    if timeout 1 true >/dev/null 2>&1; then
        timeout 5 "$@"
    elif timeout -t 1 true >/dev/null 2>&1; then
        timeout -t 5 "$@"   # BusyBox before 1.30
    else
        "$@"
    fi
}

# Fills TV_MODEL, WEBOS_RELEASE, WEBOS_NAME, FIRMWARE, KERNEL_ARCH, KERNEL_BITS
tv_info() {
    [ -n "$KERNEL_ARCH" ] && return 0
    WEBOS_RELEASE=$(json_get webos_release "$OS_INFO")
    FIRMWARE=$(json_get webos_manufacturing_version "$OS_INFO")
    IMAGE=$(json_get webos_imagename "$OS_INFO")
    [ -n "$WEBOS_RELEASE" ] || WEBOS_RELEASE=$(limited nyx-cmd OSInfo query webos_release 2>/dev/null)
    [ -n "$WEBOS_RELEASE" ] || WEBOS_RELEASE=$(sed -n 's/^VERSION_ID=//p' /etc/os-release 2>/dev/null | tr -d '"')
    TV_MODEL=""
    if command -v luna-send >/dev/null 2>&1; then
        INFO=$(limited luna-send -n 1 -f luna://com.webos.service.tv.systemproperty/getSystemInfo \
            '{"keys":["modelName","firmwareVersion"]}' 2>/dev/null)
        TV_MODEL=$(echo "$INFO" | json_get modelName)
        [ -n "$FIRMWARE" ] || FIRMWARE=$(echo "$INFO" | json_get firmwareVersion)
    fi
    # LG's marketing names: 7.x is webOS 22, 8.x webOS 23, 9.x webOS 24, 10.x webOS 25
    case "$WEBOS_RELEASE" in
        [4-6].*) WEBOS_NAME="webOS ${WEBOS_RELEASE%%.*}" ;;
        [7-9].*|1[0-9].*) WEBOS_NAME="webOS $((${WEBOS_RELEASE%%.*} + 15))" ;;
        *) WEBOS_NAME="webOS" ;;
    esac
    KERNEL_ARCH=$(uname -m)
    case "$KERNEL_ARCH" in
        aarch64|arm64) KERNEL_BITS=64 ;;
        arm*) KERNEL_BITS=32 ;;
        *) KERNEL_BITS="" ;;
    esac
}

helpers_ok() { [ -x /opt/bin/entwrap ] && [ -f "$MANAGER" ]; }
hbc_present() { [ -d /var/lib/webosbrew ] || [ -d "$HBC_DIR" ]; }

print_tv() {
    tv_info
    echo "Model:              ${TV_MODEL:-unknown}"
    echo "webOS:              $WEBOS_NAME (${WEBOS_RELEASE:-unknown}), firmware ${FIRMWARE:-unknown}"
    echo "Kernel:             $KERNEL_ARCH${KERNEL_BITS:+ ($KERNEL_BITS-bit)}, $(uname -r)"
}

# === Pre-checks ===
preflight() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root. Root the TV first (see webosbrew.org/rooting)."
    [ -d "/mnt/lg/user" ] || error_exit "Not a webOS TV (missing /mnt/lg/user)."
    [ -d "/opt" ] || error_exit "This firmware has no /opt folder, so Entware can't be mounted."
    command -v wget >/dev/null 2>&1 || error_exit "wget is missing."

    print_tv
    case "$WEBOS_RELEASE" in
        ''|[0-3].*) warn "Couldn't confirm a supported webOS version. This installer is tested on webOS 23, 24 and 25." ;;
        [4-7].*) info "$WEBOS_NAME is older than the tested versions (webOS 23 to 25), but it should work." ;;
    esac
    [ -n "$KERNEL_BITS" ] || error_exit "Unsupported CPU type: $KERNEL_ARCH. Entware for webOS needs an ARM TV."

    if ! hbc_present; then
        warn "Homebrew Channel isn't installed, so there's no boot script to mount Entware after a reboot."
        [ "$SETUP_SHELL" = 1 ] && info "Your SSH logins will mount it instead."
        confirm "Continue without a boot script?" || exit 0
    fi

    if ! wget -q -O /dev/null "$ENTWARE_BASE/armv7sf-k3.2/installer/opkg.conf"; then
        error_exit "Can't reach $ENTWARE_BASE. Check the TV's internet connection and try again. Nothing was changed."
    fi
}

check_free_space() {
    SPACE=$(df -k /mnt/lg/user 2>/dev/null | tail -n 1 | awk '{print $(NF-2)}')
    case "$SPACE" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$SPACE" -lt 51200 ]; then
        warn "Low free space: ${SPACE}K (about 50 MB recommended)"
        confirm "Continue anyway?" || error_exit "Not enough space."
    fi
}

# === Mount /opt ===
mount_opt() {
    opt_ours && return 0
    opt_mounted && error_exit "/opt is already mounted from somewhere else. Reboot the TV and try again."
    mount --bind "$BIND_SRC" /opt || error_exit "Failed to bind $BIND_SRC to /opt"
}

# === Pick the Entware build ===
# webOS's own programs are 32-bit on every LG TV, but Entware brings its own
# libraries, so the kernel decides. 64-bit kernels (most recent OLEDs) can run
# the faster aarch64 build; 32-bit kernels (many budget and older models)
# need armv7.
build_label() {
    case "$1" in
        aarch64-k3.10) echo "64-bit (aarch64-k3.10)" ;;
        armv7sf-k3.2) echo "32-bit (armv7sf-k3.2)" ;;
        *) echo "${1:-unknown}" ;;
    esac
}
feed_build() { awk '/^src/ {n=split($3, a, "/"); print a[n]; exit}' "$1" 2>/dev/null; }

recommend_build() {
    tv_info
    if [ "$KERNEL_BITS" = 64 ]; then RECOMMENDED=aarch64-k3.10; else RECOMMENDED=armv7sf-k3.2; fi
}

# The build screen: what was detected, what's recommended and why
explain_build() {
    echo
    log "$CYAN" "Entware build check"
    echo "  TV:          ${TV_MODEL:-unknown model}, $WEBOS_NAME (${WEBOS_RELEASE:-unknown})"
    echo "  Kernel:      $KERNEL_ARCH ($KERNEL_BITS-bit)"
    case "$IMAGE" in lib32-*) echo "  webOS apps:  32-bit (normal, every LG TV ships them this way)" ;; esac
    echo
    log "$GREEN" "Recommended: $(build_label "$RECOMMENDED")"
    if [ "$KERNEL_BITS" = 64 ]; then
        echo "  Why: your kernel is 64-bit, so the faster 64-bit build can run here."
        echo "       It's quicker for heavy tools (one owner measured about 19% on a G4)."
        echo "  The other choice: the 32-bit build also works on this TV, just slower."
        echo "       Pick it only if the 64-bit build gives you trouble."
    else
        echo "  Why: your kernel is 32-bit, so the 64-bit build can't run here."
        echo "       That's normal on many LG TVs, mostly older and budget models."
        echo "  You don't lose much: both builds offer nearly the same packages."
    fi
    echo "  Entware brings its own libraries, so it follows the kernel, not the 32-bit webOS apps."
    echo "  Safety: the build is test-run on this TV before anything is kept."
    if [ "$KERNEL_BITS" = 64 ]; then
        echo "       If it can't run, the installer falls back to 32-bit or undoes everything."
    else
        echo "       If it can't run, everything is undone."
    fi
    echo
}

# Sets BUILD, and FALLBACK for when the recommended 64-bit build won't run
choose_build() {
    recommend_build
    explain_build
    FALLBACK=""
    if [ -n "$FORCE_ARCH" ]; then
        BUILD="$FORCE_ARCH"
        HOW=forced
        if [ "$BUILD" = "$RECOMMENDED" ]; then
            info "Using the $(build_label "$BUILD") build (--arch)."
        else
            warn "Using the $(build_label "$BUILD") build because --arch asked for it, not the recommended one."
        fi
        return 0
    fi

    BUILD="$RECOMMENDED" HOW=recommended
    [ "$KERNEL_BITS" = 64 ] && FALLBACK=armv7sf-k3.2
    if [ "$ASSUME_YES" = 1 ]; then
        info "Using the recommended build (-y)."
        return 0
    fi

    if [ "$KERNEL_BITS" = 64 ]; then
        PROMPT="[C]ontinue with 64-bit, [S]witch to 32-bit, or [E]xit: "
    else
        PROMPT="[C]ontinue with 32-bit, or [E]xit: "
    fi
    while :; do
        read_answer "$PROMPT" ||
            error_exit "No terminal to answer on. Add -y for the recommended build, or --arch=... to pick one. Nothing was changed."
        case "$ANSWER" in
            c|C) return 0 ;;
            s|S) if [ "$KERNEL_BITS" = 64 ]; then BUILD=armv7sf-k3.2 FALLBACK="" HOW=picked; return 0; fi ;;
            e|E) info "Exited. Nothing was changed."; exit 0 ;;
        esac
    done
}

# === Download opkg and test that it runs here ===
bootstrap_opkg() {
    if opkg_works; then
        info "Existing opkg works, keeping it."
        return 0
    fi

    for ARCH in $BUILD $FALLBACK; do
        info "Downloading and test-running the $(build_label "$ARCH") build..."
        wget -q -O /opt/bin/opkg "$ENTWARE_BASE/$ARCH/installer/opkg" &&
            wget -q -O /opt/etc/opkg.conf "$ENTWARE_BASE/$ARCH/installer/opkg.conf" ||
            error_exit "Could not download opkg. Check the TV's internet connection."
        chmod 755 /opt/bin/opkg
        if opkg_works; then
            grep -q '^option tmp_dir' /opt/etc/opkg.conf || echo "option tmp_dir /opt/tmp" >> /opt/etc/opkg.conf
            success "The $(build_label "$ARCH") build runs on this TV."
            [ "$ARCH" = "$BUILD" ] || HOW=fallback
            return 0
        fi
        warn "The $(build_label "$ARCH") build doesn't run on this TV."
        [ -n "$FALLBACK" ] && [ "$ARCH" = "$BUILD" ] && info "Trying the 32-bit build instead."
    done
    rm -f /opt/bin/opkg /opt/etc/opkg.conf
    if grep -qs " /mnt/lg/user .*noexec" /proc/mounts; then
        error_exit "/mnt/lg/user is mounted noexec on this firmware, so programs stored there can't run."
    fi
    error_exit "The Entware build didn't run on this TV. Try '$(fix_cmd)' again and pick the other build."
}

# === Fix "I have no name!" Bug ===
setup_identity_files() {
    for f in passwd group shells; do
        rm -f "/opt/etc/$f"
        if [ -f "/etc/$f" ]; then
            ln -s "/etc/$f" "/opt/etc/$f"
        elif [ -f "/opt/etc/$f.1" ]; then
            cp "/opt/etc/$f.1" "/opt/etc/$f"
        fi
    done
    [ -f /etc/localtime ] && ln -sf /etc/localtime /opt/etc/localtime
    success "Linked /opt/etc/passwd and /opt/etc/group to the system files."
}

# === Install the ent helper, a saved copy of this script, and tab completion ===
# ent is a separate command. opkg itself is never replaced or wrapped.
install_entwrap() {
    cat > /opt/bin/entwrap << 'ENTWRAP'
#!/bin/sh
# Entware helper for webOS (webos-entware-installer)
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

OPKG_BIN="/opt/bin/opkg"
CACHE="/opt/tmp/entpkg-cache.txt"
MANAGER="/opt/bin/webos-entware"
unset LD_PRELOAD LD_LIBRARY_PATH

print_usage() {
    printf '%b\n' "${CYAN}ent${NC} - Entware package helper for webOS (plain opkg works too)"
    printf '%b\n' "  ${GREEN}search${NC} <text>    Search available packages"
    printf '%b\n' "  ${GREEN}install${NC} <pkg>    Install packages, plus the webOS setup some need (nano, mlocate, HTTPS)"
    printf '%b\n' "  ${GREEN}remove${NC} <pkg>     Remove packages"
    printf '%b\n' "  ${GREEN}info${NC} <pkg>       Show package details"
    printf '%b\n' "  ${GREEN}files${NC} <pkg>      List the files a package installed"
    printf '%b\n' "  ${GREEN}owns${NC} <file|cmd>  Show which package a file or command came from"
    printf '%b\n' "  ${GREEN}du${NC} [count]       Largest installed packages, and free space"
    printf '%b\n' "  ${GREEN}update${NC}           Refresh the package list"
    printf '%b\n' "  ${GREEN}upgradable${NC}       Show packages with updates"
    printf '%b\n' "  ${GREEN}upgrade${NC}          Refresh the list and upgrade everything"
    printf '%b\n' "  ${GREEN}list${NC}             List installed packages"
    printf '%b\n' "  ${GREEN}repair${NC}           Reinstall the Entware core"
    printf '%b\n' "  ${GREEN}doctor${NC}           Check the TV and the install, and say what to fix"
    printf '%b\n' "  ${GREEN}help${NC}             Show this help"
    printf '%b\n' "  Anything else is passed straight to opkg, e.g. ent list-installed"
}

refresh_cache() { $OPKG_BIN list 2>/dev/null | awk '{print $1}' > "$CACHE"; }

# ent search: in a terminal, one block per package (name, version, whether
# it's installed, then the description wrapped to the screen and cut to two
# lines), with name matches first. Piped, plain "name - version - description"
# lines for scripts. ENT_FORMAT=pretty or plain overrides.
search_pkgs() {
    if [ -z "$1" ]; then
        printf '%b\n' "${RED}Name something to search for, e.g. ent search htop${NC}"
        exit 1
    fi
    matches=$($OPKG_BIN list 2>/dev/null | grep -iF -- "$1")
    fmt=${ENT_FORMAT:-}
    [ -n "$fmt" ] || { if [ -t 1 ]; then fmt=pretty; else fmt=plain; fi; }
    if [ "$fmt" = plain ]; then
        [ -n "$matches" ] && printf '%s\n' "$matches"
        return 0
    fi
    if [ -z "$matches" ]; then
        echo "No packages match \"$1\".  Try a shorter word, or run: ent update"
        return 0
    fi
    # An exported COLUMNS wins. Otherwise ask the terminal: webOS's busybox
    # stty can't report the size, but its tput can
    cols=${COLUMNS:-}
    case "$cols" in ''|*[!0-9]*) cols=$(tput cols 2>/dev/null) ;; esac
    case "$cols" in ''|*[!0-9]*) cols=$(stty size < /dev/tty 2>/dev/null | awk '{print $2}') ;; esac
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    [ "$cols" -lt 40 ] && cols=40
    [ "$cols" -gt 100 ] && cols=100
    ENT_INSTALLED=$($OPKG_BIN list-installed 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    export ENT_INSTALLED
    printf '%s\n' "$matches" | awk -v term="$1" -v width="$cols" '
        function wrap(s, w,    n, words, i, line, cand, out, e) {
            n = split(s, words, " "); line = ""; out = ""; e = 0
            for (i = 1; i <= n; i++) {
                cand = (line == "") ? words[i] : line " " words[i]
                if (length(cand) > w && line != "") {
                    if (e == 1) {
                        if (length(line) + 3 > w) line = substr(line, 1, w - 3)
                        return out "    " line "...\n"
                    }
                    out = out "    " line "\n"; e++; line = words[i]
                } else line = cand
            }
            return (line == "") ? out : out "    " line "\n"
        }
        BEGIN {
            n = split(ENVIRON["ENT_INSTALLED"], tmp, " ")
            for (i = 1; i <= n; i++) inst[tmp[i]] = 1
            lt = tolower(term)
        }
        {
            name = $1; rest = $0; sub(/^[^ ]+ - /, "", rest)
            ver = rest; desc = ""
            if (index(rest, " - ")) { sub(/ - .*/, "", ver); desc = rest; sub(/^[^ ]+ - /, "", desc) }
            gsub(/[ \t]+/, " ", desc)
            e = "\033[1;32m" name "\033[0m  \033[0;90m" ver "\033[0m"
            if (name in inst) { e = e "  \033[0;36m[installed]\033[0m"; ni++ }
            e = e "\n" (desc == "" ? "" : wrap(desc, width - 4))
            if (index(tolower(name), lt)) a[++na] = e; else b[++nb] = e
        }
        END {
            total = na + nb
            printf "\033[0;36m%d %s \"%s\"\033[0m", total, (total == 1 ? "package matches" : "packages match"), term
            if (ni) printf "  (%d installed)", ni
            printf "\n\n"
            for (i = 1; i <= na; i++) printf "%s\n", a[i]
            if (na && nb) printf "\033[0;90mAlso mentioned in the description:\033[0m\n\n"
            for (i = 1; i <= nb; i++) printf "%s\n", b[i]
            printf "\033[0;90mMore about one: ent info <name>\033[0m\n"
        }'
}
need_pkg() { [ -n "$1" ] || { printf '%b\n' "${RED}Name a package, e.g. ent $2 htop${NC}"; exit 1; }; }

case "$1" in
  search) shift; search_pkgs "$1" ;;
  install) shift; need_pkg "$1" install; $OPKG_BIN install "$@" || exit $?
    # Setup some packages need on webOS: nano's syntax colors, HTTPS
    # certificates for OpenSSL and Python, and locate (mlocate)
    [ -f "$MANAGER" ] && sh "$MANAGER" post-install "$@" ;;
  remove) shift; need_pkg "$1" remove; $OPKG_BIN remove "$@" ;;
  info) shift; need_pkg "$1" info; $OPKG_BIN info "$@" ;;
  files) shift; need_pkg "$1" files; $OPKG_BIN files "$@" ;;
  owns) shift
    [ -n "$1" ] || { printf '%b\n' "${RED}Name a file or command, e.g. ent owns nano${NC}"; exit 1; }
    for f in "$@"; do
        case "$f" in
            /*) p="$f" ;;
            */*) p="$(pwd)/$f" ;;
            *) p=$(command -v -- "$f" 2>/dev/null) || p="" ;;
        esac
        if [ -z "$p" ] || { [ ! -e "$p" ] && [ ! -L "$p" ]; }; then
            echo "$f: not found"
            continue
        fi
        # opkg records /opt paths, not the folder behind the bind mount
        p=$(printf '%s\n' "$p" | sed 's#^/mnt/lg/user/opt/#/opt/#')
        r=$(readlink -f "$p" 2>/dev/null | sed 's#^/mnt/lg/user/opt/#/opt/#')
        out=$({ $OPKG_BIN search "$p"; [ -n "$r" ] && [ "$r" != "$p" ] && $OPKG_BIN search "$r"; } 2>/dev/null | sort -u)
        if [ -n "$out" ]; then
            printf '%s: %s\n' "$f" "$(echo "$out" | awk '{print $1}' | tr '\n' ' ')"
        else
            case "${r:-$p}" in
                /opt/*) echo "$f: in Entware's folder but not from a package (${r:-$p})" ;;
                *) echo "$f: part of webOS, not Entware (${r:-$p})" ;;
            esac
        fi
    done ;;
  du) n=${2:-15}
    case "$n" in *[!0-9]*|'') n=15 ;; esac
    printf '%b\n' "${CYAN}Largest installed packages${NC}"
    for l in /opt/lib/opkg/info/*.list; do
        [ -f "$l" ] || continue
        kb=$(while IFS= read -r f; do [ -f "$f" ] && [ ! -L "$f" ] && printf '%s\n' "$f"; done < "$l" |
            tr '\n' '\0' | xargs -0 -r du -k 2>/dev/null | awk '{s+=$1} END {print s+0}')
        pkg=${l##*/}
        echo "$kb ${pkg%.list}"
    done | sort -rn | head -n "$n" | awk '{printf "  %7.1f MB  %s\n", $1/1024, $2}'
    echo
    printf 'Entware in total:  %s\n' "$(du -sh /mnt/lg/user/opt 2>/dev/null | awk '{print $1}')"
    printf 'Free on the data partition (shared with webOS): %s\n' \
        "$(df -h /mnt/lg/user 2>/dev/null | awk 'NR==2 {print $(NF-2)}')" ;;
  update) $OPKG_BIN update && refresh_cache ;;
  upgradable) $OPKG_BIN list-upgradable ;;
  upgrade) $OPKG_BIN update && refresh_cache && $OPKG_BIN upgrade ;;
  list) $OPKG_BIN list-installed ;;
  repair) $OPKG_BIN update && refresh_cache && $OPKG_BIN install entware-opt ;;
  doctor|status) [ -f "$MANAGER" ] || { echo "$MANAGER is missing. Run the installer's doctor instead."; exit 1; }
    exec sh "$MANAGER" status ;;
  help|-h|--help|"") print_usage ;;
  *) exec $OPKG_BIN "$@" ;;
esac
ENTWRAP

    chmod +x /opt/bin/entwrap
    ln -sf /opt/bin/entwrap /opt/bin/ent

    # Keep a copy of this script, since /tmp is wiped on reboot
    if [ -f "$SELF" ] && grep -qs "$MARKER" "$SELF"; then
        # shellcheck disable=SC3013  # busybox and dash have test -ef
        [ "$SELF" -ef "$MANAGER" ] || cp "$SELF" "$MANAGER"
        chmod 755 "$MANAGER"
    elif wget -q -O "$MANAGER.new" "$SCRIPT_URL" && grep -qs "$MARKER" "$MANAGER.new"; then
        # Piped in, so there's no file to copy: save the published version
        mv -f "$MANAGER.new" "$MANAGER"
        chmod 755 "$MANAGER"
    else
        rm -f "$MANAGER.new"
        [ -f "$MANAGER" ] || info "Couldn't save a copy of this installer. 'ent doctor' needs it: download it again to $MANAGER."
    fi

    mkdir -p /opt/etc/bash_completion.d
    cat > /opt/etc/bash_completion.d/entwrap << 'COMPLETION'
# Tab completion for ent, entwrap, opkg and webos-entware (webos-entware-installer)
_ent_available() { [ -f /opt/tmp/entpkg-cache.txt ] && cat /opt/tmp/entpkg-cache.txt; }
_ent_installed() { /opt/bin/opkg list-installed 2>/dev/null | awk '{print $1}'; }

_entwrap_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}" sub="${COMP_WORDS[1]}" words
    COMPREPLY=()
    if [ "$COMP_CWORD" -eq 1 ]; then
        if [ "${COMP_WORDS[0]##*/}" = opkg ]; then
            words="update upgrade install remove info files list list-installed list-upgradable search find print-architecture"
        else
            words="search install remove info files owns du update upgradable upgrade list repair doctor help"
        fi
    else
        case "$sub" in
            install|info|search) words=$(_ent_available) ;;
            remove|files|upgrade) words=$(_ent_installed) ;;
            *) return 0 ;;
        esac
    fi
    COMPREPLY=( $(compgen -W "$words" -- "$cur") )
}
_webos_entware_complete() {
    [ "$COMP_CWORD" -eq 1 ] && COMPREPLY=( $(compgen -W "install uninstall status doctor locate --help" -- "${COMP_WORDS[1]}") )
}
complete -F _entwrap_complete entwrap ent opkg
complete -F _webos_entware_complete webos-entware
# App IDs for launch, close and applog, from a list webos-tv apps keeps
_webos_tv_apps() {
    local cache=/tmp/.webos-tv-apps
    [ -s "$cache" ] || webos-tv apps --ids > "$cache" 2>/dev/null
    [ "$COMP_CWORD" -eq 1 ] && COMPREPLY=( $(compgen -W "$(cat "$cache" 2>/dev/null)" -- "${COMP_WORDS[1]}") )
}
complete -F _webos_tv_apps launch close applog
COMPLETION

    /opt/bin/opkg list 2>/dev/null | awk '{print $1}' > /opt/tmp/entpkg-cache.txt
    success "Installed the ent helper, tab completion and the webos-entware command."
}

# === Bash Profile & Environment ===
setup_shell_environment() {
    /opt/bin/opkg install bash || warn "bash may not have installed."
    /opt/bin/opkg install nano-full || warn "nano-full may not have installed."
    /opt/bin/opkg install coreutils-dircolors || warn "dircolors may not have installed."
    # GNU ls sizes its columns to fit; busybox ls pads every column to a
    # fixed width, which leaves wide gaps in ls -l
    /opt/bin/opkg install coreutils-ls || warn "GNU ls may not have installed. ls will use the busybox version."
    if ! /opt/bin/bash -c true >/dev/null 2>&1; then
        warn "bash didn't install or doesn't run, so your login shell was left as it was."
        return 0
    fi

    # Aliases and prompt live in /opt, so they go away with Entware
    mkdir -p "$(dirname "$ENV_FILE")"
    cat > "$ENV_FILE" << 'BASHRC'
# Entware bash environment for webOS (webos-entware-installer)
case ":$PATH:" in *:/opt/bin:*) ;; *) export PATH="/opt/bin:/opt/sbin:$PATH" ;; esac
export TERM=xterm-256color
LS_OPTIONS=''
ls --color=auto / >/dev/null 2>&1 && LS_OPTIONS='--color=auto'
export LS_OPTIONS
command -v dircolors >/dev/null 2>&1 && eval "`dircolors -b`"

alias ls='ls $LS_OPTIONS -tr'
alias ll='ls $LS_OPTIONS -l'
alias l='ls $LS_OPTIONS -lAatrh'
alias la='ls $LS_OPTIONS -lA'
alias lt='ls $LS_OPTIONS -ltr'
alias ..='cd ..'
alias ...='cd ../..'
alias myip='ip a'
alias netinfo='ip -4 address show; ip route show'
alias dfh='df -h'
alias up='uptime'
echo x | grep --color=auto x >/dev/null 2>&1 && alias grep='grep --color=auto'
alias edit='nano'
alias entup='entwrap update'
alias entlist='entwrap list'
alias entfix='entwrap repair'
alias reboot_safe='echo "Rebooting..."; sleep 2; reboot'
alias tr0='truncate -s0'

# Neon PS1
RED="\[\033[0;31m\]"
GRN="\[\033[0;32m\]"
YEL="\[\033[0;33m\]"
MAG="\[\033[0;35m\]"
RST="\[\033[0m\]"
PS1="${MAG}\u${RST}@${GRN}\h${RST}:${YEL}\w${RST}\$ "

# Tab completion
if [ -f /opt/etc/bash_completion.d/entwrap ]; then
    . /opt/etc/bash_completion.d/entwrap
fi

# locate: on webOS updatedb runs through a wrapper (see webos-entware locate)
[ -x /opt/bin/updatedb ] && [ -x /opt/bin/updatedb-webos ] && alias updatedb='updatedb-webos'

findf() {
    [ -z "$1" ] && echo "Usage: findf <pattern>" && return 1
    find . -iname "*$1*" 2>/dev/null | grep -i -- "$1"
}

helpme() {
    RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
    echo -e "${CYAN}== WebOS SSH Quick Commands ==${NC}"
    echo -e "${CYAN}Navigation:${NC}  ${GREEN}.. ...${NC}"
    echo -e "${CYAN}File Ops:${NC}     ${GREEN}ls ll la lt tr0${NC}"
    echo -e "${CYAN}Sys Info:${NC}     ${GREEN}myip netinfo dfh up${NC}"
    echo -e "${CYAN}Entware:${NC}      ${GREEN}ent help, ent search, ent install, ent doctor${NC}"
    echo -e "${CYAN}Manager:${NC}      ${GREEN}webos-entware status | install | uninstall | locate${NC}"
    echo -e "${CYAN}TV:${NC}           ${GREEN}toast launch close apps applog tvshot${NC} (webos-tv help)"
    echo -e "${CYAN}Utils:${NC}        ${GREEN}edit findf reboot_safe${NC}"
}
BASHRC

    mkdir -p "$HOME_DIR"

    # Keep a ~/.bashrc we already set up, so your edits survive a repair (issue #2)
    if is_ours "$HOME_DIR/.bashrc" && grep -qs "$ENV_FILE" "$HOME_DIR/.bashrc"; then
        info "Kept your $HOME_DIR/.bashrc as it is."
    else
        setup_bashrc
    fi

    # Login bash reads ~/.bash_profile before ~/.profile. The guard in
    # ~/.profile makes sourcing it from bash safe (see issue #1).
    write_managed "$HOME_DIR/.bash_profile" << 'PROFILE'
# Entware bash login (webos-entware-installer)
[ -f "$HOME/.profile" ] && . "$HOME/.profile"
[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"
PROFILE

    # Only switch interactive sh logins to bash, only once, and only if bash runs.
    write_managed "$HOME_DIR/.profile" << 'PROFILE'
# Entware shell setup (webos-entware-installer)
# Your own login settings, once per login: the guard stops a loop if they
# start bash themselves
if [ -z "$WEBOS_ENTWARE_PRE" ] && [ -f "$HOME/.profile.pre-entware" ]; then
    WEBOS_ENTWARE_PRE=1
    export WEBOS_ENTWARE_PRE
    . "$HOME/.profile.pre-entware"
fi
# If the boot script didn't mount Entware at this boot, do it now (issue #2)
if [ "$(id -u)" = 0 ] && [ -x /mnt/lg/user/opt/bin/opkg ] && ! grep -qs " /opt " /proc/mounts &&
    ! [ /opt -ef /mnt/lg/user/opt ]; then
    if mount --bind /mnt/lg/user/opt /opt 2>/dev/null; then
        echo "$(date '+%H:%M:%S') mounted /opt at login, the boot script hadn't" >> /tmp/webos-entware-boot.log
        if [ -x /opt/etc/init.d/rc.unslung ]; then
            (unset LD_PRELOAD LD_LIBRARY_PATH; /opt/etc/init.d/rc.unslung start </dev/null >/dev/null 2>&1 &)
        fi
    fi
fi
if [ -d /opt/bin ]; then
    case ":$PATH:" in *:/opt/bin:*) ;; *) PATH="/opt/bin:/opt/sbin:$PATH"; export PATH ;; esac
fi
case "$-" in
    *i*)
        if [ -z "$BASH_VERSION" ] && [ -x /opt/bin/bash ] && /opt/bin/bash -c true >/dev/null 2>&1; then
            exec /opt/bin/bash -l
        fi
        ;;
esac
PROFILE

    success "Bash profile and aliases configured."
}

# Writes ~/.bashrc. One from an older installer has the aliases in it; they
# now live in $ENV_FILE, and settings you added yourself are moved below the
# new lines so they keep working.
setup_bashrc() {
    rc="$HOME_DIR/.bashrc"
    simple=/tmp/.webos-entware-simple.$$
    other=/tmp/.webos-entware-other.$$
    : > "$simple"
    : > "$other"
    [ -f "$rc" ] && is_ours "$rc" && legacy_custom_lines "$rc" "$simple" "$other"
    {
        bashrc_template
        if [ -s "$simple" ]; then
            echo "# Carried over from your old .bashrc"
            cat "$simple"
        fi
    } > "$simple.rc"
    # Never write a .bashrc that bash can't read
    if [ -s "$simple" ] && ! /opt/bin/bash -n "$simple.rc" >/dev/null 2>&1; then
        bashrc_template > "$simple.rc"
        warn "The settings carried over from your old .bashrc didn't parse, so they were left out."
        cat "$simple" >> "$other"
        : > "$simple"
    fi
    write_managed "$rc" < "$simple.rc" || : > "$simple"
    [ -s "$simple" ] && info "Moved $(wc -l < "$simple" | tr -d ' ') of your own settings from the old .bashrc to the new one."
    if [ -s "$other" ]; then
        warn "Your old .bashrc had lines that weren't moved, because they may depend on the lines around them:"
        sed 's/^/    /' "$other"
        info "They're still in ${LAST_BACKUP:-the old file}. Copy any you want to the end of $rc."
    fi
    rm -f "$simple" "$other" "$simple.rc"
}

# === webOS helpers ===
# One script, webos-tv, with a link for each command: toast, launch, close,
# apps, applog and tvshot. They talk to webOS's own services with
# luna-send, so they only need root, not extra packages.
write_tv_helpers() {
    cat > "$TV_HELPER" << 'WEBOSTV'
#!/bin/sh
# webOS helpers (webos-entware-installer)
# Run as toast, launch, close, apps, applog or tvshot, or as
# webos-tv <command>. webos-tv help lists them.
PATH="/opt/bin:/opt/sbin:$PATH"
LOG="${WEBOS_TV_LOG:-/var/log/messages}"
SAM="luna://com.webos.applicationManager"

die() { echo "$*" >&2; exit 1; }
# luna-send reads stdin and returns nothing when that's a script, so it
# always gets /dev/null
luna() { luna-send -n 1 "$@" < /dev/null 2>&1; }
ok() { echo "$1" | grep -q '"returnValue": *true'; }
err() { echo "$1" | sed -n 's/.*"errorText": *"\([^"]*\)".*/\1/p' | head -n 1; }
# Text as a JSON string body
json_text() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\t' '  '; }
check_id() {
    [ -n "$1" ] || die "Name an app, e.g. $2 netflix. List them with: apps"
    case "$1" in *[!A-Za-z0-9._-]*) die "\"$1\" isn't a valid app ID. List them with: apps" ;; esac
}
command -v luna-send >/dev/null 2>&1 || die "luna-send wasn't found. These helpers only work on a webOS TV."

usage() {
    cat << 'USAGE'
webOS helpers
  toast <message>           Show a notification on the TV screen
  launch <app-id> [json]    Start an app (optional launch parameters as JSON)
  close <app-id>            Close an app
  apps [-a] [text]          List apps and their IDs (-a includes hidden ones)
  applog [app-id|text]      Follow the system log, optionally filtered
  tvshot [file.png|.jpg]    Screenshot what's on screen (default: /tmp)
Tab after launch, close or applog completes app IDs.
USAGE
}

cmd=${0##*/}
if [ "$cmd" = webos-tv ]; then
    cmd=$1
    [ $# -gt 0 ] && shift
fi

case "$cmd" in
toast)
    [ -n "$*" ] || die "Usage: toast <message>"
    r=$(luna -a webosbrew luna://com.webos.notification/createToast \
        "{\"sourceId\":\"webosbrew\",\"message\":\"$(json_text "$*")\"}")
    ok "$r" || die "The toast didn't show: $(err "$r")"
    ;;
launch)
    check_id "$1" launch
    params=""
    [ -n "$2" ] && params=",\"params\":$2"
    r=$(luna "$SAM/launch" "{\"id\":\"$1\"$params}")
    if ! ok "$r"; then
        case "$(err "$r")" in
            *"not exist"*) die "No app has the ID $1. List them with: apps" ;;
            *) die "$1 didn't start: $(err "$r")" ;;
        esac
    fi
    rm -f /tmp/.webos-tv-apps
    echo "Started $1"
    ;;
close)
    check_id "$1" close
    # closeByAppId works from a root shell; on webOS 25, close only accepts
    # requests from the app's own process. Older firmware may only have close.
    r=$(luna "$SAM/closeByAppId" "{\"id\":\"$1\"}")
    case "$(err "$r")" in
        *"nknown method"*|*"no such method"*|*"Unknown method"*) r=$(luna "$SAM/close" "{\"id\":\"$1\"}") ;;
    esac
    if ! ok "$r"; then
        case "$(err "$r")" in
            *"not running"*|*"no valid life handler"*|*"no app matched"*) die "$1 isn't running." ;;
            *) die "$1 didn't close: $(err "$r")" ;;
        esac
    fi
    echo "Closed $1"
    ;;
apps)
    all=0 ids=0 filter=""
    for a in "$@"; do
        case "$a" in
            -a|--all) all=1 ;;
            --ids) ids=1; all=1 ;;
            *) filter="$a" ;;
        esac
    done
    list=$(luna "$SAM/listApps" '{}')
    ok "$list" || die "Couldn't list apps: $(err "$list")"
    running=$(luna "$SAM/running" '{}' | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | tr '\n' ' ')
    if command -v node >/dev/null 2>&1; then
        # node comes with webOS and parses the app list properly
        rows=$(printf '%s' "$list" | ALL=$all node -e '
            let s = "";
            process.stdin.on("data", d => s += d).on("end", () => {
                for (const a of JSON.parse(s).apps || []) {
                    if (process.env.ALL !== "1" && a.visible === false) continue;
                    console.log([a.id, a.title || "", a.type || ""].join("\t"));
                }
            });' 2>/dev/null)
    else
        # No node: one app per line, then pick out the fields
        rows=$(printf '%s' "$list" | sed 's/},{"/}\n{"/g' | while IFS= read -r a || [ -n "$a" ]; do
            id=$(printf '%s' "$a" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
            [ -n "$id" ] || continue
            if [ "$all" != 1 ]; then
                case "$a" in *'"visible":false'*) continue ;; esac
            fi
            title=$(printf '%s' "$a" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
            type=$(printf '%s' "$a" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
            printf '%s\t%s\t%s\n' "$id" "$title" "$type"
        done)
    fi
    [ -n "$rows" ] || die "Couldn't read the app list."
    if [ "$ids" = 1 ]; then
        printf '%s\n' "$rows" | cut -f1 | sort -u
        exit 0
    fi
    printf '%s\n' "$rows" | sort -f | grep -i -- "${filter:-.}" |
        while IFS="$(printf '\t')" read -r id title type; do
            case " $running " in *" $id "*) mark="*" ;; *) mark=" " ;; esac
            printf '%s %-40s %-28s %s\n' "$mark" "$id" "$title" "$type"
        done
    echo "(* running)"
    ;;
applog)
    [ -r "$LOG" ] || die "The system log $LOG isn't there on this TV."
    # Run in the background and wait, so a stop from outside (timeout,
    # kill) also stops tail and grep, not just this script
    trap 'pkill -P $$ 2>/dev/null; kill $(jobs -p) 2>/dev/null; exit 130' INT TERM HUP
    if [ -n "$1" ]; then
        echo "Following $LOG for lines with \"$1\" (Ctrl+C to stop)..."
        tail -n 200 -F "$LOG" 2>/dev/null | grep --line-buffered -i -F -- "$1" &
    else
        echo "Following $LOG (Ctrl+C to stop)..."
        tail -n 20 -F "$LOG" &
    fi
    wait
    ;;
tvshot)
    out=${1:-/tmp/tvshot-$(date +%Y%m%d-%H%M%S).png}
    case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac
    case "$out" in *.jpg|*.jpeg|*.JPG) fmt=JPG ;; *) fmt=PNG ;; esac
    r=$(luna luna://com.webos.service.capture/executeOneShot \
        "{\"path\":\"$(json_text "$out")\",\"method\":\"DISPLAY\",\"width\":1920,\"height\":1080,\"format\":\"$fmt\"}")
    ok "$r" && [ -s "$out" ] || die "The screenshot failed: $(err "$r")"
    echo "Saved $out ($(du -k "$out" | awk '{print $1}') KB)"
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    echo "Copy it with: scp root@${ip:-<tv-ip>}:$out ."
    echo "Protected video (Netflix and other streaming apps) shows as black."
    ;;
help|-h|--help|"")
    usage
    ;;
*)
    usage
    exit 1
    ;;
esac
WEBOSTV
    chmod 755 "$TV_HELPER"
    for c in $TV_COMMANDS; do
        if [ -e "/opt/bin/$c" ] && [ "$(readlink "/opt/bin/$c")" != webos-tv ]; then
            info "Skipped the $c command: /opt/bin/$c already exists (use webos-tv $c)."
            continue
        fi
        ln -sf webos-tv "/opt/bin/$c"
    done
    success "Installed the webOS helpers: $TV_COMMANDS (webos-tv help)."
}

tv_helpers_ok() { [ -x "$TV_HELPER" ]; }

# Free space on the data partition, in KB (webOS shares it)
data_free_kb() {
    df -k /mnt/lg/user 2>/dev/null | tail -n 1 | awk '{print $(NF-2)}'
}

# === nano ===
# nano-full ships syntax highlighting for over 130 languages, but its stock
# nanorc has every line commented out, so nano starts with no colors.
nanorc_stock() { ! grep -qsvE '^[[:space:]]*(#|$)' "$NANORC"; }
nanorc_colors() { grep -qs '^[[:space:]]*include.*/opt/share/nano' "$NANORC"; }

setup_nanorc() {
    [ -x /opt/bin/nano ] || return 0
    if [ -f "$NANORC" ] && ! grep -qs "^#.*$MARKER" "$NANORC" && ! nanorc_stock; then
        info "Kept your own $NANORC."
        return 0
    fi
    cat > "$NANORC.entware-new" << 'NANORC'
# nano settings for webOS (webos-entware-installer)
# Repairing Entware rewrites this file. To keep your own settings, delete
# the line above and the installer will leave the file alone. Your own
# ~/.nanorc is read after this file, so settings there win.

# Line numbers, and the cursor position on the status bar
set linenumbers
set constantshow
# Reopen files where you left off, and remember searches
set positionlog
set historylog

# Other common settings, off by default:
# set mouse          (click to move the cursor; hold Shift to select text)
# set autoindent
# set tabsize 4
# set softwrap

# Syntax colors for every language nano-full ships
include "/opt/share/nano/*.nanorc"
include "/opt/share/nano/extra/*.nanorc"
NANORC
    mv -f "$NANORC.entware-new" "$NANORC"
    mkdir -p "$HOME_DIR/.local/share/nano"
    success "nano set up with syntax colors and line numbers ($NANORC)."
}

# === HTTPS certificates ===
# Programs built on Entware's OpenSSL (wget-ssl, git, openssl-util) and
# Python look for certificates in /opt/etc/ssl, which stays empty unless
# ca-bundle is installed. curl and others built on libcurl get it as a
# dependency; most others don't, so HTTPS fails with certificate errors.
pkg_installed() { [ -f "/opt/lib/opkg/info/$1.control" ]; }
needs_ca() {
    for p in libopenssl python3-light python3 libgnutls libmbedtls libwolfssl; do
        pkg_installed "$p" && return 0
    done
    return 1
}
ca_ok() { [ -s "$CA_FILE" ]; }

ensure_ca() {
    needs_ca || return 0
    ca_ok && return 0
    info "Installing ca-bundle, so HTTPS works in programs like wget-ssl, git and Python..."
    if /opt/bin/opkg install ca-bundle >/dev/null 2>&1 && ca_ok; then
        success "HTTPS certificates installed ($CA_FILE)."
    else
        warn "ca-bundle didn't install, so HTTPS may fail with certificate errors. Try: ent install ca-bundle"
    fi
}

# Run by ent install with the packages it just installed
post_install_action() {
    opt_ours || exit 0
    do_nano=0 do_locate=0
    for p in "$@"; do
        case "$p" in
            nano|nano-full|nano-plus) do_nano=1 ;;
            mlocate) do_locate=1 ;;
        esac
    done
    [ "$do_nano" = 1 ] && setup_nanorc
    ensure_ca
    [ "$do_locate" = 1 ] && locate_action
    return 0
}

# === locate (mlocate) ===
# Entware's mlocate doesn't work on webOS out of the box: it ships no
# settings, so updatedb would index every file two to four times (webOS
# mounts the same storage at several paths), and updatedb refuses to run
# without an "mlocate" group, which webOS doesn't have. This writes the
# settings, a wrapper that provides the group without touching system
# files, and an hourly cron job.
locate_installed() { [ -x /opt/bin/updatedb ] && [ -x /opt/bin/locate ]; }
locate_ready() { locate_installed && [ -x "$UPDATEDB_WRAPPER" ] && [ -f "$UPDATEDB_CONF" ]; }

write_updatedb_conf() {
    if [ -f "$UPDATEDB_CONF" ] && ! grep -qs "^#.*$MARKER" "$UPDATEDB_CONF"; then
        info "Kept your own $UPDATEDB_CONF."
        return 0
    fi
    cat > "$UPDATEDB_CONF" << 'UPDATEDB'
# updatedb settings for webOS (webos-entware-installer)
# Repairing Entware rewrites this file. To keep your own settings, delete
# the line above and the installer will leave the file alone.
#
# webOS mounts the same storage at several paths, so without these excludes
# locate would list most files two to four times. Each file is indexed under
# one path only:
#   data partition: /home, /var, /opt and /mnt/lg/user
#     (/mnt/lg/cmn_data and /mnt/lg/flash are the same partition again)
#   app store: /media (/mnt/lg/appstore is the same partition)
#   app database: /var/db (/mnt/lg/db8 is the same partition)
#   app jails (/var/palm/jail): each one re-mounts system folders for one app
#
# Bind mounts are kept on purpose, since /opt and /home are bind mounts.
PRUNE_BIND_MOUNTS = "no"

# Virtual and in-memory filesystems. tmpfs covers /tmp, /run and /dev/shm,
# and also USB drives, which webOS mounts under /tmp/usb
PRUNEFS = "proc sysfs devtmpfs devpts tmpfs ramfs cgroup cgroup2 debugfs tracefs configfs securityfs pstore bpf fusectl mqueue binfmt_misc autofs usbfs vfat exfat ntfs fuseblk nfs nfs4 cifs smbfs"

PRUNEPATHS = "/proc /sys /dev /run /tmp /var/tmp /var/volatile /var/run /var/lock /var/palm/jail /mnt/lg/cmn_data /mnt/lg/flash /mnt/lg/appstore /mnt/lg/db8 /mnt/lg/user/opt /mnt/lg/user/home /mnt/lg/user/var /opt/tmp /opt/var/mlocate"

PRUNENAMES = ".git .bzr .hg .svn"
UPDATEDB
}

write_updatedb_wrapper() {
    cat > "$UPDATEDB_WRAPPER" << 'WRAPPER'
#!/bin/sh
# updatedb for webOS (webos-entware-installer)
# mlocate's updatedb won't run without an "mlocate" group, and webOS's
# /etc/group has none. Rather than edit system files, the group is added
# only inside a private mount namespace while updatedb runs, so nothing on
# the system changes. Settings are in /opt/etc/updatedb.conf. Arguments are
# passed to updatedb.
unset LD_PRELOAD LD_LIBRARY_PATH
REAL=/opt/bin/updatedb
if [ ! -x "$REAL" ]; then
    [ -t 2 ] && echo "mlocate isn't installed. Install it with: ent install mlocate" >&2
    exit 0
fi
if grep -q '^mlocate:' /etc/group 2>/dev/null; then
    exec nice -n 19 "$REAL" "$@"
fi
if ! command -v unshare >/dev/null 2>&1; then
    echo "updatedb-webos: this firmware has no unshare, so updatedb can't be given its group." >&2
    exit 1
fi
# A group number /etc/group doesn't use
gid=475
while grep -q "^[^:]*:[^:]*:$gid:" /etc/group 2>/dev/null; do gid=$((gid + 1)); done
G=/opt/etc/updatedb.group
{ cat /etc/group; echo "mlocate:x:$gid:"; } > "$G.new" && mv -f "$G.new" "$G" || exit 1
PROP="--propagation private"
unshare -m $PROP true 2>/dev/null || PROP=""
exec unshare -m $PROP sh -c '
    mount --bind /opt/etc/updatedb.group /etc/group || exit 1
    exec nice -n 19 /opt/bin/updatedb "$@"' updatedb "$@"
WRAPPER
    chmod 755 "$UPDATEDB_WRAPPER"
}

# Hourly refresh with Entware's cron, which the boot script starts
setup_locate_cron() {
    if [ ! -x /opt/sbin/cron ]; then
        info "Installing cron for the hourly refresh..."
        if ! /opt/bin/opkg install cron; then
            warn "cron didn't install, so the database won't refresh on its own. Run updatedb when you need it."
            return 0
        fi
    fi
    # Entware's stock crontab runs /opt/bin/run-parts on these folders, but
    # the cron package only ships it as run-parts-vixie
    if [ ! -e /opt/bin/run-parts ] && [ -x /opt/bin/run-parts-vixie ]; then
        ln -s run-parts-vixie /opt/bin/run-parts
    fi
    mkdir -p /opt/etc/cron.1min /opt/etc/cron.5mins /opt/etc/cron.hourly \
        /opt/etc/cron.daily /opt/etc/cron.weekly /opt/etc/cron.monthly
    cat > "$LOCATE_CRON" << CRONJOB
#!/bin/sh
# Refreshes the locate database every hour (webos-entware-installer)
exec $UPDATEDB_WRAPPER
CRONJOB
    chmod 755 "$LOCATE_CRON"
    if [ -x /opt/etc/init.d/S10cron ]; then
        (unset LD_PRELOAD LD_LIBRARY_PATH; /opt/etc/init.d/S10cron start </dev/null >/dev/null 2>&1)
    fi
}

# Never stops an install: a problem here is only a warning
setup_locate() {
    if ! opt_ours; then
        warn "/opt isn't mounted, so locate can't be set up. Run '$(fix_cmd)' first."
        return 1
    fi
    if ! locate_installed; then
        info "Installing mlocate..."
        if ! /opt/bin/opkg install mlocate || ! locate_installed; then
            warn "mlocate didn't install, so locate wasn't set up."
            return 1
        fi
    fi
    write_updatedb_conf
    write_updatedb_wrapper
    setup_locate_cron
    if "$UPDATEDB_WRAPPER"; then
        success "locate is ready. The database refreshes every hour, or run updatedb (alias for updatedb-webos)."
    else
        warn "Building the locate database failed. Run $UPDATEDB_WRAPPER to see why."
        return 1
    fi
}

locate_action() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    setup_locate || exit 1
    [ "$SETUP_SHELL" = 1 ] && info "Log in again (or run: alias updatedb=updatedb-webos) to use plain updatedb."
    return 0
}

# === Add-ons ===
# Packages that are worth a button in the TV app, and the setup each one
# needs on webOS. The list is fixed here: the app only ever names an id
# from it, so nothing it sends reaches opkg as a package name.
#   id|title|packages|removable|about
addon_catalog() {
    cat << 'ADDONS'
nano|nano with syntax colors|nano-full|no|Colors for 130+ languages, line numbers, and it reopens files where you left off
locate|locate|mlocate|yes|Fast file search, with settings for webOS and an hourly refresh
certs|HTTPS certificates|ca-bundle|no|Lets wget-ssl, git, Python and others check HTTPS sites
git|git|git git-http|yes|With HTTPS support and certificates, so clone and pull just work
python|Python 3|python3 python3-pip|yes|With pip and HTTPS certificates (the largest add-on)
htop|htop|htop|yes|See what's using the CPU and memory, live
tmux|tmux|tmux|yes|Terminal sessions that keep running when SSH drops
ncdu|ncdu|ncdu|yes|Find what's filling up the disk
rsync|rsync|rsync|yes|Fast copies to and from the TV over SSH
curl|curl|curl|yes|Fetch URLs and test APIs from the shell
jq|jq|jq|yes|Read and filter JSON, like luna-send replies
ADDONS
}

# Sets AD_ID, AD_TITLE, AD_PKGS, AD_REMOVABLE and AD_ABOUT, or fails
addon_find() {
    case "$1" in ''|*[!a-z0-9]*) return 1 ;; esac
    line=$(addon_catalog | grep "^$1|") || return 1
    IFS='|' read -r AD_ID AD_TITLE AD_PKGS AD_REMOVABLE AD_ABOUT << EOL
$line
EOL
}

addon_installed() {
    for p in $AD_PKGS; do pkg_installed "$p" || return 1; done
}

# installed, needsSetup or notInstalled
addon_state() {
    addon_installed || { echo notInstalled; return; }
    case "$AD_ID" in
        nano) nanorc_colors || { echo needsSetup; return; } ;;
        locate) locate_ready || { echo needsSetup; return; } ;;
        certs) ca_ok || { echo needsSetup; return; } ;;
        git|python) ca_ok || { echo needsSetup; return; } ;;
    esac
    echo installed
}

addons_list() {
    if [ "$JSON" = 1 ]; then
        first=1
        printf '['
        addon_catalog | while IFS='|' read -r AD_ID AD_TITLE AD_PKGS AD_REMOVABLE AD_ABOUT; do
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"id":%s,"title":%s,"packages":%s,"about":%s,"removable":%s,"state":%s}' \
                "$(json_str "$AD_ID")" "$(json_str "$AD_TITLE")" "$(json_str "$AD_PKGS")" "$(json_str "$AD_ABOUT")" \
                "$( [ "$AD_REMOVABLE" = yes ] && echo true || echo false)" "$(json_str "$(addon_state)")"
        done
        printf ']\n'
        return 0
    fi
    log "$CYAN" "Add-ons (webos-entware add <name>, webos-entware remove <name>)"
    addon_catalog | while IFS='|' read -r AD_ID AD_TITLE AD_PKGS AD_REMOVABLE AD_ABOUT; do
        case "$(addon_state)" in
            installed) st="${GREEN}installed${NC}" ;;
            needsSetup) st="${YELLOW}needs setup${NC}" ;;
            *) st="not installed" ;;
        esac
        printf '  %-8s %b\n           %s\n' "$AD_ID" "$st" "$AD_ABOUT"
    done
}

addon_add() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    addon_find "$1" || error_exit "Unknown add-on: ${1:-none}. See: webos-entware addons"
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    info "Adding $AD_TITLE..."
    /opt/bin/opkg update >/dev/null 2>&1 || warn "Couldn't refresh the package list. Trying with the one already here."
    # shellcheck disable=SC2086  # a list of package names from the catalog
    /opt/bin/opkg install $AD_PKGS || error_exit "$AD_TITLE didn't install. Check the TV's internet connection and free space."
    case "$AD_ID" in
        nano) setup_nanorc ;;
        locate) setup_locate || exit 1 ;;
        certs) ca_ok || error_exit "ca-bundle installed, but $CA_FILE is missing." ;;
        git|python)
            if ! ca_ok; then
                /opt/bin/opkg install ca-bundle >/dev/null 2>&1 && ca_ok ||
                    warn "ca-bundle didn't install, so HTTPS may fail with certificate errors."
            fi ;;
    esac
    ensure_ca
    if [ "$AD_ID" = locate ]; then
        # setup_locate already said it's ready
        [ "$SETUP_SHELL" = 1 ] && info "Log in again to use plain updatedb."
        return 0
    fi
    success "$AD_TITLE is ready."
}

addon_remove() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    addon_find "$1" || error_exit "Unknown add-on: ${1:-none}. See: webos-entware addons"
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    [ "$AD_REMOVABLE" = yes ] || error_exit "$AD_TITLE is part of the base setup, so it stays. Remove it with ent remove if you really want to."
    addon_installed || { info "$AD_TITLE isn't installed."; return 0; }
    confirm "Remove $AD_TITLE ($AD_PKGS)?" || { info "Kept $AD_TITLE."; return 0; }
    # Dependents first (git-http before git): opkg won't remove a package
    # another one still needs. No --autoremove, so shared libraries and
    # ca-bundle, which other packages may rely on, stay.
    rev=""
    for p in $AD_PKGS; do rev="$p $rev"; done
    # shellcheck disable=SC2086
    /opt/bin/opkg remove $rev || error_exit "$AD_TITLE didn't uninstall cleanly. See: ent list"
    if [ "$AD_ID" = locate ]; then
        rm -f "$LOCATE_CRON" "$UPDATEDB_WRAPPER" "$LOCATE_DB" /opt/etc/updatedb.group
        if grep -qs "^#.*$MARKER" "$UPDATEDB_CONF"; then rm -f "$UPDATEDB_CONF"; fi
    fi
    success "Removed $AD_TITLE."
}

# === Mount Entware on every boot ===
install_boot_script() {
    if [ ! -d /var/lib/webosbrew ]; then
        warn "Homebrew Channel boot hooks not found, so there's no boot script."
        if is_ours "$HOME_DIR/.profile"; then
            info "/opt will be mounted when you log in over SSH instead."
        else
            warn "Run '$(fix_cmd)' again after each reboot to remount /opt."
        fi
        return 0
    fi
    mkdir -p "$(dirname "$INIT_SCRIPT")"
    cat > "$INIT_SCRIPT" << EOF
#!/bin/sh
# Mounts Entware at boot (webos-entware-installer)
# Notes what happened in $BOOT_LOG, which 'ent doctor' shows.
# Runs in the background so it never holds up the rest of the boot.
(
    note() { echo "\$(date '+%H:%M:%S') \$1" >> $BOOT_LOG; }
    note "boot script started"
    n=0
    while [ ! -x $BIND_SRC/bin/opkg ]; do
        if [ \$n -ge 30 ]; then
            note "gave up: $BIND_SRC/bin/opkg wasn't there after 60 seconds"
            exit 0
        fi
        sleep 2
        n=\$((n + 1))
    done
    if [ /opt -ef $BIND_SRC ]; then
        note "/opt was already mounted"
    elif mount --bind $BIND_SRC /opt 2>> $BOOT_LOG; then
        note "mounted /opt"
    else
        note "failed to mount /opt"
        exit 0
    fi
    if [ -x /opt/etc/init.d/rc.unslung ]; then
        unset LD_PRELOAD LD_LIBRARY_PATH
        /opt/etc/init.d/rc.unslung start >/dev/null 2>&1
        note "started Entware services"
    fi
) < /dev/null > /dev/null 2>&1 &
exit 0
EOF
    chmod 755 "$INIT_SCRIPT"
    success "Installed boot script $INIT_SCRIPT."
}

# Copies of the shell files as they were before a fresh install, so a
# rollback puts back exactly what was there (even files from an old setup)
snapshot_shell_files() {
    for f in .profile .bash_profile .bashrc; do
        p="${HOME_DIR:?}/$f"
        rm -f "${p:?}.entware-rollback"
        [ -f "$p" ] && cp -p "$p" "$p.entware-rollback"
    done
    SNAPSHOT=1
}
rollback_shell_files() {
    for f in .profile .bash_profile .bashrc; do
        p="${HOME_DIR:?}/$f"
        if [ -f "$p.entware-rollback" ]; then
            mv -f "$p.entware-rollback" "$p"
        else
            rm -f "${p:?}"
        fi
    done
    for b in $NEW_BACKUPS; do rm -f "${b:?}"; done
}
drop_snapshot() {
    for f in .profile .bash_profile .bashrc; do
        rm -f "${HOME_DIR:?}/${f:?}.entware-rollback"
    done
}

# === Install Entware ===
# Runs on any exit while installing: a fresh install that didn't finish is
# undone, so the TV is never left half set up
on_install_exit() {
    if [ "$ROLLBACK" = 1 ]; then
        ROLLBACK=0
        warn "The install didn't finish, so its changes are being undone."
        cd / || true
        rm -f "$INIT_SCRIPT"
        [ "$SNAPSHOT" = 1 ] && rollback_shell_files
        unmount_opt
        [ "$CREATED_SRC" = 1 ] && rm -rf "$BIND_SRC"
        info "Undone. The TV is back to how it was before the install."
    elif [ "$INSTALLING" = 1 ]; then
        INSTALLING=0
        warn "The repair didn't finish. Your existing install and packages were kept."
        info "Run '$(run_cmd) doctor' to see what needs fixing."
    fi
    release_lock
}

# Checks the result before calling the install done
verify_install() {
    opt_ours || error_exit "Check failed: /opt isn't mounted from $BIND_SRC."
    opkg_works || error_exit "Check failed: opkg doesn't run."
    [ -x /opt/etc/init.d/rc.unslung ] || warn "Check: entware-opt's startup script is missing. Run 'ent repair'."
    if hbc_present; then
        [ -x "$INIT_SCRIPT" ] && sh -n "$INIT_SCRIPT" ||
            error_exit "Check failed: the boot script $INIT_SCRIPT wasn't written correctly."
    fi
    if [ "$SETUP_SHELL" = 1 ] && is_ours "$HOME_DIR/.profile"; then
        /opt/bin/bash -c true >/dev/null 2>&1 || error_exit "Check failed: bash doesn't run."
    fi
    success "Checks passed: /opt is mounted, opkg runs$(hbc_present && echo ", the boot script is in place")."
}

# What was installed and why, for status and for bug reports
write_install_info() {
    tv_info
    OLD_HOW=$(sed -n 's/^build_choice=//p' "$INFO_FILE" 2>/dev/null)
    mkdir -p "$(dirname "$INFO_FILE")"
    cat > "$INFO_FILE" << EOF
installer_version=$VERSION
installed_on=$(date '+%Y-%m-%d %H:%M')
model=${TV_MODEL:-unknown}
webos_release=${WEBOS_RELEASE:-unknown}
firmware=${FIRMWARE:-unknown}
kernel=$KERNEL_ARCH $(uname -r)
build=$(feed_build /opt/etc/opkg.conf)
build_choice=${HOW:-${OLD_HOW:-unknown}}
EOF
}

install_entware() {
    preflight
    check_free_space

    BUILD="" FALLBACK=""
    if [ -e "$BIND_SRC/bin/opkg" ]; then
        BUILD=$(feed_build "$BIND_SRC/etc/opkg.conf")
        info "Entware is already installed in $BIND_SRC (build: $(build_label "$BUILD"))."
        if [ -n "$FORCE_ARCH" ] && [ -n "$BUILD" ] && [ "$BUILD" != "$FORCE_ARCH" ]; then
            error_exit "Entware is installed for $BUILD. Uninstall first to switch to $FORCE_ARCH."
        fi
        confirm "Repair and update it? Your packages are kept." || exit 0
        HOW=""
        [ -n "$BUILD" ] || choose_build
        INSTALLING=1
    else
        choose_build
        CREATED_SRC=0
        [ -e "$BIND_SRC" ] || CREATED_SRC=1
        snapshot_shell_files
        ROLLBACK=1
    fi
    trap on_install_exit EXIT
    trap 'exit 1' INT TERM HUP

    mkdir -p "$BIND_SRC/bin" "$BIND_SRC/etc" "$BIND_SRC/lib/opkg" "$BIND_SRC/tmp" "$BIND_SRC/var/lock"
    mount_opt
    cd /opt || error_exit "Cannot cd /opt"
    # Older versions replaced opkg with a wrapper; put the real one back
    [ -x /opt/bin/opkg.real ] && mv -f /opt/bin/opkg.real /opt/bin/opkg

    bootstrap_opkg
    /opt/bin/opkg update || error_exit "opkg update failed"
    /opt/bin/opkg install entware-opt || warn "entware-opt may have failed"
    chmod 777 /opt/tmp

    setup_identity_files
    install_entwrap
    write_tv_helpers
    if [ "$SETUP_SHELL" = 1 ]; then
        setup_shell_environment
    else
        info "Skipped the shell setup. Entware programs are in /opt/bin and /opt/sbin."
    fi
    install_boot_script
    setup_nanorc
    ensure_ca
    if [ "$WITH_LOCATE" = 1 ] || locate_installed; then
        setup_locate || true
    fi
    verify_install
    ROLLBACK=0 INSTALLING=0
    drop_snapshot
    legacy_cleanup
    write_install_info

    success "Entware installed successfully!"
    echo
    show_status
    echo
    [ "$SETUP_SHELL" = 1 ] && info "Disconnect and SSH in again to get the bash shell. Type 'helpme' for shortcuts."
    return 0
}

# === Uninstall ===
restore_shell_files() {
    for f in .profile .bash_profile .bashrc; do
        p="$HOME_DIR/$f"
        if [ "$f" = .bashrc ] && is_ours "$p" && bashrc_edited "$p"; then
            saved=$(free_name "$p.entware-saved")
            mv "$p" "$saved" && info "Your edited $p was saved as $saved"
        fi
        is_ours "$p" && rm -f "$p"
        if [ -f "$p$BACKUP_SUFFIX" ] && [ ! -e "$p" ]; then
            mv "$p$BACKUP_SUFFIX" "$p" && info "Restored your original $p"
        fi
    done
}

uninstall_entware() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    # Running from the saved copy in /opt: rerun from /tmp so /opt can be unmounted
    case "$SELF" in
        /opt/*|"$BIND_SRC"/*)
            YES=""; [ "$ASSUME_YES" = 1 ] && YES="-y"
            cp "$SELF" /tmp/webos-entware-uninstall.sh && exec sh /tmp/webos-entware-uninstall.sh uninstall $YES ;;
    esac
    warn "This removes Entware, every package installed with it, and the shell setup this installer added."
    confirm "Uninstall Entware?" || exit 0

    if opt_ours && [ -x /opt/etc/init.d/rc.unslung ]; then
        /opt/etc/init.d/rc.unslung stop >/dev/null 2>&1
    fi
    rm -f "$INIT_SCRIPT"
    restore_shell_files
    opt_links | while IFS= read -r f; do
        rm -f "$f" && info "Removed $f, a link into Entware"
    done
    legacy_cleanup

    cd /
    if ! unmount_opt; then
        warn "Couldn't unmount /opt, so $BIND_SRC was kept. Reboot the TV and run uninstall again to remove it."
    elif grep -qs " $BIND_SRC/" /proc/mounts; then
        warn "Something is still mounted inside $BIND_SRC, so it was kept to avoid deleting that. Unmount it, then run uninstall again."
    else
        rm -rf "${BIND_SRC:?}"
    fi

    [ "$SELF" = /tmp/webos-entware-uninstall.sh ] && rm -f "$SELF"
    success "Entware removed."
    info "Disconnect and SSH in again to get the stock shell back."
}

# === Status / doctor ===
show_status() {
    ISSUES="" NOTES=""
    issue() { ISSUES="$ISSUES
  - $1"; }
    note() { NOTES="$NOTES
  - $1"; }
    yesno() { if "$@" >/dev/null 2>&1; then log "$GREEN" "yes"; else log "$RED" "no"; fi; }

    log "$CYAN" "TV"
    print_tv
    recommend_build
    printf "Running as root:    "; yesno [ "$(id -u)" -eq 0 ]
    printf "Homebrew Channel:   "; yesno hbc_present
    printf "Telnet recovery:    "
    if [ -e "$TELNET_OFF" ]; then log "$YELLOW" "off"; else log "$GREEN" "on"; fi

    echo
    log "$CYAN" "Entware (installer v$VERSION)"
    if [ ! -e "$BIND_SRC/bin/opkg" ]; then
        echo "Installed:          no"
        echo "Recommended build:  $(build_label "$RECOMMENDED")"
        echo
        info "Entware isn't installed. Run '$(fix_cmd)'."
        return 0
    fi
    BUILD=$(feed_build "$BIND_SRC/etc/opkg.conf")
    echo "Installed build:    $(build_label "$BUILD")"
    CHOICE=$(sed -n 's/^build_choice=//p' "$BIND_SRC/etc/webos-entware/install.info" 2>/dev/null)
    [ -n "$CHOICE" ] && echo "How it was picked:  $CHOICE"
    echo "Recommended build:  $(build_label "$RECOMMENDED")"
    printf "/opt mounted:       "; yesno opt_ours
    printf "opkg runs:          "; yesno opkg_works
    if opkg_works; then
        echo "Packages installed: $(/opt/bin/opkg list-installed 2>/dev/null | wc -l)"
        echo "Disk used:          $(du -sh "$BIND_SRC" 2>/dev/null | awk '{print $1}')"
    fi
    printf "Boot script:        "; yesno [ -x "$INIT_SCRIPT" ]
    printf "Boot script log:    "
    if [ -s "$BOOT_LOG" ]; then tail -n 1 "$BOOT_LOG"; else echo "none this boot"; fi
    printf "bash runs:          "; yesno /opt/bin/bash -c true
    printf "Shell files set up: "; yesno is_ours "$HOME_DIR/.profile"
    printf "ent, webos-entware: "; yesno helpers_ok
    printf "webOS helpers:      "; yesno tv_helpers_ok
    FREE_KB=$(data_free_kb)
    case "$FREE_KB" in
        ''|*[!0-9]*) ;;
        *) printf "Free space:         "
           if [ "$FREE_KB" -lt 51200 ]; then log "$RED" "$((FREE_KB / 1024)) MB"; else echo "$((FREE_KB / 1024)) MB"; fi ;;
    esac
    printf "nano colors:        "
    if [ ! -x /opt/bin/nano ]; then
        echo "nano not installed"
    elif nanorc_colors; then
        log "$GREEN" "on"
    else
        log "$YELLOW" "off (your own $NANORC has no syntax includes)"
    fi
    printf "HTTPS certificates: "
    if ca_ok; then
        log "$GREEN" "yes"
    elif needs_ca; then
        log "$RED" "missing"
    else
        echo "not needed yet"
    fi
    printf "locate (mlocate):   "
    if ! locate_installed; then
        echo "not installed (optional: webos-entware locate)"
    elif ! locate_ready; then
        log "$RED" "installed, not set up"
    elif [ -f "$LOCATE_DB" ]; then
        log "$GREEN" "ready, database from $(date -r "$LOCATE_DB" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    else
        log "$YELLOW" "set up, database not built yet"
    fi

    [ "$(id -u)" -eq 0 ] || note "Run as root for a full check."
    if hbc_present; then :
    elif is_ours "$HOME_DIR/.profile"; then
        note "Homebrew Channel isn't installed, so /opt is mounted when you log in over SSH, not at boot."
    else
        issue "Homebrew Channel isn't installed, so /opt isn't mounted again after a reboot. Fix: install the Homebrew Channel, or install with the shell setup so SSH logins mount it."
    fi
    if opt_ours && grep -qs "at login" "$BOOT_LOG" && ! grep -qs "boot script started" "$BOOT_LOG"; then
        note "The boot script didn't run at this boot, so your SSH login mounted /opt instead. Entware works, but its services only start once you log in. If this happens after every reboot, please open an issue on GitHub with this output."
    fi
    LEFT=$(legacy_items | tr '\n' ' ')
    [ -n "$LEFT" ] && note "Leftovers from an earlier Entware setup were found: $LEFT. Install tidies them up: $(fix_cmd)"
    COPIES=$(old_installer_copies | tr '\n' ' ')
    [ -n "$COPIES" ] && note "Old installer copies you can delete if you don't need them: $COPIES"
    [ -e "$TELNET_OFF" ] && note "Telnet is off in Homebrew Channel settings. Turning it on gives you a way back in if SSH breaks."
    if ! opt_ours; then
        if grep -qs -e "mounted /opt" -e "/opt was already mounted" "$BOOT_LOG"; then
            issue "The boot script mounted /opt at boot, but this shell can't see it. Please report this on GitHub with this output. Fix for now: $(fix_cmd)"
        elif [ -s "$BOOT_LOG" ]; then
            issue "Entware is installed but /opt isn't mounted. The boot script ran but stopped: $(tail -n 1 "$BOOT_LOG"). Fix: $(fix_cmd)"
        elif [ -x "$INIT_SCRIPT" ]; then
            issue "Entware is installed but /opt isn't mounted, and the boot script didn't run at this boot, so the Homebrew Channel didn't run its boot scripts (failsafe mode, or its startup didn't run). Fix: $(fix_cmd)"
        else
            issue "Entware is installed but /opt isn't mounted. Fix: $(fix_cmd)"
        fi
    elif ! opkg_works; then
        issue "opkg doesn't run. Fix: $(fix_cmd), or uninstall and install again."
    fi
    if [ "$BUILD" = aarch64-k3.10 ] && [ "$KERNEL_BITS" = 32 ]; then
        issue "The 64-bit build can't run on this 32-bit kernel. Fix: uninstall, then install again."
    elif [ "$BUILD" = armv7sf-k3.2 ] && [ "$KERNEL_BITS" = 64 ]; then
        if grep -qs '^build_choice=fallback' "$BIND_SRC/etc/webos-entware/install.info"; then
            note "The 64-bit build didn't run on this TV during install, so the 32-bit one is in use. That's fine."
        else
            note "The 32-bit build works here, but the 64-bit build is faster. To switch: uninstall, then install with --arch=aarch64-k3.10."
        fi
    fi
    tv_helpers_ok || issue "The webOS helpers (toast, launch, apps...) are missing. Fix: $(fix_cmd)"
    case "$FREE_KB" in
        ''|*[!0-9]*) ;;
        *) [ "$FREE_KB" -lt 51200 ] &&
            issue "Only $((FREE_KB / 1024)) MB is free on the data partition, which webOS shares. Running out can cause problems with the TV itself. 'ent du' shows the largest packages to remove." ;;
    esac
    needs_ca && ! ca_ok &&
        issue "HTTPS certificates are missing, so wget-ssl, git and Python can't check HTTPS sites. Fix: ent install ca-bundle"
    [ -x /opt/bin/nano ] && nanorc_stock &&
        issue "nano has no settings, so it starts without syntax colors. Fix: $(fix_cmd)"
    locate_installed && ! locate_ready &&
        issue "mlocate is installed but not set up for webOS, so updatedb fails. Fix: $(run_cmd) locate"
    hbc_present && [ ! -x "$INIT_SCRIPT" ] &&
        issue "The boot script is missing, so /opt won't come back after a reboot. Fix: $(fix_cmd)"
    opt_ours && is_ours "$HOME_DIR/.profile" && ! /opt/bin/bash -c true >/dev/null 2>&1 &&
        issue "Your login is set to switch to bash, but bash doesn't run, so SSH stays on the stock shell. Fix: $(fix_cmd)"

    [ -n "$NOTES" ] && { echo; info "Notes:$NOTES"; }
    echo
    if [ -z "$ISSUES" ]; then
        success "Everything looks right."
        return 0
    fi
    warn "Things to fix:$ISSUES"
    return 1
}

# Everything doctor checks, as JSON for the TV app
status_json() {
    show_status > /dev/null 2>&1
    tv_info
    recommend_build
    installed=false build="" pkgs="" used=""
    if [ -e "$BIND_SRC/bin/opkg" ]; then
        installed=true
        build=$(feed_build "$BIND_SRC/etc/opkg.conf")
    fi
    if opkg_works; then
        pkgs=$(/opt/bin/opkg list-installed 2>/dev/null | wc -l | tr -d ' ')
        used=$(du -sh "$BIND_SRC" 2>/dev/null | awk '{print $1}')
    fi
    free_kb=$(data_free_kb)
    if [ ! -x /opt/bin/nano ]; then nano=none; elif nanorc_colors; then nano=on; else nano=off; fi
    if ca_ok; then certs=yes; elif needs_ca; then certs=missing; else certs=notNeeded; fi
    lockdb=""
    if ! locate_installed; then
        loc=notInstalled
    elif ! locate_ready; then
        loc=notSetUp
    elif [ -f "$LOCATE_DB" ]; then
        loc=ready
        lockdb=$(date -r "$LOCATE_DB" '+%Y-%m-%d %H:%M' 2>/dev/null)
    else
        loc=noDatabase
    fi
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    printf '{'
    printf '"version":%s,"model":%s,"webos":%s,"webosRelease":%s,"firmware":%s,' "$(json_str "$VERSION")" \
        "$(json_str "$TV_MODEL")" "$(json_str "$WEBOS_NAME")" "$(json_str "$WEBOS_RELEASE")" "$(json_str "$FIRMWARE")"
    printf '"kernel":%s,"kernelBits":%s,"ip":%s,' "$(json_str "$KERNEL_ARCH")" "$(json_num "$KERNEL_BITS")" "$(json_str "$ip")"
    printf '"root":%s,"homebrewChannel":%s,"telnet":%s,' "$(json_bool [ "$(id -u)" -eq 0 ])" "$(json_bool hbc_present)" \
        "$(json_bool [ ! -e "$TELNET_OFF" ])"
    printf '"installed":%s,"build":%s,"buildLabel":%s,"recommended":%s,' "$installed" "$(json_str "$build")" \
        "$(json_str "$(build_label "$build")")" "$(json_str "$RECOMMENDED")"
    printf '"mounted":%s,"opkg":%s,"packages":%s,"diskUsed":%s,"freeMB":%s,' "$(json_bool opt_ours)" "$(json_bool opkg_works)" \
        "$(json_num "$pkgs")" "$(json_str "$used")" "$(json_num "$(case "$free_kb" in ''|*[!0-9]*) ;; *) echo $((free_kb / 1024)) ;; esac)")"
    printf '"bootScript":%s,"bootLog":%s,"bash":%s,"shellFiles":%s,"helpers":%s,"tvHelpers":%s,' \
        "$(json_bool [ -x "$INIT_SCRIPT" ])" "$(json_str "$(tail -n 1 "$BOOT_LOG" 2>/dev/null)")" \
        "$(json_bool /opt/bin/bash -c true)" "$(json_bool is_ours "$HOME_DIR/.profile")" "$(json_bool helpers_ok)" \
        "$(json_bool tv_helpers_ok)"
    printf '"nano":%s,"certs":%s,"locate":%s,"locateDb":%s,' "$(json_str "$nano")" "$(json_str "$certs")" \
        "$(json_str "$loc")" "$(json_str "$lockdb")"
    printf '"job":%s,"jobName":%s,' "$(json_str "$(job_state)")" "$(json_str "$(cat "$JOB_DIR/name" 2>/dev/null)")"
    printf '"issues":'
    printf '%s\n' "$ISSUES" | sed -n 's/^  - //p' | json_lines
    printf ',"notes":'
    printf '%s\n' "$NOTES" | sed -n 's/^  - //p' | json_lines
    printf '}\n'
}

# === Arguments ===
ACTION=""
if [ "$1" = post-install ]; then
    shift
    post_install_action "$@"
    exit 0
fi
if [ "$1" = job ]; then
    [ $# -le 3 ] || error_exit "Too many arguments for job."
    start_job "${2:-}" "${3:-}"
    exit 0
fi
ADDON=""
if [ "$1" = add ] || [ "$1" = remove ]; then
    ACTION=$1
    ADDON=${2:-}
    [ -n "$ADDON" ] || error_exit "Name an add-on, e.g. webos-entware $1 htop. See: webos-entware addons"
    shift 2
fi
if [ "$1" = job-status ]; then
    [ "$2" = --json ] && JSON=1
    job_status
    exit 0
fi
for arg in "$@"; do
    case "$arg" in
        install|uninstall|status|locate|upgrade|addons|doctor|clean)
            # add and remove take only options after the name
            [ -z "$ADDON" ] || { usage; exit 1; }
            case "$arg" in doctor) ACTION="status" ;; clean) ACTION="uninstall" ;; *) ACTION="$arg" ;; esac ;;
        -y|--yes) ASSUME_YES=1 ;;
        --no-shell) SETUP_SHELL=0 ;;
        --with-locate) WITH_LOCATE=1 ;;
        --json) JSON=1 ;;
        --arch=aarch64-k3.10|--arch=armv7sf-k3.2) FORCE_ARCH="${arg#--arch=}" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# === Menu ===
if [ -z "$ACTION" ]; then
    # Piped in (wget -O- ... | sh), answers are read from the terminal instead
    if [ ! -t 0 ] && ! ( : < /dev/tty ) 2>/dev/null; then
        usage
        error_exit "No terminal for the menu. Pass install, uninstall or status, plus -y."
    fi
    echo
    log "$CYAN" "Minimal WebOS Entware Manager v$VERSION"
    echo "1) Install or repair Entware"
    echo "2) Uninstall Entware"
    echo "3) Check status (doctor)"
    echo "4) Set up locate (mlocate)"
    echo "5) Add-ons (nano colors, git, python, htop, ...)"
    echo "6) Exit"
    echo
    read_answer "Choose an option [1-6]: " || exit 1
    case "$ANSWER" in
        1) ACTION="install" ;;
        2) ACTION="uninstall" ;;
        3) ACTION="status" ;;
        4) ACTION="locate" ;;
        5) JSON=0; addons_list; echo
            read_answer "Add-on to install (blank to go back): " || exit 1
            [ -n "$ANSWER" ] || exit 0
            ACTION="add"; ADDON="$ANSWER" ;;
        *) log "$CYAN" "Goodbye!"; exit 0 ;;
    esac
fi

case "$ACTION" in
    install|uninstall|locate|upgrade|add|remove)
        take_lock
        trap 'release_lock' EXIT
        trap 'exit 1' INT TERM HUP ;;
esac

case "$ACTION" in
    install) install_entware ;;
    uninstall) uninstall_entware ;;
    status) if [ "$JSON" = 1 ]; then status_json; else show_status; fi ;;
    locate) locate_action ;;
    upgrade) upgrade_packages ;;
    addons) addons_list ;;
    add) addon_add "$ADDON" ;;
    remove) addon_remove "$ADDON" ;;
esac
