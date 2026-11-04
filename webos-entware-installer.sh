#!/bin/sh

###############################################################################
# WebOS Minimal Entware Installer/Uninstaller                                 #
# Author: OhMyBahgosh                                                         #
# https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER                      #
###############################################################################
#
# Usage: sh webos-entware-installer.sh [install|uninstall|status|doctor] [options]
#        Run with no arguments for the menu, or with --help for options.

VERSION="2.13.2"

# === Color Codes ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Paths and URLs ===
# Where Entware lives: app storage (the default: bigger, and kept by "Reset
# to initial settings") or user data (shared with webOS, and where older
# versions put it). BIND_SRC is the one in use, worked out by resolve_src.
USER_SRC="/mnt/lg/user/opt"
APP_PART="/mnt/lg/appstore"
APP_SRC="$APP_PART/entware"
BIND_SRC="$USER_SRC"
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
BANNER_DIR="/opt/etc/webos-entware/banner"
NEOFETCH_BIN="/opt/bin/neofetch"
NEOFETCH_VER="7.1.0"
NEOFETCH_SHA="3dc33493e54029fb1528251552093a9f9a2894fcf94f9c3a6f809136a42348c7"
NEOFETCH_URL="https://raw.githubusercontent.com/dylanaraps/neofetch/$NEOFETCH_VER/neofetch"
ENTWARE_BASE="http://bin.entware.net"
SCRIPT_URL="https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh"
RELEASES_URL="https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/releases"
APP_ID="org.ohmybahgosh.entware"
APP_DIR="/media/developer/apps/usr/palm/applications/$APP_ID"
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
CHECK_ONLY=0
PW_FROM=random
LOCKED=0
# One install, repair or uninstall at a time, from SSH or the TV app
LOCK_DIR="/tmp/webos-entware.lock"
# Tasks the TV app starts in the background: name, pid, log, exit code
JOB_DIR="/tmp/webos-entware-job"
FORCE_ARCH=""
LOCATION=""
MOVE_TO=""
# A place you chose (install --location or move): repairs won't move it
LOC_CHOICE=""
PKG=""
TERM_ARG=""
LOG_ID=""
REFRESH=0
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
    echo "  upgrade [name] Refresh the package list and upgrade every package, or just the one named"
    echo "  updates        List packages with updates (--refresh downloads the package list first)"
    echo "  addons         List the add-ons: packages with the setup they need on webOS"
    echo "  add <name>     Install an add-on (git, python, tailscale, samba, filebrowser, ...)"
    echo "  remove <name>  Uninstall an add-on"
    echo "  info <name>    How to reach an add-on's service, and its password"
    echo "  password <name>  A new random password for a service; --ask to type your own,"
    echo "                 or --stdin to pipe one in"
    echo "  web [start|stop|status]  The phone dashboard: add-ons and passwords from a phone"
    echo "  installed      List installed packages, their size and what needs them"
    echo "  search <word>  Search Entware's packages (name matches first)"
    echo "  pkg-add <name> Install one Entware package, with its webOS setup"
    echo "  pkg-remove <name>  Uninstall one package (not ones Entware needs)"
    echo "  logs           The boot log and the TV app's recent tasks; log <name> shows one"
    echo "  move <place>   Move Entware to app storage (appstore) or back to user data (user)"
    echo "  app-update     Update the TV app (and this command) to the newest release;"
    echo "                 with --check, only say whether a newer one is out"
    echo "  job <task>     Run install, uninstall, locate, upgrade, add <name>, remove <name>,"
    echo "                 move <place> or app-update in the background (the TV app uses this)"
    echo "  job-status     Show the background task's progress"
    echo "Options:"
    echo "  -y, --yes      Don't ask; use the recommended build and answer yes"
    echo "  --no-shell     Install Entware only, leave .profile/.bashrc and the shell alone"
    echo "  --with-locate  Also set up locate (same as running locate after install)"
    echo "  --json         With status, addons, info or job-status: print JSON (the TV app reads this)"
    echo "  --location=L   Where a new install goes: appstore (app storage, the default: more"
    echo "                 space, and kept by Reset to initial settings) or user (user data)"
    echo "  --arch=ARCH    Use aarch64-k3.10 (64-bit) or armv7sf-k3.2 (32-bit) without asking"
}

# True when /opt is our bind mount
# test -ef isn't in POSIX, but busybox sh (the TV) and dash both have it
# shellcheck disable=SC3013
opt_ours() { [ /opt -ef "$BIND_SRC" ]; }

# === Where Entware lives ===
# The boot script names the folder (SRC=...), so that's the record of it
boot_src() { sed -n 's/^ *SRC=//p' "$INIT_SCRIPT" 2>/dev/null | head -n 1; }
# shellcheck disable=SC3013  # busybox and dash have test -ef
resolve_src() {
    if [ /opt -ef "$APP_SRC" ]; then
        BIND_SRC=$APP_SRC
    elif [ /opt -ef "$USER_SRC" ]; then
        BIND_SRC=$USER_SRC
    else
        case "$(boot_src)" in
            "$APP_SRC") BIND_SRC=$APP_SRC ;;
            "$USER_SRC") BIND_SRC=$USER_SRC ;;
            *) if [ -e "$APP_SRC/bin/opkg" ] && [ ! -e "$USER_SRC/bin/opkg" ]; then
                   BIND_SRC=$APP_SRC
               else
                   BIND_SRC=$USER_SRC
               fi ;;
        esac
    fi
}
loc_of() { if [ "$1" = "$APP_SRC" ]; then echo appstore; else echo user; fi; }
# user or appstore if you chose a place, auto if not
loc_choice() {
    c=$(sed -n 's/^location_choice=//p' "$BIND_SRC/etc/webos-entware/install.info" 2>/dev/null)
    echo "${c:-auto}"
}
app_mounted() { grep -qs " $APP_PART " /proc/mounts; }
# New installs go on app storage when it's there and has more room
appstore_default() {
    app_mounted || return 1
    a=$(free_kb_of "$APP_PART"); u=$(free_kb_of /mnt/lg/user)
    case "$a$u" in *[!0-9]*) return 1 ;; esac
    [ -n "$a" ] && [ -n "$u" ] && [ "$a" -gt "$u" ]
}
loc_label() { if [ "$1" = "$APP_SRC" ]; then echo "app storage"; else echo "user data"; fi; }
part_of() { if [ "$1" = "$APP_SRC" ]; then echo "$APP_PART"; else echo /mnt/lg/user; fi; }
free_kb_of() { df -k "$1" 2>/dev/null | tail -n 1 | awk '{print $(NF-2)}'; }

