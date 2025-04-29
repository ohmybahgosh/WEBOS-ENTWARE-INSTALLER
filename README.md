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

# WebOS Entware Minimal Manager

A **POSIX-compliant** safe installer to activate **Entware** package management on **rooted LG webOS TVs** (webOS 5.x through webOS 24).

No external dependencies.  
Pure shell, pure simplicity, pure power.

---

## Features

- ✅ **Safely installs Entware** with `/mnt/lg/user/opt` binding.
- ✅ **Automatically configures bash + nano-full** for a full featured terminal.
- ✅ **Fixes "I have no name!"** error via `/opt/etc/passwd` patching.
- ✅ **Sets up colorful, mobile-optimized SSH environment**.
- ✅ **Provides a safe opkg wrapper (`entwrap`)** and short alias (`ent`).
- ✅ **Includes built-in Entware CLI**: `search`, `install`, `remove`, `update`, `repair`, etc.
- ✅ **Adds tons of colorful useful aliases** (ls, grep, navigation, system info).
- ✅ **Includes friendly helper functions**: `findf`, `helpme`.
- ✅ **Offers cleaning of old broken Entware remnants safely**.
- ✅ **Lightweight** — requires under 2 MB free space initially.
- ✅ **Pure `/bin/sh` compliance** — NO bashisms, no external commands like `dialog`, `whiptail`, etc.

---

## Install Instructions

SSH into your LG TV (must be **rooted**) and run:

```sh
wget -O /tmp/webos-entware-installer.sh https://raw.githubusercontent.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/main/webos-entware-installer.sh
```

```sh
sh /tmp/webos-entware-installer.sh
```

Follow the simple menu to **Install Entware** or **Clean Old Remnants**.

---

## Usage Notes

- After installation, reconnect your SSH session to activate colorful bash.
- Use `entwrap help` or simply `ent help` to explore Entware package commands.
- Use `helpme` in your SSH session to list available shortcuts and commands.
- You now have access to full package management without risking system damage!

---

## Useful Commands

| Command | Description |
|:--------|:------------|
| `entwrap search <pkg>` | Search for Entware packages |
| `entwrap install <pkg>` | Install Entware package |
| `entwrap remove <pkg>` | Remove Entware package |
| `entwrap list` | List installed Entware packages |
| `entwrap update` | Update Entware package lists |
| `entwrap repair` | Attempt repair of Entware installation |
| `ent help` | Short alias for Entware CLI help |
| `ent install <pkg>` | Short alias to install a package |
| `helpme` | Show available SSH aliases and commands |
| `findf <pattern>` | Find files with colorful highlight |
| `reboot_safe` | Safer reboot command with delay |

---

## Important Reminders

- **Never overwrite** `/opt` system folder manually.
- **Always use `entwrap` or `ent`** instead of `opkg` directly.
- **Reboot your TV after installation** for mount changes to persist if needed.
- **Stay cautious** when installing packages that could affect system networking or shell behavior.

---

## Credits

- Project developed and maintained by [@ohmybahgosh](https://github.com/ohmybahgosh)
- Special thanks to the WebOS homebrew and rooting community.

---

## License

MIT License (see LICENSE file)

---

<p align="center"><strong>⚡ Let's make WebOS better — one safe improvement at a time! ⚡</strong></p>

