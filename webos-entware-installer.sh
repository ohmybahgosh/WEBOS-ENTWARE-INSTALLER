#!/bin/sh
#
# WebOS Entware Safe Installer v1.3
# 
# This script safely installs Entware on rooted LG webOS TVs
# by using /mnt/lg/user/opt as a writable alternative to /opt
#
# Features:
# - Safe installation of Entware package manager
# - Interactive menu-based interface
# - Automatic bash installation and configuration
# - Enables bash as default SSH shell
# - Sets up proper PATH and environment
# - Handles installations of potentially sensitive packages
# - Status check and backup functionality
# - Clean uninstall option
#
# Usage: 
#   Direct download and run:
#   curl -sL https://example.com/webos_entware_installer.sh | sh
#   
#   or
#   
#   wget -O- https://example.com/webos_entware_installer.sh | sh
#
# The script handles both direct execution and one-line installation methods
#

# ANSI color codes for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Paths and configuration
BIND_PATH="/mnt/lg/user/opt"
ENTWARE_URL="http://bin.entware.net/aarch64-k3.10/installer"
BACKUP_DIR="/opt/etc/backup"
INITD_SCRIPT="/var/lib/webosbrew/init.d/S99entware"
ENTWRAP_PATH="/opt/bin/entwrap"
COMPLETION_FILE="/opt/etc/bash_completion.d/entwrap"
LOCAL_COPY="/opt/etc/entware_installer.sh"
CACHE_FILE="/opt/tmp/entpkg-cache.txt"
PROFILE_FILE="${HOME}/.profile"
BASHRC_FILE="${HOME}/.bashrc"

#############################################################
# HELPER FUNCTIONS
#############################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    return 1
}

log_header() {
    echo -e "\n${MAGENTA}===== $1 =====${NC}\n"
}

confirm() {
    printf "${YELLOW}$1 [y/N] ${NC}"
    read -r confirm
    case "$confirm" in
        y|Y) return 0 ;;
        *) return 1 ;;
    esac
}

save_local_copy() {
    if [ -f "$LOCAL_COPY" ]; then
        return
    fi
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$LOCAL_COPY")"
    
    # Save a copy of this script
    cp "$0" "$LOCAL_COPY" 2>/dev/null || cat "$0" > "$LOCAL_COPY"
    chmod +x "$LOCAL_COPY"
    log_success "Local copy saved at $LOCAL_COPY"
}

#############################################################
# SYSTEM CHECK FUNCTIONS
#############################################################

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_webos() {
    if [ ! -d "/mnt/lg/user" ]; then
        log_error "This doesn't appear to be a webOS device (missing /mnt/lg/user)"
        return 1
    fi
    
    # Check if this is likely an LG webOS device
    if ! grep -qi "webos\|lg" /etc/issue /etc/os-release 2>/dev/null; then
        log_warning "Cannot confirm this is an LG webOS device"
        if ! confirm "Are you sure this is a webOS TV?"; then
            log_info "Installation aborted by user"
            return 1
        fi
    fi
    return 0
}

check_writable_user_path() {
    if ! touch /mnt/lg/user/entware_test 2>/dev/null; then
        log_error "Cannot write to /mnt/lg/user - check if the device is properly rooted"
        return 1
    fi
    
    rm -f /mnt/lg/user/entware_test
    log_success "/mnt/lg/user is writable"
    return 0
}

early_mount_opt() {
    log_info "Checking /opt mount state..."
    
    if ! mountpoint -q /opt; then
        log_warning "/opt is not mounted. Attempting to bind from $BIND_PATH..."
        mkdir -p "$BIND_PATH"
        if mount --bind "$BIND_PATH" /opt; then
            log_success "Mounted $BIND_PATH to /opt"
        else
            log_warning "Failed to bind-mount /opt. Will attempt alternative approaches."
        fi
    else
        log_info "/opt is already mounted"
    fi
    
    # Create necessary directories
    mkdir -p /opt/bin /opt/etc /opt/lib /opt/tmp /opt/var/lock
}

#############################################################
# INSTALLATION FUNCTIONS
#############################################################

