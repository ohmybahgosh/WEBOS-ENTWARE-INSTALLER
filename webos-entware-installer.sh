#!/bin/sh

###############################################################################
# WebOS Entware Installer/Uninstaller with USB Support - Final Enhanced Build #
# Author: OhMyBahgosh                                                         #
# Repo: https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER               #
###############################################################################

# === Color Codes ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# === Paths and URLs ===
DEFAULT_DST="/mnt/lg/user/opt"
USB_DST="/mnt/lg/user/usb/entware"
OPKG_DOWNLOAD_URL="http://bin.entware.net/aarch64-k3.10/installer/opkg"
FEED_URL="http://bin.entware.net/aarch64-k3.10"

# === Logging Helpers ===
log() { echo -e "$1$2${NC}"; }
error_exit() { log "$RED" "[ERROR] $1"; exit 1; }
success() { log "$GREEN" "[SUCCESS] $1"; }
warn() { log "$YELLOW" "[WARNING] $1"; }
confirm() { printf "${YELLOW}$1 [y/N]: ${NC}"; read -r ans; [ "$ans" = "y" ] || [ "$ans" = "Y" ]; }

# === Checks ===
[ "$(id -u)" -eq 0 ] || error_exit "Must be run as root."
[ -d "/mnt/lg/user" ] || error_exit "Not a webOS device."

check_internet() {
    ping -c1 -W2 bin.entware.net >/dev/null 2>&1 || error_exit "No internet connection."
}

check_free_space() {
    SPACE=$(df "$1" | awk 'NR==2 {print $4}')
    [ "$SPACE" -lt 20000 ] && warn "Low free space on $1 (${SPACE}K)" && confirm "Continue anyway?" || return 0
}

setup_identity_files() {
    mkdir -p /opt/etc
    echo "root:x:0:0:root:/root:/bin/sh" > /opt/etc/passwd
    echo "root:x:0:" > /opt/etc/group
    success "Created /opt/etc/passwd and group."
}

# === Entwrap CLI and Tab Completion ===
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
    echo -e "  ${GREEN}search${NC} <pkg>      - Search packages"
    echo -e "  ${GREEN}install${NC} <pkg>     - Install a package"
    echo -e "  ${GREEN}remove${NC} <pkg>      - Remove a package"
    echo -e "  ${GREEN}info${NC} <pkg>        - Package info"
    echo -e "  ${GREEN}update${NC}            - Update lists"
    echo -e "  ${GREEN}upgrade${NC}           - Upgrade packages"
    echo -e "  ${GREEN}list${NC}              - List installed"
    echo -e "  ${GREEN}repair${NC}            - Repair core"
    echo -e "  ${GREEN}help${NC}              - Show help"
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

    # Safe bash-completion (Bash only)
    mkdir -p /opt/etc/bash_completion.d
    cat > /opt/etc/bash_completion.d/entwrap << 'EOF'
if [ -n "$BASH_VERSION" ]; then
  _entwrap_complete() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    opts="search install remove info update upgrade list repair help"
    if [ $COMP_CWORD -eq 1 ]; then
      COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
    elif [ $COMP_CWORD -eq 2 ] && [ -f /opt/tmp/entpkg-cache.txt ]; then
      COMPREPLY=( $(compgen -W "$(cat /opt/tmp/entpkg-cache.txt)" -- "${cur}") )
    fi
  }
  complete -F _entwrap_complete entwrap
  complete -F _entwrap_complete ent
fi
EOF

    /opt/bin/opkg list | awk '{print $1}' > /opt/tmp/entpkg-cache.txt
    success "Installed entwrap CLI with tab completion."
}
# === Safe opkg Redirect Wrapper ===
setup_opkg_wrapper() {
    [ -f /opt/bin/opkg ] && mv /opt/bin/opkg /opt/bin/opkg.real
    cat > /opt/bin/opkg << 'EOF'
#!/bin/sh
echo -e "\033[0;33m[WARNING]\033[0m Direct opkg usage discouraged."
/opt/bin/entwrap "$@"
EOF
    chmod +x /opt/bin/opkg
    success "Installed opkg wrapper."
}

