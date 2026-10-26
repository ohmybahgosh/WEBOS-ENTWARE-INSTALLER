<p align="center">
  <img src="https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/refs/heads/main/images/WEBOS-ENTWARE-INSTALLER-BANNER.png" alt="WEBOS-ENTWARE-INSTALLER" width="800">
</p>

---

<p align="center">
  <img src="https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/refs/heads/main/images/attention.gif" alt="Attention GIF" width="250">
</p>

<h2 align="center">⚠️ Please Read Carefully ⚠️</h2>

<br>

🚧 **This project is under active development!**  
❗ **Use at your own risk.**

I have taken every reasonable precaution to ensure safe, stable, and reliable operation.  
However, no script can guarantee a completely risk-free modification.

---

### 🛡️ Before proceeding:
- ✅ **Review** all planned actions carefully.
- ✅ **Backup** your important data and system files.
- ✅ **Prepare** recovery options if anything unexpected occurs.

---

### ✍️ By using this installer, you acknowledge:
- You **accept full responsibility** for any changes made to your device.
- This software is provided **"as-is"** without any warranties or guarantees.

---

<p align="center"><strong>✨ Stay smart. Stay cautious. Stay awesome. ✨</strong></p>

---

# WebOS Entware Manager

A **POSIX shell** installer that sets up **Entware** on **rooted LG webOS TVs**, so you can install hundreds of Linux command line packages with `opkg`. It checks your TV first, picks the right build, survives reboots and uninstalls cleanly.

No external dependencies. One file, pure `/bin/sh`.

---

## Contents

