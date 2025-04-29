#!/bin/sh

###############################################################################
# WebOS Minimal Entware Installer/Uninstaller - Final Fixed Enhanced Version  #
# Author: OhMyBahgosh                                                         #
###############################################################################

# === Color Codes ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Paths and URLs ===
BIND_SRC="/mnt/lg/user/opt"
OPKG_DOWNLOAD_URL="http://bin.entware.net/aarch64-k3.10/installer/opkg"
FEED_URL="http://bin.entware.net/aarch64-k3.10"

# === Helper Functions ===
log() { echo -e "$1$2${NC}"; }
error_exit() { log "$RED" "[ERROR] $1"; exit 1; }
success() { log "$GREEN" "[SUCCESS] $1"; }
warn() { log "$YELLOW" "[WARNING] $1"; }
confirm() { printf "${YELLOW}$1 [y/N]: ${NC}"; read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ]; }

# === Pre-checks ===
[ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
[ -d "/mnt/lg/user" ] || error_exit "Not a webOS device (missing /mnt/lg/user)."

# === Internet and Free Space Checks ===
check_internet() { ping -c1 -W2 bin.entware.net >/dev/null 2>&1 || error_exit "No internet connection detected."; }
check_free_space() {
    SPACE=$(df /mnt/lg/user | awk 'NR==2 {print $4}')
    [ "$SPACE" -lt 20000 ] && warn "Low free space: ${SPACE}K" && confirm "Continue anyway?" || return 0
}

# === Setup Identity Files (Fix 'I have no name!') ===
setup_identity_files() {
    mkdir -p /opt/etc
    echo "root:x:0:0:root:/root:/bin/sh" > /opt/etc/passwd
    echo "root:x:0:" > /opt/etc/group
    success "Setup /opt/etc/passwd and /opt/etc/group."
}

# === Install Embedded Entwrap CLI ===
install_entwrap() {
    cat > /opt/bin/entwrap << 'EOF'
#!/bin/sh
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'
ENTWARE_PATH="/opt"

if [ -x "$ENTWARE_PATH/bin/opkg.real" ]; then
    OPKG_BIN="$ENTWARE_PATH/bin/opkg.real"
else
    OPKG_BIN="$ENTWARE_PATH/bin/opkg"
fi

print_usage() {
    echo -e "${CYAN}Entwrap${NC} - Entware Package Manager for webOS"
    echo
    echo "Commands:"
    echo -e "  ${GREEN}search${NC} <pkg>      - Search for packages"
    echo -e "  ${GREEN}install${NC} <pkg>     - Install a package"
    echo -e "  ${GREEN}remove${NC} <pkg>      - Remove a package"
    echo -e "  ${GREEN}info${NC} <pkg>        - Show package info"
    echo -e "  ${GREEN}update${NC}            - Update package list"
    echo -e "  ${GREEN}upgrade${NC}           - Upgrade installed packages"
    echo -e "  ${GREEN}list${NC}              - List installed packages"
    echo -e "  ${GREEN}repair${NC}            - Repair Entware core"
    echo -e "  ${GREEN}help${NC}              - Show this help message"
}

[ ! -x "$OPKG_BIN" ] && echo -e "${RED}[ERROR]${NC} opkg missing." && exit 1

CMD="$1"; shift
case "$CMD" in
    search) "$OPKG_BIN" list | grep -i "$@" | awk '{printf "\033[0;32m%s\033[0m - %s\n", $1, substr($0, index($0,$2))}' ;;
    install) "$OPKG_BIN" install "$@" ;;
    remove) "$OPKG_BIN" remove "$@" ;;
    info) "$OPKG_BIN" info "$@" ;;
    update) "$OPKG_BIN" update ;;
    upgrade) "$OPKG_BIN" upgrade ;;
    list) "$OPKG_BIN" list-installed ;;
    repair) "$OPKG_BIN" update && "$OPKG_BIN" install entware-opt ;;
    help|*) print_usage ;;
esac
EOF

    chmod +x /opt/bin/entwrap
    ln -sf /opt/bin/entwrap /opt/bin/ent

    mkdir -p /opt/etc/bash_completion.d
    cat > /opt/etc/bash_completion.d/entwrap << 'COMPLETION'
_entwrap_complete() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="search install remove info update upgrade list repair help"

    if [ $COMP_CWORD -eq 1 ]; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    elif [ $COMP_CWORD -eq 2 ]; then
        if [ -f /opt/tmp/entpkg-cache.txt ]; then
            COMPREPLY=( $(compgen -W "$(cat /opt/tmp/entpkg-cache.txt)" -- "${cur}") )
        fi
    fi
}
complete -F _entwrap_complete entwrap
complete -F _entwrap_complete ent
COMPLETION

    /opt/bin/opkg list | awk '{print $1}' > /opt/tmp/entpkg-cache.txt
    success "Installed entwrap CLI with tab-completion."
}