# The Entware folder must be root's alone: a real folder (not a link), owned
# by root, that no one else can write to. Its parent /mnt/lg/user can be
# written by any user on webOS, so otherwise a process that isn't root could
# swap in a folder of its own, and the boot script would run it as root.
# Prints the group and other write bits and the owner, e.g. "-- 0".
mode_owner() { ls -ldn "$1" 2>/dev/null | awk '{print substr($1, 6, 1) substr($1, 9, 1) " " $3}'; }
entry_safe() { [ ! -L "$1" ] && [ "$(mode_owner "$1")" = "-- 0" ]; }
src_safe() { [ -d "$1" ] && entry_safe "$1"; }
# Checking a folder by its path and then mounting it by path can be raced,
# since anyone can rename things in /mnt/lg/user. So what counts is checked
# on /opt itself after mounting, where it can't change: the folder, and
# everything on the way to what runs as root at boot.
OPT_KEY="/opt /opt/bin /opt/sbin /opt/etc /opt/etc/init.d /opt/lib /opt/bin/opkg /opt/etc/init.d/rc.unslung"
opt_trusted() {
    for k in $OPT_KEY; do
        [ -e "$k" ] || [ -L "$k" ] || continue
        entry_safe "$k" || return 1
    done
}
# Entware is root's alone: checked on /opt when it's mounted, else the folder
entware_safe() { if opt_ours; then opt_trusted; else src_safe "$BIND_SRC"; fi; }
# A folder's identity: its device and inode
dev_ino() { stat -c '%d %i' "$1" 2>/dev/null; }
# Deletes an Entware folder through a private mount of it, after making sure
# it's the folder meant: the one with identity $2, or with no $2, one that's
# root's alone with root's opkg in it. The path alone could have been
# swapped for some other folder, which root would then delete.
remove_tree() {
    rt=$(mktemp -d /tmp/.webos-entware-rm.XXXXXX) || return 1
    if ! mount --bind "$1" "$rt" 2>/dev/null; then
        rmdir "$rt"
        return 1
    fi
    if { [ -n "${2:-}" ] && [ "$(dev_ino "$rt")" = "$2" ]; } ||
        { [ -z "${2:-}" ] && src_safe "$rt" && entry_safe "$rt/bin/opkg"; }; then
        rm -rf "${rt:?}"/* "$rt"/.[!.]* "$rt"/..?* 2>/dev/null
        umount "$rt" && rmdir "$rt"
        rmdir "$1" 2>/dev/null    # by path: if it was swapped, an empty folder at most
        [ ! -e "$1" ]
        return
    fi
    umount "$rt" && rmdir "$rt"
    return 1
}
check_src() {
    [ -e "$BIND_SRC" ] || [ -L "$BIND_SRC" ] || return 0
    src_safe "$BIND_SRC" && return 0
    mo=$(mode_owner "$BIND_SRC")
    if [ -d "$BIND_SRC" ] && [ ! -L "$BIND_SRC" ] && [ "${mo#* }" = 0 ]; then
        chmod go-w "$BIND_SRC" || error_exit "Couldn't make $BIND_SRC writable by root only."
        warn "$BIND_SRC could be changed by other users. It's root's alone now."
        return 0
    fi
    error_exit "$BIND_SRC isn't a folder owned by root, so it may not be the Entware this installer set up, and it wasn't used. Look at what's in it, move it out of the way, then install again."
}
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
# KB to MB, or nothing when it isn't a number
mb_of() { case "$1" in ''|*[!0-9]*) ;; *) echo $(($1 / 1024)) ;; esac; }
# KB as words: "under 1 MB" or "25 MB"
size_text() { if [ "$1" -lt 1024 ]; then echo "under 1 MB"; else echo "$(($1 / 1024)) MB"; fi; }

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
        install|uninstall|locate|app-update) [ -z "${2:-}" ] || error_exit "$1 takes no name." ;;
        upgrade) [ -z "${2:-}" ] || pkg_name_ok "$2" || error_exit "That isn't a package name: $2" ;;
        add|remove|password) addon_find "${2:-}" || error_exit "Unknown add-on: ${2:-none}. See: webos-entware addons" ;;
        pkg-add|pkg-remove) pkg_name_ok "${2:-}" || error_exit "That isn't a package name: ${2:-none}" ;;
        move) case "${2:-}" in user|appstore) ;; *) error_exit "Move it where? Use: move appstore or move user." ;; esac ;;
        *) error_exit "Unknown task: ${1:-none}. Use install, uninstall, locate, upgrade, add, remove, password, pkg-add, pkg-remove, move or app-update." ;;
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
    # When it ends, its log is kept with the recent tasks (webos-entware logs)
    $DETACH sh -c 'trap "" HUP; d=$1; shift; echo $$ > "$d/pid"; sh "$0" "$@" -y; echo $? > "$d/exit"; sh "$0" job-archive >/dev/null 2>&1' \
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
# Package names as opkg writes them: nothing a shell would read as more
pkg_name_ok() { case "$1" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._+-]*) return 1 ;; esac; return 0; }
# The package list's age: when it was last refreshed from Entware's server
lists_file() { ls -t /opt/var/opkg-lists/* 2>/dev/null | head -n 1; }
lists_date() { f=$(lists_file); [ -n "$f" ] && date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null; }
lists_age_hours() { f=$(lists_file); [ -n "$f" ] && echo $(( $(age_of "$f") / 3600 )); }
# "name installed available" for each package with an update, from the
# package list on the TV (no download)
upgradable() { /opt/bin/opkg list-upgradable 2>/dev/null | awk -F ' - ' 'NF >= 3 && $1 !~ / / {print $1, $2, $3}'; }

# Lists packages with updates. --refresh downloads the package list first.
check_updates() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    opt_ours && opkg_works || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    if [ "$REFRESH" = 1 ]; then
        [ "$JSON" = 1 ] || info "Refreshing the package list..."
        if ! /opt/bin/opkg update > /dev/null 2>&1; then
            [ "$JSON" = 1 ] && REFRESH_FAILED=1 || warn "Couldn't reach Entware's server, so this is the list from $(lists_date)."
        fi
        /opt/bin/opkg list 2>/dev/null | awk '{print $1}' > /opt/tmp/entpkg-cache.txt
    fi
    UP=$(upgradable)
    if [ "$JSON" = 1 ]; then
        printf '{"checked":%s,"ageHours":%s,"refreshFailed":%s,"packages":[' "$(json_str "$(lists_date)")" \
            "$(json_num "$(lists_age_hours)")" "$( [ "${REFRESH_FAILED:-0}" = 1 ] && echo true || echo false)"
        first=1
        printf '%s\n' "$UP" | while read -r n i a; do
            [ -n "$n" ] || continue
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"name":%s,"installed":%s,"available":%s}' "$(json_str "$n")" "$(json_str "$i")" "$(json_str "$a")"
        done
        printf ']}\n'
        return 0
    fi
    if [ -z "$UP" ]; then
        success "Every package is up to date (package list from $(lists_date))."
        return 0
    fi
    log "$CYAN" "$(printf '%s\n' "$UP" | wc -l | tr -d ' ') package updates (package list from $(lists_date)):"
    printf '%s\n' "$UP" | awk '{printf "  %-28s %s -> %s\n", $1, $2, $3}'
    echo "Update them all: $(run_cmd) upgrade   One: $(run_cmd) upgrade <name>"
}

# upgrade: refresh the package list and upgrade everything.
# upgrade <name>: upgrade that one package, if it has an update.
upgrade_packages() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    if [ -n "$PKG" ]; then
        pkg_name_ok "$PKG" || error_exit "That isn't a package name: $PKG"
        line=$(upgradable | awk -v n="$PKG" '$1 == n')
        [ -n "$line" ] || error_exit "$PKG has no update (or isn't installed). See: $(run_cmd) updates"
        set -- $line
        info "Updating $PKG from $2 to $3..."
        /opt/bin/opkg upgrade "$PKG" || error_exit "$PKG didn't update. Run 'ent upgrade $PKG' to see why."
        ensure_ca
        [ "$PKG" = mlocate ] && locate_ready && write_updatedb_conf
        success "$PKG is now $3."
        return 0
    fi
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

# opkg runs.  --version doesn't wait for opkg's lock, so this holds while
# another opkg is busy (an update check, an install); print-architecture
# does, and also reads opkg.conf, so a new download is tested with that.
opkg_works() { /opt/bin/opkg --version 2>/dev/null | grep -q '^opkg version' || opkg_tested; }
opkg_tested() { /opt/bin/opkg print-architecture 2>/dev/null | grep -q '^arch '; }
# Installed packages, from opkg's status file, which needs no lock either
pkg_count() { n=$(grep -c '^Package:' "$OPKG_STATUS" 2>/dev/null); echo "${n:-0}"; }

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
            '{"keys":["modelName","firmwareVersion"]}' < /dev/null 2>/dev/null)
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
    if [ "$BIND_SRC" = "$APP_SRC" ] && ! grep -qs " $APP_PART " /proc/mounts; then
        error_exit "App storage ($APP_PART) isn't mounted on this TV, so Entware can't go there. Install without --location=appstore."
    fi
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
    SPACE=$(free_kb_of "$(part_of "$BIND_SRC")")
    case "$SPACE" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$SPACE" -lt 51200 ]; then
        warn "Low free space: ${SPACE}K (about 50 MB recommended)"
        confirm "Continue anyway?" || error_exit "Not enough space."
    fi
}

# === Mount /opt ===
mount_opt() {
    if ! opt_ours; then
        opt_mounted && error_exit "/opt is already mounted from somewhere else. Reboot the TV and try again."
        mount --bind "$BIND_SRC" /opt || error_exit "Failed to bind $BIND_SRC to /opt"
    fi
    if ! opt_trusted; then
        umount -l /opt 2>/dev/null
        error_exit "The Entware in $BIND_SRC isn't root's alone (a folder in it is a link, not owned by root, or others can write to it), so it wasn't used. Run: $(run_cmd) doctor"
    fi
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
        if opkg_tested; then
            grep -q '^option tmp_dir' /opt/etc/opkg.conf || echo "option tmp_dir /opt/tmp" >> /opt/etc/opkg.conf
            success "The $(build_label "$ARCH") build runs on this TV."
            [ "$ARCH" = "$BUILD" ] || HOW=fallback
            return 0
        fi
        warn "The $(build_label "$ARCH") build doesn't run on this TV."
        [ -n "$FALLBACK" ] && [ "$ARCH" = "$BUILD" ] && info "Trying the 32-bit build instead."
    done
    rm -f /opt/bin/opkg /opt/etc/opkg.conf
    if grep -qs " $(part_of "$BIND_SRC") .*noexec" /proc/mounts; then
        error_exit "$(part_of "$BIND_SRC") is mounted noexec on this firmware, so programs stored there can't run."
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
        p=$(printf '%s\n' "$p" | sed -e 's#^/mnt/lg/user/opt/#/opt/#' -e 's#^/mnt/lg/appstore/entware/#/opt/#')
        r=$(readlink -f "$p" 2>/dev/null | sed -e 's#^/mnt/lg/user/opt/#/opt/#' -e 's#^/mnt/lg/appstore/entware/#/opt/#')
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
    printf 'Entware in total:  %s\n' "$(du -sh /opt/ 2>/dev/null | awk '{print $1}')"
    printf 'Free where Entware lives: %s\n' "$(df -h /opt/ 2>/dev/null | awk 'NR==2 {print $(NF-2)}')"
    printf 'Free on user data (webOS needs some): %s\n' "$(df -h /mnt/lg/user 2>/dev/null | awk 'NR==2 {print $(NF-2)}')" ;;
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
    [ "$COMP_CWORD" -eq 1 ] && COMPREPLY=( $(compgen -W "install uninstall status doctor locate upgrade addons add remove info password web move app-update installed search pkg-add pkg-remove logs log --help" -- "${COMP_WORDS[1]}") )
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

# Entware on user data, where older versions put it: say at login that it
# can move to app storage, unless you chose user data or app storage has
# less room
if grep -qs '^location=user ' /opt/etc/webos-entware/install.info &&
    ! grep -qs '^location_choice=user$' /opt/etc/webos-entware/install.info &&
    grep -qs ' /mnt/lg/appstore ' /proc/mounts; then
    _ew_app=$(df -k /mnt/lg/appstore 2>/dev/null | awk 'NR==2 {print $(NF-2)}')
    _ew_usr=$(df -k /mnt/lg/user 2>/dev/null | awk 'NR==2 {print $(NF-2)}')
    if [ "${_ew_app:-0}" -gt "${_ew_usr:-0}" ] 2>/dev/null; then
        printf '\033[0;36m%s\033[0m\n' \
            "Entware is on user data, which webOS needs for itself. App storage has $((_ew_app / 1024)) MB free" \
            "and keeps Entware through \"Reset to initial settings\". Move it: webos-entware move appstore" \
            "(or keep it here and hide this: webos-entware move user)"
    fi
    unset _ew_app _ew_usr
fi

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

# Login banner add-on (webos-entware add banner): shown when you log in
# over SSH, not for commands, scp or sftp. Hide it with: touch ~/.hushlogin
if [ -f /opt/etc/webos-entware/banner/login.sh ] && [ ! -f "$HOME/.hushlogin" ]; then
    case "$-" in *i*) shopt -q login_shell 2>/dev/null && . /opt/etc/webos-entware/banner/login.sh ;; esac
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

    write_login_profile

    success "Bash profile and aliases configured."
}

# ~/.profile: only switches interactive sh logins to bash, only once, and
# only if bash runs. Also mounts Entware at login if the boot script didn't.
write_login_profile() {
    gen="$HOME_DIR/.profile.entware-gen"
    { printf '# Entware shell setup (webos-entware-installer)\n# Where Entware lives, for mounting it at login\nENTWARE_SRC=%s\n' "$BIND_SRC"
      cat << 'PROFILE'
# Your own login settings, once per login: the guard stops a loop if they
# start bash themselves
if [ -z "$WEBOS_ENTWARE_PRE" ] && [ -f "$HOME/.profile.pre-entware" ]; then
    WEBOS_ENTWARE_PRE=1
    export WEBOS_ENTWARE_PRE
    . "$HOME/.profile.pre-entware"
fi
# If the boot script didn't mount Entware at this boot, do it now (issue #2).
# Where it lives comes first (ENTWARE_SRC above, then the boot script's),
# and it's only used if it's root's alone, checked on /opt after mounting.
if [ "$(id -u)" = 0 ] && ! grep -qs " /opt " /proc/mounts; then
    for s in "$ENTWARE_SRC" $(sed -n 's/^ *SRC=//p' /var/lib/webosbrew/init.d/S99entware 2>/dev/null) /mnt/lg/user/opt /mnt/lg/appstore/entware; do
        [ -x "$s/bin/opkg" ] || continue
        mount --bind "$s" /opt 2>/dev/null || continue
        for p in /opt /opt/bin /opt/sbin /opt/etc /opt/etc/init.d /opt/lib /opt/bin/opkg /opt/etc/init.d/rc.unslung; do
            [ -e "$p" ] || continue
            if [ -L "$p" ] || [ "$(ls -ldn "$p" | awk '{print substr($1, 6, 1) substr($1, 9, 1) " " $3}')" != "-- 0" ]; then
                umount -l /opt 2>/dev/null
                echo "$(date '+%H:%M:%S') refused to mount $s at login: $p isn't root's alone" >> /tmp/webos-entware-boot.log
                break 2
            fi
        done
        echo "$(date '+%H:%M:%S') mounted /opt at login, the boot script hadn't" >> /tmp/webos-entware-boot.log
        if [ -x /opt/etc/init.d/rc.unslung ]; then
            (unset LD_PRELOAD LD_LIBRARY_PATH
             if command -v setsid >/dev/null 2>&1; then setsid /opt/etc/init.d/rc.unslung start; else /opt/etc/init.d/rc.unslung start; fi </dev/null >/dev/null 2>&1 &)
        fi
        break
    done
fi
# Use Entware (PATH, bash) only if what's on /opt is root's alone
ENTWARE_OK=""
if [ -d /opt/bin ]; then
    ENTWARE_OK=1
    for p in /opt /opt/bin /opt/sbin /opt/etc /opt/etc/init.d /opt/lib /opt/bin/opkg /opt/bin/bash; do
        [ -e "$p" ] || continue
        if [ -L "$p" ] || [ "$(ls -ldn "$p" | awk '{print substr($1, 6, 1) substr($1, 9, 1) " " $3}')" != "-- 0" ]; then
            ENTWARE_OK=""
            echo "Entware on /opt isn't root's alone ($p), so this login doesn't use it. Check it with a fresh copy of the installer: sh webos-entware-installer.sh doctor" >&2
            break
        fi
    done
fi
if [ -n "$ENTWARE_OK" ]; then
    case ":$PATH:" in *:/opt/bin:*) ;; *) PATH="/opt/bin:/opt/sbin:$PATH"; export PATH ;; esac
fi
case "$-" in
    *i*)
        if [ -n "$ENTWARE_OK" ] && [ -z "$BASH_VERSION" ] && [ -x /opt/bin/bash ] && /opt/bin/bash -c true >/dev/null 2>&1; then
            exec /opt/bin/bash -l
        fi
        ;;
esac
PROFILE
    } > "$gen"
    write_managed "$HOME_DIR/.profile" < "$gen"
    rm -f "$gen"
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
            *) a=$(pkg_addon "$p")
                # Installed on its own, a network service would start at boot
                # with Entware's stock settings, which may let anyone in
                if [ -n "$a" ] && [ "$a" != tailscale ] && addon_service "$a" && ! service_ready "$a"; then
                    svc_off "$a"
                    [ "$a" = samba ] && svc_off wsdd2
                    info "$p won't start until it's set up with a password: webos-entware add $a"
                fi ;;
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
#   app store: /media (/mnt/lg/appstore is the same partition; Entware on
#     app storage is indexed as /opt, not /media/entware)
#   app database: /var/db (/mnt/lg/db8 is the same partition)
#   app jails (/var/palm/jail): each one re-mounts system folders for one app
#
# Bind mounts are kept on purpose, since /opt and /home are bind mounts.
PRUNE_BIND_MOUNTS = "no"

# Virtual and in-memory filesystems. tmpfs covers /tmp, /run and /dev/shm,
# and also USB drives, which webOS mounts under /tmp/usb
PRUNEFS = "proc sysfs devtmpfs devpts tmpfs ramfs cgroup cgroup2 debugfs tracefs configfs securityfs pstore bpf fusectl mqueue binfmt_misc autofs usbfs vfat exfat ntfs fuseblk nfs nfs4 cifs smbfs"

PRUNEPATHS = "/proc /sys /dev /run /tmp /var/tmp /var/volatile /var/run /var/lock /var/palm/jail /mnt/lg/cmn_data /mnt/lg/flash /mnt/lg/appstore /mnt/lg/db8 /mnt/lg/user/opt /mnt/lg/user/home /mnt/lg/user/var /media/entware /opt/tmp /opt/var/mlocate"

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
banner|Login banner|neofetch|yes|A webOS wordmark and your TV's specs each time you log in over SSH
tailscale|Tailscale|tailscale|yes|Reach the TV from anywhere over your tailnet, with no ports opened
samba|Samba file sharing|samba4-server wsdd2|yes|Share the TV's files and USB drives with Windows and Mac, with a password
filebrowser|File Browser|filebrowser|yes|Upload and manage the TV's files from a phone or computer's browser
minidlna|Media server (DLNA)|minidlna|yes|Play videos, music and photos from the TV or a USB drive on other devices
transmission|Transmission|transmission-daemon transmission-web|yes|Torrents from a browser, saved to the TV or a USB drive, with a password
syncthing|Syncthing|syncthing|yes|Keep a folder in sync with your phone and computers, with a password
rclone|rclone|rclone fuse3-utils|yes|Copy and sync with Google Drive, Dropbox, OneDrive and 70 more clouds
nettools|Network tools|iperf3 nmap tcpdump iftop bind-dig|yes|iperf3, nmap, tcpdump, iftop and dig, for testing the TV's network
archives|Archive tools|unzip p7zip unrar|yes|Open zip, 7z and rar files
vim|Vim|vim-full|yes|The full Vim editor
mc|Midnight Commander|mc|yes|A two-pane file manager for the terminal
micro|micro|micro|yes|A simple terminal editor with mouse support and familiar shortcuts
find|Search tools|ripgrep fd fzf|yes|ripgrep, fd and fzf: fast search inside files and by name, and a fuzzy finder
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
    # neofetch isn't in Entware, so the banner brings its own copy
    [ "$AD_ID" = banner ] && { [ -x "$NEOFETCH_BIN" ] && [ -f "$BANNER_DIR/login.sh" ]; return; }
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
        banner) banner_ready || { echo needsSetup; return; } ;;
        rclone) ca_ok || { echo needsSetup; return; } ;;
        find) [ -x /opt/bin/fd ] || { echo needsSetup; return; } ;;
    esac
    if addon_service "$AD_ID"; then service_ready "$AD_ID" || { echo needsSetup; return; }; fi
    echo installed
}

addons_list() {
    if [ "$JSON" = 1 ]; then
        first=1
        printf '['
        addon_catalog | while IFS='|' read -r AD_ID AD_TITLE AD_PKGS AD_REMOVABLE AD_ABOUT; do
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"id":%s,"title":%s,"packages":%s,"about":%s,"removable":%s,"service":%s,"password":%s,"system":%s,"state":%s}' \
                "$(json_str "$AD_ID")" "$(json_str "$AD_TITLE")" "$(json_str "$AD_PKGS")" "$(json_str "$AD_ABOUT")" \
                "$( [ "$AD_REMOVABLE" = yes ] && echo true || echo false)" "$(json_bool addon_service "$AD_ID")" \
                "$(json_bool addon_has_password "$AD_ID")" "$(json_str "$(system_has "$AD_ID")")" "$(json_str "$(addon_state)")"
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
        printf '  %-13s %b\n                %s\n' "$AD_ID" "$st" "$AD_ABOUT"
    done
    echo
    echo "webos-entware info <name> shows how to reach a service, and its password."
}

addon_add() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    addon_find "$1" || error_exit "Unknown add-on: ${1:-none}. See: webos-entware addons"
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    info "Adding $AD_TITLE..."
    if [ "$AD_ID" = banner ]; then
        setup_banner || exit 1
        return 0
    fi
    sys=$(system_has "$AD_ID")
    if [ -n "$sys" ] && ! addon_installed; then
        info "webOS already has its own $(basename "$sys") ($sys). Entware's goes first on the PATH, and webOS's stays."
        confirm "Add $AD_TITLE anyway?" || { info "Nothing was added."; return 0; }
    fi
    # Only what isn't installed yet: no download, and no list refresh, for
    # packages already here
    missing=""
    for p in $AD_PKGS; do pkg_installed "$p" || missing="$missing $p"; done
    if [ -z "$missing" ]; then
        info "$AD_PKGS already installed. Checking its setup."
    else
        [ "$missing" = " $AD_PKGS" ] || info "Already installed:$(for p in $AD_PKGS; do pkg_installed "$p" && printf ' %s' "$p"; done). Installing:$missing"
        if addon_service "$AD_ID"; then
            port_check "$AD_ID" || exit 1
        fi
        /opt/bin/opkg update >/dev/null 2>&1 || warn "Couldn't refresh the package list. Trying with the one already here."
        # shellcheck disable=SC2086  # package names from the catalog
        /opt/bin/opkg install $missing || error_exit "$AD_TITLE didn't install. Check the TV's internet connection and free space."
    fi
    case "$AD_ID" in
        nano) setup_nanorc ;;
        locate) setup_locate || exit 1 ;;
        certs) ca_ok || error_exit "ca-bundle installed, but $CA_FILE is missing." ;;
        git|python|rclone)
            if ! ca_ok; then
                /opt/bin/opkg install ca-bundle >/dev/null 2>&1 && ca_ok ||
                    warn "ca-bundle didn't install, so HTTPS may fail with certificate errors."
            fi ;;
    esac
    # Entware puts fd in /opt/usr/bin, which isn't on the PATH
    [ "$AD_ID" = find ] && [ ! -e /opt/bin/fd ] && [ -x /opt/usr/bin/fd ] && ln -s /opt/usr/bin/fd /opt/bin/fd
    ensure_ca
    if addon_service "$AD_ID"; then
        setup_service "$AD_ID" || exit 1
        info "webos-entware info $AD_ID shows this again."
        return 0
    fi
    if [ "$AD_ID" = locate ]; then
        # setup_locate already said it's ready
        [ "$SETUP_SHELL" = 1 ] && info "Log in again to use plain updatedb."
        return 0
    fi
    success "Added $AD_TITLE."
}

addon_remove() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    addon_find "$1" || error_exit "Unknown add-on: ${1:-none}. See: webos-entware addons"
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    [ "$AD_REMOVABLE" = yes ] || error_exit "$AD_TITLE is part of the base setup, so it stays. Remove it with ent remove if you really want to."
    addon_installed || { info "$AD_TITLE isn't installed."; return 0; }
    confirm "Remove $AD_TITLE ($AD_PKGS)?" || { info "Kept $AD_TITLE."; return 0; }
    if [ "$AD_ID" = banner ]; then
        remove_banner
        success "Removed $AD_TITLE."
        return 0
    fi
    # Dependents first (git-http before git): opkg won't remove a package
    # another one still needs. No --autoremove, so shared libraries and
    # ca-bundle, which other packages may rely on, stay.
    addon_service "$AD_ID" && remove_service "$AD_ID"
    [ "$AD_ID" = find ] && [ "$(readlink /opt/bin/fd 2>/dev/null)" = /opt/usr/bin/fd ] && rm -f /opt/bin/fd
    rev=""
    for p in $AD_PKGS; do rev="$p $rev"; done
    # shellcheck disable=SC2086
    /opt/bin/opkg remove $rev || error_exit "$AD_TITLE didn't uninstall cleanly. See: ent list"
    if [ "$AD_ID" = locate ]; then
        rm -f "$LOCATE_CRON" "$UPDATEDB_WRAPPER" "$LOCATE_DB" /opt/etc/updatedb.group
        if grep -qs "^#.*$MARKER" "$UPDATEDB_CONF"; then rm -f "$UPDATEDB_CONF"; fi
    fi
    addon_service "$AD_ID" && [ -d "$FILES_DIR" ] && info "Your files in $FILES_DIR are kept."
    success "Removed $AD_TITLE."
}

# === Login banner ===
# neofetch isn't in Entware, so the banner add-on downloads the $NEOFETCH_VER
# release from GitHub and only uses it if it matches that release's
# checksum. Its first line is changed to Entware's bash: on webOS
# "env bash" finds BusyBox, which can't run it. The look (a webOS wordmark
# over boxed specs) and the webOS details neofetch can't find on its own
# live in $BANNER_DIR. Your edits to its config.conf are kept.
BANNER_HOOK="# Login banner add-on (webos-entware add banner)"
banner_hooked() { grep -qsF "$BANNER_HOOK" "$ENV_FILE"; }
neofetch_ours() { [ -x "$NEOFETCH_BIN" ] && sed -n 2p "$NEOFETCH_BIN" | grep -q "^# neofetch $NEOFETCH_VER, checked .*$MARKER"; }
banner_ready() { neofetch_ours && [ -f "$BANNER_DIR/login.sh" ] && [ -f "$BANNER_DIR/config.conf" ] && banner_hooked; }
banner_hook() {
    cat << 'HOOK'
# Login banner add-on (webos-entware add banner): shown when you log in
# over SSH, not for commands, scp or sftp. Hide it with: touch ~/.hushlogin
if [ -f /opt/etc/webos-entware/banner/login.sh ] && [ ! -f "$HOME/.hushlogin" ]; then
    case "$-" in *i*) shopt -q login_shell 2>/dev/null && . /opt/etc/webos-entware/banner/login.sh ;; esac
fi
HOOK
}

write_banner_files() {
    mkdir -p "$BANNER_DIR"
    cat > "$BANNER_DIR/login.sh" << 'LOGIN'
# Login banner (webos-entware-installer): the webOS wordmark, then neofetch
printf '\n'
cat /opt/etc/webos-entware/banner/wordmark.ans 2>/dev/null
printf '\n'
SHELL=/opt/bin/bash /opt/bin/neofetch --config /opt/etc/webos-entware/banner/config.conf
LOGIN
    {
        printf '             \033[38;5;141m█     \033[38;5;69m▄\033[38;5;75m▀\033[38;5;75m▀\033[38;5;39m▀\033[38;5;39m▄ \033[38;5;38m▄\033[38;5;44m▀\033[38;5;44m▀\033[38;5;45m▀\033[0m\n'
        printf '  \033[38;5;205m█   \033[38;5;206m█ \033[38;5;170m▄\033[38;5;171m▀\033[38;5;171m▀\033[38;5;135m▄ \033[38;5;141m█\033[38;5;141m▀\033[38;5;99m▀\033[38;5;105m▄  \033[38;5;69m█   \033[38;5;39m█ \033[38;5;38m▀\033[38;5;44m▄\033[38;5;44m▄\033[0m\n'
        printf '  \033[38;5;205m█ \033[38;5;205m█ \033[38;5;206m█ \033[38;5;170m█\033[38;5;171m▀\033[38;5;171m▀\033[38;5;135m▀ \033[38;5;141m█  \033[38;5;105m█  \033[38;5;69m█   \033[38;5;39m█    \033[38;5;45m█\033[0m\n'
        printf '   \033[38;5;205m▀ \033[38;5;206m▀   \033[38;5;171m▀\033[38;5;171m▀\033[38;5;135m▀ \033[38;5;141m▀\033[38;5;141m▀\033[38;5;99m▀    \033[38;5;75m▀\033[38;5;75m▀\033[38;5;39m▀  \033[38;5;38m▀\033[38;5;44m▀\033[38;5;44m▀\033[0m\n'
    } > "$BANNER_DIR/wordmark.ans"
    [ -f "$BANNER_DIR/config.conf" ] && return 0
    cat > "$BANNER_DIR/config.conf" << 'CONF'
# neofetch settings for the login banner (webos-entware-installer)
# Written by webos-entware add banner, and kept if you edit it.
# The webOS wordmark prints above it (login.sh).

print_info() {
    info underline
    info title
    info underline
    prin "$(color 12)╭──────────── $(color 10)Software$(color 12) ────────────"
    info "$(color 12)│ $(color 14)OS" distro
    info "$(color 12)│ $(color 14)Kernel" kernel
    info "$(color 12)│ $(color 14)Packages" packages
    info "$(color 12)│ $(color 14)Shell" shell
    info "$(color 12)│ $(color 14)Terminal" term
    info "$(color 12)│ $(color 14)Local IP" local_ip
    prin "$(color 12)├──────────── $(color 10)Hardware$(color 12) ────────────"
    info "$(color 12)│ $(color 14)Host" model
    info "$(color 12)│ $(color 14)CPU" cpu
    info "$(color 12)│ $(color 14)GPU" gpu
    info "$(color 12)│ $(color 14)Memory" memory
    prin "$(color 12)│ $(color 14)Disk (/opt)" "$(tv_df /opt)"
    prin "$(color 12)│ $(color 14)Disk (/home)" "$(tv_df /home)"
    prin "$(color 12)├───────────── $(color 10)Uptime$(color 12) ─────────────"
    info "$(color 12)│" uptime
    prin "$(color 12)╰──────────────────────────────────"
    info cols
}

# Disk use for a path, shown by where it's used (/opt is a bind mount)
tv_df() {
    df -h "$1" 2>/dev/null | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}'
}

# webOS details neofetch can't work out on its own
get_distro() {
    local r m
    r=$(nyx-cmd OSInfo query webos_release 2>/dev/null)
    m=${r%%.*}
    if [[ $m =~ ^[0-9]+$ ]] && ((m >= 7)); then
        distro="webOS $((m + 15)) ($r)"
    else
        distro="webOS ${r:-TV}"
    fi
}
get_model() {
    local p
    p=$(nyx-cmd DeviceInfo query product_id 2>/dev/null)
    model="LG ${p:-webOS TV}"
}
get_cpu() {
    local soc n f
    soc=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
    [[ $soc =~ (LG[0-9]+) ]] && soc=${BASH_REMATCH[1]} || soc="LG SoC"
    n=$(cut -d- -f2 /sys/devices/system/cpu/possible 2>/dev/null)
    [[ $n =~ ^[0-9]+$ ]] && n=$((n + 1)) || n=$(grep -c ^processor /proc/cpuinfo)
    f=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null)
    cpu="$soc ($n)"
    [[ $f =~ ^[0-9]+$ ]] && cpu+=" @ $(awk -v f="$f" 'BEGIN{printf "%.3fGHz", f/1000000}')"
}
get_gpu() {
    local g
    read -r g _ < /sys/class/misc/mali0/device/gpuinfo 2>/dev/null
    local c
    c=$(awk '{print $2}' /sys/class/misc/mali0/device/gpuinfo 2>/dev/null)
    gpu="${g:-Mali}${c:+ MC$c}"
}

title_fqdn="off"
kernel_shorthand="on"
distro_shorthand="on"
os_arch="off"
uptime_shorthand="off"
memory_percent="off"
memory_unit="mib"
package_managers="on"
shell_path="off"
shell_version="on"
public_ip_host="http://ident.me"
public_ip_timeout=2

# title red, underline and info white, like the mockup
colors=(203 7 7 14 7 7)
underline_enabled="on"
underline_char="¨"
separator="›"
bold="on"
color_blocks="on"
block_width=3
block_height=1
col_offset="auto"

# the wordmark is printed by login.sh, so no side image here
image_backend="off"
image_source="off"
stdout="off"
CONF
}

setup_banner() {
    if [ ! -x /opt/bin/bash ] || ! /opt/bin/bash -c true >/dev/null 2>&1 || [ ! -f "$ENV_FILE" ]; then
        warn "The login banner needs Entware's bash and shell setup. Run '$(fix_cmd)' first."
        return 1
    fi
    if ! neofetch_ours; then
        # A private folder: /opt/tmp can be written by anyone
        mkdir -p /opt/tmp
        nd=$(mktemp -d /opt/tmp/.webos-entware-neofetch.XXXXXX) || { warn "Couldn't make a temporary folder."; return 1; }
        info "Downloading neofetch $NEOFETCH_VER from GitHub..."
        if ! fetch "$NEOFETCH_URL" "$nd/dl"; then
            rm -rf "$nd"
            warn "Couldn't download neofetch. Check the TV's internet connection."
            return 1
        fi
        if [ "$(sha256sum "$nd/dl" | awk '{print $1}')" != "$NEOFETCH_SHA" ]; then
            rm -rf "$nd"
            warn "The download didn't match neofetch $NEOFETCH_VER's checksum, so it wasn't used."
            return 1
        fi
        { echo "#!/opt/bin/bash"; echo "# neofetch $NEOFETCH_VER, checked against its release checksum ($MARKER)"; tail -n +2 "$nd/dl"; } > "$nd/neofetch"
        chmod 755 "$nd/neofetch"
        if [ -e "$NEOFETCH_BIN" ]; then
            b=$(backup_name "$NEOFETCH_BIN")
            mv -f "$NEOFETCH_BIN" "$b" && info "Moved the neofetch that was there to $b."
        fi
        mv -f "$nd/neofetch" "$NEOFETCH_BIN"
        rm -rf "$nd"
    fi
    write_banner_files
    banner_hooked || { echo; banner_hook; } >> "$ENV_FILE"
    success "The login banner is ready. You'll see it the next time you log in over SSH (touch ~/.hushlogin hides it)."
}

# The hook in the shell setup stays: it does nothing without login.sh
remove_banner() {
    neofetch_ours && rm -f "$NEOFETCH_BIN"
    rm -f "$BANNER_DIR/login.sh" "$BANNER_DIR/wordmark.ans" "$BANNER_DIR/config.conf"
    rmdir "$BANNER_DIR" 2>/dev/null
    return 0
}

# === Network services (add-ons) ===
# Tailscale, Samba, File Browser, minidlna, Transmission and Syncthing run
# as Entware services, so they start with the TV (the boot script runs
# /opt/etc/init.d/rc.unslung). Each one is set up before it first starts:
# no guest access, and a password made on the TV for anything that listens
# on the network. Passwords are kept in $CRED_DIR (root only), and
# 'webos-entware info <name>' shows them again. Files go in $FILES_DIR,
# with USB drives under $FILES_DIR/USB.
FILES_DIR="/opt/files"
USB_ROOT="/tmp/usb"
CRED_DIR="/opt/etc/webos-entware/credentials"
FB_PORT=8090
ST_PORT=8384
TR_PORT=9091
DLNA_PORT=8200
SMB_CONF="/opt/etc/samba/smb.conf"
FB_CONF="/opt/etc/filebrowser/filebrowser.conf"
FB_DB="/opt/etc/filebrowser/filebrowser.db"
DLNA_CONF="/opt/etc/minidlna.conf"
TR_CONF="/opt/etc/transmission/settings.json"
ST_HOME="/opt/etc/syncthing"
ST_INIT="/opt/etc/init.d/S91webos-syncthing"
TS_DIR="/opt/var/lib/tailscale"
TS_UP_LOG="$TS_DIR/webos-entware-up.json"

addon_service() {
    case "$1" in tailscale|samba|filebrowser|minidlna|transmission|syncthing) return 0 ;; esac
    return 1
}
svc_script() {
    case "$1" in
        tailscale) echo /opt/etc/init.d/S06tailscaled ;;
        samba) echo /opt/etc/init.d/S91smb ;;
        wsdd2) echo /opt/etc/init.d/S99wsdd2 ;;
        filebrowser) echo /opt/etc/init.d/S99filebrowser ;;
        minidlna) echo /opt/etc/init.d/S90minidlna ;;
        transmission) echo /opt/etc/init.d/S88transmission ;;
        syncthing) echo "$ST_INIT" ;;
    esac
}
svc_proc() {
    case "$1" in
        tailscale) echo tailscaled ;; samba) echo smbd ;; filebrowser) echo filebrowser ;;
        minidlna) echo minidlnad ;; transmission) echo transmission-daemon ;; syncthing) echo syncthing ;;
        wsdd2) echo wsdd2 ;;
    esac
}
# Runs an Entware service's init script: start or stop. A service starts in
# a session of its own, so it keeps running after SSH or the app's task ends.
svc() {
    f=$(svc_script "$1")
    [ -n "$f" ] && [ -x "$f" ] || return 1
    (unset LD_PRELOAD LD_LIBRARY_PATH; PATH="/opt/sbin:/opt/bin:$PATH"; export PATH
     if [ "$2" = start ] && command -v setsid > /dev/null 2>&1; then setsid "$f" start; else "$f" "$2"; fi < /dev/null > /dev/null 2>&1)
}
# Boot scripts from before 2.12.0 start Entware's services with no PATH, so
# the ones whose init scripts don't set their own (Samba, and anything
# started through nohup or env) never start, and in the boot's own session.
# This brings an older boot script up to date.
boot_script_services() {
    [ -f "$INIT_SCRIPT" ] && grep -q "rc.unslung start" "$INIT_SCRIPT" || return 0
    grep -q "export PATH HOME" "$INIT_SCRIPT" && grep -q "setsid /opt/etc/init.d/rc.unslung" "$INIT_SCRIPT" && return 0
    grep -q "export PATH HOME" "$INIT_SCRIPT" ||
        sed -i "s|^\\( *\\)note \"boot script started\"\$|&\\n\\1PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=$HOME_DIR; export PATH HOME|" "$INIT_SCRIPT"
    grep -q "setsid /opt/etc/init.d/rc.unslung" "$INIT_SCRIPT" ||
        sed -i 's|^\( *\)/opt/etc/init.d/rc.unslung start >/dev/null 2>&1$|\1if command -v setsid >/dev/null 2>\&1; then setsid /opt/etc/init.d/rc.unslung start; else /opt/etc/init.d/rc.unslung start; fi >/dev/null 2>\&1|' "$INIT_SCRIPT"
    if grep -q "export PATH HOME" "$INIT_SCRIPT" && grep -q "setsid /opt/etc/init.d/rc.unslung" "$INIT_SCRIPT" && sh -n "$INIT_SCRIPT"; then
        info "Updated the boot script, so services start with the TV."
    else
        warn "Couldn't update the boot script. Repair Entware so services start with the TV."
    fi
    return 0
}
svc_running() { pidof "$(svc_proc "$1")" > /dev/null 2>&1; }
# Waits up to $3 seconds for a service to be up, or down
svc_wait() {
    n=0
    while [ $n -lt "${3:-15}" ]; do
        if [ "$2" = up ]; then svc_running "$1" && return 0; else svc_running "$1" || return 0; fi
        sleep 1
        n=$((n + 1))
    done
    if [ "$2" = up ]; then svc_running "$1"; else ! svc_running "$1"; fi
}
svc_stop() {
    svc_running "$1" || return 0
    svc "$1" stop
    svc_wait "$1" down 15 && return 0
    killall "$(svc_proc "$1")" 2>/dev/null
    svc_wait "$1" down 5
}

addon_has_password() { case "$1" in samba|filebrowser|transmission|syncthing) return 0 ;; esac; return 1; }
# The port each service listens on, to check nothing else on the TV has it
svc_port() {
    case "$1" in samba) echo 445 ;; filebrowser) echo "$FB_PORT" ;; minidlna) echo "$DLNA_PORT" ;;
        transmission) echo "$TR_PORT" ;; syncthing) echo "$ST_PORT" ;; esac
}
# A TCP port something listens on, from the kernel's own list
port_busy() {
    h=$(printf '%04X' "$1")
    cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | awk -v h="$h" '$4 == "0A" { n = split($2, a, ":"); if (a[n] == h) f = 1 } END { exit !f }'
}
# Fails when something other than this service already listens on its port
port_check() {
    pt=$(svc_port "$1")
    [ -n "$pt" ] || return 0
    svc_running "$1" && return 0
    port_busy "$pt" || return 0
    warn "Something else on the TV already uses port $pt, which $1 needs. Stop it first: netstat -tlnp | grep :$pt"
    return 1
}
# The command each add-on brings, to tell when webOS already has one. BusyBox
# applets don't count: they're cut-down versions.
addon_cmd() {
    case "$1" in
        python) echo python3 ;; find) echo rg ;; archives) echo 7z ;; nettools) echo iperf3 ;; vim) echo vim ;;
        tailscale) echo tailscaled ;; samba) echo smbd ;; minidlna) echo minidlnad ;; transmission) echo transmission-daemon ;;
        nano|locate|git|htop|tmux|ncdu|rsync|curl|jq|mc|micro|rclone|filebrowser|syncthing) echo "$1" ;;
    esac
}
system_has() {
    c=$(addon_cmd "$1")
    [ -n "$c" ] || return 0
    p=$(PATH=/usr/sbin:/usr/bin:/sbin:/bin; command -v "$c" 2>/dev/null)
    case "$p" in /*) ;; *) return 0 ;; esac
    case "$(readlink -f "$p" 2>/dev/null)" in *busybox*) return 0 ;; esac
    echo "$p"
}

# The TV's address on the home network
tv_ip() {
    ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" && $2 !~ /^tailscale/ { sub(/\/.*/, "", $4); print $4; exit }'
}
tv_addr() { a=$(tv_ip); echo "${a:-the-TVs-IP}"; }
new_password() { tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16; }

