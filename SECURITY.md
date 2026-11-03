# Security policy

The installer and the TV app run as root on your TV and change how it boots and how SSH logins start, so security problems matter even for a small project.

## Supported versions

Only the [latest release](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/releases/latest) gets fixes.

## Reporting a problem

Please don't open a public issue for a security problem.  Report it privately through GitHub's [private vulnerability reporting](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/security/advisories/new) instead.

Include what you found, how to reproduce it, and which version you used.  You'll get a reply as soon as possible, and credit in the changelog if you'd like it.

## What it does as root

So you can judge it yourself:

- **Entware itself** goes in `/mnt/lg/appstore/entware` on app storage (or `/mnt/lg/user/opt` on user data, where versions before 2.9 put it), bind-mounted on `/opt`.  It must be root's alone.  `/mnt/lg/user` itself can be written by any user on webOS, so a process that isn't root could otherwise swap in its own folder for the boot script to run as root.  The boot script, the SSH login and the installer mount it first, then check `/opt` itself (the folder and everything on the way to what runs as root must be owned by root and writable by no one else), and unmount anything else unused.  Moves and uninstalls delete old copies only through a private mount, after checking the folder's identity.  Its packages come from Entware's own server (`bin.entware.net`), the same way every Entware install gets them.  Entware serves them over HTTP and doesn't sign them; that's how Entware works everywhere, not something this installer adds.
- **One boot script**, `/var/lib/webosbrew/init.d/S99entware`, remounts `/opt` and starts Entware services.  It runs in the background, so it can't hold up the boot.
- **Shell files** in `/home/root` (`.profile`, `.bash_profile`, `.bashrc`), only without `--no-shell`.  Your own files are backed up first and put back on uninstall.  Interactive SSH logins switch to bash only if bash runs.
- **Small tools** in `/opt`: `ent`, `webos-entware`, `webos-tv` and its commands, and settings for nano and locate.  Everything in `/opt` goes away with Entware.
- **Cleanup of old setups:** it removes Entware package lists from webOS's own `/var/lib/opkg` and `/var/cache/opkg` (only lists that hold Entware's packages), an old log and an empty folder from early setups, and renames old boot scripts that also mounted Entware so they stop running.
- **Add-ons** install Entware packages from the same server into `/opt`, and nano and locate get settings files there.  Removing one only uninstalls its own packages and files.
- **locate** gets an `mlocate` group only inside a private mount namespace while `updatedb` runs.  No system file is changed.
- **The login banner add-on** is the one thing not from Entware: it downloads neofetch from a fixed URL for its 7.1.0 release on GitHub, and uses it only if its SHA-256 matches the checksum written in the installer.  Anything else is deleted unused.
- **A lock** in `/tmp` keeps the app and SSH from changing things at the same time.  Background tasks log to `/tmp` (RAM).

It never changes the system partitions, opens ports, or sends anything about your TV anywhere.

## The TV app

- It runs the installer bundled inside it through the Homebrew Channel's root service.  Every command it runs is fixed in the app's code.  Nothing typed, received or downloaded is ever passed to the shell.
- Add-ons are a list fixed in the installer.  The app only sends an add-on's short name, which the installer checks against that list before anything reaches `opkg`, so it can't be used to install or remove anything else.
- It only talks to GitHub.  It reads the latest release number from the GitHub API, to say when an update is out.  When you choose **Update**, the installer downloads that release's `SHA256SUMS` and app over HTTPS from this repository's release page, checks the app against the checksum and that its package is `org.ohmybahgosh.entware` at the expected version, and only then installs it.  The download URLs are built from the version number alone, which must look like `1.2.3`.  The Homebrew Channel offers the same updates, checked against its manifest.
- The bug report QR code holds the output of `doctor` (TV model, versions, what's installed).  It's only sent if you scan it and submit the report yourself.

## Verifying a download

Every release has a `SHA256SUMS` file covering the installer and the app.  Download it next to them and run:

```sh
sha256sum -c SHA256SUMS
```

The Homebrew Channel checks the app's SHA-256 against its manifest before installing it.
