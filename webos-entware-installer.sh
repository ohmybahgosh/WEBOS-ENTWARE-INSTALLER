#!/bin/sh

###############################################################################
# WebOS Minimal Entware Installer/Uninstaller                                 #
# Author: OhMyBahgosh                                                         #
# https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER                      #
###############################################################################
#
# Usage: sh webos-entware-installer.sh [install|uninstall|status|doctor] [options]
#        Run with no arguments for the menu, or with --help for options.

VERSION="2.2"

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
ENTWARE_BASE="http://bin.entware.net"
MARKER="webos-entware-installer"
BACKUP_SUFFIX=".pre-entware"
OS_INFO="/var/run/nyx/os_info.json"
HBC_DIR="/media/developer/apps/usr/palm/services/org.webosbrew.hbchannel.service"
TELNET_OFF="/var/luna/preferences/webosbrew_telnet_disabled"
ASSUME_YES=0
SETUP_SHELL=1
FORCE_ARCH=""
ROLLBACK=0

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
    echo "Usage: sh $0 [install|uninstall|status|doctor] [options]"
    echo "  install        Install Entware, or repair an existing install (packages are kept)"
    echo "  uninstall      Remove Entware, its packages and the shell setup it added"
    echo "  status         Check the TV and the install, and say what to fix (alias: doctor)"
    echo "Options:"
    echo "  -y, --yes      Don't ask; use the recommended build and answer yes"
    echo "  --no-shell     Install Entware only, leave .profile/.bashrc and the shell alone"
    echo "  --arch=ARCH    Use aarch64-k3.10 (64-bit) or armv7sf-k3.2 (32-bit) without asking"
}

# True when /opt is our bind mount
opt_ours() { [ /opt -ef "$BIND_SRC" ]; }
opt_mounted() { grep -qs " /opt " /proc/mounts; }

# True when a file was written by this installer (any version)
is_ours() {
    grep -qs -e "$MARKER" -e "exec /opt/bin/bash -l" -e "# Entware SSH Environment for WebOS" "$1"
}

# Write stdin to a shell file. Your own file is backed up first, and so is
# one of ours that changed since it was written (your edits, or an older
# version), so a repair never throws anything away.
write_managed() {
    cat > "$1.entware-new"
    if [ -f "$1" ] && cmp -s "$1.entware-new" "$1"; then
        rm -f "$1.entware-new"
        return 0
    fi
    if [ -f "$1" ] && ! is_ours "$1" && [ ! -f "$1$BACKUP_SUFFIX" ]; then
        cp -p "$1" "$1$BACKUP_SUFFIX" && info "Backed up $1 to $1$BACKUP_SUFFIX"
    elif [ -f "$1" ]; then
        cp -p "$1" "$1.bak" && info "Saved the old $1 as $1.bak before updating it"
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

# How to repair from a shell. The copy saved in Entware's folder still works
# after a reboot, even when /opt isn't mounted and /tmp was wiped.
fix_cmd() {
    if [ -f "$BIND_SRC/bin/webos-entware" ]; then
        echo "sh $BIND_SRC/bin/webos-entware install"
    else
        echo "sh $0 install"
    fi
}

opkg_works() { /opt/bin/opkg print-architecture 2>/dev/null | grep -q '^arch '; }

# === TV details ===
# Value of "key": "value" in a small JSON file or text (no jq on the TV)
json_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${2:--}" 2>/dev/null | head -n 1
}

# Run a command with a time limit when busybox timeout is there
limited() {
    if command -v timeout >/dev/null 2>&1; then timeout 5 "$@"; else "$@"; fi
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
        warn "Homebrew Channel isn't installed, so Entware won't be mounted again after a reboot."
        confirm "Continue without boot persistence?" || exit 0
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
    error_exit "The Entware build didn't run on this TV. Try 'sh $0 install' again and pick the other build."
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
    printf '%b\n' "  ${GREEN}install${NC} <pkg>    Install packages"
    printf '%b\n' "  ${GREEN}remove${NC} <pkg>     Remove packages"
    printf '%b\n' "  ${GREEN}info${NC} <pkg>       Show package details"
    printf '%b\n' "  ${GREEN}files${NC} <pkg>      List the files a package installed"
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
need_pkg() { [ -n "$1" ] || { printf '%b\n' "${RED}Name a package, e.g. ent $2 htop${NC}"; exit 1; }; }

case "$1" in
  search) shift; $OPKG_BIN list | grep -i -- "${1:-.}" | awk '{printf "\033[0;32m%s\033[0m - %s\n", $1, substr($0, index($0,$2))}' ;;
  install) shift; need_pkg "$1" install; $OPKG_BIN install "$@" ;;
  remove) shift; need_pkg "$1" remove; $OPKG_BIN remove "$@" ;;
  info) shift; need_pkg "$1" info; $OPKG_BIN info "$@" ;;
  files) shift; need_pkg "$1" files; $OPKG_BIN files "$@" ;;
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
        [ "$SELF" -ef "$MANAGER" ] || cp "$SELF" "$MANAGER"
        chmod 755 "$MANAGER"
    elif [ ! -f "$MANAGER" ]; then
        info "Couldn't save a copy of this installer (it was piped in). 'ent doctor' needs it: download it again to $MANAGER."
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
            words="search install remove info files update upgradable upgrade list repair doctor help"
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
    [ "$COMP_CWORD" -eq 1 ] && COMPREPLY=( $(compgen -W "install uninstall status doctor --help" -- "${COMP_WORDS[1]}") )
}
complete -F _entwrap_complete entwrap ent opkg
complete -F _webos_entware_complete webos-entware
COMPLETION

    /opt/bin/opkg list 2>/dev/null | awk '{print $1}' > /opt/tmp/entpkg-cache.txt
    success "Installed the ent helper, tab completion and the webos-entware command."
}