- [Features](#features)
- [Supported TVs](#supported-tvs)
- [Requirements](#requirements)
- [Install](#install)
- [The build check (32-bit or 64-bit)](#the-build-check-32-bit-or-64-bit)
- [Options](#options)
- [After installing](#after-installing)
- [Managing the install](#managing-the-install)
- [The ent helper](#the-ent-helper)
- [Shell setup and shortcuts](#shell-setup-and-shortcuts)
- [What it changes on the TV](#what-it-changes-on-the-tv)
- [Reboots](#reboots)
- [Uninstall](#uninstall)
- [Troubleshooting and recovery](#troubleshooting-and-recovery)
- [FAQ](#faq)
- [Credits](#credits)

---

## Features

- ✅ **Checks the TV before touching anything**: root, model, webOS version, kernel, Homebrew Channel, free space and the Entware download server.
- ✅ **Picks the right Entware build**: recommends 64-bit (`aarch64`) or 32-bit (`armv7`) from your kernel, tells you why, and asks you to continue, switch or exit.
- ✅ **Test-runs the build first**. If the 64-bit build can't run, it falls back to 32-bit.
- ✅ **Never leaves a half install**. If a fresh install fails partway, everything it did is undone. A failed repair keeps your existing install and packages.
- ✅ **Checks the result** when it finishes and prints a summary.
- ✅ **Survives reboots** with a Homebrew Channel boot script that remounts `/opt` and starts Entware services.
- ✅ **`doctor` check** that shows what's installed and says exactly what to fix.
- ✅ **`ent` helper** for searching, installing and checking packages, with Tab completion for `ent`, `opkg` and package names. `opkg` itself is never replaced.
- ✅ **Saves itself as `webos-entware`**, so status, repair and uninstall work any time, even after a reboot wipes `/tmp`.
- ✅ **Optional bash shell** with nano, colors, a neon prompt and handy aliases, plus a safe fallback to the stock shell if bash is ever missing or broken.
- ✅ **Backs up your own `.profile` and `.bashrc`** and puts them back on uninstall.
- ✅ **Fixes "I have no name!"** by linking Entware to the system user files.
- ✅ **Clean uninstall** that removes everything it added.

---

## Supported TVs

- **webOS 23, 24 and 25** (webOS 8, 9 and 10 internally) are the main targets.
- **webOS 22 and older** (webOS 4 and up) should work too. The installer tells you when your version is outside the tested range.
- Both **64-bit and 32-bit kernels** are supported. Most recent OLEDs (C2, C3, G4, C4 and up) have a 64-bit kernel. Many budget and older models have a 32-bit one.

---

## Requirements

- A **rooted** LG webOS TV with the **Homebrew Channel** installed. See [webosbrew.org/rooting](https://www.webosbrew.org/pages/rooting/) and check your firmware at [cani.rootmy.tv](https://cani.rootmy.tv).
- **SSH** turned on in Homebrew Channel settings. Keeping **telnet** on too gives you a way back in if SSH ever breaks.
- An **internet connection** on the TV.
- About **50 MB** free space.

Without the Homebrew Channel, Entware still installs, but `/opt` won't come back after a reboot. The installer warns you and asks first.

---

## Install

SSH into your TV as root, then download and run the installer:

```sh
wget -O /tmp/webos-entware-installer.sh https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh
sh /tmp/webos-entware-installer.sh
```

Pick **1) Install or repair Entware**. The installer shows your TV details and the build it recommends, then asks you to confirm.

When it finishes, **disconnect and SSH in again** to get the bash shell.

### Skip the menu

```sh
sh /tmp/webos-entware-installer.sh install      # install, or repair an existing install
sh /tmp/webos-entware-installer.sh doctor       # check the TV and the install
sh /tmp/webos-entware-installer.sh uninstall    # remove everything
```

### One line, piped into sh

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
| `-h`, `--help` | Show the commands and options |

---

## After installing

- SSH in again to get bash. Type `helpme` for the shortcuts.
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
| `webos-entware` | Open the menu |

`doctor` shows your model, webOS version, kernel, Homebrew Channel and telnet status, the installed and recommended builds, whether `/opt` is mounted, whether `opkg` and bash run, and whether the boot script and shell files are in place. It ends with "Everything looks right" or a list of problems, each with its fix.

The installer also writes `/opt/etc/webos-entware/install.info` with the installer version, date, model, webOS version, firmware, kernel and build. It's handy to paste into a bug report.

If you piped the installer into sh, there was no file to save. Download it once more to `/opt/bin/webos-entware` if you want the command.

---

## The ent helper

`ent` (also called `entwrap`) is a separate helper command. Plain `opkg` keeps working as normal.

| Command | What it does |
|:--------|:-------------|
| `ent search <text>` | Search available packages |
| `ent install <pkg>` | Install packages |
| `ent remove <pkg>` | Remove packages |
| `ent info <pkg>` | Show package details |
| `ent files <pkg>` | List the files a package installed |
| `ent list` | List installed packages |
| `ent update` | Refresh the package list |
| `ent upgradable` | Show packages with updates |
| `ent upgrade` | Refresh the list and upgrade everything |
| `ent repair` | Reinstall the Entware core |
| `ent doctor` | Same as `webos-entware doctor` |
| `ent help` | Show all `ent` commands |

Anything else is passed straight to `opkg`, so `ent list-installed` works too.

**Tab completion** (in the bash shell): press Tab after `ent`, `opkg` or `webos-entware` to complete commands. After `install`, `info` or `search` it completes available package names. After `remove`, `files` or `upgrade` it completes installed ones.

---

## Shell setup and shortcuts

Unless you use `--no-shell`, the installer adds bash, nano-full and dircolors, and sets SSH logins to switch to bash. If bash is ever missing or broken, logins stay on the stock shell instead of failing.

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

## What it changes on the TV

| Path | What |
|:-----|:-----|
| `/mnt/lg/user/opt` | Entware, all packages, and the `ent` and `webos-entware` commands |
| `/opt` | Bind mount of the folder above |
| `/var/lib/webosbrew/init.d/S99entware` | Boot script that remounts `/opt` and starts Entware services |
| `/home/root/.profile` | Switches interactive SSH logins to bash (skipped with `--no-shell`) |
| `/home/root/.bash_profile` | Loads `.profile` and `.bashrc` in bash |
| `/home/root/.bashrc` | Loads the aliases and prompt |

Your own `.profile`, `.bash_profile` and `.bashrc` are saved with a `.pre-entware` suffix before they are replaced. Your old `.profile` and `.bashrc` still run from the new files. Nothing else on the system is touched.

---

## Reboots

The Homebrew Channel runs the scripts in `/var/lib/webosbrew/init.d` at every boot. The installer's `S99entware` script remounts `/opt` and starts any Entware services in `/opt/etc/init.d`. It does nothing if Entware has been removed.

---

## Uninstall

```sh
webos-entware uninstall
```

(or `sh /tmp/webos-entware-installer.sh uninstall` if you still have the downloaded copy)

This asks first, then removes Entware, every package installed with it, the boot script and the shell files the installer wrote, and unmounts `/opt`. Your original shell files are put back. Disconnect and SSH in again afterwards.

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

**Entware is gone after a reboot.** Run `doctor`. If the boot script is missing, run install again. The Homebrew Channel must be installed for boot scripts to run.

**The TV crashed during boot.** On the next boot the Homebrew Channel starts in failsafe mode, skips boot scripts and opens telnet. Connect with telnet, remove `/var/lib/webosbrew/init.d/S99entware`, then reboot.

**The install stopped with an error.** A fresh install undoes itself, so the TV is as it was. Fix what the message says (often the internet connection) and run install again.

**"No terminal to answer on."** The installer couldn't ask its questions. Run it from an SSH session, or add `-y` or `--arch=...`.

**Installed with an older version of this script?** Run install again. It removes the old `opkg` wrapper and replaces the old shell files, keeping your packages.

---

## FAQ

**Why 32-bit or 64-bit?** Every LG TV runs a 32-bit system, but Entware brings its own libraries, so only the kernel matters. A 64-bit kernel can run the faster `aarch64` build. A 32-bit kernel needs `armv7`. Both are normal, and both offer nearly the same packages.

**Where does it download from?** Only Entware's official server, using the same files as Entware's own `generic.sh` installer: `opkg` and `opkg.conf` from `http://bin.entware.net/aarch64-k3.10/installer/` (64-bit) or `http://bin.entware.net/armv7sf-k3.2/installer/` (32-bit). Packages then come from the feed that `opkg.conf` names. It's plain http because that's what Entware publishes.

**Does it change opkg?** No. `opkg` is Entware's own, untouched. `ent` is a separate helper.

**Can I keep my own shell?** Yes. Install with `--no-shell`. Entware programs are in `/opt/bin` and `/opt/sbin`.

---

## Important Reminders

- **Never overwrite** system partitions or the stock `/opt` folder manually.
- **Stay cautious** when installing packages that could affect system networking or shell behavior.
- **Keep telnet on** in Homebrew Channel settings as a backup way in.

---

## Credits

- Developed and maintained by [OhMyBahGosh](https://github.com/ohmybahgosh)
- Built on [Entware](https://github.com/Entware/Entware) and the [webOS Homebrew Channel](https://github.com/webosbrew/webos-homebrew-channel)
- Special thanks to the webOS homebrew and rooting community

---

## License

MIT License (see LICENSE file)

---

<p align="center"><strong>⚡ Let's make WebOS better, one safe improvement at a time! ⚡</strong></p>