# Saved logins: user=... and password=..., readable by root only
cred_get() { sed -n "s/^$2=//p" "$CRED_DIR/$1" 2>/dev/null | head -n 1; }
cred_save() {
    mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"
    (umask 077; printf 'user=%s\npassword=%s\n' "$2" "$3" > "$CRED_DIR/$1")
}
# The password already made for an add-on, or a new one
cred_password() {
    p=$(cred_get "$1" password)
    [ -n "$p" ] || p=$(new_password)
    [ ${#p} -ge 12 ] || { warn "Couldn't make a password (no /dev/urandom?)."; return 1; }
    echo "$p"
}

files_dirs() {
    mkdir -p "$FILES_DIR/Downloads/Watch" "$FILES_DIR/Media" "$FILES_DIR/Sync" || return 1
    [ -e "$FILES_DIR/USB" ] || [ -L "$FILES_DIR/USB" ] || ln -s "$USB_ROOT" "$FILES_DIR/USB"
    return 0
}
# A config file that's ours, or wasn't there, is written over. Anyone
# else's is kept next to it first.
take_conf() {
    [ -f "$1" ] || { mkdir -p "$(dirname "$1")"; return 0; }
    grep -qs "$MARKER" "$1" && return 0
    b=$(backup_name "$1")
    cp -p "$1" "$b" && info "Kept the old $(basename "$1") as $b."
}
# Sets "key": value in a JSON settings file with one key per line (Transmission's)
json_set() {
    grep -q "^[[:space:]]*\"$2\":" "$1" || return 1
    sed -i "s|^\([[:space:]]*\"$2\": \).*[^,]\(,\{0,1\}\)\$|\1$3\2|" "$1"
}

ts() { (unset LD_PRELOAD LD_LIBRARY_PATH; /opt/bin/tailscale "$@" < /dev/null 2>/dev/null); }
ts_field() { ts status --json | sed -n "s/^  \"$1\": \"\([^\"]*\)\".*/\1/p" | head -n 1; }

service_ready() {
    svc_running "$1" || return 1
    case "$1" in
        tailscale) [ "$(ts_field BackendState)" = Running ] ;;
        samba) grep -qs "$MARKER" "$SMB_CONF" && [ -s "$CRED_DIR/samba" ] ;;
        filebrowser) grep -qs "$MARKER" "$FB_CONF" && [ -s "$CRED_DIR/filebrowser" ] ;;
        minidlna) grep -qs "$MARKER" "$DLNA_CONF" ;;
        transmission) grep -qs '"rpc-authentication-required": true' "$TR_CONF" && [ -s "$CRED_DIR/transmission" ] ;;
        syncthing) [ -x "$ST_INIT" ] && [ -s "$CRED_DIR/syncthing" ] ;;
    esac
}

