# Contributing to the WebOS Entware installer

Thanks for helping.  Reports from real TVs, fixes, docs and code are all welcome.  Please follow the [code of conduct](CODE_OF_CONDUCT.md).

## Reporting how it went on your TV

Compatibility reports help most, whether it worked or not.  The easiest way: open the Entware app on the TV, choose **Report for GitHub**, then **It works on my TV**, and scan the QR code with your phone.  It opens the form with your TV, version, build and the full check already filled in.

Without the app, run `webos-entware doctor` over SSH and paste the output into the [compatibility report form](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/new?template=compatibility-report.yml).  Something broken?  Use **Something went wrong** in the app, or the [bug report form](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/new?template=bug-report.yml).  Ideas go in the [idea form](https://github.com/ohmybahgosh/WEBOS-ENTWARE-INSTALLER/issues/new?template=feature-request.yml).  Security problems go privately, see [SECURITY.md](SECURITY.md).

## Working on the code

The installer is one POSIX `sh` file, `webos-entware-installer.sh`, that runs as root under busybox on the TV.  It also writes the `ent`, `webos-entware` and `webos-tv` commands.  The TV app is plain HTML, CSS and ES5 JavaScript in `webos-app/`, and it runs the same installer.  Start with the [README](README.md).

```sh
sudo tests/run_tests.sh             # the test suite under busybox sh, closest to the TV
sudo tests/run_tests.sh dash        # and under dash
shellcheck -s sh -S warning webos-entware-installer.sh
python3 tests/check-issue-forms.py
webos-app/build.sh                  # the TV app's IPK (needs ares-package from @webos-tools/cli)
tests/check-ipk.sh                  # checks the IPK and its manifest
node tests/ui-test.js               # drives the app with the remote's keys (needs playwright)
node tests/web-test.js              # the phone dashboard: its server's checks, and the page on a phone
```

The tests need root because they run in a private mount namespace, with tmpfs over the TV's paths and fake `wget`, `opkg` and `luna-send`.  Nothing is downloaded and your machine is left as it was.

AI-assisted pull requests are welcome, held to the same standard as the rest of this project (v2.0 on was built with AI coding agents too): say in the pull request that AI was used, make sure you understand and have reviewed every change, and test it on a real TV.

Ground rules:

- **It runs as root on someone's TV.**  Never write to system partitions, give every change a way back, and make sure a failed install leaves the TV as it was.
- **POSIX `sh` for busybox.**  No bashisms.  ShellCheck must pass at warning level.
- **Only Entware that's root's alone.**  Anything that mounts or runs Entware checks `/opt` after mounting it, so a folder another user can write to is never used.
- **Pinned and checked downloads.**  Anything that isn't from Entware's own server comes from a fixed release and is kept only if its SHA-256 matches.
- **Keep the user's files.**  Shell files are backed up before they're replaced, and settings people edit (nanorc, the banner's config) are kept.
- **A test for every change in behavior,** in `tests/run_tests.sh` (or `tests/ui-test.js` for the app, `tests/web-test.js` for the phone dashboard).
- **Write for TV owners.**  Plain words in output, the app and docs, two spaces between sentences, no em dashes, and a line in `CHANGELOG.md` for anything they'd notice.

Open a pull request against `main`; the template lists what to check.

## Releases

The maintainer cuts releases by pushing a `v*` tag.  GitHub Actions runs the tests, builds the TV app, and publishes the installer, the IPK, its Homebrew Channel manifest and `SHA256SUMS`, with release notes from the changelog.  ohmybahgosh.dev then refreshes its Homebrew Channel repository.
