# Changelog

All notable changes to the WebOS Entware installer.  Versions follow [semantic versioning](https://semver.org/).

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