# When a setup doesn't finish, the service is stopped and kept from
# starting at boot: an Entware service's stock settings may be open to
# anyone on the network (Samba's let guests in, Transmission's has no
# password). Adding it again turns it back on.
setup_failed() {
    svc_stop "$1"
    svc_off "$1"
    [ "$1" = samba ] && { svc_stop wsdd2; svc_off wsdd2; }
    warn "$2"
    return 1
}
# Off: rc.unslung only runs init scripts that can run, and Samba's has no
# ENABLED switch
svc_off() {
    f=$(svc_script "$1")
    [ -f "$f" ] || return 0
    sed -i 's/^ENABLED=yes/ENABLED=no/' "$f"
    chmod 644 "$f"
}
svc_on() {
    f=$(svc_script "$1")
    [ -f "$f" ] || return 0
    sed -i 's/^ENABLED=no/ENABLED=yes/' "$f"
    chmod 755 "$f"
}

# Services' own logs, kept to their last 500 lines when they pass 1 MB
trim_logs() {
    for f in /opt/var/log/filebrowser.log /opt/var/log/minidlna.log; do
        [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 1048576 ] && { tail -n 500 "$f" > "$f.new" && mv -f "$f.new" "$f"; }
    done
    return 0
}
setup_service() {
    port_check "$1" || return 1
    trim_logs
    files_dirs || { warn "Couldn't make $FILES_DIR."; return 1; }
    boot_script_services
    svc_on "$1"
    [ "$1" = samba ] && svc_on wsdd2
    "setup_$1"
}

setup_tailscale() {
    mkdir -p "$TS_DIR"
    svc_running tailscale || svc tailscale start
    n=0
    until [ -n "$(ts_field BackendState)" ] || [ $n -ge 20 ]; do sleep 1; n=$((n + 1)); done
    st=$(ts_field BackendState)
    [ -n "$st" ] || { setup_failed tailscale "Tailscale didn't start. See $TS_DIR."; return 1; }
    if [ "$st" != Running ]; then
        # Waits for the sign-in in the background. DNS and the firewall
        # are left to webOS.
        pkill -f "tailscale up" 2>/dev/null
        (unset LD_PRELOAD LD_LIBRARY_PATH
         nohup /opt/bin/tailscale up --accept-dns=false --netfilter-mode=off --json < /dev/null > "$TS_UP_LOG" 2>&1 &)
        n=0
        until [ -n "$(ts_field AuthURL)" ] || [ "$(ts_field BackendState)" = Running ] || [ $n -ge 30 ]; do sleep 1; n=$((n + 1)); done
    fi
    if [ "$(ts_field BackendState)" = Running ]; then
        ip4=$(ts ip -4 | head -n 1)
        success "Tailscale is connected. The TV is $ip4 on your tailnet: ssh root@$ip4"
        return 0
    fi
    url=$(ts_field AuthURL)
    [ -n "$url" ] || { warn "Tailscale is running, but didn't give a sign-in link. Check the TV's internet connection, then add it again."; return 1; }
    success "Tailscale is running. Sign in to connect the TV to your tailnet:"
    echo "  $url"
    info "In the TV app, open Tailscale in Add-ons for a QR code of this link. The TV connects by itself once you sign in, and after every restart."
    return 0
}

setup_samba() {
    pw=$(cred_password samba) || return 1
    svc_stop samba
    svc_stop wsdd2
    take_conf "$SMB_CONF"
    cat > "$SMB_CONF" << EOF
# Samba add-on ($MARKER): shares $FILES_DIR, with USB drives in USB.
# Sign in as tv. 'webos-entware info samba' shows the password.
[global]
    netbios name = LGTV
    server string = LG TV (Entware)
    workgroup = WORKGROUP
    security = user
    map to guest = Never
    restrict anonymous = 2
    username map = /opt/etc/samba/users.map
    passdb backend = smbpasswd
    smb passwd file = /opt/etc/samba/smbpasswd
    server min protocol = SMB2_10
    load printers = no
    printing = bsd
    printcap name = /dev/null
    disable spoolss = yes
    unix extensions = no
    log file = /opt/var/log/samba/log.%m
    max log size = 100
    log level = 0

[TV]
    comment = Files on the TV, and USB drives in USB
    path = $FILES_DIR
    valid users = root
    read only = no
    follow symlinks = yes
    wide links = yes
EOF
    echo "root = tv" > /opt/etc/samba/users.map
    # smbd needs these, and the init script only makes them when it runs
    mkdir -p /opt/var/log/samba /opt/var/lib/samba/private /opt/var/cache/samba /opt/var/run/samba/ncalrpc
    printf '%s\n%s\n' "$pw" "$pw" | (unset LD_PRELOAD LD_LIBRARY_PATH; /opt/bin/smbpasswd -s -a root) > /dev/null 2>&1 ||
        { setup_failed samba "Couldn't set Samba's password."; return 1; }
    chmod 600 /opt/etc/samba/smbpasswd 2>/dev/null
    cred_save samba tv "$pw"
    svc samba start
    svc_wait samba up 10 || { setup_failed samba "Samba didn't start. See /opt/var/log/samba."; return 1; }
    svc wsdd2 start
    success "Samba is sharing $FILES_DIR (USB drives are in USB)."
    echo "  Windows: \\\\$(tv_addr)\\TV    Mac: smb://$(tv_addr)/TV"
    echo "  User: tv    Password: $pw"
}

fb() { (unset LD_PRELOAD LD_LIBRARY_PATH; cd /opt/etc/filebrowser && /opt/sbin/filebrowser "$@" -d "$FB_DB" < /dev/null > /dev/null 2>&1); }
setup_filebrowser() {
    pw=$(cred_password filebrowser) || return 1
    svc_stop filebrowser
    take_conf "$FB_CONF"
    cat > "$FB_CONF" << EOF
# File Browser add-on ($MARKER): $FILES_DIR, on port $FB_PORT
ADDR="-a 0.0.0.0"
PORT="-p $FB_PORT"
DB="-d $FB_DB"
LOG="-l /opt/var/log/filebrowser.log"
ROOT="-r $FILES_DIR"
OPTIONS="\$ADDR \$PORT \$DB \$LOG \$ROOT"
EOF
    [ -f "$FB_DB" ] || fb config init -a 0.0.0.0 -p "$FB_PORT" -r "$FILES_DIR" ||
        { setup_failed filebrowser "Couldn't set up File Browser's settings."; return 1; }
    fb users update admin -p "$pw" || fb users add admin "$pw" --perm.admin ||
        { setup_failed filebrowser "Couldn't set File Browser's password."; return 1; }
    cred_save filebrowser admin "$pw"
    svc filebrowser start
    svc_wait filebrowser up 10 || { setup_failed filebrowser "File Browser didn't start. See /opt/var/log/filebrowser.log."; return 1; }
    success "File Browser is at http://$(tv_addr):$FB_PORT"
    echo "  User: admin    Password: $pw"
}

setup_minidlna() {
    svc_stop minidlna
    take_conf "$DLNA_CONF"
    cat > "$DLNA_CONF" << EOF
# minidlna add-on ($MARKER): serves $FILES_DIR (USB drives are in USB)
port=$DLNA_PORT
friendly_name=LG TV (Entware)
media_dir=$FILES_DIR
wide_links=yes
db_dir=/opt/var/minidlna
log_dir=/opt/var/log
inotify=yes
album_art_names=Cover.jpg/cover.jpg/AlbumArtSmall.jpg/albumartsmall.jpg/AlbumArt.jpg/albumart.jpg/Album.jpg/album.jpg/Folder.jpg/folder.jpg/Thumb.jpg/thumb.jpg
strict_dlna=no
notify_interval=900
serial=12345678
model_number=1
EOF
    mkdir -p /opt/var/minidlna
    svc minidlna start
    svc_wait minidlna up 10 || { setup_failed minidlna "minidlna didn't start. See /opt/var/log/minidlna.log."; return 1; }
    success "minidlna is serving $FILES_DIR as \"LG TV (Entware)\" to media players on your network."
    echo "  Put videos, music and photos in $FILES_DIR/Media, or on a USB drive."
}

setup_transmission() {
    pw=$(cred_password transmission) || return 1
    [ -f "$TR_CONF" ] || { setup_failed transmission "$TR_CONF is missing. Remove Transmission and add it again."; return 1; }
    # It writes its settings back when it stops, so it's stopped first
    svc_stop transmission
    ok=1
    json_set "$TR_CONF" rpc-authentication-required true || ok=0
    json_set "$TR_CONF" rpc-username '"tv"' || ok=0
    # As a JSON string, then made safe for sed's replacement
    pwj=$(printf '%s' "$pw" | sed -e 's/[\\"]/\\&/g' -e 's/[\\&|]/\\&/g')
    json_set "$TR_CONF" rpc-password "\"$pwj\"" || ok=0
    json_set "$TR_CONF" rpc-port "$TR_PORT" || ok=0
    json_set "$TR_CONF" download-dir "\"$FILES_DIR/Downloads\"" || ok=0
    json_set "$TR_CONF" incomplete-dir "\"$FILES_DIR/Downloads/.incomplete\"" || ok=0
    json_set "$TR_CONF" incomplete-dir-enabled true || ok=0
    json_set "$TR_CONF" watch-dir "\"$FILES_DIR/Downloads/Watch\"" || ok=0
    json_set "$TR_CONF" watch-dir-enabled true || ok=0
    if [ "$ok" != 1 ] || ! grep -q '"rpc-authentication-required": true' "$TR_CONF"; then
        setup_failed transmission "Couldn't set Transmission's password in $TR_CONF."
        return 1
    fi
    chmod 600 "$TR_CONF"
    cred_save transmission tv "$pw"
    svc transmission start
    svc_wait transmission up 10 || { setup_failed transmission "Transmission didn't start."; return 1; }
    success "Transmission is at http://$(tv_addr):$TR_PORT"
    echo "  User: tv    Password: $pw"
    echo "  Downloads go to $FILES_DIR/Downloads. Torrent files dropped in Downloads/Watch start by themselves."
}