setup_user_opt() {
    log_header "Setting up $BIND_PATH"
    
    if [ ! -d "$BIND_PATH" ]; then
        log_info "Creating $BIND_PATH directory"
        mkdir -p "$BIND_PATH"
        if [ $? -ne 0 ]; then
            log_error "Failed to create $BIND_PATH directory"
            return 1
        fi
    else
        log_info "$BIND_PATH already exists"
    fi
    
    # Create necessary subdirectories
    for dir in bin sbin etc lib tmp var; do
        if [ ! -d "$BIND_PATH/$dir" ]; then
            mkdir -p "$BIND_PATH/$dir"
            log_info "Created $BIND_PATH/$dir"
        fi
    done
    
    # Create completion directory for later use
    mkdir -p "$BIND_PATH/etc/bash_completion.d"
    
    log_success "User opt directory structure ready"
    return 0
}

install_entware() {
    log_header "Installing Entware"
    
    # Check if Entware is already installed
    if [ -f "/opt/bin/opkg" ]; then
        log_warning "Entware appears to be already installed."
        if ! confirm "Continue anyway and reinstall?"; then
            log_info "Installation cancelled by user."
            return 1
        fi
    fi
    
    # Early mount check - ensure /opt is accessible
    early_mount_opt
    
    # Download the entware installer or use the generic one
    log_info "Downloading Entware installer..."
    mkdir -p /opt/tmp
    cd /opt/tmp
    
    if ! wget -q -O entware_installer.sh "$ENTWARE_URL/opkg"; then
        log_warning "Failed to download from $ENTWARE_URL/opkg, trying generic installer..."
        wget -q -O entware_installer.sh http://bin.entware.net/armv7sf-k3.2/installer/generic.sh
    fi
    
    if [ $? -ne 0 ]; then
        log_error "Failed to download Entware installer"
        return 1
    fi
    
    # Make the installer executable
    chmod +x entware_installer.sh
    
    log_info "Setting up Entware directories..."
    mkdir -p /opt/bin /opt/etc/opkg /opt/lib /opt/tmp /opt/var/lock
    
    # Run the installer and create symlinks
    log_info "Installing opkg..."
    cp entware_installer.sh /opt/bin/opkg && chmod 755 /opt/bin/opkg
    
    # Download opkg.conf if needed
    if [ ! -f /opt/etc/opkg.conf ]; then
        log_info "Downloading opkg configuration..."
        wget -q -O /opt/etc/opkg.conf "$ENTWARE_URL/opkg.conf" || {
            log_warning "Failed to download opkg.conf, creating a basic one..."
            cat > /opt/etc/opkg.conf << 'EOT'
src/gz entware http://bin.entware.net/aarch64-k3.10/installer
dest root /
dest ram /tmp
lists_dir ext /opt/var/opkg-lists
option tmp_dir /opt/tmp
EOT
        }
    fi
    
    # Create symbolic links for convenience
    ln -sf /opt/bin/opkg /opt/bin/entpkg 2>/dev/null
    ln -sf /opt/bin/opkg /opt/bin/entware 2>/dev/null
    chmod 777 /opt/tmp
    
    # Update package lists
    log_info "Updating package lists..."
    /opt/bin/opkg update
    
    # Install entware-opt package
    log_info "Installing entware-opt package..."
    /opt/bin/opkg install entware-opt
    
    if [ $? -ne 0 ]; then
        log_error "Failed to install entware-opt package"
        return 1
    fi
    
    log_success "Entware core installed successfully"
    return 0
}

create_boot_script() {
    log_header "Creating Boot Persistence Script"
    
    # Create the webosbrew init.d directory if it doesn't exist
    mkdir -p "$(dirname "$INITD_SCRIPT")"
    
    # Create the boot script
    cat > "$INITD_SCRIPT" << 'EOF'
#!/bin/sh
#
# S99entware - WebOS Entware Boot Script
# This script sets up the Entware paths during boot
#

# ANSI color codes
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Paths
SRC="/mnt/lg/user/opt"
DST="/opt"
INIT="/opt/etc/init.d/rc.unslung"

# Log file
LOG_FILE="/mnt/lg/user/entware_boot.log"

log() {
    echo "$(date): $1" >> "$LOG_FILE"
}

start() {
    echo -e "${YELLOW}Initializing Entware paths...${NC}"
    
    # Create log entry
    log "Starting Entware boot script"
    
    # Ensure source directory exists
    mkdir -p "$SRC"
    
    # Mount check
    if ! mountpoint -q "$DST"; then
        log "Binding $SRC to $DST"
        
        # Create target if needed
        [ ! -d "$DST" ] && mkdir -p "$DST"
        
        # Perform bind mount
        mount --bind "$SRC" "$DST"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Successfully bound $SRC to $DST${NC}"
            log "Successfully bound $SRC to $DST"
        else
            echo -e "${RED}Failed to bind mount $DST${NC}"
            log "Failed to bind mount $DST"
            return 1
        fi
    else
        log "$DST is already mounted"
    fi
    
    # Start Entware services if available
    if [ -x "$INIT" ]; then
        log "Starting Entware services"
        "$INIT" start
    fi
    
    return 0
}

case "$1" in
    start)
        start
        ;;
    *)
        echo "Usage: $0 {start}"
        exit 1
        ;;