# === Environment Setup (bash, nano, dircolors, aliases, PS1) ===
setup_bash_environment() {
    /opt/bin/entwrap install bash || warn "bash may not have installed properly."
    /opt/bin/entwrap install nano-full || warn "nano-full may not have installed properly."
    /opt/bin/entwrap install coreutils-dircolors || warn "dircolors may not have installed properly."

    HOME_DIR="/home/root"
    mkdir -p "$HOME_DIR"

    cat > "$HOME_DIR/.bashrc" << 'EOF'
# === Entware Bash Environment ===
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
alias reboot_safe='echo "Use at your own risk (reboot)"; sleep 2; reboot'
alias tr0='truncate -s0'

# Neon Prompt
RED="\033[0;31m"
GRN="\033[0;32m"
YEL="\033[0;33m"
MAG="\033[0;35m"
RST="\033[0m"
PS1="${MAG}\u${RST}@${GRN}\h${RST}:${YEL}\w${RST}\$ "

helpme() {
  CYAN='\033[0;36m'
  GREEN='\033[0;32m'
  NC='\033[0m'
  echo -e "${CYAN}== WebOS SSH Commands ==${NC}"
  echo -e "${GREEN}Navigation:${NC} ..  ...  cd"
  echo -e "${GREEN}System:${NC} myip  netinfo  dfh  up"
  echo -e "${GREEN}Packages:${NC} entup  entlist  entfix"
  echo -e "${GREEN}Utilities:${NC} edit  findf  reboot_safe"
}

findf() {
  if [ -z "$1" ]; then echo "Usage: findf <pattern>"; return 1; fi
  find . -iname "*$1*" 2>/dev/null | grep --color=auto "$1"
}
EOF

    cat > "$HOME_DIR/.profile" << 'EOF'
if [ -x /opt/bin/bash ]; then
  . ~/.bashrc
  exec /opt/bin/bash -l
fi
EOF

    success "Shell environment configured."
}

# === Entware Installation Logic ===
install_entware() {
    TARGET="$1"
    [ -z "$TARGET" ] && TARGET="$DEFAULT_DST"

    check_internet
    check_free_space "$TARGET"

    mkdir -p "$TARGET/bin" "$TARGET/etc" "$TARGET/lib" "$TARGET/tmp" "$TARGET/var/lock"

    if ! mountpoint -q /opt; then
        mount --bind "$TARGET" /opt || error_exit "Bind-mount failed."
    fi

    cd /opt || error_exit "Could not cd to /opt"
    wget -q -O /opt/bin/opkg "$OPKG_DOWNLOAD_URL" || error_exit "opkg download failed."
    chmod 755 /opt/bin/opkg

    cat > /opt/etc/opkg.conf << EOF
src/gz entware $FEED_URL
dest root /
dest ram /tmp
lists_dir ext /opt/var/opkg-lists
option tmp_dir /opt/tmp
EOF

    /opt/bin/opkg update || error_exit "opkg update failed."
    /opt/bin/opkg install entware-opt || warn "entware-opt may have issues."

    setup_identity_files
    install_entwrap
    setup_opkg_wrapper
    setup_bash_environment

    success "Entware fully installed to: $TARGET"
}

migrate_existing() {
    [ -d "$DEFAULT_DST" ] || error_exit "No existing Entware found."
    mkdir -p "$USB_DST"
    cp -a "$DEFAULT_DST/"* "$USB_DST"/ || error_exit "Copy failed"
    success "Migration complete."
}

clean_old_entware() {
    warn "Removing old Entware..."
    umount /opt 2>/dev/null
    rm -rf "$DEFAULT_DST"
    rm -f /var/lib/webosbrew/init.d/S99entware
    success "Old Entware removed."
}

# === MENU ===
main_menu() {
    echo
    log "$CYAN" "Minimal WebOS Entware Manager"
    echo "1) Install to internal (/mnt/lg/user/opt)"
    echo "2) Install to USB (/mnt/lg/user/usb/entware)"
    echo "3) Migrate existing install to USB"
    echo "4) Clean old Entware install"
    echo "5) Exit"
    echo
    printf "${YELLOW}Choose [1-5]: ${NC}"
    read -r choice
    case "$choice" in
        1) install_entware "$DEFAULT_DST" ;;
        2) install_entware "$USB_DST" ;;
        3) migrate_existing ;;
        4) clean_old_entware ;;
        *) log "$CYAN" "Goodbye!"; exit 0 ;;
    esac
}

main_menu