setup_syncthing() {
    pw=$(cred_password syncthing) || return 1
    svc_stop syncthing
    # The package's own start script sets no password or home for
    # Syncthing, so this one runs it instead
    [ -f /opt/etc/init.d/S92syncthing ] && { sed -i 's/^ENABLED=yes/ENABLED=no/' /opt/etc/init.d/S92syncthing; chmod 644 /opt/etc/init.d/S92syncthing; }
    mkdir -p "$ST_HOME" && chmod 700 "$ST_HOME"
    printf '%s\n' "$pw" | (unset LD_PRELOAD LD_LIBRARY_PATH; HOME="$ST_HOME" STNODEFAULTFOLDER=1 \
        /opt/bin/syncthing generate --home="$ST_HOME" --gui-user=tv --gui-password=- --no-port-probing) > /dev/null 2>&1 ||
        { setup_failed syncthing "Couldn't set up Syncthing in $ST_HOME."; return 1; }
    cat > "$ST_INIT" << EOF
#!/bin/sh
# Syncthing add-on ($MARKER): settings in $ST_HOME, web page on port $ST_PORT
ENABLED=yes
PROCS=syncthing
ARGS="serve --home=$ST_HOME --no-browser --no-upgrade --gui-address=http://0.0.0.0:$ST_PORT"
PREARGS="env HOME=$ST_HOME STNODEFAULTFOLDER=1"
DESC=Syncthing
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
    chmod 755 "$ST_INIT"
    cred_save syncthing tv "$pw"
    svc syncthing start
    svc_wait syncthing up 15 || { setup_failed syncthing "Syncthing didn't start."; return 1; }
    success "Syncthing is at http://$(tv_addr):$ST_PORT"
    echo "  User: tv    Password: $pw"
    echo "  Share a folder like $FILES_DIR/Sync with your other devices from there."
}

# Stops a service and takes away what its setup added. What's in
# $FILES_DIR stays.
remove_service() {
    case "$1" in
        tailscale)
            pkill -f "tailscale up" 2>/dev/null
            svc_running tailscale && ts logout > /dev/null 2>&1
            svc_stop tailscale
            rm -rf /opt/var/lib/tailscale
            rm -f /opt/var/tailscaled.state ;;
        samba)
            svc_stop wsdd2
            svc_stop samba
            grep -qs "$MARKER" "$SMB_CONF" && rm -f /opt/etc/samba/smb.conf
            rm -f /opt/etc/samba/smbpasswd /opt/etc/samba/users.map ;;
        filebrowser)
            svc_stop filebrowser
            grep -qs "$MARKER" "$FB_CONF" && rm -f /opt/etc/filebrowser/filebrowser.conf
            rm -f /opt/etc/filebrowser/filebrowser.db ;;
        minidlna)
            svc_stop minidlna
            grep -qs "$MARKER" "$DLNA_CONF" && rm -f /opt/etc/minidlna.conf
            rm -rf /opt/var/minidlna ;;
        transmission)
            svc_stop transmission
            # It holds the password
            rm -f /opt/etc/transmission/settings.json ;;
        syncthing)
            svc_stop syncthing
            rm -f /opt/etc/init.d/S91webos-syncthing
            rm -rf /opt/etc/syncthing ;;
    esac
    case "$1" in [a-z]*) rm -f "/opt/etc/webos-entware/credentials/$1" ;; esac
    return 0
}

# A new password for a service: random, or one you type (--ask) or pipe in
# (--stdin). It's never taken from the command line, where other programs
# on the TV could see it.
# 12 to 64 characters you can type, symbols included, but no spaces, and
# not starting with a dash (it would read as an option)
pw_ok() {
    [ ${#1} -ge 12 ] && [ ${#1} -le 64 ] || return 1
    case "$1" in -*) return 1 ;; esac
    ! printf '%s' "$1" | LC_ALL=C grep -q '[^!-~]'
}
PW_RULE="Use 12 to 64 characters: letters, numbers and symbols, with no spaces, not starting with -"
addon_password() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    addon_find "$1" || error_exit "Unknown add-on: ${1:-none}. See: webos-entware addons"
    addon_has_password "$AD_ID" || error_exit "$AD_TITLE has no password."
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    addon_installed || error_exit "$AD_TITLE isn't added. Add it first: webos-entware add $AD_ID"
    case "$PW_FROM" in
        stdin) IFS= read -r pw || [ -n "$pw" ] || error_exit "No password on standard input." ;;
        ask)
            [ -t 0 ] || error_exit "--ask needs a terminal. Use --stdin to pipe one in."
            trap 'stty echo 2>/dev/null' EXIT INT
            stty -echo
            printf "New password for %s: " "$AD_TITLE"; IFS= read -r pw; echo
            printf "Again: "; IFS= read -r pw2; echo
            stty echo
            [ "$pw" = "$pw2" ] || error_exit "The two passwords didn't match. Nothing changed." ;;
        *) pw=$(new_password) ;;
    esac
    pw_ok "$pw" || error_exit "$PW_RULE. Nothing changed."
    old=$(cred_get "$AD_ID" password)
    cred_save "$AD_ID" "$(cred_get "$AD_ID" user)" "$pw"
    info "Setting a new password for $AD_TITLE. It restarts for a moment."
    if ! setup_service "$AD_ID"; then
        [ -n "$old" ] && cred_save "$AD_ID" "$(cred_get "$AD_ID" user)" "$old"
        error_exit "The password didn't change. $AD_TITLE is stopped: add it again to start it with the old one."
    fi
    success "Changed the password for $AD_TITLE."
}

# === Phone dashboard ===
# A small web page for managing add-ons and passwords from a phone or
# computer on the same network, served by the TV's own Node.js. The TV app
# starts it and shows a QR code of its address with a sign-in code; it
# stops by itself after 30 minutes without use. See webos-app/web.
WEB_DIR="/tmp/webos-entware-web"
WEB_PORT=8095
web_server() {
    for d in "$(dirname "$SELF")/web" "$APP_DIR/assets/web"; do
        [ -f "$d/server.js" ] && { echo "$d/server.js"; return 0; }
    done
    return 1
}
web_node() { for n in /usr/bin/node "$(command -v node 2>/dev/null)"; do [ -x "$n" ] && { echo "$n"; return 0; }; done; return 1; }
web_pid() { p=$(cat "$WEB_DIR/pid" 2>/dev/null); case "$p" in ''|*[!0-9]*) return 1 ;; esac; kill -0 "$p" 2>/dev/null && echo "$p"; }
# Eight characters that can't be mistaken for each other across a room
web_code() { tr -dc 'ACDEFHJKMNPQRTWXY3479' < /dev/urandom 2>/dev/null | head -c 8; }
web_status() {
    pid=$(web_pid) port=$(cat "$WEB_DIR/port" 2>/dev/null) code=$(cat "$WEB_DIR/code" 2>/dev/null)
    a=$(tv_ip)
    if [ "$JSON" = 1 ]; then
        if [ -n "$pid" ] && [ -n "$port" ]; then
            printf '{"running":true,"port":%s,"url":%s,"code":%s}\n' "$port" "$(json_str "http://${a:-127.0.0.1}:$port")" "$(json_str "$code")"
        else
            printf '{"running":false,"port":null,"url":"","code":""}\n'
        fi
        return 0
    fi
    if [ -n "$pid" ] && [ -n "$port" ]; then
        success "The phone dashboard is at http://${a:-the-TVs-IP}:$port"
        echo "  Code: $code"
        echo "  Or open http://${a:-the-TVs-IP}:$port/#k=$code to sign in directly. It stops after 30 minutes without use."
    else
        info "The phone dashboard isn't running. Start it with: $(run_cmd) web start"
    fi
}
web_action() {
    case "$1" in
        start)
            [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
            if [ -z "$(web_pid)" ]; then
                js=$(web_server) || error_exit "The phone dashboard comes with the TV app. Install the app from the Homebrew Channel."
                node=$(web_node) || error_exit "Node.js isn't on this TV, so the phone dashboard can't run."
                rm -rf "${WEB_DIR:?}"
                (umask 077; mkdir -p "$WEB_DIR" && web_code > "$WEB_DIR/code")
                [ "$(wc -c < "$WEB_DIR/code")" -eq 8 ] || error_exit "Couldn't make a sign-in code."
                # A session of its own, so it outlives the app's task or SSH
                (unset LD_PRELOAD LD_LIBRARY_PATH
                 if command -v setsid > /dev/null 2>&1; then
                     setsid "$node" "$js" --dir "$WEB_DIR" --script "$SELF" --port "$WEB_PORT" < /dev/null > "$WEB_DIR/log" 2>&1 &
                 else
                     nohup "$node" "$js" --dir "$WEB_DIR" --script "$SELF" --port "$WEB_PORT" < /dev/null > "$WEB_DIR/log" 2>&1 &
                 fi)
                n=0
                while [ ! -s "$WEB_DIR/port" ] && [ $n -lt 50 ]; do sleep 0.2 2>/dev/null || sleep 1; n=$((n + 1)); done
                [ -s "$WEB_DIR/port" ] || error_exit "The phone dashboard didn't start: $(tail -n 2 "$WEB_DIR/log" 2>/dev/null)"
            fi
            web_status ;;
        stop)
            pid=$(web_pid) && kill "$pid" 2>/dev/null
            n=0
            while web_pid > /dev/null && [ $n -lt 25 ]; do sleep 0.2 2>/dev/null || sleep 1; n=$((n + 1)); done
            rm -rf "${WEB_DIR:?}"
            if [ "$JSON" = 1 ]; then web_status; else success "Stopped the phone dashboard."; fi ;;
        status|'') web_status ;;
        *) error_exit "Use: webos-entware web start, web stop or web status" ;;
    esac
}

# How to reach an add-on, and its login: 'webos-entware info <name>'
INFO_URL="" INFO_USER="" INFO_PASS="" INFO_LINES=""
info_line() { INFO_LINES="$INFO_LINES
$1"; }
addon_info_collect() {
    a=$(tv_addr)
    INFO_URL="" INFO_USER=$(cred_get "$AD_ID" user) INFO_PASS=$(cred_get "$AD_ID" password) INFO_LINES=""
    case "$AD_ID" in
        tailscale)
            st=$(ts_field BackendState)
            if [ "$st" = Running ]; then
                ip4=$(ts ip -4 | head -n 1)
                info_line "Connected to your tailnet as $ip4."
                info_line "From any device on it: ssh root@$ip4"
            elif [ -n "$(ts_field AuthURL)" ]; then
                INFO_URL=$(ts_field AuthURL)
                info_line "Not signed in yet. Open the sign-in link (on the TV, scan the QR code) and sign in to Tailscale."
            else
                info_line "Not connected (${st:-not running}). Choose Finish setup to get a sign-in link."
            fi ;;
        samba)
            info_line "Windows: \\\\$a\\TV  (in File Explorer's address bar)"
            info_line "Mac: smb://$a/TV  (Finder, Go, Connect to Server)"
            info_line "Shares $FILES_DIR. USB drives are in the USB folder." ;;
        filebrowser)
            INFO_URL="http://$a:$FB_PORT"
            info_line "Open $INFO_URL in a browser on your phone or computer."
            info_line "Upload, download and manage $FILES_DIR (USB drives are in USB)." ;;
        minidlna)
            info_line "Media players on your network see \"LG TV (Entware)\" (in VLC: Local Network, UPnP)."
            info_line "It serves $FILES_DIR: put media in Media, or on a USB drive." ;;
        transmission)
            INFO_URL="http://$a:$TR_PORT"
            info_line "Open $INFO_URL in a browser to add and manage torrents."
            info_line "Downloads go to $FILES_DIR/Downloads, on the TV's app storage ($(df -m /opt 2>/dev/null | awk 'NR == 2 {print $4}') MB free). For big ones, choose a USB drive in Transmission's settings: $FILES_DIR/USB/..."
            info_line "Torrent files dropped in Downloads/Watch start by themselves." ;;
        syncthing)
            INFO_URL="http://$a:$ST_PORT"
            info_line "Open $INFO_URL in a browser to add devices and folders."
            info_line "Sync a folder like $FILES_DIR/Sync with your phone or computer." ;;
        rclone)
            info_line "Set up a cloud account over SSH with: rclone config"
            info_line "Then, for example: rclone copy gdrive:Photos $FILES_DIR/Media/Photos" ;;
        nettools) info_line "iperf3, nmap, tcpdump, iftop and dig, for testing the TV's network over SSH." ;;
        archives) info_line "unzip, 7z (p7zip) and unrar, over SSH." ;;
        vim) info_line "Edit files over SSH with vim." ;;
        mc) info_line "Run mc over SSH for a two-pane file manager." ;;
        micro) info_line "Edit files over SSH with micro (Ctrl+S saves, Ctrl+Q quits)." ;;
        find) info_line "rg searches inside files, fd finds files by name, and fzf picks from a list (Ctrl+R in bash)." ;;
        *) info_line "$AD_ABOUT." ;;
    esac
}
addon_info() {
    addon_find "$1" || error_exit "Unknown add-on: ${1:-none}. See: webos-entware addons"
    state=$(addon_state)
    addon_info_collect
    if [ "$JSON" = 1 ]; then
        printf '{"id":%s,"title":%s,"state":%s,"service":%s,"hasPassword":%s,"url":%s,"user":%s,"password":%s,"lines":%s}\n' \
            "$(json_str "$AD_ID")" "$(json_str "$AD_TITLE")" "$(json_str "$state")" "$(json_bool addon_service "$AD_ID")" "$(json_bool addon_has_password "$AD_ID")" \
            "$(json_str "$INFO_URL")" "$(json_str "$INFO_USER")" "$(json_str "$INFO_PASS")" "$(printf '%s\n' "$INFO_LINES" | json_lines)"
        return 0
    fi
    log "$CYAN" "$AD_TITLE ($state)"
    printf '%s\n' "$INFO_LINES" | sed '/^$/d; s/^/  /'
    [ "$AD_ID" = tailscale ] && [ -n "$INFO_URL" ] && echo "  $INFO_URL"
    [ -n "$INFO_USER" ] && echo "  User: $INFO_USER    Password: $INFO_PASS"
    return 0
}