esac

exit 0
EOF

    chmod +x "$INITD_SCRIPT"
    
    # Test the script by running it
    log_info "Testing boot script..."
    "$INITD_SCRIPT" start
    
    log_success "Boot persistence script created"
    return 0
}

setup_bash() {
    log_header "Setting Up Bash"
    
    # Install bash package
    log_info "Installing bash..."
    
    # Make sure our path is correctly set for opkg
    export PATH="/opt/bin:/opt/sbin:$PATH"
    
    # Check if opkg command is available
    if ! which opkg >/dev/null 2>&1; then
        log_error "opkg command not found. Entware installation may have failed."
        return 1
    fi
    
    # Install bash
    log_info "Installing bash package..."
    /opt/bin/opkg install bash
    
    if [ $? -ne 0 ]; then
        log_error "Failed to install bash"
        log_warning "You can try installing it later with: entwrap install bash"
        return 1
    fi
    
    # Check if bash was installed
    if [ ! -f "/opt/bin/bash" ]; then
        log_error "Bash executable not found after installation"
        return 1
    fi
    
    # Set up bash configuration
    log_info "Setting up bash configuration..."
    
    # Create .bashrc for the current user
    cat > "$BASHRC_FILE" << 'EOF'
# Bash configuration for WebOS Entware

# Enable colors
export TERM=xterm-256color
export CLICOLOR=1
export LS_COLORS="di=1;34:ln=35:so=32:pi=33:ex=31:bd=34;46:cd=34;43:su=30;41:sg=30;46:tw=30;42:ow=30;43"

# Neon-style prompt
RED="\[\033[0;31m\]"
GRN="\[\033[0;32m\]"
YEL="\[\033[0;33m\]"
BLU="\[\033[0;34m\]"
MAG="\[\033[0;35m\]"
CYN="\[\033[0;36m\]"
RST="\[\033[0m\]"

PS1="${GRN}\u${RST}@${CYN}\h${RST}:${MAG}\w${RST}\$ "

# Aliases
alias ls='ls --color=auto'
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias cls='clear'
alias entpkg='/opt/bin/opkg'
alias entwrap='/opt/bin/entwrap'

# Path
export PATH="/opt/bin:/opt/sbin:$PATH"

# Source bash completion if it exists
if [ -f /opt/etc/bash_completion ]; then
    . /opt/etc/bash_completion
fi

# Source Entware bash completion
if [ -f /opt/etc/bash_completion.d/entwrap ]; then
    . /opt/etc/bash_completion.d/entwrap
fi

# Welcome message
echo -e "\033[0;32m======================================\033[0m"
echo -e "\033[0;32m WebOS Entware Environment Activated\033[0m"
echo -e "\033[0;32m======================================\033[0m"
echo ""
echo -e "\033[0;33mEntware commands available via 'entwrap':\033[0m"
echo -e "\033[0;36m - entwrap install <package>\033[0m"
echo -e "\033[0;36m - entwrap search <term>\033[0m"
echo -e "\033[0;36m - entwrap help\033[0m"
echo ""
EOF

    # Create .bash_profile to load .bashrc
    cat > "${HOME}/.bash_profile" << 'EOF'
# Source bashrc if it exists
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
EOF

    # Create the same files for root user if we're not already root
    if [ "$HOME" != "/root" ]; then
        mkdir -p "/root"
        cp "$BASHRC_FILE" /root/.bashrc
        cp "${HOME}/.bash_profile" /root/.bash_profile
    fi
    
    # Modify SSH setup to use bash if possible
    log_info "Setting up bash as default SSH shell..."
    
    # Method 1: Set up profile to exec bash
    cat > "$PROFILE_FILE" << 'EOF'
#!/bin/sh
# Automatically switch to bash if available
if [ -f /opt/bin/bash ]; then
    export PATH="/opt/bin:/opt/sbin:$PATH"
    exec /opt/bin/bash -l
else
    # Fallback to standard PATH for Entware
    export PATH="/opt/bin:/opt/sbin:$PATH"
fi
EOF

    # Make sure root has this too
    if [ "$HOME" != "/root" ]; then
        cp "$PROFILE_FILE" /root/.profile
    fi
    
    # Method 2: Use /etc/shells if it exists
    if [ -f "/etc/shells" ]; then
        if ! grep -q "/opt/bin/bash" /etc/shells; then
            echo "/opt/bin/bash" >> /etc/shells
            log_info "Added bash to /etc/shells"
        fi
    else
        log_warning "/etc/shells not found. Cannot add bash to system shells."
    fi
    
    # Method 3: Try to set bash as default shell for current user
    if command -v chsh >/dev/null 2>&1; then
        log_info "Attempting to set bash as default shell using chsh..."
        chsh -s /opt/bin/bash $(whoami) 2>/dev/null
        
        if [ $? -ne 0 ]; then
            log_warning "chsh command failed. Using profile method instead."
        fi
    else
        log_info "chsh not available. Using profile method for shell switching."
    fi
    
    log_success "Bash setup complete"
    return 0
}