# === Setup Safe opkg Wrapper ===
setup_opkg_wrapper() {
    [ -f /opt/bin/opkg ] && mv /opt/bin/opkg /opt/bin/opkg.real
    cat > /opt/bin/opkg << 'EOF'
#!/bin/sh
echo -e "\033[0;33m[WARNING]\033[0m Direct opkg usage discouraged!"
/opt/bin/entwrap "$@"
EOF
    chmod +x /opt/bin/opkg
    success "Installed safe opkg wrapper."
}

# === Setup bash, nano-full, coreutils-dircolors ===
setup_bash_environment() {
    /opt/bin/entwrap install bash || warn "bash install may have issues."
    /opt/bin/entwrap install nano-full || warn "nano-full install may have issues."
    /opt/bin/entwrap install coreutils-dircolors || warn "dircolors install may have issues."

    HOME_DIR="/home/root"
    mkdir -p "$HOME_DIR"

    cat > "$HOME_DIR/.bashrc" << 'EOF'
# WebOS Entware Environment
export PATH="/opt/bin:/opt/sbin:$PATH"
export TERM=xterm-256color
export LS_OPTIONS='--color=auto'
eval "`dircolors`"
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
alias grep='grep --color=auto'
alias edit='nano'
alias entup='entwrap update'
alias entlist='entwrap list'
alias entfix='entwrap repair'
alias reboot_safe='echo "Use at your own risk! (reboot)" && sleep 2 && reboot'
alias tr0='truncate -s0'

# Neon Prompt
RED="\[\033[0;31m\]"
GRN="\[\033[0;32m\]"
YEL="\[\033[0;33m\]"
MAG="\[\033[0;35m\]"
RST="\[\033[0m\]"
PS1="${MAG}\u${RST}@${GRN}\h${RST}:${YEL}\w${RST}\$ "

findf() {
    if [ -z "$1" ]; then echo "Usage: findf <pattern>"; return 1; fi
    find . -iname "*$1*" 2>/dev/null | grep --color=auto "$1"
}

helpme() {
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}== WebOS SSH Quick Commands ==${NC}\n"
echo -e "${CYAN}Navigation:${NC}\n  ${GREEN}..${NC}, ${GREEN}...${NC}"
echo -e "${CYAN}File Listing:${NC}\n  ${GREEN}ls, ll, l, la, lt${NC}"
echo -e "${CYAN}System Info:${NC}\n  ${GREEN}myip, netinfo, dfh, up${NC}"
echo -e "${CYAN}Package Management:${NC}\n  ${GREEN}entup, entlist, entfix, entwrap help${NC}"
echo -e "${CYAN}Utilities:${NC}\n  ${GREEN}edit, findf, reboot_safe, grep${NC}"
}

# Load entwrap tab-completion if available
if [ -f /opt/etc/bash_completion.d/entwrap ]; then
  . /opt/etc/bash_completion.d/entwrap
fi


EOF

    cat > "$HOME_DIR/.profile" << 'EOF'
if [ -x /opt/bin/bash ]; then
    . ~/.bashrc
    exec /opt/bin/bash -l
fi
EOF

    success "Bash environment fully configured."
}

# === Install Entware ===
install_entware() {
    check_internet
    check_free_space
    mkdir -p "$BIND_SRC/bin" "$BIND_SRC/etc" "$BIND_SRC/lib" "$BIND_SRC/tmp" "$BIND_SRC/var/lock"

    if ! mountpoint -q /opt; then
        mount --bind "$BIND_SRC" /opt || error_exit "Failed to bind-mount /opt."
    fi

    cd /opt || error_exit "Cannot access /opt."
    wget -q -O /opt/bin/opkg "$OPKG_DOWNLOAD_URL" || error_exit "Download opkg failed."
    chmod 755 /opt/bin/opkg

    cat > /opt/etc/opkg.conf << EOF
src/gz entware $FEED_URL
dest root /
dest ram /tmp
lists_dir ext /opt/var/opkg-lists
option tmp_dir /opt/tmp
EOF

    /opt/bin/opkg update || error_exit "opkg update failed."
    /opt/bin/opkg install entware-opt || warn "entware-opt install issues."

    setup_identity_files
    install_entwrap
    setup_opkg_wrapper
    setup_bash_environment

    success "Entware installation complete!"
}

# === Clean Old Installations ===
clean_old_entware() {
    warn "Cleaning old Entware remnants..."
    if mountpoint -q /opt; then umount /opt || warn "Could not unmount /opt."; fi
    rm -rf /mnt/lg/user/opt
    rm -f /var/lib/webosbrew/init.d/S99entware 2>/dev/null
    success "Old Entware remnants removed."
}

# === Main Menu ===
echo
log "$CYAN" "Minimal WebOS Entware Manager"
echo "1) Install Entware"
echo "2) Clean Old Entware Remnants"
echo "3) Exit"
echo
printf "${YELLOW}Choose an option [1-3]: ${NC}"
read -r choice

case "$choice" in
    1) install_entware ;;
    2) clean_old_entware ;;
    *) log "$CYAN" "Goodbye!"; exit 0 ;;
esac