# === Packages: installed, search, add and remove one ===
# For the TV app's Packages screen.  Package names and search words are
# checked before anything reaches opkg.
OPKG_STATUS="/opt/lib/opkg/status"
# Part of Entware or the shell setup: removing these breaks things
BASE_PKGS=" entware-opt entware-release entware-upgrade opkg libc libgcc libpthread librt libssp libstdcpp ldconfig terminfo locales findutils grep zoneinfo-core bash nano-full coreutils-ls coreutils-dircolors ca-bundle "
pkg_base() { case "$BASE_PKGS" in *" $1 "*) return 0 ;; esac; return 1; }
term_ok() { case "$1" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; esac; [ ${#1} -le 40 ]; }

# One line per installed package: name version auto(0/1) needed-by(comma list or -)
installed_lines() {
    [ -f "$OPKG_STATUS" ] || return 0
    awk '
        function flush() { if (p != "") { n++; name[n] = p; ver[p] = v; auto[p] = a } p = ""; v = ""; a = 0 }
        /^Package:/ { flush(); p = $2 }
        /^Version:/ { v = $2 }
        /^Auto-Installed: yes/ { a = 1 }
        /^Depends:/ {
            sub(/^Depends: */, "")
            k = split($0, d, ",")
            for (i = 1; i <= k; i++) {
                x = d[i]; sub(/^ */, "", x); sub(/[ (].*/, "", x)
                if (x != "") need[x] = (need[x] == "" ? p : need[x] "," p)
            }
        }
        END {
            flush()
            for (i = 1; i <= n; i++) {
                q = name[i]
                # only dependents that are installed
                by = ""; m = split(need[q], b, ",")
                for (j = 1; j <= m; j++) if (b[j] in ver) by = (by == "" ? b[j] : by "," b[j])
                print q, ver[q], auto[q], (by == "" ? "-" : by)
            }
        }' "$OPKG_STATUS" | sort
}
pkg_size_kb() {
    f="/opt/lib/opkg/info/$1.list"
    [ -f "$f" ] || { echo 0; return; }
    tr '\n' '\0' < "$f" | xargs -0 ls -lnd 2>/dev/null | awk '$1 !~ /^d/ { s += $5 } END { printf "%d", (s + 1023) / 1024 }'
}
# The add-on a package belongs to, if any
pkg_addon() {
    addon_catalog | while IFS='|' read -r id _t pk _r _a; do
        [ "$id" = banner ] && continue
        for x in $pk; do [ "$x" = "$1" ] && { echo "$id"; return; }; done
    done
}

# Everything about the installed packages, as JSON, in one pass: from
# opkg's status file and each package's control file (its section, size
# and description), with what needs it, whether Entware needs it, and the
# add-on it came with.  Sizes come from Installed-Size, or from the
# package's files when that's missing.
installed_json() {
    cat=$(addon_catalog | awk -F'|' '$1 != "banner" { printf "%s|%s|%s;", $1, $2, $3 }')
    set -- /opt/lib/opkg/info/*.control
    [ -e "$1" ] || set --
    awk -v base="$BASE_PKGS" -v cat="$cat" '
        function js(x) { gsub(/\\/, "\\\\", x); gsub(/"/, "\\\"", x); gsub(/[\001-\037]/, " ", x); return "\"" x "\"" }
        function flush() { if (p != "") { n++; name[n] = p; ver[p] = v; auto[p] = a; when[p] = t } p = ""; v = ""; a = 0; t = "" }
        BEGIN {
            k = split(cat, entries, ";")
            for (i = 1; i <= k; i++) {
                if (split(entries[i], f, "|") < 3) continue
                m = split(f[3], pk, " ")
                for (j = 1; j <= m; j++) { addon[pk[j]] = f[1]; addonTitle[pk[j]] = f[2] }
            }
        }
        FILENAME ~ /\.control$/ {
            if (/^[ \t]/) {
                # The description goes on over indented lines: keep enough to read
                if (indesc && length(desc[cp]) < 200) { d = $0; sub(/^[ \t.]+/, "", d); if (d != "") desc[cp] = desc[cp] " " d }
                next
            }
            indesc = 0
            if (/^Package:/) cp = $2
            else if (/^Section:/) sect[cp] = $2
            else if (/^Installed-Size:/) size[cp] = $2
            else if (/^Description:/) { d = $0; sub(/^Description: */, "", d); desc[cp] = d; indesc = 1 }
            next
        }
        /^Package:/ { flush(); p = $2 }
        /^Version:/ { v = $2 }
        /^Auto-Installed: yes/ { a = 1 }
        /^Installed-Time:/ { t = $2 }
        /^Depends:/ {
            dd = $0; sub(/^Depends: */, "", dd)
            k = split(dd, dep, ",")
            for (i = 1; i <= k; i++) {
                x = dep[i]; sub(/^ */, "", x); sub(/[ (].*/, "", x)
                if (x != "") need[x] = (need[x] == "" ? p : need[x] "," p)
            }
        }
        END {
            flush()
            printf "["
            for (i = 1; i <= n; i++) {
                q = name[i]
                by = ""; m = split(need[q], b, ",")
                for (j = 1; j <= m; j++) if (b[j] in ver && index(", " by ", ", ", " b[j] ", ") == 0) by = (by == "" ? b[j] : by ", " b[j])
                kb = size[q] != "" ? int((size[q] + 1023) / 1024) : -1
                if (kb < 0) {
                    kb = 0; s = 0
                    cmd = "tr \"\\n\" \"\\0\" < /opt/lib/opkg/info/" q ".list 2>/dev/null | xargs -0 ls -lnd 2>/dev/null"
                    while ((cmd | getline line) > 0) { split(line, w, " "); if (w[1] !~ /^d/) s += w[5] }
                    close(cmd)
                    kb = int((s + 1023) / 1024)
                }
                printf "%s{\"name\":%s,\"version\":%s,\"sizeKB\":%d,\"auto\":%s,\"neededBy\":%s,\"base\":%s,\"addon\":%s,\"addonTitle\":%s,\"section\":%s,\"description\":%s,\"installed\":%s}",
                    (i > 1 ? "," : ""), js(q), js(ver[q]), kb, (auto[q] ? "true" : "false"), js(by),
                    (index(base, " " q " ") ? "true" : "false"), js(addon[q]), js(addonTitle[q]), js(sect[q]), js(desc[q]),
                    (when[q] ~ /^[0-9]+$/ ? when[q] : "null")
            }
            printf "]\n"
        }' "$OPKG_STATUS" "$@"
}

installed_list() {
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    if [ "$JSON" = 1 ]; then
        if [ -f "$OPKG_STATUS" ]; then installed_json; else echo '[]'; fi
        return 0
    fi
    log "$CYAN" "Installed packages ($(installed_lines | wc -l | tr -d ' '))"
    installed_lines | while read -r n v a by; do
        note=""
        pkg_base "$n" && note=" (part of Entware)"
        [ "$a" = 1 ] && [ -z "$note" ] && note=" (needed by $(echo "$by" | sed 's/,/, /g'))"
        printf '  %-24s %-16s %6s KB%s\n' "$n" "$v" "$(pkg_size_kb "$n")" "$note"
    done
}

# Package list from Entware's server: refreshed if it's missing or a day old
fresh_lists() {
    h=$(lists_age_hours)
    if [ -z "$h" ] || [ "$h" -ge 24 ]; then
        /opt/bin/opkg update >/dev/null 2>&1 || [ -n "$h" ] ||
            error_exit "Couldn't download the package list. Check the TV's internet connection."
    fi
}

# Name matches first, then matches in the description; at most 60
search_list() {
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    term_ok "$TERM_ARG" || error_exit "Search for a word made of letters, numbers, dots, dashes, underscores or plus signs (up to 40)."
    fresh_lists
    inst=" $(installed_lines | awk '{printf "%s ", $1}') "
    t=$(echo "$TERM_ARG" | tr 'A-Z' 'a-z')
    tab=$(printf '\t')
    res=$(/opt/bin/opkg list 2>/dev/null | awk -F ' - ' -v t="$t" '
        NF >= 2 && $1 !~ / / {
            d = $3; for (i = 4; i <= NF; i++) d = d " - " $i
            n = tolower($1)
            # exact, then starts with it, then by where it appears and the shortest name
            i = index(n, t)
            if (i) print (n == t ? 0 : (i == 1 ? 1 : 20000 + i * 100 + length(n))) "\t" $1 "\t" $2 "\t" d
            else if (index(tolower(d), t)) print 900000 "\t" $1 "\t" $2 "\t" d
        }' | sort -t "$(printf '\t')" -k1,1n -k2,2 | head -n 60)
    if [ "$JSON" = 1 ]; then
        first=1
        printf '['
        while IFS="$tab" read -r _r n v d; do
            [ -n "$n" ] || continue
            [ "$first" = 1 ] || printf ','
            first=0
            case "$inst" in *" $n "*) i=true ;; *) i=false ;; esac
            printf '{"name":%s,"version":%s,"description":%s,"installed":%s}' \
                "$(json_str "$n")" "$(json_str "$v")" "$(json_str "$(echo "$d" | cut -c1-160)")" "$i"
        done << EOL
$res
EOL
        printf ']\n'
    else
        while IFS="$tab" read -r _r n v d; do
            [ -n "$n" ] || continue
            case "$inst" in *" $n "*) i=" [installed]" ;; *) i="" ;; esac
            printf '%s  %s%s\n    %s\n' "$n" "$v" "$i" "$(echo "$d" | cut -c1-120)"
        done << EOL
$res
EOL
    fi
}

pkg_add() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    pkg_name_ok "$PKG" || error_exit "That isn't a package name: $PKG"
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    if pkg_installed "$PKG"; then info "$PKG is already installed."; return 0; fi
    info "Installing $PKG..."
    fresh_lists
    /opt/bin/opkg install "$PKG" || error_exit "$PKG didn't install. Check the name, the TV's internet connection and free space."
    pkg_installed "$PKG" || error_exit "$PKG didn't install."
    post_install_action "$PKG"
    success "$PKG is installed."
}

pkg_remove() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    pkg_name_ok "$PKG" || error_exit "That isn't a package name: $PKG"
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first."
    pkg_installed "$PKG" || { info "$PKG isn't installed."; return 0; }
    pkg_base "$PKG" && error_exit "$PKG is part of Entware or its shell setup, so it stays."
    by=$(installed_lines | awk -v p="$PKG" '$1 == p && $4 != "-" {print $4}' | sed 's/,/, /g')
    [ -z "$by" ] || error_exit "$PKG is needed by $by.  Remove those first."
    # locate's settings and hourly job go with it
    if [ "$PKG" = mlocate ]; then addon_find locate && addon_remove locate; return; fi
    confirm "Remove $PKG?" || { info "Kept $PKG."; return 0; }
    # A service stops first, and its setup goes with it
    a=$(pkg_addon "$PKG")
    [ -n "$a" ] && addon_service "$a" && remove_service "$a"
    /opt/bin/opkg remove "$PKG" || error_exit "$PKG didn't uninstall cleanly. See: ent list"
    pkg_installed "$PKG" && error_exit "$PKG is still installed."
    success "Removed $PKG."
}

# === Logs: the boot log and the TV app's recent tasks ===
LOG_DIR="/opt/var/log/webos-entware"
# Keeps a finished task's log, with when it ran and how it ended (last 10)
archive_job() {
    [ -f "$JOB_DIR/exit" ] && [ -f "$JOB_DIR/log" ] || return 0
    opt_ours || return 0
    s=$(cat "$JOB_DIR/started" 2>/dev/null); e=$(cat "$JOB_DIR/exit" 2>/dev/null)
    n=$(tr -c 'A-Za-z0-9._+-' '_' < "$JOB_DIR/name" 2>/dev/null | sed 's/_*$//')
    case "$s$e" in ''|*[!0-9]*) return 0 ;; esac
    mkdir -p "$LOG_DIR" 2>/dev/null || return 0
    f="$LOG_DIR/$s-$e-${n:-task}.log"
    [ -e "$f" ] || cp "$JOB_DIR/log" "$f" 2>/dev/null
    # shellcheck disable=SC2012  # names are ours: digits, dashes and safe characters
    ls -1 "$LOG_DIR" 2>/dev/null | sort -rn | sed -n '11,$p' | while read -r old; do rm -f "$LOG_DIR/$old"; done
}
log_id_ok() { case "$1" in ''|*[!A-Za-z0-9._+-]*) return 1 ;; esac; return 0; }