create_entwrap_cli() {
    log_header "Creating Entwrap CLI Tool"
    
    # Create the entwrap script
    cat > "$ENTWRAP_PATH" << 'EOF'
#!/bin/sh

# Entwrap - Entware Package Manager Wrapper
# A user-friendly interface for Entware on webOS

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

ENTWARE_PATH="/opt"
OPKG_BIN="$ENTWARE_PATH/bin/opkg"
CACHE_FILE="$ENTWARE_PATH/tmp/entpkg-cache.txt"

print_usage() {
    echo -e "${CYAN}Entwrap${NC} - Entware Package Manager for webOS"
    echo
    echo -e "Usage: ${YELLOW}entwrap${NC} <command> [options]"
    echo
    echo "Commands:"
    echo -e "  ${GREEN}search${NC} <package>     Search for packages"
    echo -e "  ${GREEN}install${NC} <package>    Install a package"
    echo -e "  ${GREEN}remove${NC} <package>     Remove a package"
    echo -e "  ${GREEN}info${NC} <package>       Show package information"
    echo -e "  ${GREEN}update${NC}              Update package lists"
    echo -e "  ${GREEN}upgrade${NC}             Upgrade installed packages"
    echo -e "  ${GREEN}list${NC}                List installed packages"
    echo -e "  ${GREEN}files${NC} <package>     List files in package"
    echo -e "  ${GREEN}safe-install${NC} <pkg>  Force install (ignores deps)"
    echo -e "  ${GREEN}refresh-cache${NC}       Refresh package cache"
    echo -e "  ${GREEN}help${NC}                Show this help message"
    echo -e "  ${GREEN}self-repair${NC}         Fix tab-completion and paths"
    echo
    echo -e "Example: ${YELLOW}entwrap install nano${NC}"
}

check_entware() {
    if [ ! -f "$OPKG_BIN" ]; then
        echo -e "${RED}[ERROR]${NC} Entware opkg not found at $OPKG_BIN"
        echo -e "Please run the WebOS Entware Installer first"
        exit 1
    fi
}

setup_path() {
    # Already in PATH?
    if echo "$PATH" | grep -q "$ENTWARE_PATH/bin"; then
        return 0
    fi
    
    export PATH="$ENTWARE_PATH/bin:$ENTWARE_PATH/sbin:$PATH"
    echo -e "${BLUE}[INFO]${NC} Added Entware to PATH for this session"
}
create_completion() {
    mkdir -p "$ENTWARE_PATH/etc/bash_completion.d"
    
    cat > "$COMPLETION_FILE" << 'COMPLETION_EOF'
# entwrap completion for bash
_entwrap_completions() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    
    # Main commands
    if [ $COMP_CWORD -eq 1 ]; then
        opts="search install remove info update upgrade list files safe-install refresh-cache help self-repair"
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
    
    # Command-specific options
    case "$prev" in
        search|install|remove|info|safe-install|files)
            # Try to use package cache for completion if available
            if [ -f /opt/tmp/entpkg-cache.txt ]; then
                COMPREPLY=( $(compgen -W "$(cat /opt/tmp/entpkg-cache.txt)" -- ${cur}) )
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

complete -F _entwrap_completions entwrap
complete -F _entwrap_completions ent
COMPLETION_EOF

    # Also create a POSIX shell compatible version for basic sh
    cat > "${COMPLETION_FILE}.sh" << 'COMPLETION_EOF'
# entwrap completion - POSIX sh compatible version
_entwrap_completions() {
    COMPREPLY=()
    cur="$2"
    prev="$3"
    
    # Main commands
    if [ "$1" = 1 ]; then
        opts="search install remove info update upgrade list files safe-install refresh-cache help self-repair"
        COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
        return 0
    fi
    
    # Command-specific options
    case "$prev" in
        search|install|remove|info|safe-install|files)
            # Try to use package cache for completion if available
            if [ -f /opt/tmp/entpkg-cache.txt ]; then
                COMPREPLY=( $(compgen -W "$(cat /opt/tmp/entpkg-cache.txt)" -- ${cur}) )
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

complete -F _entwrap_completions entwrap
complete -F _entwrap_completions ent
COMPLETION_EOF

    # Create a symbolic link for convenience
    ln -sf "$ENTWRAP_PATH" "$ENTWARE_PATH/bin/ent" 2>/dev/null
    
    echo -e "${GREEN}[SUCCESS]${NC} Created bash completion for entwrap"
    
    # Source the completion file if bash is present
    if command -v bash >/dev/null 2>&1; then
        echo -e "${BLUE}[INFO]${NC} To enable tab completion, run: source $COMPLETION_FILE"
    fi
}

