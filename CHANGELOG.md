# Changelog

All notable changes to the WebOS Entware installer.  Versions follow [semantic versioning](https://semver.org/).

## [2.12.0] - 2026-11-04

### Added

- **Six network services** as add-ons: Tailscale, Samba file sharing, File Browser, a DLNA media server (minidlna), Transmission and Syncthing.  Each starts with the TV, and is set up before it first starts: a password made on the TV for anything with a login, no guest access, and Entware's stock settings replaced.  If a setup doesn't finish, the service is stopped and kept from starting at boot.  See [Network services](README.md#network-services).
- **Open a service in Add-ons** to see its address and password, with a QR code of the address for your phone.  Tailscale shows a QR code of its sign-in link.  Over SSH: `webos-entware info <name>`.
- **Seven more add-ons:** rclone (with FUSE for `rclone mount`), Network tools (iperf3, nmap, tcpdump, iftop and dig), Archive tools (unzip, 7z and unrar), Vim, Midnight Commander, micro, and Search tools (ripgrep, fd and fzf).
- A shared folder for the services, `/opt/files`, with `Downloads`, `Media` and `Sync` in it, and USB drives in `USB`.  Removing a service never deletes it.

### Changed

- A service package installed on its own, with `ent install` or the Packages screen, waits until it's set up as an add-on, so it never starts with settings that let anyone in.  Removing one from the Packages screen also takes its setup away.

### Fixed

- Entware services you installed yourself now start with the TV too.  The boot script started them with no PATH, so init scripts that don't set their own (like Samba's), or that start through `nohup` or `env`, couldn't find their programs.  It also starts them in a session of their own.  Adding a network service updates an older boot script, and so does a repair.

## [2.11.1] - 2026-11-04

### Changed

- The TV app checks for a newer release through the installer on the TV, like LG-USB-2-ETH0.  It runs `webos-entware app-update --check` instead of only asking GitHub's API from the app.  When one is out, **Update to vX** shows at the top of the list with the version you have, and OK downloads it, checks it against the release's checksums and installs it.  If the installer can't answer, the app still asks GitHub directly.

### Fixed

- `app-update` also brings the `webos-entware` command up to the newest release when the app is already current.  Before, an app updated from the Homebrew Channel left an older command behind.

## [2.11.0] - 2026-11-04

### Added

- **Packages in the TV app:** a new screen for every Entware package.  It opens on what's installed, with each package's version and size, and **Remove** on the ones you can take off: packages Entware or the shell setup needs, and ones other packages need, say why they stay.  The search field at the top opens the TV's keyboard: type a word like htop or python to see what matches (names first), then press OK on one to install it, with the same webOS setup `ent install` does.  Over SSH: `webos-entware installed`, `webos-entware search <word>`, `webos-entware pkg-add <name>` and `webos-entware pkg-remove <name>`.
- **Full check and logs** (it was **Full check**) lists the full check, this boot's log from the boot script, and the last 10 tasks the app ran, each with its full log.  Over SSH: `webos-entware logs` and `webos-entware log <name>`.  Task logs are kept in `/opt/var/log/webos-entware`.
- **What's new:** after the app updates, it shows that version's changes once.

### Changed

- The app's buttons are a little shorter, so all of them still fit with Packages added.

## [2.10.1] - 2026-11-03

### Added

- **Report for GitHub** in the TV app (it was **Report a problem**) now asks what you want to report.  **It works on my TV** shows a QR code for a new compatibility report form, filled in with your TV, version, build, where Entware lives and the full check.  **Something went wrong** shows the bug report QR code as before.
- A compatibility report form, `CONTRIBUTING.md`, a code of conduct and a pull request template on GitHub.

## [2.10.0] - 2026-11-02

### Added

- **Login banner add-on:** a webOS wordmark and your TV's specs each time you log in over SSH: the webOS version, kernel, packages, shell, IP, model, chip, GPU, memory, disk use for `/opt` and `/home`, and the uptime.  Add it from the app's **Add-ons** screen or with `webos-entware add banner`.  It runs neofetch, which isn't in Entware, so it downloads the 7.1.0 release from GitHub and only uses it if it matches that release's checksum.  It runs neofetch with Entware's bash (on webOS `env bash` finds BusyBox, which can't run it), and its settings read the webOS version, model, chip and GPU from the TV, since neofetch gets those wrong.  It only shows at an SSH login, not for commands, scp or sftp, and `touch ~/.hushlogin` hides it.  Your edits to its settings are kept.  Tried on an LG C2 with webOS 25.