logs_list() {
    archive_job
    if [ "$JSON" = 1 ]; then
        printf '{"boot":'
        tail -n 40 "$BOOT_LOG" 2>/dev/null | json_lines
        printf ',"current":%s,"tasks":[' "$(json_str "$(job_state)")"
        first=1
        # shellcheck disable=SC2012
        ls -1 "$LOG_DIR" 2>/dev/null | sort -rn | while read -r f; do
            s=${f%%-*}; r=${f#*-}; e=${r%%-*}; n=${r#*-}; n=${n%.log}
            [ "$first" = 1 ] || printf ','
            first=0
            printf '{"id":%s,"name":%s,"when":%s,"exit":%s}' "$(json_str "${f%.log}")" \
                "$(json_str "$(echo "$n" | tr '_' ' ')")" "$(json_str "$(date -d "@$s" '+%Y-%m-%d %H:%M' 2>/dev/null)")" "$(json_num "$e")"
        done
        printf ']}\n'
        return 0
    fi
    log "$CYAN" "Boot log ($BOOT_LOG)"
    if [ -s "$BOOT_LOG" ]; then sed 's/^/  /' "$BOOT_LOG"; else echo "  Nothing yet this boot."; fi
    echo
    log "$CYAN" "Recent tasks from the TV app ($LOG_DIR)"
    # shellcheck disable=SC2012
    ls -1 "$LOG_DIR" 2>/dev/null | sort -rn | while read -r f; do
        s=${f%%-*}; r=${f#*-}; e=${r%%-*}; n=${r#*-}; n=${n%.log}
        printf '  %s  %-20s %s\n' "$(date -d "@$s" '+%Y-%m-%d %H:%M' 2>/dev/null)" "$(echo "$n" | tr '_' ' ')" \
            "$( [ "$e" = 0 ] && echo "done" || echo "failed ($e)")"
    done
}

log_show() {
    log_id_ok "$LOG_ID" || error_exit "That isn't a log name: $LOG_ID"
    f="$LOG_DIR/$LOG_ID.log"
    [ -f "$f" ] || error_exit "No log called $LOG_ID.  See: webos-entware logs"
    if [ "$JSON" = 1 ]; then
        printf '{"id":%s,"log":' "$(json_str "$LOG_ID")"
        tail -n 300 "$f" | json_lines
        printf '}\n'
    else
        cat "$f"
    fi
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
    SRC=$BIND_SRC
    note() { echo "\$(date '+%H:%M:%S') \$1" >> $BOOT_LOG; }
    note "boot script started"
    # Boot scripts start with no PATH, and Entware's init scripts need one
    # to find what they start
    PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=$HOME_DIR; export PATH HOME
    n=0
    while [ ! -x "\$SRC/bin/opkg" ]; do
        if [ \$n -ge 30 ]; then
            note "gave up: \$SRC/bin/opkg wasn't there after 60 seconds"
            exit 0
        fi
        sleep 2
        n=\$((n + 1))
    done
    if [ /opt -ef "\$SRC" ]; then
        note "/opt was already mounted"
    elif mount --bind "\$SRC" /opt 2>> $BOOT_LOG; then
        note "mounted /opt"
    else
        note "failed to mount /opt"
        exit 0
    fi
    # Only Entware that's root's alone, checked on /opt itself now that it's
    # mounted: the folder, and everything on the way to what runs as root.
    # Anything else may have been swapped in, so it's unmounted unused.
    for p in $OPT_KEY; do
        [ -e "\$p" ] || continue
        if [ -L "\$p" ] || [ "\$(ls -ldn "\$p" | awk '{print substr(\$1, 6, 1) substr(\$1, 9, 1) " " \$3}')" != "-- 0" ]; then
            umount -l /opt 2>/dev/null
            note "refused to mount \$SRC: \$p isn't root's alone (owner or permissions changed)"
            exit 0
        fi
    done
    if [ -x /opt/etc/init.d/rc.unslung ]; then
        unset LD_PRELOAD LD_LIBRARY_PATH
        # In a session of their own, so services that stay in the foreground
        # (Tailscale, Syncthing, File Browser) outlive the boot
        if command -v setsid >/dev/null 2>&1; then setsid /opt/etc/init.d/rc.unslung start; else /opt/etc/init.d/rc.unslung start; fi >/dev/null 2>&1
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
    OLD_CHOICE=$(sed -n 's/^location_choice=//p' "$INFO_FILE" 2>/dev/null)
    OLD_CHOICE=${OLD_CHOICE:-auto}
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
location=$(loc_of "$BIND_SRC") $BIND_SRC
location_choice=${LOC_CHOICE:-$OLD_CHOICE}
EOF
}

install_entware() {
    preflight
    check_src
    check_free_space

    BUILD="" FALLBACK=""
    if [ -e "$BIND_SRC/bin/opkg" ]; then
        BUILD=$(feed_build "$BIND_SRC/etc/opkg.conf")
        info "Entware is already installed in $BIND_SRC, on $(loc_label "$BIND_SRC") (build: $(build_label "$BUILD"))."
        if [ -n "$FORCE_ARCH" ] && [ -n "$BUILD" ] && [ "$BUILD" != "$FORCE_ARCH" ]; then
            error_exit "Entware is installed for $BUILD. Uninstall first to switch to $FORCE_ARCH."
        fi
        confirm "Repair and update it? Your packages are kept." || exit 0
        HOW=""
        [ -n "$BUILD" ] || choose_build
        INSTALLING=1
    else
        info "Entware goes in $BIND_SRC, on $(loc_label "$BIND_SRC")."
        choose_build
        CREATED_SRC=0
        [ -e "$BIND_SRC" ] || CREATED_SRC=1
        snapshot_shell_files
        ROLLBACK=1
    fi
    trap on_install_exit EXIT
    trap 'exit 1' INT TERM HUP

    mkdir -p "$BIND_SRC/bin" "$BIND_SRC/etc" "$BIND_SRC/lib/opkg" "$BIND_SRC/tmp" "$BIND_SRC/var/lock"
    chmod 755 "$BIND_SRC"
    mount_opt
    cd /opt || error_exit "Cannot cd /opt"
    # Older versions replaced opkg with a wrapper; put the real one back
    [ -x /opt/bin/opkg.real ] && mv -f /opt/bin/opkg.real /opt/bin/opkg

    bootstrap_opkg
    /opt/bin/opkg update || error_exit "opkg update failed"
    /opt/bin/opkg install entware-opt || warn "entware-opt may have failed"
    # Everyone's scratch space, sticky so no one can rename or remove others' files
    chmod 1777 /opt/tmp

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
    migrate_to_appstore
    echo
    show_status
    echo
    [ "$SETUP_SHELL" = 1 ] && info "Disconnect and SSH in again to get the bash shell. Type 'helpme' for shortcuts."
    return 0
}

# Installs on user data (from older versions, or made where app storage
# wasn't there) move to app storage on a repair, with the same checked move
# as "move appstore", unless you chose user data. If the move can't happen
# now, Entware stays where it is, working, and the repair still succeeds.
migrate_to_appstore() {
    [ "$BIND_SRC" = "$USER_SRC" ] && [ "$(loc_choice)" != user ] && appstore_default || return 0
    echo
    info "Entware is on user data, which webOS needs for itself. App storage has more room and keeps Entware through \"Reset to initial settings\"."
    if [ "$ASSUME_YES" != 1 ] && ! confirm "Move Entware to app storage now?"; then
        sed -i 's/^location_choice=.*/location_choice=user/' "$INFO_FILE"
        info "Kept on user data, and repairs won't ask again. Move it any time: $(run_cmd) move appstore"
        return 0
    fi
    if (ASSUME_YES=1; move_entware appstore); then
        resolve_src
    else
        resolve_src
        warn "Entware stays on user data for now, working as before. Repair again later to move it, or run: $(run_cmd) move appstore"
    fi
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
    OLD_ID=""
    opt_ours && OLD_ID=$(dev_ino /opt)
    if ! unmount_opt; then
        warn "Couldn't unmount /opt, so $BIND_SRC was kept. Reboot the TV and run uninstall again to remove it."
    elif grep -qs " $BIND_SRC/" /proc/mounts; then
        warn "Something is still mounted inside $BIND_SRC, so it was kept to avoid deleting that. Unmount it, then run uninstall again."
    elif [ -e "$BIND_SRC" ] && ! remove_tree "$BIND_SRC" "$OLD_ID"; then
        warn "Couldn't confirm $BIND_SRC is the Entware folder (it may have been changed), so it was kept. Look at what's in it, and delete it yourself if it is."
    fi

    [ "$SELF" = /tmp/webos-entware-uninstall.sh ] && rm -f "$SELF"
    success "Entware removed."
    info "Disconnect and SSH in again to get the stock shell back."
}

# === Move Entware between user data and app storage ===
# Copies everything through a private mount of a fresh folder, checks the
# copy, switches /opt over, checks /opt is that copy, and only then removes
# the old folder (through a private mount too, after checking it's the one).
# Any failure before the switch leaves Entware where it was, untouched.
services() { [ -x /opt/etc/init.d/rc.unslung ] && (unset LD_PRELOAD LD_LIBRARY_PATH; /opt/etc/init.d/rc.unslung "$1" </dev/null >/dev/null 2>&1); return 0; }
# Every name with its type, mode and owner, every link target and every
# file's checksum under a folder, as one checksum. tmp is left out: it's
# scratch space.
tree_sum() {
    (cd "$1" || exit 1
     find . -mindepth 1 -path ./tmp -prune -o -print | sort | while IFS= read -r f; do
         if [ -L "$f" ]; then echo "L $f -> $(readlink "$f")"
         elif [ -d "$f" ]; then echo "D $f"
         elif [ -f "$f" ]; then echo "F $f $(md5sum < "$f" | cut -c1-32)"
         else echo "O $f"
         fi
     done
     find . -mindepth 1 -path ./tmp -prune -o -exec stat -c '%n %a %u %g' {} + | sort
    ) | md5sum | cut -c1-32
}
# Programs using Entware (files open in it, running from it, or sitting in
# a folder of it), other than this one and the shells it was started from:
# moving now could lose what they write. A path under /opt counts only if
# it's on Entware's own device (not the stock /opt hidden under it).
opt_users() {
    odev=$(stat -c %d /opt/ 2>/dev/null)
    mine=" $$ "
    p=$$
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
        mine="$mine$p "
    done
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        case "$mine" in *" $pid "*) continue ;; esac
        for l in "$d/exe" "$d/cwd" "$d"/fd/*; do
            case "$(readlink "$l" 2>/dev/null)" in
                /opt|/opt/*|"$BIND_SRC"|"$BIND_SRC"/*)
                    if [ "$(stat -L -c %d "$l" 2>/dev/null)" = "$odev" ]; then
                        echo "$(cat "$d/comm" 2>/dev/null) ($pid)"
                        break
                    fi ;;
            esac
        done
    done | sort -u | tr '\n' ' '
}
move_entware() {
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    # Not from inside /opt: this and everything it starts would count as
    # using Entware, and /opt has to be unmounted
    cd / || error_exit "Can't cd to /."
    case "$1" in
        appstore) TO=$APP_SRC ;;
        user) TO=$USER_SRC ;;
        *) error_exit "Move it where? Use: $(run_cmd) move appstore (app storage) or move user (user data)." ;;
    esac
    FROM=$BIND_SRC
    [ -e "$FROM/bin/opkg" ] || error_exit "Entware isn't installed, so there's nothing to move. To install it on app storage: $(run_cmd) install --location=$1"
    if [ "$FROM" = "$TO" ]; then
        info "Entware is already on $(loc_label "$TO") ($TO)."
        # Asked for by name, so it's a choice: repairs and notices leave it be
        if [ -n "$LOC_CHOICE" ] && [ -f "$INFO_FILE" ]; then
            if grep -q '^location_choice=' "$INFO_FILE"; then
                sed -i "s/^location_choice=.*/location_choice=$LOC_CHOICE/" "$INFO_FILE"
            else
                echo "location_choice=$LOC_CHOICE" >> "$INFO_FILE"
            fi
            [ "$TO" = "$USER_SRC" ] && info "It stays there: repairs won't move it, and the login notice is off."
        fi
        return 0
    fi
    opt_ours || error_exit "Entware isn't mounted on /opt. Run '$(fix_cmd)' first, then move it."
    opt_trusted || error_exit "The Entware on /opt isn't root's alone, so it wasn't moved. Run: $(run_cmd) doctor"
    TOPART=$(part_of "$TO")
    # App storage must be its own mounted partition, never the folder under it
    if [ "$TO" = "$APP_SRC" ] && ! grep -qs " $APP_PART " /proc/mounts; then
        error_exit "App storage ($APP_PART) isn't mounted, so Entware can't move there."
    fi
    [ -d "$TOPART" ] || error_exit "$TOPART is missing, so Entware can't move there."
    if [ -e "$TO" ] || [ -L "$TO" ]; then
        error_exit "$TO already exists, maybe from an earlier move. Look inside, remove it if you don't need it, then move again."
    fi
    # Mounts made inside Entware's /opt come after its own line in /proc/mounts
    # (ones under the stock /opt, hidden by Entware, come before)
    inner=$(awk '$2 == "/opt" {n = NR; m = ""} n && NR > n && $2 ~ "^/opt/" && m == "" {m = $2} END {print m}' /proc/mounts)
    [ -z "$inner" ] || error_exit "Something is mounted inside /opt ($inner). Unmount it, then move again."
    need=$(du -sk /opt/ 2>/dev/null | awk '{print $1}')
    free=$(free_kb_of "$TOPART")
    case "$need" in ''|*[!0-9]*) need="" ;; esac
    case "$free" in ''|*[!0-9]*) free="" ;; esac
    [ -n "$need" ] && [ -n "$free" ] || error_exit "Couldn't work out the space needed, so nothing was moved."
    if [ $((free - need)) -lt 51200 ]; then
        error_exit "Not enough space on $(loc_label "$TO"): Entware needs $(size_text "$need") plus 50 MB to spare, and $((free / 1024)) MB is free."
    fi
    info "Entware uses $(size_text "$need"). It moves from $(loc_label "$FROM") ($FROM) to $(loc_label "$TO") ($TO)."
    confirm "Move Entware? Its services stop for a moment, and your packages and settings come along." || exit 0

    # From here it runs to the end: Ctrl-C or a dropped SSH session can't
    # stop it halfway
    trap '' INT HUP TERM PIPE
    info "Stopping Entware services..."
    services stop
    busy=$(opt_users)
    if [ -n "$busy" ]; then
        services start
        error_exit "These are still using Entware, and moving now could lose what they write: $busy. Close them (and log out of other SSH sessions), then move again."
    fi
    OLD_ID=$(dev_ino /opt)
    if [ -z "$OLD_ID" ]; then
        services start
        error_exit "Couldn't read /opt's identity (stat -c), so nothing was moved."
    fi
    info "Checking what's there..."
    SUM=$(tree_sum /opt)

    # A fresh folder (mkdir fails if anything has that name), used only
    # through a private mount so it can't be swapped while it's filled
    if ! mkdir -m 755 "$TO" 2>/dev/null; then
        services start
        error_exit "Couldn't create $TO, so nothing was changed."
    fi
    mp=$(mktemp -d /tmp/.webos-entware-move.XXXXXX) || { services start; error_exit "Couldn't make a temporary folder, so nothing was changed."; }
    if ! mount --bind "$TO" "$mp" 2>/dev/null || ! src_safe "$mp" || [ -n "$(ls -A "$mp")" ]; then
        umount "$mp" 2>/dev/null; rmdir "$mp"
        services start
        error_exit "$TO changed while it was being set up, so nothing was moved. Look at what's there before trying again."
    fi
    NEW_ID=$(dev_ino "$mp")
    if [ -z "$NEW_ID" ]; then
        umount "$mp"; rmdir "$mp"; rmdir "$TO" 2>/dev/null
        services start
        error_exit "Couldn't read the new folder's identity (stat -c), so nothing was moved."
    fi
    info "Copying..."
    if ! cp -a /opt/. "$mp/" || [ "$(tree_sum "$mp")" != "$SUM" ]; then
        rm -rf "${mp:?}"/* "$mp"/.[!.]* "$mp"/..?* 2>/dev/null
        umount "$mp"; rmdir "$mp"
        rmdir "$TO" 2>/dev/null
        services start
        error_exit "The copy failed or didn't match the original (out of space?), so nothing was changed. Entware is still on $(loc_label "$FROM")."
    fi
    umount "$mp"; rmdir "$mp"

    # Switch /opt over. A shell or program still running from the old /opt
    # keeps working (lazy unmount); new ones see the new place. What gets
    # mounted must be the very folder that was filled and checked.
    cd /
    if ! umount /opt 2>/dev/null && ! umount -l /opt 2>/dev/null; then
        remove_tree "$TO" "$NEW_ID"
        services start
        error_exit "Couldn't unmount /opt, so nothing was changed. Reboot the TV and try again."
    fi
    if ! mount --bind "$TO" /opt 2>/dev/null || [ "$(dev_ino /opt)" != "$NEW_ID" ] || ! opt_trusted || ! opkg_works; then
        umount -l /opt 2>/dev/null
        remove_tree "$TO" "$NEW_ID"
        if mount --bind "$FROM" /opt 2>/dev/null && [ "$(dev_ino /opt)" = "$OLD_ID" ]; then
            services start
            error_exit "Entware didn't run from $(loc_label "$TO"), so it was put back on $(loc_label "$FROM"). Nothing was lost."
        fi
        umount -l /opt 2>/dev/null
        error_exit "Entware didn't run from $(loc_label "$TO"), and $FROM had changed, so /opt was left unmounted. Run: $(fix_cmd)"
    fi
    BIND_SRC=$TO
    # The login record first, then the boot script, which decides at boot
    is_ours "$HOME_DIR/.profile" && write_login_profile
    install_boot_script
    write_install_info
    services start
    success "Entware now runs from $(loc_label "$TO") ($TO)."

    if remove_tree "$FROM" "$OLD_ID"; then
        success "Removed the old copy from $(loc_label "$FROM"), freeing $(size_text "$need") there."
    else
        warn "Couldn't confirm $FROM is the old copy (it may have changed), so it was kept. Look at what's in it, and delete it yourself if it is."
    fi
    info "Programs already running keep using the old copy until they restart. Log in again to use the new one."
}

# === Update the TV app ===
# Downloads the newest release of the app from GitHub, checks it against the
# release's SHA256SUMS and that it really is this app, installs it with
# webOS's app installer, and reopens it. The saved webos-entware command is
# updated to the same release. Every URL is built here from the version
# number, which must look like 1.2.3; nothing else from the download is used.
fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 300 -o "$2" "$1"
    else
        wget -q -O "$2" "$1"
    fi
}
app_version() { sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' "$APP_DIR/appinfo.json" 2>/dev/null | head -n 1; }
# True when version $1 is newer than $2
version_gt() {
    awk -v a="$1" -v b="$2" 'BEGIN { split(a, x, "."); split(b, y, ".")
        for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
        exit 1 }'
}
# The webos-entware command's own version
manager_version() { sed -n 's/^VERSION="\([0-9.]*\)".*/\1/p' "$MANAGER" 2>/dev/null | head -n 1; }

# app-update --check: is a newer release out?  Only reads; the TV app asks
# this when it opens and every few hours, and shows an Update button if so.
app_update_check() {
    cur=$(app_version)
    UW=$(mktemp -d /tmp/.webos-entware-update.XXXXXX) || error_exit "Couldn't make a temporary folder."
    trap 'rm -rf "${UW:?}"' EXIT
    v=""
    if fetch "$RELEASES_URL/latest/download/SHA256SUMS" "$UW/SHA256SUMS" 2>/dev/null; then
        v=$(sed -n "s/^[0-9a-f]\{64\}  ${APP_ID}_\([0-9]*\.[0-9]*\.[0-9]*\)_all\.ipk\$/\1/p" "$UW/SHA256SUMS" | head -n 1)
    fi
    newer=false err=""
    [ -n "$v" ] && version_gt "$v" "${cur:-0}" && newer=true
    [ -n "$v" ] || err="Couldn't check GitHub for a new release."
    if [ "$JSON" = 1 ]; then
        printf '{"current":%s,"command":%s,"latest":%s,"newer":%s,"notes":%s,"error":%s}\n' \
            "$(json_str "$cur")" "$(json_str "$(manager_version)")" "$(json_str "$v")" "$newer" \
            "$(json_str "${v:+$RELEASES_URL/tag/v$v}")" "$(json_str "$err")"
        [ -n "$v" ]
        return
    fi
    [ -n "$v" ] || error_exit "Couldn't reach GitHub. Check the TV's internet connection."
    if [ "$newer" = true ]; then
        info "Version $v is out (the app is v${cur:-not installed}). What's new: $RELEASES_URL/tag/v$v"
        echo "Update with: $(run_cmd) app-update"
    else
        success "The app is up to date (v${cur:-$v})."
    fi
    return 0
}