# === Bash Profile & Environment ===
setup_shell_environment() {
    /opt/bin/opkg install bash || warn "bash may not have installed."
    /opt/bin/opkg install nano-full || warn "nano-full may not have installed."
    /opt/bin/opkg install coreutils-dircolors || warn "dircolors may not have installed."
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
    echo -e "${CYAN}Manager:${NC}      ${GREEN}webos-entware status | install | uninstall${NC}"
    echo -e "${CYAN}Utils:${NC}        ${GREEN}edit findf reboot_safe${NC}"
}
BASHRC

    mkdir -p "$HOME_DIR"

    # Keep a ~/.bashrc we already set up, so your edits survive a repair (issue #2)
    if is_ours "$HOME_DIR/.bashrc" && grep -qs "$ENV_FILE" "$HOME_DIR/.bashrc"; then
        info "Kept your $HOME_DIR/.bashrc as it is."
    else
        bashrc_template | write_managed "$HOME_DIR/.bashrc"
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
[ -f "$HOME/.profile.pre-entware" ] && . "$HOME/.profile.pre-entware"
# If the boot script didn't mount Entware at this boot, do it now (issue #2)
if [ "$(id -u)" = 0 ] && [ -x /mnt/lg/user/opt/bin/opkg ] && ! grep -qs " /opt " /proc/mounts; then
    if mount --bind /mnt/lg/user/opt /opt 2>/dev/null; then
        echo "$(date '+%H:%M:%S') mounted /opt at login, the boot script hadn't" >> /tmp/webos-entware-boot.log
        if [ -x /opt/etc/init.d/rc.unslung ]; then
            (unset LD_PRELOAD LD_LIBRARY_PATH; /opt/etc/init.d/rc.unslung start >/dev/null 2>&1 &)
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

# === Mount Entware on every boot ===
install_boot_script() {
    if [ ! -d /var/lib/webosbrew ]; then
        warn "Homebrew Channel boot hooks not found, so /opt won't come back after a reboot."
        warn "Run 'sh $0 install' again after each reboot to remount it."
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

# === Install Entware ===
# Runs on any exit while installing: a fresh install that didn't finish is
# undone, so the TV is never left half set up
on_install_exit() {
    if [ "$ROLLBACK" = 1 ]; then
        ROLLBACK=0
        warn "The install didn't finish, so its changes are being undone."
        cd / || true
        rm -f "$INIT_SCRIPT"
        restore_shell_files
        if opt_ours; then umount /opt 2>/dev/null || umount -l /opt 2>/dev/null; fi
        [ "$CREATED_SRC" = 1 ] && rm -rf "$BIND_SRC"
        info "Undone. The TV is back to how it was before the install."
    elif [ "$INSTALLING" = 1 ]; then
        INSTALLING=0
        warn "The repair didn't finish. Your existing install and packages were kept."
        info "Run 'sh $0 doctor' to see what needs fixing."
    fi
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
    if [ "$SETUP_SHELL" = 1 ]; then
        setup_shell_environment
    else
        info "Skipped the shell setup. Entware programs are in /opt/bin and /opt/sbin."
    fi
    install_boot_script
    verify_install
    ROLLBACK=0 INSTALLING=0
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
            mv -f "$p" "$p.entware-saved" && info "Your edited $p was saved as $p.entware-saved"
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

    cd /
    if opt_ours; then
        umount /opt 2>/dev/null || umount -l /opt 2>/dev/null ||
            warn "Couldn't unmount /opt. It will be gone after a reboot."
    fi
    rm -rf "$BIND_SRC"

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
        info "Entware isn't installed. Run 'sh $0 install'."
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

    [ "$(id -u)" -eq 0 ] || note "Run as root for a full check."
    hbc_present || issue "Homebrew Channel isn't installed, so /opt isn't mounted again after a reboot."
    if opt_ours && grep -qs "at login" "$BOOT_LOG" && ! grep -qs "boot script started" "$BOOT_LOG"; then
        note "The boot script didn't run at this boot, so your SSH login mounted /opt instead. Entware works, but its services only start once you log in. If this happens after every reboot, please open an issue on GitHub with this output."
    fi
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

# === Arguments ===
ACTION=""
for arg in "$@"; do
    case "$arg" in
        install|uninstall|status) ACTION="$arg" ;;
        doctor) ACTION="status" ;;
        clean) ACTION="uninstall" ;;
        -y|--yes) ASSUME_YES=1 ;;
        --no-shell) SETUP_SHELL=0 ;;
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
    echo "4) Exit"
    echo
    read_answer "Choose an option [1-4]: " || exit 1
    case "$ANSWER" in
        1) ACTION="install" ;;
        2) ACTION="uninstall" ;;
        3) ACTION="status" ;;
        *) log "$CYAN" "Goodbye!"; exit 0 ;;
    esac
fi

case "$ACTION" in
    install) install_entware ;;
    uninstall) uninstall_entware ;;
    status) show_status ;;
esac