# Generate package cache for tab completion
generate_cache() {
    mkdir -p "$ENTWARE_PATH/tmp"
    "$OPKG_BIN" list | awk '{print $1}' > "$CACHE_FILE"
    echo -e "${GREEN}[SUCCESS]${NC} Generated package cache for tab completion"
}

# Check if a package is potentially sensitive
check_sensitive_package() {
    package="$1"
    
    # List of potentially sensitive packages that might affect system behavior
    case "$package" in
        bash|zsh|ksh|tcsh|csh|fish|sudo|su|chroot|dropbear|openssh-*|iptables*|ufw|firewall*|syslog-ng|rsyslog|systemd*|rc.d|init|monit|supervisor|dnsmasq|hostapd|wpa_supplicant|mount|umount|format|fdisk|parted|mkfs*|ntfs*|dosfs*|e2fs*|gparted|coreutils|binutils|openvpn|wireguard*|iptables*|nftables)
            return 0  # It's sensitive
            ;;
        *)
            return 1  # Not sensitive
            ;;
    esac
}

run_opkg() {
    setup_path
    "$OPKG_BIN" "$@"
}

highlight_search() {
    awk '
    /^[a-z0-9.+_-]+ - [0-9]/ {
        split($0, parts, " - ");
        split(parts[2], rest, " ");
        printf "\n\033[32m%s\033[0m - \033[34m%s\033[0m\n", parts[1], rest[1];
        $1=$2=""; sub(/^  /, "", $0);
        printf "\033[33m%s\033[0m\n", $0;
        next
    }
    /.*/ { print }
    '
}

