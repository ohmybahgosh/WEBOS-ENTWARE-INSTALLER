# Changelog

All notable changes to the WebOS Entware installer.  Versions follow [semantic versioning](https://semver.org/).

## [2.15.2] - 2026-11-05

### Fixed

- **Services that didn't start after the TV restarted:** some services, like MiniDLNA, keep a PID file on Entware's storage, which survives a restart.  When the old PID belonged to something else by the next boot, MiniDLNA said it was already running and quit, so the media server was off until you started it.  The boot script now clears PID files left from before the restart, before it starts Entware's services.  Existing boot scripts are brought up to date when the app updates.
- **Samba's log no longer repeats** "dos charset 'CP850' unavailable" at every start.  New Samba setups say ASCII outright.

### Changed

- **`ent svc` leaves out Syncthing's own script** when the Syncthing add-on runs it, so Syncthing is listed once, as webos-syncthing.  `ent svc status syncthing` and the rest still work by name.

## [2.15.1] - 2026-11-05

### Fixed

- **`ent svc` said Samba was stopped when it was running:** Samba's service script doesn't name its program the way the others do, so `ent svc` and the `tv` and `ent` overviews looked for a program called smb instead of smbd.  They now find the program a script starts when it doesn't say, and `ent svc logs smb` finds Samba's logs in their own folder.

## [2.15.0] - 2026-11-05

### Added

- **`tv` for the TV and `ent` for Entware:** two commands for everything over SSH, with Tab completion for their commands and what each one takes (package names, add-ons, services, app IDs, inputs and settings).  `tv` works apps, the screen, the system, files and automation.  `ent` works packages, add-ons and services, and still passes anything else to `opkg`.  On its own, `tv` shows how the TV is doing and what's on screen, and `ent` shows how Entware is doing.  `tv help` and `ent help` list everything, in groups.  `entwrap`, `webos-entware`, `webos-tv`, their commands and the `entup`, `entlist` and `entfix` shortcuts all keep working.
- **Control the TV from SSH:** `tv volume`, `tv mute`, `tv input` (with what's plugged into each port), `tv screen off`, `tv power off`, `tv reboot`, `tv open <url>` in the TV's browser, `tv youtube <link>` and `tv settings get|set` for picture and sound settings.
- **Back up and restore:** `tv backup` saves Entware's settings (with your add-ons' passwords), your crontab, SSH keys, boot scripts and the lists of packages and add-ons you installed, to a USB drive if one's plugged in.  `tv restore` reinstalls them and puts the settings back.
- **More for the TV:** `tv keys add <github-user>` adds SSH keys from GitHub; `tv autostart` manages boot scripts; `tv ports`, `tv top`, `tv temp`, `tv space`, `tv net test`, `tv usb eject`, `tv wake`, `tv serve` (share a folder with a QR code) and `tv done` (a toast when a long command finishes).
- **More for Entware:** `ent show` reads like the TV app's package page (size, what else it installs, its commands, its add-on, and whether webOS or the Homebrew Channel already has it); `ent browse` lists packages by category; `ent why` says what needs a package; `ent cleanup` removes packages nothing needs; `ent addon` and `ent svc` add add-ons and start, stop and turn off any Entware service; `ent share` lists every address; `ent where` says where a command comes from.
- **SSH commands in the TV app:** a new screen lists every `tv` and `ent` command with what it does, and your TV's SSH address.  LEFT and RIGHT switch between them.
- **`webos-entware helpers`** writes `tv`, `ent`, the webOS helpers and Tab completion again.  Updating the app does this too, so you get them without repairing.

### Changed

- **`ent install` and `ent remove`** now go through the same steps as the TV app: `ent remove` stops a service first and won't remove what Entware or another package needs.  Both still work from scripts without asking, and options like `--force-reinstall` still go straight to `opkg`.
- **`ent info`** shows the fuller package page, like `ent show`.

## [2.14.1] - 2026-11-04

### Fixed

- **Another build of an installed program now counts as installed in Browse:** with nano-full installed, nano and nano-plus showed as not installed, and **Hide installed** kept them.  Builds of one program (like nano, nano-full and nano-plus, vim and vim-full, or wget-ssl and wget-nossl) now say **Have nano-full**, hide with what's installed, and their page says you don't need both.
- **What the Homebrew Channel ships now shows as on the TV:** dropbear, rsync and sftp-server come with the Homebrew Channel, but Browse said they weren't installed.  They now say **Homebrew has it** and hide with what's installed.  Commands webOS has its own copy of still say **webOS has one**, since Entware's are usually fuller.
- **Category icons on the TV:** some category symbols, like the one for Fun & games, aren't in the TV's fonts and showed as a broken box.  The categories now have drawn icons.

## [2.14.0] - 2026-11-04

### Added

- **Browse Entware's packages from the TV app:** Packages is now a full screen with three tabs: **Browse**, **Installed** and **Updates**.  Browse opens on **Start here**, a hand-picked set of tools that work well on a TV, and lists the 1,100+ packages a person would pick in plain categories (Shell & terminal, Files & backup, Downloads & torrents, Media & audio, Network tools and more).  Libraries and plugin modules are hidden unless you turn on **Show libraries too**.
- **A page for every package:** its whole description, how much it downloads and how much space it takes with everything it needs, your free space, what else it installs and what you already have, and tips for using it on a TV.  When an add-on covers a package, adding the add-on is offered first.
- **Search from any tab:** name matches come first, then matches in the description, with the word marked and a filter for each category.  If nothing matches, one more press searches libraries too.
- **webos-entware pkginfo NAME** shows everything about one package, and **webos-entware catalog** lists the packages Browse shows, as JSON (`--all` for libraries too).

### Changed

- **Installed and Updates are tabs of Packages:** Installed has a chip for each group, and OK on a package opens its page, with Remove (or why it stays).  **Package updates** on the main screen opens the Updates tab.

## [2.13.2] - 2026-11-04

### Changed

- **The TV app's Packages screen shows what's installed much better**: packages are grouped into **Installed on their own**, **From add-ons**, **No longer needed**, **Part of Entware** and **Libraries and helpers**, with how many are in each group at the top and their size by each heading.  Every package shows its version, section, size, when it was added and what it is, and a tag saying what you can do: **Remove**, the add-on it came with, **Entware** or **Needed** (with what needs it).  CH+ and CH− jump between groups.
- **Removing an add-on's package removes the add-on:** OK on a package that came with an add-on offers to remove that add-on, setup included, rather than leave it half there.
- **Listing what's installed is much faster:** about 0.1 seconds on a C2 with 121 packages, down from about 5.

### Fixed

- **"null packages" on the TV app's status** ([#3](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/3)): while another opkg held its lock (an update check, an install from SSH), the status check couldn't run opkg, so it had no package count, and the full check could say opkg doesn't run.  It now counts packages from opkg's status file and checks opkg without waiting for the lock.  The app also leaves the count out rather than show "null" if it's ever missing.

## [2.13.1] - 2026-11-04

### Fixed

- **Typing your own password on the phone dashboard:** a password the dashboard couldn't take was refused with a message hidden behind the bar at the top, so nothing seemed to happen.  The form now says what's wrong as you type, with a checklist, and Save waits until it's right.  An error from the TV shows in the form itself, and other messages float where you can see them.

### Changed

- **Passwords can have symbols:** any 12 to 64 characters you can type, with no spaces and not starting with -.  Before, only a few symbols were allowed.
- **The phone dashboard's logins read better:** the user and the password each have their own line, with **Copy** next to the user and **Show password** and **Copy password** right under the password.
- **Back to a list is instant in the TV app:** backing out of a package, an add-on or a log shows the list again as it was, without reading it from the TV again.  It's read again only after a task may have changed it.
- **Clearer password choices:** on the phone dashboard, **Change password** opens one place with **Make a random one for me** or your own, with **Show** to see what you typed.  On the TV, the choice is **New random password**.

## [2.13.0] - 2026-11-04

### Added

- **Manage from your phone:** the first row in Add-ons shows a QR code that opens a dashboard on your phone, signed in, like TiviBro's web editor.  Add and remove add-ons, see each service's address and password, and make a new password or set your own.  It needs the code shown on the TV, only answers your home network and tailnet, and stops after 30 minutes without use.  Over SSH: `webos-entware web start`.  A task's progress stays at the bottom of the screen while the other buttons wait, a new password shows straight after it's set, and Copy works on the TV's plain http page.
- **Change a service's password:** New password on a service's screen in the TV app, and `webos-entware password <name>` over SSH (`--ask` to type your own).  Settings, devices and torrents stay.

### Changed

- Adding an add-on whose packages are already installed doesn't download them again, and only the missing ones of a bundle are installed.
- When webOS has its own copy of an add-on's command (it ships curl and python3), the installer and the app say so and ask first.
- A service won't start when something else on the TV already uses its port, and says which port.
- Transmission's screen says how much room app storage has, and how to save big downloads to a USB drive.
- File Browser's and minidlna's logs are kept under 1 MB.

### Fixed

- The TV's model was missing from status when the installer ran with standard input closed: luna-send gives up then, so it now reads from /dev/null.

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