### Also in this release

- Everything from [2.9.2](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/blob/main/CHANGELOG.md#292---2026-11-02), which wasn't released on its own: the app's **Package updates** screen, with **Update** for one package or **Update all**, and `webos-entware updates` and `webos-entware upgrade <name>` over SSH.

## [2.9.2] - 2026-11-02

### Added

- **Package updates in the app:** **Package updates** (the old **Update packages**) opens a screen listing every package with an update, with its current and new version.  **Update** updates one, **Update all** updates them all, and **Check again** downloads the package list from Entware's server.  The button says how many updates there are, and the app refreshes the package list once a day when it opens.  Each update runs in the background and returns to the list.
- `webos-entware updates [--refresh] [--json]` lists packages with updates, and `webos-entware upgrade <name>` updates one package.  `doctor` mentions how many updates there are.

## [2.9.1] - 2026-11-02

### Added

- **Notices for installs on user data:** until Entware moves to app storage, the TV app shows a notice next to its **Move to app storage** button, and SSH logins and the `webos-entware` menu say how to move it.  They stop once it moves, or once you choose user data.
- `webos-entware move user` on an install that's already on user data now keeps it there for good: repairs won't move it, and the notices stop.
- **The app updates itself:** when a new release is out, **Update to v…** downloads it from GitHub, checks it against the release's `SHA256SUMS` and that it's this app at that version, installs it with webOS's app installer, and reopens it with a toast.  The `webos-entware` command updates to the same release.  Over SSH: `webos-entware app-update`.  It also looks for new releases every 6 hours while the app is open.

### Changed

- The app's status card is a little tighter, so the notice fits.
- Tab completion for `webos-entware` knows `upgrade`, `addons`, `add`, `remove`, `move` and `app-update`.

## [2.9.0] - 2026-11-02

### Added

- **Entware on app storage, by default:** new installs go on the TV's app storage, which is much bigger than user data (about 2.7 GB against 720 MB on a C2, which webOS shares) and keeps Entware through "Reset to initial settings".  `--location=user` puts one on user data instead.  Researched on a C2 with webOS 25.
- **Older installs move over on a repair**, with a checked move: services stop, the install is copied into a fresh folder and checked, `/opt` switches over and is checked to be that copy, and only then is the old copy removed.  Over SSH it asks first (no means it won't ask again).  If it can't move right then, the repair still succeeds and the next one tries again.  `webos-entware move appstore|user` moves it either way, and that choice sticks.
- `doctor` and the app show where Entware lives and the free space in both areas.  The app's Repair moves an older install, and a **Move to app storage** button does it on its own.

### Security

- Entware is only used when it's root's alone.  `/mnt/lg/user`, where older versions put it, can be written by any user on webOS, so a process that isn't root could otherwise swap in its own folder to run as root at the next boot.  The boot script, the SSH login and the installer now mount Entware first and then check `/opt` itself (so it can't be swapped between the check and its use): the folder and everything on the way to what runs as root must be owned by root and writable by no one else.  Anything else is unmounted unused, and a login won't use it.  Old copies are deleted only through a private mount after checking their identity.  `/opt/tmp` is now sticky (1777).  Found researching app storage, and checked by an independent review.

### Changed

- `ent search` is much easier to read, especially on a phone: a count at the top, then each package as its own block, with the name, version and whether it's installed on one line and the description below it, wrapped to the screen and cut to two lines.  Packages whose name matches come first.  Piped into another command, it still prints one plain line per package.

### Fixed

- `ent search` printed a stray dash between the package name and its version.
- Adding locate said it was ready twice.

## [2.8.0] - 2026-11-02

### Added

- **Add-ons:** `addons`, `add <name>` and `remove <name>`, for packages worth one press and the setup each needs on webOS: nano with syntax colors, locate, HTTPS certificates, git, Python, htop, tmux, ncdu, rsync, curl and jq.  The list is fixed in the installer.  In the TV app, an **Add-ons** screen adds, finishes setting up or removes each one in the background, and the menu over SSH has them too.
- **CI:** an ES5 lint of the app (for older webOS browsers), a check of what's inside the built IPK and that its manifest matches, a headless run of the app driven with the remote's keys (screenshots saved with each run), actionlint, CodeQL, and Dependabot for the actions.  Every action is pinned to a commit, and newer pushes cancel older runs.

### Changed

- A new app icon: the package box with a terminal badge, for packages plus a real shell.
- locate is set up from Add-ons now, so the app's separate "Set up locate" button is gone.  `webos-entware locate` still works.
- The app's buttons are a little more compact, so every one fits above the footer even with an update showing.

## [2.7.0] - 2026-11-02

### Added

- **The TV app** (`org.ohmybahgosh.entware`): Entware's status at a glance, and install, repair, package updates, locate setup and uninstall from the remote, with no SSH needed.  It runs the installer bundled inside it, as root through the Homebrew Channel.  Built with `webos-app/build.sh` and published with each release, with a Homebrew Channel manifest.
- **Background tasks:** `job install|uninstall|locate|upgrade` runs a task detached from the app, and `job-status [--json]` follows it.  Closing the app can't stop an install halfway, and reopening the app picks the progress back up.
- **One task at a time:** install, repair, uninstall, locate and upgrade take a lock, so the app and an SSH session can never change things at the same time.  A lock left by a stopped task is cleared on its own.
- `upgrade`: refreshes the package list and upgrades every Entware package.
- `status --json`: everything `doctor` checks, for the app and for scripts.
- **Report a problem** in the app: a QR code that opens a bug report on your phone with the TV, version, build and the full check already filled in.
- Releases on GitHub with the installer, the app, its manifest and a `SHA256SUMS` file, built by CI after the tests pass.
- `SECURITY.md`, and this changelog.

### Fixed

- `close` couldn't close apps from SSH on webOS 25, which only accepts `close` from the app itself.  It now uses `closeByAppId`, found testing the TV app on a C2.

## [2.6.0] - 2026-11-01

### Added

- **webOS helpers:** `toast`, `launch`, `close`, `apps`, `applog` and `tvshot`, one script (`/opt/bin/webos-tv`) linked under each name.  Tab after `launch`, `close` or `applog` completes app IDs.  A package's own command with the same name is never replaced.
- `ent owns <file or command>` shows which package something came from, following alternatives links and the `/mnt/lg/user/opt` path.
- `ent du` lists the largest packages and the free space on the shared data partition.  `doctor` flags it below 50 MB.

### Fixed

- Found testing on a webOS 25 TV: `applog` stopped by `timeout` left `tail` and `grep` running, and `ent du` measured the current folder for packages that own no regular files.

## [2.5.1] - 2026-11-01

### Changed

- The shell setup installs GNU ls (`coreutils-ls`), which sizes `ls -l` columns to fit.  Busybox ls pads every column to a fixed width.

## [2.5.0] - 2026-11-01

### Added

- **nano syntax colors:** nano-full ships 130+ syntax files, but its stock nanorc is all comments.  The installer writes one with every syntax file, line numbers and position history.  An edited nanorc is kept.
- **HTTPS certificates:** whenever OpenSSL or Python is installed, `ca-bundle` is added, so `wget-ssl`, `git` and pip can check HTTPS sites.
- `ent install` runs the setup these packages and mlocate need.

## [2.4.0] - 2026-11-01

### Added

- **locate (mlocate) for webOS:** settings that skip webOS's duplicate mount points, an `updatedb-webos` wrapper that provides the `mlocate` group inside a private mount namespace (no system file changes), and an hourly refresh with Entware's cron.

## [2.3.0] - 2026-11-01

### Added

- Detects and repairs setups left by older versions of this installer and early manual setups: old boot scripts, Entware package lists in webOS's own opkg folders, old logs and folders, and settings in an old-style `.bashrc`, which move to the new one.

### Fixed

- From a safety audit: backups never overwrite an older one, a failed fresh install puts shell files back exactly as they were, a `.profile.pre-entware` that starts bash can't loop the login, uninstall never deletes across a mount, and more.

## [2.2.1] - 2026-10-27

### Fixed

- Piped installs save a copy of the installer, fix hints point to something that works, uninstall clears stacked mounts on `/opt`, and installs without the Homebrew Channel are explained instead of reported as broken.

## [2.2] - 2026-10-27

### Added

- Repair keeps your `.bashrc` edits.  The boot script notes each step in a log, and SSH logins mount `/opt` if the boot script didn't run.  The test suite.

## [2.1] - 2026-10-26

### Changed

- Overhauled installer: checks the TV, recommends the 64-bit or 32-bit build and test-runs it, undoes a failed install, a boot script so `/opt` survives reboots, `doctor`, the `ent` helper and tab completion.

## 2.0 - 2026-10-25

### Fixed

- An SSH lockout from a bash login loop.  The first version made with AI coding agents.

## 1.x

Hand-written by [OhMyBahGosh](https://github.com/ohmybahgosh).  The first public versions of the installer and uninstaller.