# Main entwrap function
main_entwrap() {
    check_entware
    setup_path
    
    CMD="$1"
    shift
    
    case "$CMD" in
        search)
            echo -e "${BLUE}[SEARCH]${NC} Searching for package: $1"
            run_opkg list | grep -i "$1" | highlight_search
            ;;
        install)
            # Check if the package is potentially sensitive
            if check_sensitive_package "$1"; then
                echo -e "${YELLOW}[WARNING]${NC} The package '$1' can potentially modify system behavior."
                echo -e "${YELLOW}[WARNING]${NC} Installing it may affect your webOS TV's operation."
                echo -e "Are you sure you want to install it? (y/N) "
                read -r confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo -e "${BLUE}[INFO]${NC} Installation cancelled"
                    exit 0
                fi
                echo -e "${YELLOW}[CAUTION]${NC} Installing potentially sensitive package: $1"
            else
                echo -e "${BLUE}[INSTALL]${NC} Installing package: $1"
            fi
            run_opkg install "$@"
            
            # Special case for bash - let user know about the shell profile
            if [ "$1" = "bash" ]; then
                echo -e "${GREEN}[INFO]${NC} Bash installed successfully."
                echo -e "${YELLOW}[TIP]${NC} You may want to add this to your .profile to use bash by default:"
                echo -e "  if [ -f /opt/bin/bash ]; then"
                echo -e "      exec /opt/bin/bash -l"
                echo -e "  fi"
            fi
            
            # Update the package cache
            generate_cache
            ;;
        safe-install)
            echo -e "${YELLOW}[FORCE-INSTALL]${NC} Force installing package: $1"
            run_opkg install "$1" --force-depends --force-checksum
            generate_cache
            ;;
        remove)
            # Check if the package is potentially sensitive
            if check_sensitive_package "$1"; then
                echo -e "${YELLOW}[WARNING]${NC} Removing the package '$1' may affect system functionality."
                echo -e "Are you sure you want to remove it? (y/N) "
                read -r confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo -e "${BLUE}[INFO]${NC} Removal cancelled"
                    exit 0
                fi
                echo -e "${YELLOW}[CAUTION]${NC} Removing potentially sensitive package: $1"
            else
                echo -e "${BLUE}[REMOVE]${NC} Removing package: $1"
            fi
            run_opkg remove "$@"
            generate_cache
            ;;
        info)
            echo -e "${BLUE}[INFO]${NC} Package information: $1"
            run_opkg info "$@"
            ;;
        files)
            echo -e "${BLUE}[FILES]${NC} Files in package: $1"
            run_opkg files "$@"
            ;;
        update)
            echo -e "${BLUE}[UPDATE]${NC} Updating package lists"
            run_opkg update
            echo -e "${BLUE}[UPGRADE]${NC} Checking for available upgrades"
            run_opkg list-upgradable
            generate_cache
            ;;
        upgrade)
            echo -e "${BLUE}[UPGRADE]${NC} Upgrading installed packages"
            run_opkg upgrade
            generate_cache
            ;;
        list)
            echo -e "${BLUE}[LIST]${NC} Installed packages"
            run_opkg list-installed
            ;;
        refresh-cache)
            echo -e "${BLUE}[REFRESH]${NC} Refreshing package cache"
            run_opkg update
            generate_cache
            ;;
        help)
            print_usage
            ;;
        self-repair)
            echo -e "${BLUE}[REPAIR]${NC} Setting up tab-completion"
            create_completion
            echo -e "${BLUE}[REPAIR]${NC} Ensuring correct permissions"
            chmod +x "$ENTWRAP_PATH"
            echo -e "${BLUE}[REPAIR]${NC} Generating package cache"
            generate_cache
            echo -e "${GREEN}[SUCCESS]${NC} Self-repair completed"
            ;;
        *)
            echo -e "${YELLOW}[WARNING]${NC} Unknown command: $CMD"
            print_usage
            exit 1
            ;;
    esac
}

#############################################################
# MANAGEMENT FUNCTIONS
#############################################################

backup_system_files() {
    log_header "Backing Up Critical System Files"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    log_info "Backing up critical system files..."
    
    # List of critical files to backup
    for file in passwd group shells shadow gshadow; do
        if [ -f "/etc/$file" ]; then
            cp "/etc/$file" "$BACKUP_DIR/$file" 2>/dev/null
            chmod 400 "$BACKUP_DIR/$file" 2>/dev/null
            log_success "Backed up /etc/$file"
        else
            log_warning "File /etc/$file not found, skipping"
        fi
    done
    
    # Create README file with timestamp
    cat > "$BACKUP_DIR/README" << EOF
WebOS System Files Backup
Created on: $(date)
By: WebOS Entware Installer

These files are backups of critical system files.
DO NOT MODIFY THESE FILES!

In case of emergency, you can restore them by copying
back to their original location in /etc/
EOF

    log_success "Backup completed to $BACKUP_DIR"
    return 0
}

revert_entware() {
    log_header "Removing Entware Installation"
    
    if ! confirm "Are you sure you want to remove Entware? This will remove all installed packages."; then
        log_info "Removal cancelled by user"
        return 1
    fi
    
    # Remove boot autostart script
    if [ -f "$INITD_SCRIPT" ]; then
        rm -f "$INITD_SCRIPT"
        log_success "Removed boot autostart script"
    fi
    
    # Remove entwrap
    if [ -f "$ENTWRAP_PATH" ]; then
        rm -f "$ENTWRAP_PATH"
        log_success "Removed entwrap CLI tool"
    fi
    
    # Remove symlinks
    rm -f /opt/bin/ent 2>/dev/null
    
    # Check if /opt is mounted
    if mountpoint -q /opt; then
        log_warning "Attempting to unmount /opt"
        if umount /opt; then
            log_success "Successfully unmounted /opt"
        else
            log_error "Failed to unmount /opt"
            log_info "You may need to reboot to complete the removal"
        fi
    fi
    
    # Remove profile entries
    if [ -f "$PROFILE_FILE" ]; then
        log_info "Cleaning up profile entries..."
        sed -i '/Entware PATH/d' "$PROFILE_FILE" 2>/dev/null
        sed -i '/\/opt\/bin/d' "$PROFILE_FILE" 2>/dev/null
        sed -i '/rc.unslung/d' "$PROFILE_FILE" 2>/dev/null
        sed -i '/bash_completion.d\/entwrap/d' "$PROFILE_FILE" 2>/dev/null
        sed -i '/exec \/opt\/bin\/bash/d' "$PROFILE_FILE" 2>/dev/null
    fi
    
    log_info "Entware removal process completed"
    
    if confirm "It's recommended to reboot your device now. Reboot now?"; then
        log_info "Rebooting..."
        reboot
    else
        log_warning "Please reboot your device manually later to complete the removal"
    fi
    
    return 0
}

