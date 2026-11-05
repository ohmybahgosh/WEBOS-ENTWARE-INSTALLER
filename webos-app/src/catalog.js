// What the Browse tab knows that Entware's package list doesn't: friendly
// categories, hand-picked tools to start with, plain-English one-liners for
// popular packages, and tips for using some of them on a TV.  Packages are
// matched by name first, then by Entware's section.
window.ENTWARE_CATALOG = {
    cats: [
        { id: 'shell', title: 'Shell & terminal', lead: 'Shells, terminal helpers and everyday tools for SSH.',
            names: 'bash zsh fish tmux screen dtach abduco mc fzf bat tree less most dialog whiptail byobu ncdu eza lsd ripgrep fd the_silver_searcher sd ' +
                'figlet toilet neofetch fastfetch zoxide direnv tldr watch pv moreutils parallel expect coreutils findutils grep sed gawk diffutils which ' +
                'file bc dc units calc ccze colordiff multitail lnav jq yq xmlstarlet asciinema ttyd shellinabox rlwrap ncurses-utils tput hexyl xxd',
            match: '^(fish|hstr|fzy|column|colrm|rev$|look$|cal$|time$|script-utils|whereis|namei|entr$|task-spooler|taskwarrior|remind|pcal|chezmoi|highlight|jo$|jq-full|man-|groff|more$|wcd$|mcookie|uuidgen|logger|flock|daemonize|reptyr|qrencode|iconv|byobu)' },
        { id: 'editors', title: 'Editors', lead: 'Edit files and settings from the terminal.',
            names: 'nano nano-full nano-plus vim vim-full vim-fuller neovim micro joe joe-extras mg emacs jed zile dte vis ed elvis kakoune helix mle' },
        { id: 'files', title: 'Files & backup', lead: 'Copy, sync, compress and look after files and drives.',
            names: 'rsync rclone borgbackup restic unison rdiff-backup rsnapshot 7-zip p7zip unzip zip unrar tar xz zstd bzip2 gzip pigz lz4 lzop cpio ' +
                'e2fsprogs ntfs-3g ntfs-3g-utils exfat-fuse exfat-fsck exfat-mkfs dosfstools hdparm smartmontools fdisk cfdisk sfdisk parted lsblk blkid ' +
                'mlocate findutils-locate duf gdu dufs filebrowser syncthing davfs2 sshfs curlftpfs nfs-utils nfs-kernel-server samba4-server samba4-client ' +
                'samba4-utils wsdd2 vsftpd proftpd pure-ftpd minidlna mergerfs bindfs archivemount fuse3-utils fuse-utils badblocks f2fs-tools btrfs-progs ' +
                'xfsprogs-mkfs xfsprogs-fsck mdadm squashfs-tools fio rmlint jdupes fdupes',
            match: '^(xfs-|xz|zipcmp|zipmerge|ziptool|squashfs|tune2fs|resize2fs|dumpe2fs|debugfs|e2freefrag|e4crypt|ext4magic|extundelete|f2fsck|mkf2fs|mkhfs|hfsfsck|gdisk|cgdisk|sgdisk|fixparts|partx|wipefs|losetup|fstrim|filefrag|fallocate|hardlink|rdfind|restic|kopia|tarsnap|urbackup|par2|hashdeep|rhash|xxhash|cksfv|chattr|lsattr|testdisk|dislocker|cryfs|gocryptfs|encfs|cryptsetup|lvm2|sdparm|sd-idle|smart|s3fs|simple-mtpfs|rar2fs|unionfs|fuse-convmvfs|loggedfs|nnn|vifm|far2l|dysk|dfc|mount-utils|swap-utils|nfusr|lrzsz|lzma|dos2unix|unix2dos|rename$|progress$)' },
        { id: 'downloads', title: 'Downloads & torrents', lead: 'Download files, videos and torrents to the TV or a USB drive.',
            match: '^(transmission|aria2|wget|curl$|yt-dlp|youtube|qbittorrent|rtorrent|deluge|axel|lftp|nzbget|sabnzbd|amule|gallery-dl|httrack)' },
        { id: 'media', title: 'Media & audio', lead: 'Convert, inspect, stream and share video, music and photos.', sections: 'multimedia sound',
            match: '^(tesseract|zbar|poppler|qpdf|ghostscript|xpdf|tiff-utils|giflib|lcms|jbigkit|gnuplot|rtl|dump1090|view1090|ink$|sane-|hplip|gutenprint|splix|brlaser|airprint|airsane|ffmpeg|ffprobe|mediainfo|mkvtoolnix|imagemagick|graphicsmagick|exiv2|jhead|gerbera|icecast|mpd|mpc|shairport|owntone|go2rtc|mosquitto-client)' },
        { id: 'network', title: 'Network tools', lead: 'Test, watch and troubleshoot your network.', sections: 'net',
            match: '^(minicom|picocom|setserial|mbim|qmi-|smstools|gpsd|owfs|owshell|digitemp|sngrep|sipgrep|netflow|cnetflow|cnflegacy|csflow|goflow|resolveip|nmap|iperf|mtr|tcpdump|bind-|knot-|drill|ethtool|iftop|nload|bmon|vnstat|arp-|netcat|socat|whois|traceroute|iputils|speedtest|' +
                'dnsmasq|unbound|adguardhome|stubby|dnscrypt|avahi|ngrep|darkstat|nethogs|net-tools|iproute2|ip-full|curl|httping|fping|hping|tcping|wakeonlan|etherwake)' },
        { id: 'vpn', title: 'VPN & security', lead: 'Private networks, encryption, firewalls and SSH.',
            match: '^(certtool|gnutls-utils|nss-utils|mbedtls-util|pcsc|jose$|pinentry|tailscale|wireguard|openvpn|zerotier|strongswan|tor$|tor-|torsocks|i2pd|gnupg|gpg|openssl-util|pass$|fail2ban|iptables|ip6tables|ipset|' +
                'nftables|dropbear|openssh|sudo|keepassxc|age$|crowdsec|stunnel|shadowsocks|xray|v2ray|sing-box|ocserv|softethervpn|nebula|netbird|headscale|' +
                'cloudflared|frp|ngrok|autossh|sshpass|knock|pwgen|apg|oath-toolkit|nextdns|dnscrypt-proxy2|https-dns-proxy|vpnc|openconnect|sstp|pptp|xl2tpd)' },
        { id: 'servers', title: 'Servers & web', lead: 'Web servers, databases, mail and other services.', sections: 'mail',
            match: '^(pgsql|goaccess|promlens|tang$|unixodbc|tidy-html5|xsltproc|nginx|lighttpd|apache|caddy|php8|mariadb|sqlite3|redis|postgresql|mosquitto$|node-red|homebridge|cups|squid|privoxy|tinyproxy|haproxy|' +
                'uhttpd|cron|incron|monit|nut-|apcupsd|ttyd|shellinabox|webdav|radicale|dovecot|postfix|exim|msmtp|fetchmail|mutt|nail|memcached|' +
                'influxdb|telegraf|grafana|prometheus|node-exporter|alertmanager|transmission-web|rutorrent|znc|ngircd|bitlbee|asterisk$|freeradius3$|' +
                'tvheadend|xupnpd|udpxy|minissdpd|miniupnpd)' },
        { id: 'dev', title: 'Programming', lead: 'Languages, compilers and developer tools.', sections: 'lang devel',
            match: '^(python3|perl$|ruby$|node$|node-npm|nodejs|lua$|lua5|luajit|go$|golang$|gcc|make$|cmake|autoconf|automake|libtool-bin|pkg-config|' +
                'binutils|gdb|strace|ltrace|git|subversion|mercurial|tig|lazygit|php8-cli|tcl|guile|erlang$|rust|openjdk|ccache|meson|ninja|patch|diffstat|' +
                'quilt|bison|flex|m4|swig|upx|duktape|quickjs|tcc|nasm|yasm|valgrind)' },
        { id: 'system', title: 'System & monitoring', lead: 'See what the TV is doing and keep it healthy.', sections: 'admin',
            match: '^(lscpu|lsns|lslocks|ipcs|prlimit|ionice|ioping|haveged|rng-tools|hwclock|fake-hwclock|kmod$|kexec|ldd$|ldconfig|dbus|setterm|wall$|nsenter|unshare|limitcpu|loadwatch|memtester|lmbench|procs$|saidar|statgrab|fatrace|inotify|keyd$|keyctl|keyutils|uuidd|sysfsutils|i2c-tools|gpioctl|usbids|pciids|pnpids|hub-ctrl|usbrelay|sispmctl|fxload|uvcdynctrl|v4l-utils|lirc|lcdproc|lcd4linux|rrdtool|rrdcgi|getopt|nonroot|empty$|shc$|smartd|htop|btop|bottom|atop|glances|nmon|iotop|lsof|sysstat|procps|psmisc|dstat|monit|collectd$|netdata|lm-sensors|usbutils|pciutils|' +
                'util-linux|dmesg|logrotate|sysbench|stress|watchdog|syslog-ng|rsyslog|audit|uptimed|beszel|zabbix|nagios|ntopng|ncdu|dool|bmon|vmstat|' +
                'cpulimit|nice|schedtool|taskset|at$|anacron)' },
        { id: 'games', title: 'Fun & games', lead: 'Terminal games and toys.', sections: 'games',
            match: '^(nyancat|cowsay|fortune|sl$|cmatrix|asciiquarium|nethack|angband|crawl|zork|gnuchess|vitetris|tty-solitaire|sudoku|minesweep|bastet|' +
                'moon-buggy|ninvaders|2048|figlet|toilet|lolcat|ratatui|superstartrek|cavezofphear)' },
        { id: 'other', title: 'Everything else', lead: 'Everything that doesn\'t fit the other categories.' },
        { id: 'libs', title: 'Libraries & modules', lead: 'Libraries, plugins and modules that other packages use.  You rarely need to install these yourself.' }
    ],

    // Shown first on Browse, in this order
    featured: ['htop', 'mc', 'rclone', 'ncdu', 'tmux', 'aria2', 'fzf', 'zsh', 'ffmpeg', 'yt-dlp', 'micro', 'nmap', 'git', 'python3',
        'rsync', 'jq', 'tree', 'iperf3', 'ripgrep', 'iftop', 'neovim', 'curl', '7-zip', 'nethack'],

    // Plain-English one-liners, used instead of Entware's description in lists
    blurbs: {
        '7-zip': 'Open and make .7z, .zip, .rar and most other archives.',
        aria2: 'Fast downloads over HTTP, FTP and BitTorrent, with resume.',
        bash: 'The shell you get over SSH, with history, completion and colors.',
        'bind-dig': 'dig: look up DNS records for any name.',
        borgbackup: 'Encrypted, deduplicated backups to a drive or over SSH.',
        cron: 'Run commands on a schedule.',
        curl: 'Fetch URLs and test APIs from the shell.',
        dropbear: 'A small SSH server.  The Homebrew Channel already gives you one.',
        e2fsprogs: 'Make and check Linux (ext2, ext3, ext4) file systems.',
        fd: 'A fast, friendly way to find files by name.',
        ffmpeg: 'Convert, trim and inspect video and audio files.',
        ffprobe: 'Show what\'s inside a video or audio file.',
        filebrowser: 'Upload and manage the TV\'s files from a browser.',
        fzf: 'Fuzzy finder: type a few letters to find any file or past command.',
        git: 'Clone, pull and keep track of changes to code and configs.',
        gnupg: 'Encrypt, decrypt and sign files with GPG.',
        htop: 'See what\'s running on your TV and how much CPU and memory it uses.',
        iftop: 'See which connections are using your network, live.',
        imagemagick: 'Resize, convert and edit images from the command line.',
        iperf3: 'Measure the network speed between the TV and another device.',
        jq: 'Read and filter JSON, like luna-send replies.',
        lftp: 'A powerful FTP and SFTP client with mirroring.',
        mc: 'A two-pane file manager in the terminal.  Copy, move and view files with arrow keys.',
        mediainfo: 'Technical details about video and audio files.',
        micro: 'A simple editor with mouse support and familiar shortcuts.',
        minidlna: 'Share videos, music and photos with TVs and phones on your network.',
        mkvtoolnix: 'Make, split and edit Matroska (.mkv) video files.',
        mlocate: 'Find any file by name in a moment.',
        nano: 'A simple, friendly text editor.',
        'nano-full': 'nano with syntax colors for 130+ languages.',
        ncdu: 'Find what\'s filling up your storage, biggest folders first.',
        neovim: 'A modern Vim with plugins and better defaults.',
        nethack: 'The classic dungeon adventure, in your terminal.',
        nethogs: 'See which programs are using the network.',
        nmap: 'Scan your network for devices and open ports.',
        'ntfs-3g': 'Read and write Windows-formatted (NTFS) drives.',
        p7zip: 'Open and make .7z archives.',
        python3: 'The Python language, with its standard library.',
        'python3-pip': 'Install Python packages from PyPI.',
        rclone: 'Copy and sync with Google Drive, Dropbox, OneDrive, S3 and 70 more clouds.',
        ripgrep: 'Search inside files, very fast.',
        rsync: 'Copy only what changed between folders or computers.  Great for backups.',
        'samba4-server': 'Share folders with Windows, Mac and Linux computers.',
        screen: 'Keep terminal sessions running after you disconnect.',
        socat: 'Connect almost anything to anything: sockets, files and ports.',
        'sqlite3-cli': 'The sqlite3 command, for small single-file databases.',
        syncthing: 'Keep folders in sync with your phone and computers.',
        tailscale: 'Reach the TV from anywhere over your private tailnet.',
        tcpdump: 'Capture and inspect network traffic.',
        tmux: 'Keep SSH sessions running after you disconnect, with split panes.',
        'transmission-daemon': 'A torrent client that runs in the background.',
        tree: 'Show folders and files as a tree.',
        unrar: 'Open .rar archives.',
        unzip: 'Open .zip files.',
        vim: 'The Vim editor, small version.',
        'vim-full': 'The full Vim editor.',
        vnstat: 'Keep track of how much data the TV sends and receives.',
        'wget-ssl': 'Download files over HTTP and HTTPS.',
        'yt-dlp': 'Download video and audio from YouTube and thousands of other sites.',
        zsh: 'A friendlier shell with smarter completion and spelling fixes.'
    },

    // Tips for using a package on a TV, shown on its page
    tips: {
        rclone: ['Signing in to Google Drive, Dropbox or OneDrive needs a browser, so run rclone config over SSH, answer n to "Use web browser", and run the command it prints on a computer.',
            'Put files in /opt/files so File Browser, Samba and the media server can see them.'],
        'yt-dlp': ['Save videos to /opt/files or a USB drive (/tmp/usb), so the TV\'s own media player can find them.'],
        aria2: ['Save downloads to /opt/files or a USB drive (/tmp/usb), not the TV\'s system storage.'],
        ffmpeg: ['Converting video on the TV works, but it\'s slow.  It\'s handy for remuxing and trimming.'],
        cron: ['Edit your schedule with crontab -e over SSH.  Entware starts cron at boot.'],
        nmap: ['Runs as root on the TV, so every scan type works.'],
        tcpdump: ['Save a capture with -w to /opt/files, then open it in Wireshark on a computer.'],
        dropbear: ['The Homebrew Channel already runs an SSH server, so you don\'t need this one.'],
        'openssh-server': ['The Homebrew Channel already runs an SSH server (dropbear) on port 22, so this one would need another port.'],
        bash: ['Part of Entware\'s shell setup here: SSH logins use it.'],
        python3: ['It\'s big.  The Python add-on adds pip and HTTPS certificates too.'],
        git: ['The git add-on adds HTTPS support and certificates, so clone and pull just work.'],
        'transmission-daemon': ['The Transmission add-on sets a password, a download folder and the web page on port 9091.'],
        'samba4-server': ['The Samba add-on sets a password and shares /opt/files and USB drives.'],
        minidlna: ['The media server add-on shares /opt/files and USB drives, and rescans at boot.'],
        syncthing: ['The Syncthing add-on sets a password and keeps its data in /opt/files.'],
        tailscale: ['The Tailscale add-on starts it at boot and shows a QR code to sign in.']
    }
};