app_update() {
    [ "$CHECK_ONLY" = 1 ] && { app_update_check; return; }
    [ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
    [ -f "$APP_DIR/appinfo.json" ] || error_exit "The Entware TV app isn't installed. Install it from the Homebrew Channel (repository https://ohmybahgosh.dev/repo)."
    # Installing replaces the app's folder, this script's copy included, so
    # carry on from a copy in /tmp (same process, so the lock stays ours)
    case "$SELF" in
        "$APP_DIR"/*|/opt/*|"$BIND_SRC"/*)
            cp "$SELF" /tmp/webos-entware-app-update.sh && exec sh /tmp/webos-entware-app-update.sh app-update -y ;;
    esac
    cur=$(app_version)
    UW=$(mktemp -d /tmp/.webos-entware-update.XXXXXX) || error_exit "Couldn't make a temporary folder."
    trap 'rm -rf "${UW:?}"; [ "$SELF" = /tmp/webos-entware-app-update.sh ] && rm -f "$SELF"; release_lock' EXIT
    info "Checking GitHub for the newest release (the app is v${cur:-unknown})..."
    fetch "$RELEASES_URL/latest/download/SHA256SUMS" "$UW/SHA256SUMS" ||
        error_exit "Couldn't reach GitHub. Check the TV's internet connection, or update from the Homebrew Channel."
    line=$(grep -E "^[0-9a-f]{64}  ${APP_ID}_[0-9]+\.[0-9]+\.[0-9]+_all\.ipk$" "$UW/SHA256SUMS" | head -n 1)
    [ -n "$line" ] || error_exit "The newest release has no TV app in it. Try the Homebrew Channel."
    sum=${line%% *}
    file=${line##* }
    v=${file#"${APP_ID}"_}
    v=${v%_all.ipk}
    if ! version_gt "$v" "${cur:-0}"; then
        # The command can lag behind the app (an app installed from the
        # Homebrew Channel doesn't update it), so bring it along anyway
        update_command "$v"
        success "The app is up to date (v${cur:-$v})."
        return 0
    fi
    info "Downloading v$v..."
    fetch "$RELEASES_URL/download/v$v/$file" "$UW/app.ipk" || error_exit "The download failed. Nothing was changed."
    [ "$(sha256sum "$UW/app.ipk" | awk '{print $1}')" = "$sum" ] ||
        error_exit "The download didn't match the release's checksum, so it wasn't installed."
    (cd "$UW" && ar x app.ipk control.tar.gz && mkdir c && tar xzf control.tar.gz -C c) >/dev/null 2>&1
    if ! grep -qx "Package: $APP_ID" "$UW/c/control" 2>/dev/null || ! grep -qx "Version: $v" "$UW/c/control" 2>/dev/null; then
        error_exit "The download isn't version $v of this app, so it wasn't installed."
    fi
    success "Downloaded v$v and checked it against the release."

    update_command "$v"

    info "Installing v$v. The app closes for a moment, then opens again."
    luna-send -n 1 luna://com.webos.appInstallService/dev/install \
        "{\"id\":\"$APP_ID\",\"ipkUrl\":\"$UW/app.ipk\",\"subscribe\":true}" < /dev/null > /dev/null 2>&1
    n=0
    while [ "$(app_version)" != "$v" ] && [ $n -lt 60 ]; do sleep 1; n=$((n + 1)); done
    [ "$(app_version)" = "$v" ] ||
        error_exit "webOS didn't finish installing v$v. Try again, or update from the Homebrew Channel."
    success "The app is now v$v."
    luna-send -n 1 luna://com.webos.notification/createToast "{\"sourceId\":\"$APP_ID\",\"message\":\"Entware app updated to v$v\"}" < /dev/null > /dev/null 2>&1
    luna-send -n 1 luna://com.webos.applicationManager/launch "{\"id\":\"$APP_ID\"}" < /dev/null > /dev/null 2>&1
    return 0
}

# The saved webos-entware command follows the app, when it's older than
# release $1 and the download checks out too ($UW/SHA256SUMS is that release's)
update_command() {
    opt_ours && [ -f "$MANAGER" ] || return 0
    version_gt "$1" "$(manager_version)" || return 0
    sline=$(grep -E "^[0-9a-f]{64}  webos-entware-installer\.sh$" "$UW/SHA256SUMS" | head -n 1)
    if [ -n "$sline" ] && fetch "$RELEASES_URL/download/v$1/webos-entware-installer.sh" "$UW/installer.sh" &&
        [ "$(sha256sum "$UW/installer.sh" | awk '{print $1}')" = "${sline%% *}" ] && grep -qs "$MARKER" "$UW/installer.sh"; then
        cp "$UW/installer.sh" "$MANAGER.new" && chmod 755 "$MANAGER.new" && mv -f "$MANAGER.new" "$MANAGER" &&
            success "Updated the webos-entware command to v$1."
    fi
    return 0
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
    echo "Location:           $(loc_label "$BIND_SRC") ($BIND_SRC)"
    printf "Root's alone:       "; yesno entware_safe
    printf "/opt mounted:       "; yesno opt_ours
    printf "opkg runs:          "; yesno opkg_works
    if opkg_works; then
        echo "Packages installed: $(pkg_count)"
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
    APP_KB=""
    grep -qs " $APP_PART " /proc/mounts && APP_KB=$(free_kb_of "$APP_PART")
    case "$APP_KB" in *[!0-9]*) APP_KB="" ;; esac
    case "$FREE_KB" in
        ''|*[!0-9]*) ;;
        *) printf "Free space:         "
           if [ "$FREE_KB" -lt 51200 ]; then printf '%b' "$RED$((FREE_KB / 1024)) MB$NC"; else printf '%s' "$((FREE_KB / 1024)) MB"; fi
           printf ' user data'
           [ -n "$APP_KB" ] && printf ', %s MB app storage' "$((APP_KB / 1024))"
           echo ;;
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
    if ! entware_safe; then
        bad=""
        for k in $OPT_KEY; do { [ -e "$k" ] || [ -L "$k" ]; } && ! entry_safe "$k" && { bad=$k; break; }; done
        issue "Entware isn't root's alone (${bad:-$BIND_SRC} is a link, not owned by root, or others can write to it), so the boot script won't mount it. If root owns it, fix it with: chmod go-w ${bad:-$BIND_SRC}. Otherwise look at what's in it first: it may not be the Entware this installer set up."
    fi
    if [ "$BIND_SRC" = "$APP_SRC" ] && [ -n "$APP_KB" ] && [ "$APP_KB" -lt 51200 ]; then
        issue "Only $((APP_KB / 1024)) MB is free on app storage, where Entware lives, so apps and packages may fail to install. 'ent du' shows the largest packages to remove."
    fi
    if [ "$BIND_SRC" = "$USER_SRC" ] && [ -n "$APP_KB" ] && [ "$(loc_choice)" != user ] && appstore_default; then
        note "Entware is on user data, which webOS needs for itself. App storage has $((APP_KB / 1024)) MB free and keeps Entware through \"Reset to initial settings\". A repair moves it there: $(fix_cmd)"
    fi
    case "$FREE_KB" in
        ''|*[!0-9]*) ;;
        *) [ "$FREE_KB" -lt 51200 ] &&
            issue "Only $((FREE_KB / 1024)) MB is free on user data, which webOS needs for itself. Running out can cause problems with the TV. 'ent du' shows the largest packages to remove." ;;
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

    if opt_ours && opkg_works; then
        n_up=$(upgradable | wc -l | tr -d ' ')
        [ "${n_up:-0}" -gt 0 ] 2>/dev/null &&
            note "$n_up package updates are available (package list from $(lists_date)). See them: $(run_cmd) updates"
    fi
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
        pkgs=$(pkg_count)
        used=$(du -sh "$BIND_SRC" 2>/dev/null | awk '{print $1}')
    fi
    free_kb=$(free_kb_of "$(part_of "$BIND_SRC")")
    user_kb=$(data_free_kb)
    app_kb=""
    grep -qs " $APP_PART " /proc/mounts && app_kb=$(free_kb_of "$APP_PART")
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
        "$(json_num "$pkgs")" "$(json_str "$used")" "$(json_num "$(mb_of "$free_kb")")"
    printf '"bootScript":%s,"bootLog":%s,"bash":%s,"shellFiles":%s,"helpers":%s,"tvHelpers":%s,' \
        "$(json_bool [ -x "$INIT_SCRIPT" ])" "$(json_str "$(tail -n 1 "$BOOT_LOG" 2>/dev/null)")" \
        "$(json_bool /opt/bin/bash -c true)" "$(json_bool is_ours "$HOME_DIR/.profile")" "$(json_bool helpers_ok)" \
        "$(json_bool tv_helpers_ok)"
    printf '"locationChoice":%s,' "$(json_str "$(loc_choice)")"
    up_n=""
    opkg_works && up_n=$(upgradable | wc -l | tr -d ' ')
    printf '"updates":%s,"updatesChecked":%s,"updatesAgeHours":%s,' "$(json_num "$up_n")" "$(json_str "$(lists_date)")" "$(json_num "$(lists_age_hours)")"
    printf '"location":%s,"srcSafe":%s,"userFreeMB":%s,"appFreeMB":%s,' "$(json_str "$(loc_of "$BIND_SRC")")" \
        "$(json_bool entware_safe)" "$(json_num "$(mb_of "$user_kb")")" "$(json_num "$(mb_of "$app_kb")")"
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
resolve_src
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
if [ "$1" = upgrade ] && [ -n "${2:-}" ] && [ "${2#-}" = "$2" ]; then
    ACTION=upgrade
    PKG=$2
    MOVE_TO=-    # so no other action can follow
    shift 2
elif [ "$1" = move ]; then
    ACTION=move
    MOVE_TO=${2:-}
    LOC_CHOICE=$MOVE_TO
    [ -n "$MOVE_TO" ] || error_exit "Move it where? Use: webos-entware move appstore (app storage) or move user (user data)."
    shift 2
elif [ "$1" = add ] || [ "$1" = remove ] || [ "$1" = info ] || [ "$1" = password ]; then
    ACTION=$1
    ADDON=${2:-}
    [ -n "$ADDON" ] || error_exit "Name an add-on, e.g. webos-entware $1 htop. See: webos-entware addons"
    shift 2
fi
case "$1" in
    search|pkg-add|pkg-remove|log)
        [ -n "${2:-}" ] || error_exit "$1 needs a name, e.g. webos-entware $1 htop"
        case "$1" in search) TERM_ARG=$2 ;; log) LOG_ID=$2 ;; *) PKG=$2 ;; esac
        ACTION=$1
        MOVE_TO=-    # so no other action can follow
        shift 2 ;;
esac
if [ "$1" = job-archive ]; then
    archive_job
    exit 0
fi
if [ "$1" = job-status ]; then
    [ "$2" = --json ] && JSON=1
    job_status
    exit 0
fi
if [ "$1" = web ]; then
    [ "${3:-}" = --json ] && JSON=1
    web_action "${2:-status}"
    exit 0
fi
for arg in "$@"; do
    case "$arg" in
        install|uninstall|status|locate|upgrade|addons|doctor|clean|app-update|updates|installed|logs)
            # add and remove take only options after the name
            [ -z "$ADDON" ] && [ -z "$MOVE_TO" ] || { usage; exit 1; }
            case "$arg" in doctor) ACTION="status" ;; clean) ACTION="uninstall" ;; *) ACTION="$arg" ;; esac ;;
        -y|--yes) ASSUME_YES=1 ;;
        --no-shell) SETUP_SHELL=0 ;;
        --with-locate) WITH_LOCATE=1 ;;
        --json) JSON=1 ;;
        --refresh) REFRESH=1 ;;
        --check) CHECK_ONLY=1 ;;
        --stdin) PW_FROM=stdin ;;
        --ask) PW_FROM=ask ;;
        --location=user|--location=appstore) LOCATION="${arg#--location=}" ;;
        --arch=aarch64-k3.10|--arch=armv7sf-k3.2) FORCE_ARCH="${arg#--arch=}" ;;
        -h|--help) usage; exit 0 ;;
        *) usage; exit 1 ;;
    esac
done

# Where a new install goes: --location if given, else app storage when it's
# there and has more room, else user data. An existing install stays put
# (a repair may move it to app storage; "move" moves it either way).
if [ -n "$LOCATION" ]; then
    LOC_CHOICE=$LOCATION
    if [ "$LOCATION" = appstore ]; then WANT=$APP_SRC; else WANT=$USER_SRC; fi
    if [ -e "$BIND_SRC/bin/opkg" ]; then
        if [ "$BIND_SRC" != "$WANT" ] && [ "$ACTION" = install ]; then
            error_exit "Entware is already installed on $(loc_label "$BIND_SRC"). To move it: $(run_cmd) move $LOCATION"
        fi
    else
        BIND_SRC=$WANT
    fi
elif [ ! -e "$USER_SRC/bin/opkg" ] && [ ! -e "$APP_SRC/bin/opkg" ] && appstore_default; then
    BIND_SRC=$APP_SRC
fi

# === Menu ===
if [ -z "$ACTION" ]; then
    # Piped in (wget -O- ... | sh), answers are read from the terminal instead
    if [ ! -t 0 ] && ! ( : < /dev/tty ) 2>/dev/null; then
        usage
        error_exit "No terminal for the menu. Pass install, uninstall or status, plus -y."
    fi
    echo
    log "$CYAN" "Minimal WebOS Entware Manager v$VERSION"
    if [ "$BIND_SRC" = "$USER_SRC" ] && [ -e "$USER_SRC/bin/opkg" ] && [ "$(loc_choice)" != user ] && appstore_default; then
        info "Entware is on user data, which webOS needs for itself. Option 1 (repair) moves it to app storage, which has more room and keeps it through \"Reset to initial settings\"."
    fi
    echo "1) Install or repair Entware"
    echo "2) Uninstall Entware"
    echo "3) Check status (doctor)"
    echo "4) Set up locate (mlocate)"
    echo "5) Add-ons (nano colors, git, python, htop, login banner, ...)"
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

[ "$CHECK_ONLY" = 1 ] && [ "$ACTION" != app-update ] && error_exit "--check goes with app-update."
case "$ACTION" in
    install|uninstall|locate|upgrade|add|remove|password|move|app-update|pkg-add|pkg-remove)
        # app-update --check only reads, so it doesn't wait on a running task
        if [ "$CHECK_ONLY" != 1 ]; then
            take_lock
            trap 'release_lock' EXIT
            trap 'exit 1' INT TERM HUP
        fi ;;
esac

case "$ACTION" in
    install) install_entware ;;
    uninstall) uninstall_entware ;;
    status) if [ "$JSON" = 1 ]; then status_json; else show_status; fi ;;
    locate) locate_action ;;
    upgrade) upgrade_packages ;;
    addons) addons_list ;;
    add) addon_add "$ADDON" ;;
    info) addon_info "$ADDON" ;;
    password) addon_password "$ADDON" ;;
    remove) addon_remove "$ADDON" ;;
    move) move_entware "$MOVE_TO" ;;
    app-update) app_update ;;
    installed) installed_list ;;
    search) search_list ;;
    pkg-add) pkg_add ;;
    pkg-remove) pkg_remove ;;
    logs) logs_list ;;
    log) log_show ;;
    updates) [ "$REFRESH" = 1 ] && take_lock && trap 'release_lock' EXIT
        check_updates ;;
esac