safe_reboot() {
    log_header "Safe Reboot"
    
    if ! confirm "Are you sure you want to reboot the system?"; then
        log_info "Reboot cancelled"
        return 1
    fi
    
    log_info "Syncing file systems..."
    sync
    
    log_info "Rebooting system..."
    reboot
    
    return 0
}

check_status() {
    log_header "Entware Status Check"
    
    # Display system information
    echo -e "${BLUE}System Information:${NC}"
    echo -e "  OS Version: $(uname -a 2>/dev/null || echo 'Unknown')"
    echo -e "  Hostname: $(hostname 2>/dev/null || echo 'Unknown')"
    echo -e "  Date: $(date)"
    
    # Check mount status
    echo -e "\n${BLUE}Mount Status:${NC}"
    if mountpoint -q /opt; then
        echo -e "  ${GREEN}✓${NC} /opt is mounted"
        echo -e "  Mount details: $(mount | grep ' on /opt ')"
    else
        echo -e "  ${RED}✗${NC} /opt is NOT mounted"
    fi
    
    # Check Entware installation
    echo -e "\n${BLUE}Entware Installation:${NC}"
    if [ -f "/opt/bin/opkg" ]; then
        echo -e "  ${GREEN}✓${NC} Entware is installed"
        OPKG_VER=$(/opt/bin/opkg --version 2>/dev/null || echo "Unknown")
        echo -e "  Version: $OPKG_VER"
    else
        echo -e "  ${RED}✗${NC} Entware is NOT installed"
    fi
    
    # Check command line tools
    echo -e "\n${BLUE}Command Line Tools:${NC}"
    [ -f "$ENTWRAP_PATH" ] && echo -e "  ${GREEN}✓${NC} entwrap CLI is installed" || echo -e "  ${RED}✗${NC} entwrap CLI is NOT installed"
    [ -f "/opt/bin/bash" ] && echo -e "  ${GREEN}✓${NC} bash is installed" || echo -e "  ${RED}✗${NC} bash is NOT installed"
    
    # Check boot script
    echo -e "\n${BLUE}Boot Configuration:${NC}"
    [ -f "$INITD_SCRIPT" ] && echo -e "  ${GREEN}✓${NC} Boot autostart script is installed" || echo -e "  ${RED}✗${NC} Boot autostart script is NOT installed"
    [ -f "/opt/etc/init.d/rc.unslung" ] && echo -e "  ${GREEN}✓${NC} Entware init script is installed" || echo -e "  ${RED}✗${NC} Entware init script is NOT installed"
    
    # Check profile configuration
    echo -e "\n${BLUE}Profile Configuration:${NC}"
    grep -q '/opt/bin' "$PROFILE_FILE" 2>/dev/null && echo -e "  ${GREEN}✓${NC} PATH is configured" || echo -e "  ${RED}✗${NC} PATH is NOT configured"
    
    return 0
}

