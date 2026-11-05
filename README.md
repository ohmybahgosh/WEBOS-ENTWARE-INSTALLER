<div align="center">

<img src="images/banner.png" alt="Entware for rooted LG webOS TVs: hundreds of Linux packages, a real bash shell, and a TV app to run it all from the remote" width="100%">

# WEBOS-ENTWARE-INSTALLER

**Entware for rooted LG webOS TVs, from the remote or one line over SSH.  Checks your TV first, picks the right build, survives reboots and uninstalls cleanly.**

[![CI](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/actions/workflows/ci.yml/badge.svg)](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ohmybahgosh/WEBOS-ENTWARE-INSTALLER?sort=semver)](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/releases/latest)
[![webOS](https://img.shields.io/badge/webOS-23%20%C2%B7%2024%20%C2%B7%2025-ffb547)](#supported-tvs)
[![Homebrew Channel](https://img.shields.io/badge/Homebrew%20Channel-app-4cc3ff)](#the-tv-app)
[![Shell](https://img.shields.io/badge/POSIX-sh-89e051)](webos-entware-installer.sh)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![ohmybahgosh.dev](https://img.shields.io/badge/ohmybahgosh.dev-project%20page-33e1ff)](https://ohmybahgosh.dev/webos-entware-installer/)

</div>

Sets up **Entware** on **rooted LG webOS TVs**, so you can install hundreds of Linux command line packages with `opkg`, and gives you a bash shell, handy webOS commands and one-press [add-ons](#add-ons) like git, Python, Tailscale, Samba file sharing and a media server.  Run it from the **[TV app](#the-tv-app)** with your remote, or over SSH.  Either way it's one POSIX shell script with no dependencies.

> [!IMPORTANT]
> **This changes a rooted TV, so read what it does first.**  It installs into the TV's app storage (`/mnt/lg/appstore/entware`), adds one Homebrew Channel boot script and, unless you use `--no-shell`, swaps in its own shell files after backing yours up.  Everything it adds is listed in [What it changes on the TV](#what-it-changes-on-the-tv), and `webos-entware uninstall` takes it all back out.  Keep **telnet** on in the Homebrew Channel as a way back in.  Provided as-is, with no warranty.

> [!NOTE]
> **How this is built.**  I, [OhMyBahGosh](https://github.com/ohmybahgosh), wrote the first versions by hand.  From v2.0 on, it's written with AI coding agents (Claude), directed, reviewed and tested by me.  I've been building software for over 17 years.  My day job is data engineering, and network security and pentesting are what I do for fun.  AI writes a lot of the code here; I decide what it does, check how it does it, and nothing ships until it's run on a real TV (an LG C2 on webOS 25).
>
> Many of the fixes that mattered came from that real-TV testing: a 2025 install the old version left half-working, `luna-send` answering nothing when called from a script, webOS having no group for `locate`, and helpers that left processes running.  The [changelog](CHANGELOG.md) has the full story.
>
> - **Tests on every push:** 320+ [tests](tests/run_tests.sh) install, repair, reboot, add and remove add-ons and uninstall in a private mount namespace with fake TV paths, under busybox `sh` (the TV's shell) and dash.  CI also runs ShellCheck, lints the app as ES5 for older TVs, builds the IPK and [checks what's in it](tests/check-ipk.sh), [drives the app with the remote's keys](tests/ui-test.js) in a headless browser, [tests the phone dashboard](tests/web-test.js) on a phone-sized screen, lints the workflows, and runs CodeQL.  Every action is pinned to a commit.  The CI badge above shows the latest run.
> - **Hard to break the TV:** a failed install undoes itself, your own shell files are backed up and put back, logins only switch to bash if it runs, and system partitions are never touched.  [SECURITY.md](SECURITY.md) lists everything it does as root.
>
> Commits list me as the author and Claude as the committer.  Found a problem?  See [SECURITY.md](SECURITY.md) or open an issue.

**Found a bug or have an idea?**  [Open an issue](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/new/choose), or use the [templates on ohmybahgosh.dev](https://ohmybahgosh.dev/contact/?t=ent-bug).

## Quick start

**With the remote (easiest):** in the Homebrew Channel, open Settings, add the repository `https://ohmybahgosh.dev/repo`, install **Entware**, open it and choose **Install Entware**.  [Step by step with screenshots](#from-the-homebrew-channel-recommended).

**Over SSH:**

```sh
wget -O /tmp/webos-entware-installer.sh https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh
sh /tmp/webos-entware-installer.sh install
```

Then log in again for the bash shell, and try `ent search htop` or `webos-entware add git`.  [More SSH options](#over-ssh).

---

## Contents

- [Quick start](#quick-start)
- [The TV app](#the-tv-app)
- [Features](#features)
- [Supported TVs](#supported-tvs)
- [Requirements](#requirements)
- [Install](#install)
  - [From the Homebrew Channel](#from-the-homebrew-channel-recommended)
  - [Over SSH](#over-ssh)
- [The build check (32-bit or 64-bit)](#the-build-check-32-bit-or-64-bit)
- [Options](#options)
- [After installing](#after-installing)
- [Managing the install](#managing-the-install)
- [The tv and ent commands](#the-tv-and-ent-commands)
- [Shell setup and shortcuts](#shell-setup-and-shortcuts)
- [webOS helpers](#webos-helpers)
- [nano](#nano)
- [HTTPS certificates](#https-certificates)
- [locate (mlocate)](#locate-mlocate)
- [Login banner](#login-banner)
- [Add-ons](#add-ons)
  - [Network services](#network-services)
  - [Manage from your phone](#manage-from-your-phone)
- [Where Entware lives](#where-entware-lives)
- [What it changes on the TV](#what-it-changes-on-the-tv)
  - [Upgrading from an older setup](#upgrading-from-an-older-setup)
- [Reboots](#reboots)
- [Uninstall](#uninstall)
- [Troubleshooting and recovery](#troubleshooting-and-recovery)
- [FAQ](#faq)
- [Contributing](#contributing)
- [Credits](#credits)

---

## The TV app

<img src="webos-app/src/icon160.png" width="80" align="right" alt="">

The easiest way in.  It runs the same installer underneath, as root through the Homebrew Channel, so you don't need SSH to install or manage Entware.

- **Status at a glance:** whether Entware is installed and mounted, the build, packages and disk use, the boot script, the SSH shell, nano, HTTPS certificates, locate, free space and telnet recovery, plus any problems found.
- **Install Entware**, or **Repair** when something's wrong.  It uses the recommended build for your TV and keeps your packages and settings on a repair.
- **Add-ons:** 25 of them, each with the setup it needs on webOS.  Tools like git, Python, htop, tmux, Vim and a [login banner](#login-banner), and [network services](#network-services) like Tailscale, Samba, File Browser, a DLNA media server, Transmission and Syncthing.  One press adds, finishes setting up or removes one.  A service opens to its address and password, with a QR code for your phone.
- **Manage from your phone:** a QR code that opens a [dashboard](#manage-from-your-phone) on your phone, signed in, for add-ons and passwords.
- **Packages:** a full screen with three tabs.
  - **Browse** opens on **Start here**, hand-picked tools that work well on a TV, and lists the 1,100+ Entware packages a person would pick in plain categories: Shell & terminal, Editors, Files & backup, Downloads & torrents, Media & audio, Network tools, VPN & security, Servers & web, Programming, System & monitoring, and Fun & games.  Libraries and plugin modules stay out of the way unless you turn on **Show libraries too**.
  - **Every package has a page:** its whole description, how much it downloads and how much room it takes with everything it needs, your free space, what else it installs, and tips for using it on a TV.  When an [add-on](#add-ons) covers it, adding the add-on is offered first.  **Install** uses the same webOS setup `ent install` does.
  - **Search** from any tab, with the TV's keyboard.  Name matches come first, then matches in the description, with a filter for each category.
  - **Installed** groups what's here: installed on their own, from add-ons, no longer needed, part of Entware, and libraries.  A package's page has **Remove**, or says why it stays.
  - **Updates** lists every package with an update, with **Update** for one or **Update all**.  The main screen's **Package updates** button shows how many there are and opens this tab, and the app checks Entware's server for new ones once a day.
- **Uninstall Entware**, with a confirmation before anything is removed.
- **Live progress:** every task runs in the background on the TV and its log shows as it goes.  Closing the app doesn't stop it, and reopening the app picks the progress back up.
- **Full check and logs:** everything `doctor` looks at, on screen, plus this boot's log from the boot script and the logs of the last 10 tasks the app ran.
- **What's new:** after the app updates, it shows what changed, once.
- **Report for GitHub:** a QR code that opens a report on your phone with your TV, version, build and the full check already filled in.  **It works on my TV** opens a compatibility report, and **Something went wrong** a bug report.
- **Updates itself:** when a new version is out, **Update to v…** downloads it from GitHub, checks it against the release's checksums and that it really is this app, installs it and reopens.  The `webos-entware` command updates with it.  The Homebrew Channel offers updates too.
- **Made for the remote:** arrow keys and OK, or point and click with the Magic Remote.  BACK closes whatever is open.

<p align="center"><img src="images/app-demo.gif" width="720" alt="The TV app with the remote: opening Add-ons, showing the Manage from your phone QR code and sign-in code, adding the Login banner and watching it install, then opening Package updates"></p>

<p align="center">
  <img src="images/app-status.png" width="49%" alt="The Entware app on an LG C2: Entware is ready, 36 packages on app storage, no problems found, with Check and repair, Package updates, Packages, Add-ons, Full check and logs, Report for GitHub and Uninstall Entware">
  <img src="images/app-addons.png" width="49%" alt="The Add-ons screen at the network services: Tailscale asking you to sign in, and Samba, File Browser, the DLNA media server, Transmission and Syncthing running">
</p>
<p align="center">
  <img src="images/app-packages.png" width="49%" alt="Packages, Browse tab: 1,113 packages in categories down the left, and Start here showing htop, mc, rclone, ncdu, tmux, aria2, fzf, zsh, ffmpeg, yt-dlp, micro and nmap, each with a one-line description and Installed or Add-on sets it up">
  <img src="images/app-package-page.png" width="49%" alt="The yt-dlp page: its description, a tip to save videos where the TV's media player can find them, a 13.1 MB download with 15 more packages, 32.5 MB once installed, 1.3 GB free, what else it installs, and Install yt-dlp">
</p>
<p align="center">
  <img src="images/app-packages-search.png" width="49%" alt="A search for video: 18 matches with the word marked, ffmpeg, yt-dlp, ffprobe, mediainfo, minidlna (Installed) and mkvtoolnix, with a filter chip for each category">
  <img src="images/app-packages-installed.png" width="49%" alt="The Installed tab: 121 packages, 336 MB, with chips for On their own, From add-ons, No longer needed, Entware and Libraries, and each package's version, size and Remove">
</p>
<p align="center">
  <img src="images/app-updates.png" width="49%" alt="The Updates tab: Update all 2 packages, curl and nmap with their current and new versions, each with Update, and Check again">
  <img src="images/app-logs.png" width="49%" alt="Full check and logs: the full check, this boot's log, and recent tasks like Install htop and Add banner, each with View">
</p>
<p align="center"><img src="images/app-report.gif" width="49%" alt="Animated: Report for GitHub offers It works on my TV and Something went wrong, each showing a QR code with the TV's details filled in"></p>

**Get it:** [from the Homebrew Channel](#from-the-homebrew-channel-recommended), in four steps with screenshots.

Already installed Entware over SSH?  Open the app and it shows your install as it is.  The app and the `webos-entware` command run the same installer, and a repair from the app updates the saved command to the app's version.  Removing the app leaves Entware installed; use **Uninstall Entware** first if you want it gone too.

---

## Features

- ✅ **A TV app** for the Homebrew Channel: install, repair, add-ons, updates and uninstall from the remote, with live progress.
- ✅ **One-press add-ons** (git, Python, htop, tmux, Vim, a login banner and more), each set up for webOS.
- ✅ **Network services, set up safely:** Tailscale, Samba, File Browser, a DLNA media server, Transmission and Syncthing, each with a password made on the TV and no guest access, before it first starts.
- ✅ **Checks the TV before touching anything**: root, model, webOS version, kernel, Homebrew Channel, free space and the Entware download server.
- ✅ **Picks the right Entware build**: recommends 64-bit (`aarch64`) or 32-bit (`armv7`) from your kernel, tells you why, and asks you to continue, switch or exit.
- ✅ **Test-runs the build first**. If the 64-bit build can't run, it falls back to 32-bit.
- ✅ **Never leaves a half install**. If a fresh install fails partway, everything it did is undone. A failed repair keeps your existing install and packages.
- ✅ **Checks the result** when it finishes and prints a summary.
- ✅ **Survives reboots** with a Homebrew Channel boot script that remounts `/opt` and starts Entware services, plus a backup remount at SSH login if the boot script didn't run.
- ✅ **`doctor` check** that shows what's installed and says exactly what to fix.
- ✅ **One `tv` command** for everything over SSH: packages, add-ons, services, apps, volume and inputs, backups, SSH keys and more, with Tab completion throughout.
- ✅ **`ent` helper** for searching, installing and checking packages, with Tab completion for `ent`, `opkg` and package names. `opkg` itself is never replaced.
- ✅ **Saves itself as `webos-entware`**, so status, repair and uninstall work any time, even after a reboot wipes `/tmp`.
- ✅ **Optional bash shell** with nano, colors, a neon prompt and handy aliases, plus a safe fallback to the stock shell if bash is ever missing or broken.
- ✅ **Backs up your own `.profile` and `.bashrc`** and puts them back on uninstall. Your edits to the installer's `.bashrc` survive a repair.
- ✅ **Fixes "I have no name!"** by linking Entware to the system user files.
- ✅ **webOS helpers** (`toast`, `launch`, `close`, `apps`, `applog`, `tvshot`) for scripting the TV from SSH.
- ✅ **One task at a time:** the app and SSH can never change things at once.
- ✅ **Clean uninstall** that removes everything it added.

---

## Supported TVs

- **webOS 23, 24 and 25** (webOS 8, 9 and 10 internally) are the main targets.
- **webOS 22 and older** (webOS 4 and up) should work too. The installer tells you when your version is outside the tested range.
- Both **64-bit and 32-bit kernels** are supported. Most recent OLEDs (C2, C3, G4, C4 and up) have a 64-bit kernel. Many budget and older models have a 32-bit one.

Tried it on a TV that isn't listed?  A [compatibility report](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/new?template=compatibility-report.yml) helps others with the same model, whether it worked or not.  The TV app fills one in for you: **Report for GitHub**, then **It works on my TV**.

---

## Requirements

- A **rooted** LG webOS TV with the **Homebrew Channel** installed. See [webosbrew.org/rooting](https://www.webosbrew.org/pages/rooting/) and check your firmware at [cani.rootmy.tv](https://cani.rootmy.tv).
- **SSH** turned on in Homebrew Channel settings, to install over SSH or use the bash shell.  The TV app doesn't need it.  Keeping **telnet** on too gives you a way back in if SSH ever breaks.
- An **internet connection** on the TV.
- About **50 MB** free space.

Without the Homebrew Channel, Entware still installs, but there's no boot script. With the shell setup, `/opt` comes back when you log in over SSH. With `--no-shell`, run install again after each reboot. The installer warns you and asks first.

---

## Install

### From the Homebrew Channel (recommended)

No SSH needed.  Everything happens on the TV with the remote.

**1.  Add the repository.**  Open the Homebrew Channel and select the gear icon at the top right.  Under **Repositories**, choose **Add repository**, enter `https://ohmybahgosh.dev/repo` and add it.  It then shows up in the list.

<p align="center"><img src="images/hb-settings.png" width="760" alt="The Homebrew Channel's settings on the TV: Root configuration on the left, and on the right the repositories, with https://ohmybahgosh.dev/repo listed below the two webosbrew.org ones and Add repository underneath"></p>

**2.  Find Entware in the app list.**  Go back to the main screen.  **Entware** is listed with the other apps, with its cube and terminal icon.

<p align="center"><img src="images/hb-apps.png" width="760" alt="The Homebrew Channel's app list on the TV with Entware selected, next to LG-USB-2-ETH0 and TiviBro"></p>

**3.  Install it.**  Open Entware and choose **Install**.  The page shows the version, that it needs root, and what the app does.  When a new version is out, the same page offers **Update**, and so does the app itself.

<p align="center"><img src="images/hb-entware.png" width="760" alt="Entware's page in the Homebrew Channel: version 2.10.1, root required, Launch and Uninstall buttons, screenshots of the app and its description, from https://ohmybahgosh.dev/repo"></p>

**4.  Open it and choose Install Entware.**  Choose **Launch**.  The app checks your TV, picks the right build and installs Entware in about two minutes, with the progress on screen.  When it's done it says **Entware is ready**.

<p align="center"><img src="images/app-status.png" width="760" alt="The Entware app on an LG C2 after installing: Entware is ready, 36 packages on app storage, no problems found"></p>

From there, [add-ons](#add-ons) are one press away.  For the bash shell and `ent`, SSH in to the TV (turn on SSH in the Homebrew Channel's settings first).

### Or install the app's IPK yourself

Download `org.ohmybahgosh.entware_*.ipk` from the [latest release](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/releases/latest) and install it with `ares-install`, or on the TV:

```sh
luna-send -n 1 luna://com.webos.appInstallService/dev/install '{"id":"org.ohmybahgosh.entware","ipkUrl":"/tmp/org.ohmybahgosh.entware_2.13.2_all.ipk"}'
```

The Homebrew Channel won't offer updates for it unless you add the repository too, but the app's own **Update to v…** still works.

### Over SSH

SSH into your TV as root, then download and run the installer:

```sh
wget -O /tmp/webos-entware-installer.sh https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh
sh /tmp/webos-entware-installer.sh
```

Pick **1) Install or repair Entware**. The installer shows your TV details and the build it recommends, then asks you to confirm.

When it finishes, **disconnect and SSH in again** to get the bash shell.

<p align="center"><img src="images/term-install.gif" width="760" alt="An install over SSH, animated: the TV check, the recommended 64-bit build on app storage, each step, and Everything looks right"></p>

#### Skip the menu

```sh
sh /tmp/webos-entware-installer.sh install      # install, or repair an existing install
sh /tmp/webos-entware-installer.sh doctor       # check the TV and the install
sh /tmp/webos-entware-installer.sh uninstall    # remove everything
```

#### One line, piped into sh

```sh
wget -O - https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh | sh -s -- install
```

It still asks its questions in your SSH session. Add `-y` at the end to skip them and take the recommended build. With no terminal at all (for example from a script), it refuses to guess and asks for `-y` or `--arch`.

---

## The build check (32-bit or 64-bit)

Before it changes anything, the installer shows what it found and what it recommends:

```
Entware build check
  TV:          OLED65C2PUA, webOS 24 (9.2.1)
  Kernel:      aarch64 (64-bit)
  webOS apps:  32-bit (normal, every LG TV ships them this way)

Recommended: 64-bit (aarch64-k3.10)
  Why: your kernel is 64-bit, so the faster 64-bit build can run here.
       It's quicker for heavy tools (one owner measured about 19% on a G4).
  The other choice: the 32-bit build also works on this TV, just slower.
       Pick it only if the 64-bit build gives you trouble.
  Entware brings its own libraries, so it follows the kernel, not the 32-bit webOS apps.
  Safety: the build is test-run on this TV before anything is kept.
       If it can't run, the installer falls back to 32-bit or undoes everything.

[C]ontinue with 64-bit, [S]witch to 32-bit, or [E]xit:
```

On a TV with a 32-bit kernel it recommends the 32-bit build, explains that this is normal on many LG TVs, and offers only Continue or Exit, since the 64-bit build can't run there.

---

## Options

| Option | What it does |
|:-------|:-------------|
| `-y`, `--yes` | Skip the questions and use the recommended build |
| `--arch=aarch64-k3.10` | Use the 64-bit build without asking |
| `--arch=armv7sf-k3.2` | Use the 32-bit build without asking |
| `--no-shell` | Install Entware only. Your `.profile`, `.bashrc` and login shell are left alone |
| `--with-locate` | Also set up locate |
| `--location=user` | Put a new install on user data instead of app storage (the default).  See [Where Entware lives](#where-entware-lives) |
| `--json` | With `status` or `job-status`: print JSON |
| `-h`, `--help` | Show the commands and options |

---

## After installing

- SSH in again to get bash.  Type `tv` to see how the TV is doing, and `ent` for Entware.  `tv help` and `ent help` list everything.
- Try `ent search htop`, then `ent install htop`.
- Run `webos-entware doctor` any time to check everything.

---

## Managing the install

After the first install, the installer is saved on the TV as the `webos-entware` command:

| Command | What it does |
|:--------|:-------------|
| `webos-entware doctor` | Check the TV and the install, and say what to fix (same as `status`) |
| `webos-entware install` | Repair or update the install. Your packages are kept |
| `webos-entware uninstall` | Remove Entware and everything the installer added |
| `webos-entware updates` | List packages with updates and their versions (`--refresh` downloads the package list first, `--json` for scripts) |
| `webos-entware upgrade` | Refresh the package list and upgrade every package (same as `ent upgrade`).  `upgrade <name>` updates just that one |
| `webos-entware locate` | Set up locate (see [locate](#locate-mlocate)) |
| `webos-entware addons` | List the [add-ons](#add-ons) and whether each is installed |
| `webos-entware add <name>` | Install an add-on with its webOS setup, e.g. `add git` |
| `webos-entware remove <name>` | Uninstall an add-on |
| `webos-entware info <name>` | How to reach a [network service](#network-services), and its password |
| `webos-entware password <name>` | A new random password for a service; `--ask` to type your own, or `--stdin` to pipe one in |
| `webos-entware web start` | The [phone dashboard](#manage-from-your-phone): prints its address and sign-in code.  `web stop` stops it |
| `webos-entware installed` | List installed packages with their version, size and what needs them (`--json` for scripts) |
| `webos-entware search <word>` | Search Entware's packages, names first, marking what's installed |
| `webos-entware helpers` | Write `tv`, `ent`, the webOS helpers and Tab completion again (app updates do this too) |
| `webos-entware pkginfo <name>` | All about one package: its whole description, sizes, and what else it would install (`--json` for scripts) |
| `webos-entware catalog --json` | The packages the app's Browse tab lists, with their category data; `--all` for libraries and modules too |
| `webos-entware pkg-add <name>` | Install one package with its webOS setup, like `ent install` |
| `webos-entware pkg-remove <name>` | Uninstall one package.  Packages Entware needs, and ones other packages need, are kept |
| `webos-entware logs` | This boot's boot script log and the TV app's last 10 tasks.  `log <name>` shows one |
| `webos-entware status --json` | Everything `doctor` checks, as JSON for scripts |
| `webos-entware app-update` | Update the TV app (and this command) to the newest release, checked against its checksums |
| `webos-entware app-update --check` | Only say whether a newer release is out (add `--json` for the app) |
| `webos-entware move appstore` | Move Entware to app storage, or `move user` to user data.  A repair also moves older installs to app storage.  See [Where Entware lives](#where-entware-lives) |
| `webos-entware job <task>` | Run `install`, `uninstall`, `locate`, `upgrade`, `add <name>`, `remove <name>`, `pkg-add <name>`, `pkg-remove <name>` or `move <place>` in the background; `job-status` follows it.  Its log is kept for `logs` |
| `webos-entware` | Open the menu |

`doctor` shows your model, webOS version, kernel, Homebrew Channel and telnet status, the installed and recommended builds, whether `/opt` is mounted, whether `opkg` and bash run, and whether the boot script and shell files are in place. It ends with "Everything looks right" or a list of problems, each with its fix.

<p align="center"><img src="images/cli-doctor.png" width="760" alt="webos-entware doctor on an LG C2 with webOS 25: everything checks out"></p>

The installer also writes `/opt/etc/webos-entware/install.info` with the installer version, date, model, webOS version, firmware, kernel and build. It's handy to paste into a bug report.

Install, repair, uninstall, locate, upgrade and installing or removing a package take a lock, so two of them can never run at once, from SSH or the TV app.  If one is running, the other says so and stops.  A lock left by a task that was stopped is cleared on its own.

If you piped the installer into sh, there's no file to copy, so it saves the published version from GitHub instead. If that download fails, it tells you, and you can download it to `/opt/bin/webos-entware` yourself.

---

## The tv and ent commands

Two commands cover everything over SSH, each with Tab completion for its commands and what each one takes:

- **`tv`** works the TV: apps, the screen, the system, files and automation.
- **`ent`** works Entware: packages, add-ons and services.  Anything it doesn't know goes straight to `opkg`, so `ent list-installed` works too.

`tv` on its own shows how the TV is doing and what's on screen, with one line about Entware.  `ent` on its own shows how Entware is doing.  `tv help` and `ent help` list everything, and `tv help <command>` gives examples.  If you type a package command after `tv`, like `tv install htop`, it tells you the `ent` command instead.

The older commands all keep working: `entwrap` (the same as `ent`), `webos-entware`, `webos-tv`, `toast`, `launch`, `close`, `apps`, `applog`, `tvshot` and the `entup`, `entlist` and `entfix` shortcuts.  `tv` and `ent` hand off to them where they already do the job.

### ent: packages, add-ons and services

| Packages | |
|:--|:--|
| `ent search <word>` | Search packages by name or description.  Each result shows its version, whether it's installed, and its description cut to fit the screen.  Name matches come first |
| `ent show <pkg>` | Everything about one package: its description, size, what else it installs, its commands, its add-on, and whether webOS or the Homebrew Channel already has it.  `ent info` does the same |
| `ent install <pkg>`, `ent remove <pkg>` | Install or remove, with the webOS setup some need (nano colors, HTTPS certificates, locate).  `ent remove` won't remove what Entware or another package needs.  With `fzf` installed, leave the name out to pick from a list |
| `ent browse [category]` | Packages by category, like the TV app's Browse |
| `ent list [text]`, `ent files <pkg>`, `ent owns <file or command>` | What's installed, a package's files, and which package a file came from (or that it's part of webOS) |
| `ent why <pkg>`, `ent du [count]` | What needs a package, and the biggest packages with free space |
| `ent cleanup` | Remove packages nothing needs any more |
| `ent update`, `ent upgrade [pkg]`, `ent upgradable` | The package list and updates |
| `ent repair` | Reinstall Entware's core |

| Add-ons, services and checks | |
|:--|:--|
| `ent addon [list\|add\|remove\|info\|password] <name>` | The [add-ons](#add-ons) |
| `ent svc [list\|start\|stop\|restart\|enable\|disable\|logs] <name>` | Every Entware service, whether it came from an add-on or not |
| `ent share` | The addresses for File Browser, Samba, the media server and the rest |
| `ent where <command>` | Where a command comes from (Entware, webOS or the Homebrew Channel) and which one runs |
| `ent doctor` | Check Entware and the TV, and say what to fix (the same as `webos-entware doctor`) |

<p align="center"><img src="images/term-ent.gif" width="760" alt="ent search top, animated: htop marked installed and btop, then ent owns htop"></p>

### tv: the TV

| Apps | |
|:--|:--|
| `tv apps`, `tv launch`, `tv close`, `tv running` | Apps, and what's on screen |
| `tv app install <ipk or link>`, `tv app uninstall <id>` | Your own app packages |
| `tv open <url>`, `tv youtube <link>` | Open a page in the TV's browser, or play a video in YouTube |

| The screen | |
|:--|:--|
| `tv toast <message>`, `tv shot [file]` | A notification on the TV, or a screenshot |
| `tv volume [up\|down\|0-100]`, `tv mute [on\|off]` | The volume |
| `tv input [list\|hdmi1-4]` | The inputs, with what's plugged in, and switching between them |
| `tv screen off\|on` | Turn the picture off or on, with the TV still running |
| `tv power off`, `tv reboot` | Turn the TV off, or restart it (both ask first) |
| `tv settings get\|set <category> [key=value]` | Picture, sound and other settings, like `tv settings set picture backlight=40` |

| System and files | |
|:--|:--|
| `tv info`, `tv top`, `tv temp` | The TV's details, what's busy, and how hot the chip is (on TVs that report it) |
| `tv space [clean]` | What's using storage, and clearing caches, old logs and screenshots |
| `tv ports` | What's listening on the network, and which program it is |
| `tv net [test\|speed <host>]`, `tv wake <mac>` | Network details, a connection test, a speed test with iperf3, and Wake-on-LAN |
| `tv usb [eject <drive>]` | USB drives, and unmounting one safely |
| `tv logs [boot\|tasks\|text]`, `tv report` | The logs, and what to put in a GitHub issue |
| `tv serve [folder] [port]`, `tv qr <text>` | Share a folder over HTTP with a QR code for your phone, or show any text as a QR code |
| `tv backup [where]`, `tv restore <file>` | Your settings, add-ons, packages, crontab, SSH keys and boot scripts, in one file.  It goes to a USB drive if one's plugged in.  It holds your add-ons' passwords, so keep it private |

| Automation | |
|:--|:--|
| `tv autostart [list\|add\|on\|off\|remove\|show]` | Scripts the Homebrew Channel runs when the TV starts |
| `tv keys [list\|add\|remove]` | Who can log in over SSH.  `tv keys add <github-user>` adds their keys from GitHub |
| `tv done <command>` | Run something long, then pop up on the TV when it's done |

Anything that changes or removes something asks first in a terminal, and `-y` answers yes.  Without a terminal to ask on, `tv` doesn't go ahead.  `ent install` and `ent remove` go ahead from scripts, as `ent` always has.

**Tab completion** (in the bash shell): press Tab after `tv`, `ent`, `opkg` or `webos-entware`.  After `ent install`, `show` or `search` it completes available package names, and after `ent remove`, `files` or `upgrade` installed ones.  It also completes add-ons, services, app IDs, inputs and settings.

---

## Shell setup and shortcuts

Unless you use `--no-shell`, the installer adds bash, nano-full, dircolors and GNU ls (`coreutils-ls`, which fits `ls -l` columns to their contents, unlike busybox ls), and sets SSH logins to switch to bash. If bash is ever missing or broken, logins stay on the stock shell instead of failing.

| Shortcut | What it does |
|:---------|:-------------|
| `helpme` | List the shortcuts |
| `ls`, `ll`, `la`, `lt`, `l` | Colored file listings |
| `..`, `...` | Go up one or two folders |
| `myip`, `netinfo` | Network addresses and routes |
| `dfh`, `up` | Disk space and uptime |
| `edit <file>` | Open a file in nano |
| `findf <text>` | Find files by name, with highlighting |
| `entup`, `entlist`, `entfix` | `ent update`, `ent list`, `ent repair` |
| `tr0 <file>` | Empty a file |
| `reboot_safe` | Reboot after a short delay |

The aliases and prompt live in `/opt/etc/webos-entware/bashrc`, so they go away with Entware.

---

## webOS helpers

Small commands for working with the TV from SSH. They use webOS's own services through `luna-send`, so they need nothing extra installed.

| Command | What it does |
|:--------|:-------------|
| `toast <message>` | Show a notification on the TV screen, e.g. at the end of a script or cron job |
| `launch <app-id> [json]` | Start an app, with optional launch parameters: `launch netflix` |
| `close <app-id>` | Close an app |
| `apps [-a] [text]` | List apps with their IDs and types; `*` marks running ones. `-a` includes hidden apps, and text filters the list |
| `applog [app-id or text]` | Follow the system log (`/var/log/messages`), optionally only lines that mention an app |
| `tvshot [file]` | Save a screenshot of the screen (PNG, or JPG if the name ends in `.jpg`; default in `/tmp`) and print the `scp` command to copy it. Streaming apps show black, since protected video can't be captured |

Tab after `launch`, `close` or `applog` completes app IDs. `webos-tv help` lists the commands, and each one also works as `webos-tv <command>`. If a package already installed a command with one of these names, the installer leaves it alone and you can use `webos-tv <command>` instead.

<p align="center"><img src="images/cli-helpers.png" width="760" alt="webos-tv help, apps listing the TV's apps, and toast"></p>

`doctor` also shows the free space on user data, which webOS needs for itself, and on app storage, and flags the one Entware is on when it's below 50 MB.

---

## nano

nano-full ships syntax colors for over 130 languages, but its stock `/opt/etc/nanorc` has every line commented out, so nano starts plain. The installer writes a nanorc that turns on all of them, with line numbers, the cursor position on the status bar, and reopening files where you left off. Common extras (mouse, autoindent, tab size, soft wrap) are listed in the file, commented out.

It only replaces a stock nanorc or one it wrote itself (marked on its first line), so a nanorc you've edited is kept. Settings in your own `~/.nanorc` are read afterwards and win. Installing nano with `ent install nano-full` sets it up too.

<p align="center"><img src="images/cli-nano.png" width="760" alt="nano editing a shell script with syntax colors and line numbers"></p>

---

## HTTPS certificates

Programs built on Entware's OpenSSL (`wget-ssl`, `git`, `openssl-util`) and Python check HTTPS sites against `/opt/etc/ssl/certs/ca-certificates.crt`, which only exists once `ca-bundle` is installed. `curl` and anything else built on libcurl pull it in themselves, but most others don't, so their HTTPS downloads fail with certificate errors.

Whenever OpenSSL or Python is installed, through `ent install` or found during a repair, the installer adds `ca-bundle`. `doctor` shows whether the certificates are there, and flags it when a program needs them and they're missing.

---

## locate (mlocate)

`locate` finds files by name instantly from a database. Entware's mlocate doesn't work on webOS out of the box: `updatedb` refuses to run because webOS has no `mlocate` group, and with no settings it would list most files several times, since webOS mounts the same storage at several paths. Set it up with any of these:

```sh
ent install mlocate          # installs it and sets it up
webos-entware add locate     # sets it up (installs mlocate if needed)
webos-entware locate         # the same
sh webos-entware-installer.sh install --with-locate
```

This adds:

| Path | What |
|:-----|:-----|
| `/opt/etc/updatedb.conf` | Excludes duplicate mount points (`/mnt/lg/cmn_data`, `/mnt/lg/flash`, `/mnt/lg/appstore`, `/mnt/lg/db8`, app jails in `/var/palm/jail`), virtual filesystems, `/tmp` (and so USB drives) and `.git` folders. Each file is indexed under one path |
| `/opt/bin/updatedb-webos` | Runs `updatedb` with an `mlocate` group that exists only inside a private mount namespace, so no system file is changed. In the bash shell, `updatedb` is an alias for it |
| `/opt/etc/cron.hourly/updatedb` | Refreshes the database every hour, using Entware's `cron` (installed if needed and started by the boot script) |

A full refresh takes a couple of seconds. Repairing Entware sets locate up again if mlocate is installed. It rewrites `updatedb.conf` only while the file still has the installer's first line, so delete that line to keep your own settings. Scripts should call `updatedb-webos`, since the `updatedb` alias only exists in the interactive shell. `doctor` shows whether locate is ready and how old the database is.

<p align="center"><img src="images/cli-locate.png" width="760" alt="webos-entware add locate setting locate up, then locate nanorc finding files"></p>

---

## Login banner

An add-on that greets you with a webOS wordmark and your TV's specs each time you log in over SSH: the webOS version, kernel, packages, shell, IP, model, chip, GPU, memory, where Entware's space goes and the uptime.

```sh
webos-entware add banner     # or Add-ons > Login banner in the TV app
```

<p align="center"><img src="images/term-banner.gif" width="760" alt="Animated: webos-entware add banner, then logging in to an LG C2 over SSH again shows the webOS wordmark in a pink to cyan gradient and the TV's specs in boxes for Software, Hardware and Uptime"></p>

It runs [neofetch](https://github.com/dylanaraps/neofetch), which isn't in Entware, so the add-on downloads the 7.1.0 release from GitHub and only uses it if it matches that release's checksum.  Two things make it work on webOS:

- **Entware's bash:** neofetch starts with `#!/usr/bin/env bash`, and on webOS that finds BusyBox, which can't run it.  The installed copy points at `/opt/bin/bash` instead.
- **What neofetch can't work out on its own:** it calls the TV "Rockhopper" and counts the wrong number of cores.  The banner's settings read the webOS version, model, chip and GPU from the TV itself, so an LG C2 shows as webOS 25 (10.3.1), LG OLED65C2PUA, LG1213 (4) @ 1.400GHz and Mali-G52 MC3.

It only shows when you log in over SSH, not for `ssh tv 'command'`, scp or sftp.  To hide it for a while without removing it, `touch ~/.hushlogin`.  To change what it shows, edit `/opt/etc/webos-entware/banner/config.conf` (a normal [neofetch config](https://github.com/dylanaraps/neofetch/wiki/Customizing-Info)).  Adding the banner again keeps your edits.  `webos-entware remove banner` takes neofetch and the banner off again.

<p align="center"><img src="images/app-banner.png" width="760" alt="The TV app asking: Add Login banner? It downloads neofetch 7.1.0 from GitHub and checks it against the release's checksum"></p>

---

## Add-ons

Packages worth one press, with the setup each needs on webOS.  Install them from the TV app's **Add-ons** screen, or over SSH:

```sh
webos-entware addons         # what's available and what's installed
webos-entware add git        # install one
webos-entware remove git     # and take it off again
```

| Add-on | Packages | What you get |
|:-------|:---------|:-------------|
| `nano` | nano-full | [Syntax colors](#nano) for 130+ languages and line numbers.  Part of the shell setup, so it stays |
| `locate` | mlocate | [locate](#locate-mlocate) with settings for webOS and an hourly refresh.  Removing it takes the settings and the hourly job too |
| `certs` | ca-bundle | [HTTPS certificates](#https-certificates).  Stays, since other packages rely on it |
| `git` | git, git-http | git with HTTPS, and the certificates it needs |
| `python` | python3, python3-pip | Python 3 with pip, and the certificates it needs.  The largest add-on |
| `htop` | htop | A live view of CPU and memory use |
| `tmux` | tmux | Terminal sessions that keep running when SSH drops |
| `ncdu` | ncdu | Find what's filling up the disk |
| `rsync` | rsync | Fast copies to and from the TV over SSH |
| `curl` | curl | Fetch URLs and test APIs |
| `jq` | jq | Read and filter JSON, like `luna-send` replies |
| `banner` | neofetch 7.1.0, from GitHub | A [login banner](#login-banner) with a webOS wordmark and your TV's specs.  The only add-on not from Entware, so it's checked against the release's checksum |
| `rclone` | rclone, fuse3-utils | Copy, sync and mount Google Drive, Dropbox, OneDrive and 70 more clouds.  Set one up with `rclone config` |
| `nettools` | iperf3, nmap, tcpdump, iftop, bind-dig | Test the TV's network: speed between devices, open ports, traffic and DNS |
| `archives` | unzip, p7zip, unrar | Open zip, 7z and rar files |
| `vim` | vim-full | The full Vim editor |
| `mc` | mc | Midnight Commander, a two-pane file manager |
| `micro` | micro | A simple editor with mouse support and familiar shortcuts (Ctrl+S, Ctrl+Q) |
| `find` | ripgrep, fd, fzf | Fast search inside files (`rg`) and by name (`fd`), and a fuzzy finder.  Entware keeps fd outside the PATH, so the add-on links it into `/opt/bin` |

The six [network services](#network-services) below are add-ons too.  Any other Entware package installs with `ent install <package>` as usual.

Before adding one, the installer checks what's already there.  Packages already installed aren't downloaded again, only the missing ones are.  And when webOS has its own copy of the command (it ships `curl` and `python3`, for example), it says so and asks first, in the app too.  Entware's comes first on the PATH, and webOS's stays where it is.  BusyBox's cut-down commands don't count.  The list is fixed in the installer, so the app can only ever ask for one of these by name.

<p align="center"><img src="images/cli-addons.png" width="760" alt="webos-entware addons listing every add-on and whether it is installed, then adding the login banner"></p>

### Network services

Six add-ons run a service that starts with the TV.  Entware's own settings for some of them are open to anyone on your network (Samba lets guests in, and Transmission has no password), so each add-on sets the service up before it first starts:

- **A password made on the TV** for anything with a login, 16 random letters and numbers.  It's kept in `/opt/etc/webos-entware/credentials`, which only root can read, and adding the add-on again keeps it.
- **No guest access**, and nothing started with its stock settings.  If a setup doesn't finish, the service is stopped and kept from starting at boot.  Installed on its own with `ent install` (or the Packages screen), a service waits until you add it here.
- **One shared folder, `/opt/files`,** with `Downloads`, `Media` and `Sync` in it, and USB drives in `USB`.  Removing a service never deletes your files.  It's on app storage, so point Transmission at a USB drive for big downloads.
- **Checked against the TV first:** a service won't start if something else on the TV already has its port, and the boot script starts services with the PATH they need.  An add-on whose packages are already installed isn't downloaded again, only set up.

| Add-on | Packages | What you get | Where |
|:-------|:---------|:-------------|:------|
| `tailscale` | tailscale | Reach the TV over SSH from anywhere on your tailnet, with no ports opened.  The app shows a QR code of the sign-in link, and the TV reconnects by itself after a restart.  DNS and the firewall stay webOS's | `ssh root@<tailnet IP>` |
| `samba` | samba4-server, wsdd2 | Share `/opt/files` with Windows and Mac.  SMB2 and up, and it shows up in Windows' Network | `\\<TV IP>\TV`, user `tv` |
| `filebrowser` | filebrowser | Upload, download and manage `/opt/files` from a browser on your phone or computer | `http://<TV IP>:8090`, user `admin` |
| `minidlna` | minidlna | Play videos, music and photos from `/opt/files` and USB drives on other TVs, consoles and VLC.  No login: DLNA has none, and it only reads | "LG TV (Entware)" |
| `transmission` | transmission-daemon, transmission-web | Torrents from a browser, saved to `/opt/files/Downloads`.  Torrent files dropped in `Downloads/Watch` start by themselves | `http://<TV IP>:9091`, user `tv` |
| `syncthing` | syncthing | Keep a folder like `/opt/files/Sync` in sync with your phone and computers | `http://<TV IP>:8384`, user `tv` |

<p align="center"><img src="images/cli-services.png" width="760" alt="Over SSH: webos-entware addons listing Tailscale, Samba, File Browser, minidlna, Transmission, Syncthing and the tool add-ons, then webos-entware info samba with its Windows and Mac addresses, user and password, and webos-entware password filebrowser making a new one"></p>

In the TV app, open a service in **Add-ons** to see its address and password, with a QR code of the address for your phone, and **New random password**.  To type your own, use [Manage from your phone](#manage-from-your-phone).  Over SSH:

```sh
webos-entware info samba             # the address, user and password
webos-entware password samba         # a new random password
webos-entware password samba --ask   # type your own: 12 to 64 characters, symbols welcome, no spaces
webos-entware remove samba           # stops it, and deletes its settings and password
```

Change a password here rather than in the service's own settings page: setting a service up again puts back the one saved here.

### Manage from your phone

**Add-ons > Manage from your phone** in the TV app starts a small dashboard and shows a QR code.  Scan it and your phone's browser opens the dashboard, signed in.  It's the same idea as TiviBro's web editor.  From there you can add, finish setting up and remove add-ons, see each service's address and password, and change a password, to a random one or one you type (with Show, and a checklist as you type), without typing on the TV.

- **A sign-in code** shown on the TV: eight characters that can't be mistaken for each other across a room.  The QR code carries it, or you type it.  Five wrong codes lock that phone out for a minute.
- **Only your home network** (and your tailnet) can reach it.  It's served by the TV's own Node.js on port 8095, and stops by itself after 30 minutes without use, or when you choose **Stop** on the TV.  A new start makes a new code.
- **Nothing it sends can do more than the TV app can.**  It runs the same installer, with the same fixed commands and add-on names, and a password you type goes to the installer on standard input, never on a command line.

Over SSH: `webos-entware web start` prints the address and code, and `webos-entware web stop` stops it.

<p align="center"><img src="images/web-dashboard.png" width="300" alt="The phone dashboard: Tailscale asking you to sign in, and File Browser running with its address, user admin, its password with Show and Copy, and Open, Change password and Remove"></p>

Ports 8080 and 9080 are taken by webOS, so File Browser uses 8090.  Removing Tailscale signs the TV out of your tailnet.

<p align="center"><img src="images/app-addon-info.png" width="760" alt="File Browser in the TV app's Add-ons: Running, with a QR code of http://192.168.50.96:8090, the address, user admin and its password, and Remove File Browser"></p>

---

## Where Entware lives

LG TVs have two storage areas that Entware can use:

| | App storage (the default) | User data |
|:--|:--|:--|
| Folder | `/mnt/lg/appstore/entware` | `/mnt/lg/user/opt` |
| Size on a C2 | about 2.7 GB | about 720 MB |
| Shared with | installed apps | webOS's own settings, caches and databases |
| Firmware update | kept | kept |
| "Reset to initial settings" | kept | **deleted** |
| Factory reset | deleted | deleted |

New installs go on **app storage** when the TV has it and it has more room than user data, which is the case on every recent LG TV.  Otherwise they go on user data, where versions before 2.9 always put Entware.  User data is small, and webOS needs some of it for itself.  App storage has much more room and survives "Reset to initial settings".

**Older installs move over on their next repair.**  Running install (or **Repair** in the TV app) on an Entware that's on user data moves it to app storage, with the same checked move as `webos-entware move appstore`.  Over SSH it asks first.  Say no and it stays on user data, and repairs won't ask again.  If the move can't happen right then (another program is using Entware, or there's no room), Entware stays where it is, working, the repair still succeeds, and the next repair tries again.

```sh
sh webos-entware-installer.sh install --location=user    # a new install on user data instead
webos-entware move appstore                               # move an existing install to app storage
webos-entware move user                                   # or back to user data, and keep it there
```

A move stops Entware's services and checks no other program is using Entware.  Then it copies everything into a fresh folder, checks the copy matches, switches `/opt` over and checks it's that very copy, updates the boot script and your login, and only then removes the old copy.  If anything fails before the switch, Entware stays where it was.  It took 28 seconds for 25 MB on a C2.  `doctor` and the TV app show where Entware is and the free space in each area.

Until it moves, Entware points this out: the TV app shows a notice and a **Move to app storage** button, and SSH logins, the `webos-entware` menu and `doctor` say how to move it.  Installs from before 2.9 get these once the TV app updates from the Homebrew Channel, or with their next repair, which moves them anyway.

Choosing a place with `--location` or `move` sticks: repairs won't move it again, and the notices stop.  `webos-entware move user` on an install that's already on user data keeps it there for good.

Entware goes in a new root-only folder at the top of app storage, not `/media/developer` or `/media/internal`: other apps can write to those, and Entware's programs run as root.

**Only Entware that's root's alone is used.**  `/mnt/lg/user` can be written by any user on webOS, so a process that isn't root could otherwise swap in a folder of its own for the boot script to run as root.  So the boot script, the SSH login and the installer mount Entware first and then check `/opt` itself, where it can no longer be swapped: the folder and everything on the way to what runs as root (`bin`, `sbin`, `etc`, `etc/init.d`, `lib`, `opkg`, `rc.unslung`) must be real folders and files, owned by root, that no one else can write to.  Anything else is unmounted unused, and a login won't put it on your PATH or start its bash.  `doctor` shows this as "Root's alone" and names anything that fails.  Deleting an old copy (after a move, or on uninstall) goes through a private mount, after checking it's the very folder meant.

---

## What it changes on the TV

| Path | What |
|:-----|:-----|
| `/mnt/lg/appstore/entware` | Entware, all packages, and the `ent` and `webos-entware` commands.  `/mnt/lg/user/opt` instead when it's on [user data](#where-entware-lives) |
| `/opt` | Bind mount of the folder above. On webOS 25 the stock `/opt` only holds LG's factory test programs (`/opt/webos/tests`), which are hidden while Entware is mounted. Nothing on the TV needs them |
| `/var/lib/webosbrew/init.d/S99entware` | Boot script that remounts `/opt` and starts Entware services |
| `/home/root/.profile` | Switches interactive SSH logins to bash, and remounts `/opt` if the boot script didn't (skipped with `--no-shell`) |
| `/home/root/.bash_profile` | Loads `.profile` and `.bashrc` in bash |
| `/home/root/.bashrc` | Loads the aliases and prompt. Add your own settings here: repairing keeps this file |
| `/opt/bin/neofetch`, `/opt/etc/webos-entware/banner` | Only with the [login banner](#login-banner) add-on: neofetch, and the banner's wordmark and settings |
| `/opt/files`, `/opt/etc/webos-entware/credentials` | Only with a [network service](#network-services): the shared folder, and each service's password |
| Each service's settings in `/opt/etc` | Only with a network service: `samba/smb.conf`, `filebrowser/filebrowser.conf`, `minidlna.conf`, `transmission/settings.json`, `syncthing/` and the `S91webos-syncthing` start script.  Entware's stock settings are kept as `.bak` first, and removing the service deletes what it set up |
| `/tmp/webos-entware-web` | Only while the [phone dashboard](#manage-from-your-phone) runs: its port and sign-in code, root only.  Gone when it stops, and at every restart |

Your own `.profile`, `.bash_profile` and `.bashrc` are saved with a `.pre-entware` suffix before they are replaced. Your old `.profile` and `.bashrc` still run from the new files. A repair keeps the installer's `.bashrc` as it is, edits included, and if it ever has to rewrite `.profile` or `.bash_profile` after you changed them, it saves your copy as `.bak` first (then `.bak.1`, `.bak.2` and so on, so an older backup is never overwritten). Uninstalling saves an edited `.bashrc` as `.bashrc.entware-saved`.

If a fresh install fails partway, your shell files are put back exactly as they were, and the backups it made are removed.

Apart from the leftovers described in [Upgrading from an older setup](#upgrading-from-an-older-setup), nothing else on the system is touched.

### Upgrading from an older setup

Run install. It finds an Entware folder left by an older version of this script (or by an early manual setup), keeps your packages, and repairs everything around it:

- Moves Entware from user data to app storage, which has more room (see [Where Entware lives](#where-entware-lives))
- Puts the real `opkg` back where older versions had replaced it with a wrapper
- Replaces the old shell files. Your old `.bashrc` is saved as `.bashrc.bak`. One-line settings you added to it yourself (`alias`, `export`, `NAME=value`) are moved to the end of the new `.bashrc`, so they still work and still win over the defaults. Anything else, like lines inside a function, is listed on screen for you to copy over yourself.
- Writes the boot script, and turns off any older boot script that also mounts Entware on `/opt`. It is renamed with an `.entware-old` suffix, so it stops running but you can still read it.
- Removes Entware package lists from webOS's own opkg folders (`/var/lib/opkg/lists/entware` and Entware's lists in `/var/cache/opkg`). These are left when Entware's opkg runs before `/opt` is set up. webOS doesn't use them, and lists from other feeds are left alone.
- Removes an old boot log (`/mnt/lg/user/entware_boot.log`) and an empty `/mnt/lg/user/lib/opkg` folder from early setups

The cleanup only runs once the install has passed its checks. `doctor` lists any of these leftovers, plus old copies of installer scripts in your home folder that you may want to delete.

Your `nanorc` and other settings in `/opt/etc` are kept. Links in your home folder that point into Entware, like `~/.nanorc -> /opt/etc/nanorc`, keep working, and uninstall removes them.

---

## Reboots

The Homebrew Channel runs the scripts in `/var/lib/webosbrew/init.d` at every boot. The installer's `S99entware` script remounts `/opt` and starts any Entware services in `/opt/etc/init.d`. It runs in the background, so it never holds up the boot, and gives up quietly if Entware has been removed.

Each boot it notes what it did in `/tmp/webos-entware-boot.log`, and `doctor` shows the last line. If `doctor` says there is no boot log, the boot script never ran, which means the Homebrew Channel didn't run its boot scripts at that boot.

As a backup, your SSH login also mounts `/opt` if the boot script didn't, so Entware and bash are there as soon as you log in. `doctor` tells you when that happened. Services in `/opt/etc/init.d` then start at login instead of at boot.

> **Upgrading from a version before 2.1?** Those versions didn't write a boot script, so `/opt` was gone after every reboot. Run install once with the current version to add it.

---

## Uninstall

```sh
webos-entware uninstall
```

(or `sh /tmp/webos-entware-installer.sh uninstall` if you still have the downloaded copy)

This asks first, then removes Entware, every package installed with it, the boot script and the shell files the installer wrote, links in your home folder that point into Entware, and unmounts `/opt`. Your original shell files are put back. Disconnect and SSH in again afterwards.

If `/opt` can't be unmounted, or something (like a USB drive) is still mounted inside Entware's folder, the folder is kept rather than deleted. Fix that and run uninstall again.

To reinstall later, just run the install again.

---

## Troubleshooting and recovery

**Start here:** `webos-entware doctor` lists each problem with its fix.

**SSH closes right after login, or bash misbehaves.** Get a plain shell that skips your login files:

```sh
ssh -t root@<tv-ip> sh       # plain shell over SSH
telnet <tv-ip>               # Homebrew Channel telnet, if it's on
```

From there, `rm /home/root/.profile` gets normal SSH back right away. Then run `webos-entware install` to repair, or `webos-entware uninstall`.

**Entware is gone after a reboot.** Run `sh /mnt/lg/appstore/entware/bin/webos-entware doctor`, or `sh /mnt/lg/user/opt/bin/webos-entware doctor` if it's on user data (the saved copy works even while `/opt` isn't mounted). If the boot script is missing, run install again. If it says the boot script didn't run, the Homebrew Channel skipped its boot scripts at that boot: open the Homebrew Channel app once and check again. If the problem keeps coming back, please open an issue with the `doctor` output.

**The TV crashed during boot.** On the next boot the Homebrew Channel starts in failsafe mode, skips boot scripts and opens telnet. Connect with telnet, remove `/var/lib/webosbrew/init.d/S99entware`, then reboot.

**The install stopped with an error.** A fresh install undoes itself, so the TV is as it was. Fix what the message says (often the internet connection) and run install again.

**"No terminal to answer on."** The installer couldn't ask its questions. Run it from an SSH session, or add `-y` or `--arch=...`.

**A service isn't running.** Open it in the TV app's Add-ons and choose **Finish setup**, or run `webos-entware add <name>` again: it keeps the password and says what went wrong.  If another program on the TV has its port, it says which port.  Services start at boot through the boot script, so after updating from 2.11 or older, adding any service (or a repair) brings an older boot script up to date.

**Forgot a service's password?** `webos-entware info <name>`, or open it in Add-ons on the TV or in the phone dashboard.

**The phone dashboard won't open.** The phone needs to be on the same network as the TV (or on your tailnet), and the dashboard stops after 30 minutes without use: start it again from Add-ons.  A new start makes a new code, so scan the new QR code.

**Installed with an older version of this script?** Run install again. It keeps your packages and cleans up after the old version. See [Upgrading from an older setup](#upgrading-from-an-older-setup).

---

## FAQ

**Why 32-bit or 64-bit?** Every LG TV runs a 32-bit system, but Entware brings its own libraries, so only the kernel matters. A 64-bit kernel can run the faster `aarch64` build. A 32-bit kernel needs `armv7`. Both are normal, and both offer nearly the same packages.

**Where does it download from?** Only Entware's official server, using the same files as Entware's own `generic.sh` installer: `opkg` and `opkg.conf` from `http://bin.entware.net/aarch64-k3.10/installer/` (64-bit) or `http://bin.entware.net/armv7sf-k3.2/installer/` (32-bit). Packages then come from the feed that `opkg.conf` names. It's plain http because that's what Entware publishes.

**Does it change opkg?** No. `opkg` is Entware's own, untouched. `ent` is a separate helper.

**Can I keep my own shell?** Yes. Install with `--no-shell`. Entware programs are in `/opt/bin` and `/opt/sbin`. Without the shell setup there's no backup remount at login, so `/opt` depends on the boot script alone.

**How is it tested?** `tests/run_tests.sh` runs install, repair, reboots, add-ons and uninstall on a Linux PC as root, inside a private mount namespace with fake `wget` and `opkg`, under busybox sh and dash. It doesn't touch the PC or download anything. CI also builds the TV app, checks the IPK, clicks through the app in a headless browser, and tests the phone dashboard's sign-in, checks and page. None of it can stand in for a real TV, so changes are tried on one (an LG C2 on webOS 25) before release.

**Will my browser show certificate errors?** No.  File Browser, Transmission, Syncthing and the phone dashboard are plain `http://` on your home network, so there are no certificates to go wrong.  Browsers mark them "Not secure", and one with HTTPS-only mode turned on shows a page first with a button to continue.  Plain http isn't encrypted on your Wi-Fi, which is normal for home devices.  A self-signed certificate would be worse: every page would open with a full warning.  For encryption, use the services over [Tailscale](#network-services).

**Does the app phone home?** No. It only talks to GitHub: it reads the latest release number to say when an update is out, and downloads that release when you choose **Update**. See [SECURITY.md](SECURITY.md).

---

## Important Reminders

- **Never overwrite** system partitions or the stock `/opt` folder manually.
- **Stay cautious** when installing packages that could affect system networking or shell behavior.
- **Keep telnet on** in Homebrew Channel settings as a backup way in.

---

## Contributing

Compatibility reports, bug reports and ideas are welcome: use the [issue forms](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/new/choose), or **Report for GitHub** in the TV app.  [CONTRIBUTING.md](CONTRIBUTING.md) has the details, and everyone here follows the [code of conduct](CODE_OF_CONDUCT.md).  For pull requests, run the tests first (`sudo tests/run_tests.sh` and `sudo tests/run_tests.sh dash`, which need root for their private mount namespace) and test on a real TV if you can, saying which model and webOS version.

AI-assisted pull requests are welcome too, held to the same standard as the rest of this project: say in the pull request that AI was used, make sure you understand and have reviewed every change, and test it on a real TV.

To build the TV app yourself: `npm install -g @webos-tools/cli`, then `webos-app/build.sh`.  The IPK and its Homebrew Channel manifest land in `webos-app/out/`.  `tests/check-ipk.sh` checks the build, `node tests/ui-test.js` (with `npm install playwright`) clicks through the app and saves screenshots to `tests/ui-out/`, and `node tests/web-test.js` does the same for the phone dashboard.

---

## Credits

- Developed and maintained by [OhMyBahGosh](https://github.com/ohmybahgosh)
- Built on [Entware](https://github.com/Entware/Entware) and the [webOS Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel)
- The app's QR codes use [qrcode-generator](https://github.com/kazuhikoarase/qrcode-generator) by Kazuhiko Arase (MIT)
- The login banner runs [neofetch](https://github.com/dylanaraps/neofetch) by Dylan Araps (MIT), downloaded from its 7.1.0 release when you add it
- Special thanks to the webOS homebrew and rooting community

---

## License

MIT License.  See [LICENSE](LICENSE).

---

<p align="center"><strong>⚡ Let's make WebOS better, one safe improvement at a time! ⚡</strong></p>