display_summary() {
    log_header "Installation Summary"
    
    echo -e "${GREEN}✓${NC} Entware installed at: ${CYAN}/opt${NC} (linked from ${CYAN}$BIND_PATH${NC})"
    echo -e "${GREEN}✓${NC} Entwrap CLI Tool: ${CYAN}$ENTWRAP_PATH${NC}"
    echo -e "${GREEN}✓${NC} Boot Persistence: ${CYAN}$INITD_SCRIPT${NC}"
    echo -e "${GREEN}✓${NC} Bash Shell: ${CYAN}/opt/bin/bash${NC}"
    echo -e "${GREEN}✓${NC} Profile Setup: ${CYAN}$PROFILE_FILE, $BASHRC_FILE${NC}"
    echo -e "${GREEN}✓${NC} System Backups: ${CYAN}$BACKUP_DIR${NC}"
    
    # Check if /opt is properly set up
    OPT_STATUS="Unknown"
    if [ -L "/opt" ] && [ "$(readlink /opt)" = "$BIND_PATH" ]; then
        OPT_STATUS="${GREEN}Symlinked to $BIND_PATH${NC}"
    elif mountpoint -q /opt && mount | grep -q "$BIND_PATH on /opt "; then
        OPT_STATUS="${GREEN}Bind mounted to $BIND_PATH${NC}"
    elif mountpoint -q /opt; then
        OPT_STATUS="${YELLOW}Mounted but not to $BIND_PATH${NC}"
    elif [ -d "/opt" ]; then
        OPT_STATUS="${YELLOW}Directory exists but not mounted/linked${NC}"
    elif [ ! -e "/opt" ]; then
        OPT_STATUS="${RED}Not found${NC}"
    fi
    
    echo -e "${GREEN}✓${NC} /opt Status: ${OPT_STATUS}"
    
    echo ""
    echo -e "${YELLOW}Next Steps:${NC}"
    echo -e "1. SSH into your TV again to automatically enter bash shell"
    echo -e "2. Try the Entwrap tool: ${CYAN}entwrap help${NC}"
    echo -e "3. Install packages: ${CYAN}entwrap install nano${NC}"
    echo -e "4. ${RED}Important:${NC} Reboot to test persistence: ${CYAN}reboot${NC}"
    
    echo ""
    echo -e "${MAGENTA}Notes:${NC}"
    echo -e "• Bash is now your default shell when connecting via SSH"
    echo -e "• The entwrap tool will warn before installing potentially sensitive packages"
    echo -e "• To check status anytime, run this installer and select 'Check Status'"
    echo -e "• If packages don't work after reboot, run: ${CYAN}$INITD_SCRIPT start${NC}"
    echo -e "• All commands will work with either /opt or $BIND_PATH paths"
    echo -e "• If installation was done via curl/wget one-liner, a reboot is highly recommended"
}

#############################################################
# MAIN EXECUTION
#############################################################

# Full installation function
do_full_install() {
    check_root || return 1
    check_webos || return 1
    check_writable_user_path || return 1
    
    setup_user_opt || return 1
    install_entware || return 1
    create_entwrap_cli || return 1
    create_boot_script || return 1
    backup_system_files || return 1
    setup_bash || return 1
    save_local_copy
    
    display_summary
    
    echo -e "\n${GREEN}Installation completed successfully!${NC}"
    echo -e "${YELLOW}Note:${NC} SSH into your TV again to start using bash automatically."
    
    return 0
}

# Main menu function
show_menu() {
    log_header "WebOS Entware Installer Menu"
    
    echo -e "1) ${CYAN}Check Entware Status${NC}"
    echo -e "2) ${CYAN}Install Entware + Bash${NC}"
    echo -e "3) ${CYAN}Backup System Files${NC}"
    echo -e "4) ${CYAN}Create/Repair Entwrap CLI${NC}"
    echo -e "5) ${CYAN}Create/Repair Boot Script${NC}"
    echo -e "6) ${CYAN}Remove Entware${NC}"
    echo -e "7) ${CYAN}Safe Reboot${NC}"
    echo -e "8) ${CYAN}Exit${NC}"
    echo
    printf "${YELLOW}Please select an option [1-8]: ${NC}"
    read -r opt
    
    case "$opt" in
        1) check_status ;;
        2) do_full_install ;;
        3) backup_system_files ;;
        4) create_entwrap_cli ;;
        5) create_boot_script ;;
        6) revert_entware ;;
        7) safe_reboot ;;
        8) echo -e "${GREEN}Exiting. Goodbye!${NC}"; exit 0 ;;
        *) log_warning "Invalid option. Please select 1-8." ;;
    esac
}

# Entry point
log_header "WebOS Entware Safe Installer v1.3"

# Check if we have a valid command as argument
if [ "$1" = "install" ]; then
    # Non-interactive mode - direct install
    do_full_install
    exit 0
elif [ "$1" = "status" ]; then
    # Just check the status
    check_status
    exit 0
elif [ "$1" = "uninstall" ]; then
    # Remove Entware
    revert_entware
    exit 0
elif [ "$1" = "help" ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo -e "WebOS Entware Safe Installer v1.3"
    echo -e "Usage: $0 [OPTION]"
    echo -e "Options:"
    echo -e "  install     Non-interactive installation"
    echo -e "  status      Check installation status"
    echo -e "  uninstall   Remove Entware"
    echo -e "  help        Show this help message"
    echo -e "  (no option) Interactive menu mode"
    exit 0
else
    # No valid args, start the interactive menu
    # First check if we're root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Enter the menu loop
    while true; do
        show_menu
        echo
    done
fi 
