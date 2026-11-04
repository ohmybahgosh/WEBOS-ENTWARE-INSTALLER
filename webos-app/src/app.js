/*
 * Entware TV app.
 *
 * A remote-friendly front end for webos-entware-installer.sh, which ships
 * inside the app. Root commands go through the Homebrew Channel's own root
 * service (luna://org.webosbrew.hbchannel.service/exec), so the app needs no
 * service of its own. Every command is a fixed string: nothing typed or
 * received is ever passed to the shell.
 *
 * Install, repair, uninstall, locate, add-ons, packages and package updates run as background
 * tasks (the script's "job" command), detached from the app, so closing the
 * app can't stop one halfway. The app follows the task's log while it runs,
 * and picks it up again if it's reopened.
 *
 * Plain ES5, so it runs on older webOS browsers too.
 */
(function () {
    'use strict';

    var REPO_PATH = '/ohmybahgosh/WEBOS-ENTWARE-INSTALLER';
    var RELEASES_API = 'https://api.github.com/repos' + REPO_PATH + '/releases/latest';
    var HBC_EXEC = 'luna://org.webosbrew.hbchannel.service/exec';
    var KEY = { UP: 38, DOWN: 40, ENTER: 13, BACK: 461, ESC: 27, BACKSPACE: 8 };

    // The script ships inside the app: <app dir>/assets/webos-entware-installer.sh
    var appDir = decodeURIComponent(window.location.pathname).replace(/\/[^\/]*$/, '');
    var SCRIPT = appDir + '/assets/webos-entware-installer.sh';

    var state = null;        // last status --json
    var latest = null;       // newest release on GitHub, if newer than this app
    var overlayMode = null;  // null, 'busy', 'message', 'confirm', or a list: 'addons', 'updates', 'report', 'packages', 'logs', 'addoninfo'
    var onConfirm = null;
    var jobTimer = null;
    var busy = false;        // a status call or task is in flight
    var addons = [];         // last addons --json
    var listIndex = 0;       // focused row on the Add-ons, Package updates or Report screen
    var backTo = '';         // 'addons' or 'updates': the screen to reopen after a task's result
    var upd = null;          // last updates --json
    var updRows = [];        // rows on the Package updates screen
    var autoChecked = false; // refreshed the package list once this session

    function $(id) { return document.getElementById(id); }

    function esc(s) {
        return String(s === undefined || s === null ? '' : s)
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }
    function plain(s) { return String(s || '').replace(/\x1b\[[0-9;]*m/g, ''); }
    // Single-quote a string for the shell
    function shq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'"; }
    function parseJson(out) {
        var i = (out || '').indexOf('{');
        if (i < 0) { return null; }
        try { return JSON.parse(out.slice(i)); } catch (e) { return null; }
    }

    // ------------------------------------------------------------------ luna

    var bridges = [];
    function luna(uri, params, cb) {
        if (typeof window.PalmServiceBridge === 'undefined') {
            cb({ returnValue: false, errorText: 'Not running on a webOS TV' });
            return;
        }
        var bridge = new window.PalmServiceBridge();
        bridges.push(bridge); // keep a reference until the reply arrives
        bridge.onservicecallback = function (msg) {
            var i = bridges.indexOf(bridge);
            if (i >= 0) { bridges.splice(i, 1); }
            var reply;
            try { reply = JSON.parse(msg); } catch (e) { reply = { returnValue: false, errorText: 'Unreadable reply' }; }
            cb(reply);
        };
        bridge.call(uri, JSON.stringify(params));
    }

    // Run the bundled script as root, with fixed arguments. cb(ok, stdout, error)
    // JSON answers leave stderr out, so a stray message can't break them.
    function runScript(args, cb) {
        if (window.ENTWARE_DEMO) { window.ENTWARE_DEMO(args, cb); return; }
        var errs = / --json$/.test(args) ? ' 2>/dev/null' : ' 2>&1';
        luna(HBC_EXEC, { command: 'sh ' + shq(SCRIPT) + ' ' + args + errs }, function (r) {
            cb(r.returnValue !== false, r.stdoutString || '', r.errorText || r.stderrString || '');
        });
    }

    // ------------------------------------------------------------------ status

    function refresh(cb) {
        runScript('status --json', function (ok, out, err) {
            var data = parseJson(out);
            if (!data) {
                showNoRoot(ok ? 'The installer gave an unexpected answer.' : err);
                if (cb) { cb(null); }
                return;
            }
            state = data;
            render();
            if (cb) { cb(data); }
        });
    }

    function showNoRoot(detail) {
        $('dot').className = 'dot dot-bad';
        $('headline').textContent = "Can't reach the TV as root";
        $('subline').textContent = 'This app needs a rooted TV with the Homebrew Channel.  ' + (detail || '');
        $('facts').innerHTML = '';
        $('notes').innerHTML = '';
    }

    function row(label, value) {
        return '<tr><td>' + esc(label) + '</td><td>' + value + '</td></tr>';
    }
    function yes(v, onText, offText, offClass) {
        return v ? '<span class="ok">' + esc(onText) + '</span>' : '<span class="' + (offClass || 'bad') + '">' + esc(offText) + '</span>';
    }

    function render() {
        var s = state;
        $('meta').innerHTML = esc('v' + s.version) + '<br>' + esc([s.model, s.webos && s.webos + (s.webosRelease ? ' (' + s.webosRelease + ')' : '')]
            .filter(function (x) { return x; }).join(' · '));
        $('ssh').textContent = s.ip ? 'ssh root@' + s.ip : '';

        // Headline
        var dot, head, sub;
        if (s.job === 'running') {
            dot = 'dot-busy';
            head = 'Working: ' + jobTitle(s.jobName);
            sub = 'A task is running.  Its progress opens in a moment.';
        } else if (!s.installed) {
            dot = 'dot-warn';
            head = 'Entware isn\'t installed';
            sub = 'Choose Install Entware.  It takes about two minutes and needs internet.';
        } else if (s.issues.length) {
            dot = 'dot-bad';
            head = 'Entware needs a repair';
            sub = s.issues[0];
        } else {
            dot = 'dot-ok';
            head = 'Entware is ready';
            sub = (s.packages !== null && s.packages !== undefined ? s.packages + ' packages.  ' : '') + 'No problems found.';
        }
        $('dot').className = 'dot ' + dot;
        $('headline').textContent = head;
        $('subline').textContent = sub;

        // Facts
        var html = '';
        if (s.installed) {
            html += row('Build', esc(s.buildLabel || s.build || 'unknown'));
            html += row('Mounted on /opt', yes(s.mounted, 'yes', 'no'));
            if (s.packages !== null) {
                html += row('Packages', esc(s.packages + (s.diskUsed ? ' · ' + s.diskUsed + ' used' : '')));
            }
            html += row('Remounts at boot', yes(s.bootScript, 'yes', s.homebrewChannel ? 'no' : 'at SSH login', s.homebrewChannel ? 'bad' : 'warn'));
            html += row('SSH shell', s.shellFiles ? yes(s.bash, 'bash', 'stock (bash missing)') : '<span class="dim">stock shell</span>');
            var nano = { on: yes(true, 'syntax colors on'), off: '<span class="warn">no colors (your own nanorc)</span>', none: '<span class="dim">not installed</span>' }[s.nano];
            html += row('nano', nano || esc(s.nano));
            var certs = { yes: yes(true, 'installed'), missing: '<span class="bad">missing</span>', notNeeded: '<span class="dim">not needed yet</span>' }[s.certs];
            html += row('HTTPS certificates', certs || esc(s.certs));
            var loc = {
                ready: yes(true, 'ready' + (s.locateDb ? ' · indexed ' + s.locateDb : '')),
                notSetUp: '<span class="bad">installed, not set up</span>',
                noDatabase: '<span class="warn">set up, not indexed yet</span>',
                notInstalled: '<span class="dim">not installed</span>'
            }[s.locate];
            html += row('locate', loc || esc(s.locate));
        } else {
            html += row('Recommended build', esc(buildLabel(s.recommended)));
            html += row('Kernel', esc(s.kernel + (s.kernelBits ? ' (' + s.kernelBits + '-bit)' : '')));
            html += row('Homebrew Channel', yes(s.homebrewChannel, 'yes', 'not found', 'warn'));
        }
        if (s.installed) {
            html += row('Location', (s.location === 'appstore' ? 'app storage' : 'user data') +
                (s.srcSafe === false ? ' · <span class="bad">not root\'s alone</span>' : ''));
        }
        var free = [];
        if (s.userFreeMB !== null && s.userFreeMB !== undefined) {
            free.push(s.userFreeMB < 50 ? '<span class="bad">' + esc(s.userFreeMB + ' MB') + '</span> user data' : esc(s.userFreeMB + ' MB') + ' user data');
        }
        if (s.appFreeMB !== null && s.appFreeMB !== undefined) {
            free.push(s.appFreeMB < 50 ? '<span class="bad">' + esc(s.appFreeMB + ' MB') + '</span> apps' : esc(s.appFreeMB + ' MB') + ' apps');
        }
        if (free.length) { html += row('Free space', free.join(' · ')); }
        html += row('Telnet recovery', yes(s.telnet, 'on', 'off', 'warn'));
        $('facts').innerHTML = html;

        // Notes: a move notice for installs on user data, then the rest of the
        // issues, then notes (doctor's own move note is the same thing)
        var notes = s.issues.slice(1).concat(s.notes.filter(function (n) { return !/A repair moves it there/.test(n); }));
        var html2 = '';
        // Problems come first; the notice shows when there are none
        if (canMove(s) && !s.issues.length) {
            html2 += '<li class="tip">Entware is on user data, which webOS needs.  Move it to app storage: ' +
                esc(s.appFreeMB + ' MB free') + ', and it survives resets.</li>';
            notes = [];
        } else {
            notes = notes.slice(0, 2);
        }
        $('notes').innerHTML = html2 + notes.map(function (n) { return '<li>' + esc(n) + '</li>'; }).join('');

        // Buttons for this state
        show('install', true);
        $('install-title').textContent = s.installed ? (s.issues.length ? 'Repair Entware' : 'Check and repair') : 'Install Entware';
        $('install-hint').textContent = s.installed ? 'keeps your packages and settings' : 'about two minutes, needs internet';
        show('upgrade', s.installed && s.mounted);
        var n = s.updates;
        $('upgrade-hint').textContent = n > 0 ? n + (n === 1 ? ' update' : ' updates') + ' available' :
            (n === 0 ? 'all up to date' + (s.updatesChecked ? ' · list from ' + s.updatesChecked.split(' ')[0] : '') : 'see what can be updated');
        document.querySelector('[data-action="upgrade"]').className = 'btn' + (n > 0 ? ' btn-attn' : '');
        show('addons', s.installed && s.mounted);
        show('packages', s.installed && s.mounted);
        show('move', canMove(s));
        show('uninstall', s.installed);
        show('update', !!latest);
        if (latest) {
            $('update-title').textContent = 'Update to v' + latest;
            $('update-hint').textContent = 'you have v' + s.version + ', downloads, checks and installs it';
        }
        if (current >= buttons().length) { current = buttons().length - 1; }
        if (!overlayMode) { focusCurrent(); }

        // A task started earlier (or from another screen) is still running
        if (s.job === 'running' && !jobTimer) { followJob(s.jobName); }
    }

    // App storage is where Entware belongs when it's there and has more
    // room than user data (the installer's own rule). Not offered if you
    // chose user data.
    function appstoreBetter(s) {
        return s.appFreeMB !== null && s.appFreeMB !== undefined && s.userFreeMB !== null && s.userFreeMB !== undefined &&
            s.appFreeMB > s.userFreeMB;
    }
    function canMove(s) {
        return !!(s.installed && s.mounted && s.location === 'user' && s.locationChoice !== 'user' &&
            s.srcSafe !== false && appstoreBetter(s));
    }

    function show(action, on) {
        document.querySelector('[data-action="' + action + '"]').style.display = on ? '' : 'none';
    }

    function buildLabel(b) {
        return { 'aarch64-k3.10': '64-bit (aarch64-k3.10)', 'armv7sf-k3.2': '32-bit (armv7sf-k3.2)' }[b] || b || 'unknown';
    }

    // ------------------------------------------------------------------ overlay

    function overlay(mode, titleHtml, bodyHtml, hint) {
        overlayMode = mode;
        $('overlay-title').innerHTML = titleHtml;
        $('overlay-body').innerHTML = bodyHtml;
        $('overlay-hint').textContent = hint || '';
        $('overlay').className = 'overlay';
    }
    function closeOverlay() {
        overlayMode = null;
        onConfirm = null;
        $('overlay').className = 'overlay hidden';
        if (backTo) {
            var b = backTo;
            backTo = '';
            // A list just shown is drawn again as it was; it's read again
            // from the TV only after a task may have changed it
            if (b === 'updates') { openUpdates(false); } else if (b === 'report') { openReportMenu(); }
            else if (b === 'packages') { if (fresh.packages && pkgList) { renderPackages(); } else { openPackages(); } }
            else if (b === 'logs') { if (fresh.logs && logData) { renderLogs(); } else { openLogs(); } }
            else if (b === 'addoninfo' && addonInfo && addonInfo.addon) { openAddonInfo(addonInfo.addon); }
            else {
                // Back on the add-on that was open
                if (addonInfo) { listIndex = addonInfo.index; addonInfo = null; }
                if (fresh.addons && addons.length) { renderAddons(); } else { openAddons(); }
            }
            return;
        }
        focusCurrent();
    }
    function confirmThen(title, text, fn) {
        backTo = /^(addons|updates|packages|logs|addoninfo)$/.test(overlayMode || '') ? overlayMode : ''; // BACK returns to the list
        onConfirm = fn;
        overlay('confirm', esc(title), esc(text), 'Press OK to go ahead, or BACK to cancel.');
    }
    // OK on a confirmation: go ahead, without returning to the screen behind it
    function acceptConfirm() {
        var fn = onConfirm;
        backTo = '';
        closeOverlay();
        fn();
    }
    // Scroll a long log or report in the open panel
    function scrollPanel(by) {
        var pre = $('overlay-body').querySelector('pre');
        if (pre) { pre.scrollTop += by; }
    }

    // ------------------------------------------------------------------ tasks

    function jobTitle(name) {
        var u = /^upgrade (.+)$/.exec(name || '');
        if (u) { return 'Update ' + u[1]; }
        var pk = /^pkg-(add|remove) (.+)$/.exec(name || '');
        if (pk) { return (pk[1] === 'add' ? 'Install ' : 'Remove ') + pk[2]; }
        var m = /^(add|remove|password) ([a-z0-9]+)$/.exec(name || '');
        if (m) {
            var a = addonById(m[2]);
            return ({ add: 'Add ', remove: 'Remove ', password: 'New password for ' })[m[1]] + (a ? a.title : m[2]);
        }
        return { install: 'Install and repair', uninstall: 'Uninstall', locate: 'Set up locate',
            'move appstore': 'Move to app storage', 'move user': 'Move to user data', 'app-update': 'Update the app',
            upgrade: 'Update all packages' }[name] || name || 'Task';
    }

    function logHtml(lines) {
        return '<pre id="log">' + esc(lines.map(plain).join('\n')) + '</pre>';
    }

    // Start a task in the background, then follow it
    // Lists read from the TV that are still current, until a task runs
    var fresh = { addons: false, packages: false, logs: false };
    function stale() { fresh.addons = fresh.packages = fresh.logs = false; }

    function startJob(name) {
        if (busy || !/^(install|uninstall|locate|upgrade|app-update|(upgrade|pkg-add|pkg-remove) [A-Za-z0-9][A-Za-z0-9._+-]*|(add|remove|password) [a-z0-9]+|move (user|appstore))$/.test(name)) { return; }
        stale();
        busy = true;
        overlay('busy', '<span class="spinner"></span>' + esc(jobTitle(name)), logHtml(['Starting…']), 'You can leave the app open, or press BACK later.  The task keeps going either way.');
        runScript('job ' + name, function (ok, out) {
            if (!/Started:/.test(out)) {
                busy = false;
                overlay('message', '<span class="result-bad">' + esc(jobTitle(name)) + ' didn\'t start</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to close.');
                return;
            }
            followJob(name);
        });
    }

    // Check on the running task every second or so and show its log
    function followJob(name) {
        busy = true;
        if (jobTimer) { clearTimeout(jobTimer); }
        function poll() {
            jobTimer = null;
            runScript('job-status --json', function (ok, out) {
                var j = parseJson(out) || { state: 'lost', log: [] };
                var log = j.log && j.log.length ? j.log : ['Working…'];
                var title = jobTitle(j.name || name);
                if (j.state === 'running') {
                    var pre = overlayMode === 'busy' && $('log');
                    if (pre) {
                        // Update the text in place, so scrolling up to read stays put
                        var atEnd = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
                        pre.textContent = log.map(plain).join('\n');
                        if (atEnd) { pre.scrollTop = pre.scrollHeight; }
                    } else {
                        overlay('busy', '<span class="spinner"></span>' + esc(title), logHtml(log), 'This keeps going even if you close the app.');
                        $('log').scrollTop = $('log').scrollHeight;
                    }
                    jobTimer = setTimeout(poll, 1200);
                    return;
                }
                busy = false;
                var jn = j.name || name;
                backTo = /^(add|remove) /.test(jn) ? 'addons' : (/^password /.test(jn) && addonInfo ? 'addoninfo' :
                    (/^upgrade/.test(jn) ? 'updates' : (/^pkg-/.test(jn) ? 'packages' : '')));
                var good = j.state === 'done' && j.exit === 0;
                var heading = good ? title + ': done' : (j.state === 'lost' ? title + ' stopped before finishing' : title + ': something went wrong');
                overlay('message', '<span class="' + (good ? 'result-ok' : 'result-bad') + '">' + esc(heading) + '</span>', logHtml(log),
                    (good && j.name === 'install' ? 'New SSH logins get the bash shell.  ' : '') + 'Use ▲ ▼ to scroll.  Press OK or BACK to close.');
                $('log').scrollTop = $('log').scrollHeight;
                refresh();
            });
        }
        poll();
    }

    // ------------------------------------------------------------------ add-ons

    function addonById(id) {
        for (var i = 0; i < addons.length; i++) { if (addons[i].id === id) { return addons[i]; } }
        return null;
    }

    function openAddons() {
        if (busy) { return; }
        busy = true;
        overlay('busy', '<span class="spinner"></span>Add-ons', logHtml(['Checking what\'s installed…']), '');
        runScript('addons --json', function (ok, out) {
            busy = false;
            var list = null;
            var i = (out || '').indexOf('[');
            try { list = i >= 0 ? JSON.parse(out.slice(i)) : null; } catch (e) { list = null; }
            if (!list || !list.length) {
                overlay('message', '<span class="result-bad">Couldn\'t list the add-ons</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to close.');
                return;
            }
            addons = list;
            fresh.addons = true;
            if (listIndex > addons.length) { listIndex = 0; }
            renderAddons();
        });
    }

    function addonPill(a) {
        if (a.state === 'installed') { return a.removable ? '<span class="pill pill-ok">' + (a.service ? 'Running' : 'Installed') + '</span>' : '<span class="pill pill-ok">Included</span>'; }
        if (a.state === 'needsSetup') { return '<span class="pill pill-warn">' + (a.id === 'tailscale' ? 'Sign in' : 'Finish setup') + '</span>'; }
        return '<span class="pill pill-add">Add</span>';
    }

    // The first row opens the phone dashboard; the add-ons follow
    function renderAddons() {
        var html = '<div class="addons" id="addon-list">' +
            '<div class="addon' + (listIndex === 0 ? ' focus' : '') + '" data-i="0"><div><b>Manage from your phone</b>' +
            '<small>add-ons, addresses and passwords, from your phone\'s browser</small></div><span class="pill pill-add">QR code</span></div>' +
            addons.map(function (a, i) {
                return '<div class="addon' + (i + 1 === listIndex ? ' focus' : '') + '" data-i="' + (i + 1) + '">' +
                    '<div><b>' + esc(a.title) + '</b><small>' + esc(a.about) + '</small></div>' + addonPill(a) + '</div>';
            }).join('') + '</div>';
        overlay('addons', 'Add-ons', html, 'OK adds one, or opens it to finish setup, see its password or remove it.  BACK to close.');
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { focusAddon(parseInt(row.getAttribute('data-i'), 10)); });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); chooseAddon(); });
        });
        focusAddon(listIndex);
    }

    function focusAddon(i) {
        var rows = document.querySelectorAll('.addon');
        if (!rows.length) { return; }
        listIndex = Math.max(0, Math.min(i, rows.length - 1));
        for (var r = 0; r < rows.length; r++) { rows[r].className = 'addon' + (r === listIndex ? ' focus' : ''); }
        // Keep the focused row in view
        var box = $('addon-list'), row = rows[listIndex];
        if (row.offsetTop < box.scrollTop) { box.scrollTop = row.offsetTop; }
        else if (row.offsetTop + row.offsetHeight > box.scrollTop + box.clientHeight) { box.scrollTop = row.offsetTop + row.offsetHeight - box.clientHeight; }
    }

    function chooseAddon() {
        if (listIndex === 0) { addonInfo = { addon: null, index: 0 }; openWeb('addons'); return; }
        var a = addons[listIndex - 1];
        // Ids are short names from the installer's fixed list; anything else is refused
        if (!a || !/^[a-z0-9]+$/.test(a.id)) { return; }
        if (a.state === 'notInstalled') {
            confirmThen('Add ' + a.title + '?', (a.system ? 'webOS already has its own (' + a.system + ').  This adds Entware\'s too, which comes first on the PATH.  ' : '') +
                a.about + '.  ' + (a.id === 'banner' ?
                'Downloads neofetch 7.1.0 from GitHub and checks it against the release\'s checksum.  Needs internet.' :
                'Installs ' + a.packages + ' from Entware, and needs internet.') +
                (a.id === 'tailscale' ? '  It starts with the TV.  Then sign in to Tailscale with the QR code it shows here.' :
                    (a.service ? '  It starts with the TV, with no guest access and a password made on the TV.  Afterwards, open it here for its address and password.' : '')),
                function () { startJob('add ' + a.id); });
        } else if (a.service) {
            openAddonInfo(a, listIndex);
        } else if (a.state === 'needsSetup') {
            confirmThen('Finish setting up ' + a.title + '?', 'It\'s installed, but not set up for webOS yet.  This finishes the setup.',
                function () { startJob('add ' + a.id); });
        } else if (a.removable) {
            confirmThen('Remove ' + a.title + '?', 'Uninstalls ' + a.packages + (a.id === 'locate' ? ', its settings and the hourly refresh' : (a.id === 'banner' ? ' and the banner' : '')) + '.  You can add it again any time.',
                function () { startJob('remove ' + a.id); });
        } else {
            backTo = 'addons';
            overlay('message', esc(a.title), esc(a.title + ' is part of the base setup, so it stays installed.  ' + a.about + '.'), 'Press OK or BACK to go back.');
        }
    }

    // A network service: how to reach it and its password, with a QR code
    // of its address (or Tailscale's sign-in link) for a phone, and what can
    // be done with it
    var addonInfo = null;   // { addon, index (in the add-ons list), info, rows }
    function openAddonInfo(a, index) {
        if (busy) { return; }
        busy = true;
        if (index !== undefined) { addonInfo = { addon: a, index: index }; }
        overlay('busy', '<span class="spinner"></span>' + esc(a.title), logHtml(['Checking ' + a.title + '…']), '');
        runScript('info ' + a.id + ' --json', function (ok, out) {
            busy = false;
            var d = parseJson(out);
            if (!d || d.id !== a.id) {
                backTo = 'addons';
                overlay('message', '<span class="result-bad">Couldn\'t check ' + esc(a.title) + '</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to go back.');
                return;
            }
            var rows = [];
            if (d.state !== 'installed') {
                rows.push(a.id === 'tailscale' ?
                    { act: 'setup', title: d.url ? 'Get a new sign-in link' : 'Connect', sub: 'starts Tailscale and asks it for a sign-in link' } :
                    { act: 'setup', title: 'Finish setup', sub: 'sets it up again and starts it, with the same password' });
            }
            if (d.hasPassword && d.state === 'installed') {
                rows.push({ act: 'password', title: 'New random password', sub: 'the TV makes one and shows it here.  To type your own, use Manage from your phone.' });
            }
            rows.push({ act: 'web', title: 'Manage from your phone', sub: d.hasPassword ? 'see the password, or type your own, on your phone' : 'all your add-ons, from your phone' });
            rows.push({ act: 'remove', title: 'Remove ' + a.title, sub: a.id === 'tailscale' ? 'signs the TV out of your tailnet and uninstalls tailscale' :
                'stops it and uninstalls ' + a.packages + '.  Your files in /opt/files stay.' });
            addonInfo = { addon: a, index: addonInfo && addonInfo.addon && addonInfo.addon.id === a.id ? addonInfo.index : 0, info: d, rows: rows };
            listIndex = 0;
            renderAddonInfo();
        });
    }
    function renderAddonInfo() {
        var a = addonInfo.addon, d = addonInfo.info, svg = '';
        if (d.url) {
            try {
                var qr = window.qrcode(0, 'M');
                qr.addData(d.url);
                qr.make();
                svg = qr.createSvgTag({ cellSize: 4, margin: 12, scalable: true });
            } catch (e) { svg = ''; }
        }
        var text = (d.lines || []).map(function (l) { return '<p>' + esc(l) + '</p>'; }).join('') +
            (d.user ? '<div class="cred">User <b>' + esc(d.user) + '</b><br>Password <b>' + esc(d.password) + '</b></div>' : '') +
            (d.url && a.id === 'tailscale' ? '<p class="dim">' + esc(d.url) + '</p>' : '');
        var html = '<div class="qr qr-small">' + svg + '<div class="info-text">' + text + '</div></div>' +
            '<div class="addons addons-short" id="addon-list">' + addonInfo.rows.map(function (r, i) {
                return '<div class="addon' + (i === listIndex ? ' focus' : '') + '" data-i="' + i + '">' +
                    '<div><b>' + esc(r.title) + '</b><small>' + esc(r.sub) + '</small></div></div>';
            }).join('') + '</div>';
        overlay('addoninfo', esc(a.title) + (d.state === 'installed' ? ' <span class="pill pill-ok">Running</span>' : ''), html,
            (svg ? 'Scan the QR code with your phone.  ' : '') + 'OK picks, BACK goes back.');
        backTo = 'addons';
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { focusAddon(parseInt(row.getAttribute('data-i'), 10)); });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); chooseAddonInfo(); });
        });
        focusAddon(listIndex);
    }
    function chooseAddonInfo() {
        var a = addonInfo && addonInfo.addon, r = addonInfo && addonInfo.rows[listIndex];
        if (!a || !r || !/^[a-z0-9]+$/.test(a.id)) { return; }
        if (r.act === 'setup') {
            backTo = '';
            startJob('add ' + a.id);
        } else if (r.act === 'password') {
            confirmThen('New random password for ' + a.title + '?', 'The old one stops working, and ' + a.title + ' restarts for a moment.  ' +
                'To choose your own, use Manage from your phone, or over SSH: webos-entware password ' + a.id + ' --ask',
                function () { startJob('password ' + a.id); });
        } else if (r.act === 'web') {
            openWeb('addoninfo');
        } else if (r.act === 'remove') {
            confirmThen('Remove ' + a.title + '?', 'Stops it, uninstalls ' + a.packages + ' and deletes its settings and password.' +
                (a.id === 'tailscale' ? '  The TV signs out of your tailnet.' : '  Your files in /opt/files stay.'),
                function () { startJob('remove ' + a.id); });
        }
    }

    // The phone dashboard (webos-app/web, run by 'webos-entware web'): a QR
    // code of its address that signs the phone in, and the code to type
    var webFrom = 'addons';
    function openWeb(from) {
        if (busy) { return; }
        busy = true;
        webFrom = from || 'addons';
        overlay('busy', '<span class="spinner"></span>Manage from your phone', logHtml(['Starting the phone dashboard…']), '');
        runScript('web start --json', function (ok, out) {
            busy = false;
            var d = parseJson(out);
            if (!d || !d.running || !/^http:\/\/[0-9.]+:\d+$/.test(d.url) || !/^[A-Z0-9]{8}$/.test(d.code)) {
                backTo = webFrom;
                overlay('message', '<span class="result-bad">The phone dashboard didn\'t start</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to go back.');
                return;
            }
            var svg = '';
            try {
                var qr = window.qrcode(0, 'M');
                qr.addData(d.url + '/#k=' + d.code);
                qr.make();
                svg = qr.createSvgTag({ cellSize: 4, margin: 12, scalable: true });
            } catch (e) { svg = ''; }
            var code = d.code.slice(0, 4) + ' ' + d.code.slice(4);
            listIndex = 0;
            overlay('web', 'Manage from your phone', '<div class="qr qr-small">' + svg + '<div class="info-text">' +
                '<p>Scan this with your phone\'s camera to add and remove add-ons, and see or change passwords, from its browser.</p>' +
                '<p>Or open <b>' + esc(d.url) + '</b> on a phone or computer on your network, and enter this code:</p>' +
                '<div class="cred web-code">' + esc(code) + '</div>' +
                '<p class="dim">It stops by itself after 30 minutes without use.</p></div></div>' +
                '<div class="addons addons-short" id="addon-list"><div class="addon focus" data-i="0"><div><b>Stop the phone dashboard</b>' +
                '<small>signs out every phone, and makes a new code next time</small></div></div></div>',
                'OK stops it.  BACK goes back and leaves it running.');
            backTo = webFrom;
        });
    }
    function chooseWeb() {
        if (busy) { return; }
        busy = true;
        runScript('web stop --json', function () {
            busy = false;
            closeOverlay();
        });
    }

    // ------------------------------------------------------------------ package updates

    // refreshList: download the package list from Entware's server first
    function openUpdates(refreshList) {
        if (busy) { return; }
        busy = true;
        overlay('busy', '<span class="spinner"></span>Package updates',
            logHtml([refreshList ? 'Checking Entware\'s server for updates…' : 'Reading the package list…']), '');
        runScript('updates --json' + (refreshList ? ' --refresh' : ''), function (ok, out) {
            busy = false;
            var d = parseJson(out);
            if (!d || !d.packages) {
                overlay('message', '<span class="result-bad">Couldn\'t check for updates</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to close.');
                return;
            }
            upd = d;
            if (state) {
                state.updates = d.packages.length;
                state.updatesChecked = d.checked;
                state.updatesAgeHours = d.ageHours;
            }
            renderUpdates();
        });
    }

    function renderUpdates() {
        var p = upd.packages;
        updRows = [];
        if (p.length > 1) {
            updRows.push({ kind: 'all', title: 'Update all ' + p.length + ' packages', sub: 'refreshes the package list, then updates every package', pill: 'Update all' });
        }
        p.forEach(function (x) {
            updRows.push({ kind: 'pkg', name: x.name, installed: x.installed, available: x.available,
                title: x.name, sub: x.installed + '  →  ' + x.available, pill: 'Update' });
        });
        updRows.push({ kind: 'check', title: 'Check again', sub: 'downloads the package list from Entware\'s server', pill: '' });
        if (listIndex >= updRows.length) { listIndex = 0; }
        var head = '<div class="list-head">' +
            (p.length ? esc(p.length + (p.length === 1 ? ' package has an update.' : ' packages have updates.')) : '<span class="ok">Every package is up to date.</span>') +
            '  <span class="dim">Package list from ' + esc(upd.checked || 'unknown') +
            (upd.refreshFailed ? ' (Entware\'s server couldn\'t be reached)' : '') + '</span></div>';
        var html = head + '<div class="addons" id="addon-list">' + updRows.map(function (r, i) {
            return '<div class="addon' + (i === listIndex ? ' focus' : '') + '" data-i="' + i + '">' +
                '<div><b>' + esc(r.title) + '</b><small>' + esc(r.sub) + '</small></div>' +
                (r.pill ? '<span class="pill pill-add">' + esc(r.pill) + '</span>' : '') + '</div>';
        }).join('') + '</div>';
        overlay('updates', 'Package updates', html, 'OK updates or checks again.  BACK to close.');
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { focusAddon(parseInt(row.getAttribute('data-i'), 10)); });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); chooseUpdate(); });
        });
        focusAddon(listIndex);
    }

    function chooseUpdate() {
        var r = updRows[listIndex];
        if (!r) { return; }
        if (r.kind === 'check') { openUpdates(true); return; }
        if (r.kind === 'all') {
            confirmThen('Update all ' + upd.packages.length + ' packages?',
                'Refreshes the package list, then updates every package that has an update.  Your settings are kept.  A service restarts if its package updates.',
                function () { startJob('upgrade'); });
            return;
        }
        if (!/^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(r.name)) { return; }
        confirmThen('Update ' + r.name + '?', 'From ' + r.installed + ' to ' + r.available + '.  Its settings are kept.',
            function () { startJob('upgrade ' + r.name); });
    }

    // Once a session, if the package list is a day old, refresh it quietly so
    // the update count is current
    function autoCheckUpdates(s) {
        if (autoChecked || window.ENTWARE_DEMO || !s || !s.installed || !s.mounted) { return; }
        autoChecked = true;
        if (s.updatesAgeHours !== null && s.updatesAgeHours < 24) { return; }
        runScript('updates --json --refresh', function () { if (!busy && !overlayMode) { refresh(); } });
    }

    // ------------------------------------------------------------------ actions

    var actions = {
        install: function () {
            if (!state) { return; }
            if (!state.installed) {
                confirmThen('Install Entware?',
                    'Installs Entware on ' + (appstoreBetter(state) ? 'app storage (' + state.appFreeMB + ' MB free)' : 'user data') +
                    ', about 25 MB, mounts it on /opt at every boot, and adds bash, nano and GNU ls with a few helpers.  ' +
                    'SSH logins switch to bash, and your own shell files are kept.  Uses the recommended ' + buildLabel(state.recommended) + ' build.  ' +
                    'If anything goes wrong, everything is undone.',
                    function () { startJob('install'); });
            } else {
                confirmThen(state.issues.length ? 'Repair Entware?' : 'Check and repair Entware?',
                    'Checks everything and fixes what it finds: the mount, the boot script, the shell setup and the helpers.  Your packages and your own settings are kept.' +
                    (canMove(state) ? '  Entware also moves from user data to app storage, which has more room and keeps it through "Reset to initial settings".' : ''),
                    function () { startJob('install'); });
            }
        },
        upgrade: function () { listIndex = 0; openUpdates(!!(state && (state.updatesAgeHours === null || state.updatesAgeHours >= 24))); },
        addons: function () { listIndex = 0; openAddons(); },
        packages: function () { listIndex = 0; pkgQuery = ''; pkgList = null; openPackages(); },
        move: function () {
            if (!state) { return; }
            confirmThen('Move Entware to app storage?',
                'User data, which webOS needs for itself, has ' + state.userFreeMB + ' MB free.  App storage has ' + state.appFreeMB + ' MB.  ' +
                'Repairing does this too.  ' +
                'Entware and all ' + (state.packages || 'its') + ' packages move there, along with your settings, and its services restart.  ' +
                'It\'s copied and checked before anything is removed, and it also keeps Entware through "Reset to initial settings".',
                function () { startJob('move appstore'); });
        },
        uninstall: function () {
            if (!state) { return; }
            confirmThen('Uninstall Entware?',
                'Removes Entware, all ' + (state.packages || 'its') + ' packages, the boot script and the bash login setup, and puts your original shell files back.  ' +
                'This can\'t be undone, but you can install again any time.',
                function () { startJob('uninstall'); });
        },
        doctor: function () { listIndex = 0; openLogs(); },
        report: function () {
            if (busy) { return; }
            busy = true;
            runScript('status', function (ok, out) {
                busy = false;
                doctorText = plain(out).trim();
                listIndex = 0;
                openReportMenu();
            });
        },
        update: function () {
            if (!state || !latest) { return; }
            confirmThen('Update the app to v' + latest + '?',
                'Downloads v' + latest + ' from GitHub, checks it against the release\'s checksums, and installs it.  ' +
                'The app closes for a moment and opens again.  Entware and your packages aren\'t touched, and the webos-entware command updates too.',
                function () { startJob('app-update'); });
        }
    };

    // ------------------------------------------------------------------ packages

    // One screen for every Entware package: what's installed (with Remove),
    // or, after a search, what matches (with Install).  Names and search words
    // are checked here and again by the installer.
    var PKG_NAME = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;
    var SEARCH_WORD = /^[A-Za-z0-9._+-]{1,40}$/;
    var pkgQuery = '';       // last search, '' for the installed list
    var pkgList = [];        // installed --json, or search --json
    var pkgInstalled = {};   // installed packages by name, for the search view
    var pkgRows = [];        // rows under the search field

    function listJson(out) {
        var i = (out || '').indexOf('[');
        try { return i >= 0 ? JSON.parse(out.slice(i)) : null; } catch (e) { return null; }
    }
    // A long description, cut at a word so it fits on two lines
    function short(t, n) {
        t = String(t || '');
        if (t.length <= n) { return t; }
        t = t.slice(0, n);
        return t.slice(0, Math.max(t.lastIndexOf(' '), n - 20)).replace(/[\s,.;:(]+$/, '') + '…';
    }
    function kb(n) { return n >= 1024 ? (Math.round(n / 102.4) / 10) + ' MB' : (n || 0) + ' KB'; }

    function openPackages() {
        if (busy) { return; }
        busy = true;
        overlay('busy', '<span class="spinner"></span>Packages', logHtml([pkgQuery ? 'Searching for ' + pkgQuery + '…' : 'Reading what\'s installed…']), '');
        runScript('installed --json', function (ok, out) {
            var inst = listJson(out);
            if (!inst) {
                busy = false;
                overlay('message', '<span class="result-bad">Couldn\'t list the packages</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to close.');
                return;
            }
            pkgInstalled = {};
            inst.forEach(function (p) { pkgInstalled[p.name] = p; });
            if (!pkgQuery) {
                busy = false;
                pkgList = inst;
                fresh.packages = true;
                renderPackages();
                return;
            }
            runScript('search ' + pkgQuery + ' --json', function (ok2, out2) {
                busy = false;
                pkgList = listJson(out2);
                if (!pkgList) {
                    overlay('message', '<span class="result-bad">The search didn\'t work</span>', logHtml(plain(out2).trim().split('\n')), 'Press OK or BACK to go back.');
                    pkgQuery = '';
                    backTo = 'packages';
                    return;
                }
                fresh.packages = true;
                renderPackages();
            });
        });
    }

    function pkgRow(p) {
        var i = pkgInstalled[p.name];
        if (!pkgQuery) {
            var why = p.base ? 'part of Entware, so it stays' :
                (p.neededBy ? 'needed by ' + p.neededBy : (p.addon ? 'from the ' + p.addon + ' add-on' : ''));
            return { name: p.name, title: p.name, sub: p.version + '  ·  ' + kb(p.sizeKB) + (why ? '  ·  ' + why : ''),
                pill: p.base || p.neededBy ? '' : 'Remove', cls: 'pill-warn', installed: true };
        }
        return { name: p.name, title: p.name + '  ' + p.version, sub: short(p.description, 110),
            pill: i ? 'Installed' : 'Install', cls: i ? 'pill-ok' : 'pill-add', installed: !!i };
    }

    function renderPackages() {
        pkgRows = pkgList.map(pkgRow);
        var head = pkgQuery ?
            (pkgList.length ? esc(pkgList.length + (pkgList.length === 60 ? '+' : '') + ' packages match "' + pkgQuery + '"') :
                'Nothing matches "' + esc(pkgQuery) + '".  Try a shorter word.') +
                '  <span class="dim">Press OK on the search to change it, or clear it to see what\'s installed.</span>' :
            esc(pkgList.length + ' packages installed') + '  <span class="dim">Search for more, or press OK on one to remove it.</span>';
        var html = '<div class="list-head">' + head + '</div><div class="addons" id="addon-list">' +
            '<div class="addon" data-i="0"><input id="pkg-q" class="pkg-q" type="text" maxlength="40" autocomplete="off" spellcheck="false" ' +
            'placeholder="Search Entware\'s packages, like htop or python" value="' + esc(pkgQuery) + '"></div>' +
            pkgRows.map(function (r, i) {
                return '<div class="addon" data-i="' + (i + 1) + '"><div><b>' + esc(r.title) + '</b><small>' + esc(r.sub) + '</small></div>' +
                    (r.pill ? '<span class="pill ' + r.cls + '">' + esc(r.pill) + '</span>' : '') + '</div>';
            }).join('') + '</div>';
        overlay('packages', 'Packages', html, 'OK on the search field types a word.  OK on a package installs or removes it.  BACK to close.');
        var q = $('pkg-q');
        q.addEventListener('keydown', function (e) {
            var k = e.keyCode;
            if (k === KEY.ENTER) { e.preventDefault(); e.stopPropagation(); q.blur(); runSearch(q.value); }
            else if (k === KEY.DOWN || k === KEY.BACK || k === KEY.ESC) { e.preventDefault(); e.stopPropagation(); q.blur(); if (k === KEY.DOWN) { focusAddon(1); } }
            else { e.stopPropagation(); }
        });
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { if (document.activeElement !== q) { focusAddon(parseInt(row.getAttribute('data-i'), 10)); } });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); choosePackage(); });
        });
        focusAddon(Math.min(listIndex, pkgRows.length));
    }

    function runSearch(v) {
        v = String(v || '').replace(/^\s+|\s+$/g, '');
        if (v && !SEARCH_WORD.test(v)) {
            $('overlay-hint').textContent = 'Search for one word: letters, numbers, dots, dashes, underscores or plus signs.';
            return;
        }
        pkgQuery = v;
        listIndex = v ? 1 : 0;
        openPackages();
    }

    function choosePackage() {
        if (listIndex === 0) { $('pkg-q').focus(); return; }
        var r = pkgRows[listIndex - 1];
        if (!r || !PKG_NAME.test(r.name)) { return; }
        var p = pkgInstalled[r.name];
        backTo = 'packages';
        if (!r.installed) {
            var found = pkgList[listIndex - 1] || {};
            confirmThen('Install ' + r.name + '?', (found.description ? found.description + '  ' : '') +
                'Installs version ' + (found.version || '') + ' and anything it needs from Entware, and sets it up for webOS where that\'s needed.  Needs internet.',
                function () { startJob('pkg-add ' + r.name); });
            backTo = 'packages';
            return;
        }
        if (p && p.base) {
            overlay('message', esc(r.name), esc(r.name + ' is part of Entware or its shell setup, so it stays installed.'), 'Press OK or BACK to go back.');
            return;
        }
        if (p && p.neededBy) {
            overlay('message', esc(r.name), esc(r.name + ' is needed by ' + p.neededBy + ', so remove ' + (p.neededBy.indexOf(',') >= 0 ? 'those' : 'that') + ' first.'), 'Press OK or BACK to go back.');
            return;
        }
        confirmThen('Remove ' + r.name + '?', 'Uninstalls ' + r.name + (p ? ' (' + kb(p.sizeKB) + ')' : '') +
            '.  Packages it needed stay, since others may use them.  You can install it again any time.',
            function () { startJob('pkg-remove ' + r.name); });
        backTo = 'packages';
    }

    // ------------------------------------------------------------------ logs

    // The full check, the boot log and the app's recent tasks
    var logRows = [];
    var logData = null;
    function openLogs() {
        if (busy) { return; }
        busy = true;
        overlay('busy', '<span class="spinner"></span>Full check and logs', logHtml(['Reading the logs…']), '');
        runScript('logs --json', function (ok, out) {
            busy = false;
            logData = parseJson(out) || { boot: [], tasks: [] };
            fresh.logs = true;
            renderLogs();
        });
    }
    function renderLogs() {
        var boot = logData.boot || [];
        logRows = [{ kind: 'check', title: 'Full check', sub: 'everything doctor looks at, checked now', pill: 'Run' },
            { kind: 'boot', title: 'Boot log', sub: boot.length ? boot.length + ' lines this boot, last: ' + boot[boot.length - 1] : 'nothing yet this boot', pill: 'View' }];
        (logData.tasks || []).forEach(function (t) {
            logRows.push({ kind: 'task', id: t.id, title: jobTitle(t.name), sub: (t.when || '') + '  ·  ' + (t.exit === 0 ? 'done' : 'something went wrong'),
                pill: 'View', bad: t.exit !== 0 });
        });
        if (logRows.length === 2) { logRows.push({ kind: 'none', title: 'No tasks yet', sub: 'installs, add-ons and updates you run from this app show up here', pill: '' }); }
        if (listIndex >= logRows.length) { listIndex = 0; }
        var html = '<div class="addons" id="addon-list">' + logRows.map(function (r, i) {
            return '<div class="addon" data-i="' + i + '"><div><b>' + esc(r.title) + '</b><small>' + esc(r.sub) + '</small></div>' +
                (r.pill ? '<span class="pill ' + (r.bad ? 'pill-warn' : 'pill-add') + '">' + esc(r.pill) + '</span>' : '') + '</div>';
        }).join('') + '</div>';
        overlay('logs', 'Full check and logs', html, 'OK opens one.  BACK to close.');
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { focusAddon(parseInt(row.getAttribute('data-i'), 10)); });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); chooseLog(); });
        });
        focusAddon(listIndex);
    }

    function chooseLog() {
        var r = logRows[listIndex];
        if (!r || r.kind === 'none') { return; }
        backTo = 'logs';
        if (r.kind === 'check') { runFullCheck(); return; }
        if (r.kind === 'boot') {
            overlay('message', 'Boot log', logHtml((logData.boot && logData.boot.length) ? logData.boot : ['Nothing yet this boot.']), 'Use ▲ ▼ to scroll.  Press OK or BACK to go back.');
            return;
        }
        if (!/^[A-Za-z0-9._+-]+$/.test(r.id) || busy) { return; }
        busy = true;
        runScript('log ' + r.id + ' --json', function (ok, out) {
            busy = false;
            var j = parseJson(out);
            overlay('message', esc(r.title) + '  <span class="dim">' + esc(r.sub) + '</span>',
                logHtml(j && j.log && j.log.length ? j.log : plain(out).trim().split('\n')), 'Use ▲ ▼ to scroll.  Press OK or BACK to go back.');
            $('log').scrollTop = $('log').scrollHeight;
        });
    }

    function runFullCheck() {
        if (busy) { return; }
        busy = true;
        overlay('busy', '<span class="spinner"></span>Full check', logHtml(['Checking…']), '');
        runScript('status', function (ok, out) {
            busy = false;
            overlay('message', 'Full check', logHtml(plain(out).trim().split('\n')), 'Use ▲ ▼ to scroll.  Press OK or BACK to close.');
        });
    }

    // ------------------------------------------------------------------ what's new

    // After the app updates, its changelog shows once.  The notes are built
    // into the app (whatsnew.js) from CHANGELOG.md.
    function store(k, v) {
        try {
            if (v === undefined) { return window.localStorage.getItem(k); }
            window.localStorage.setItem(k, v);
        } catch (e) { /* no storage: just don't remember */ }
        return null;
    }
    function maybeWhatsNew() {
        var n = window.ENTWARE_NOTES;
        if (!n || !n.version) { return; }
        var seen = store('entware.seenVersion');
        store('entware.seenVersion', n.version);
        if (!seen || seen === n.version || !n.notes || !n.notes.length || overlayMode || busy) { return; }
        overlay('message', 'What\'s new in v' + esc(n.version),
            '<ul class="whatsnew">' + n.notes.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('') + '</ul>',
            'Press OK or BACK to close.');
    }

    // Pre-filled GitHub issues, as QR codes to scan with a phone: a compatibility
    // report when it works, a bug report when something went wrong
    var doctorText = '';
    var REPORTS = [
        { kind: 'compat', title: 'It works on my TV', sub: 'a compatibility report, so others know it works on this model', pill: 'QR code' },
        { kind: 'bug', title: 'Something went wrong', sub: 'a bug report with this TV\'s details and the full check', pill: 'QR code' }
    ];
    function openReportMenu() {
        if (listIndex >= REPORTS.length) { listIndex = 0; }
        var html = '<div class="addons" id="addon-list">' + REPORTS.map(function (r, i) {
            return '<div class="addon' + (i === listIndex ? ' focus' : '') + '" data-i="' + i + '">' +
                '<div><b>' + esc(r.title) + '</b><small>' + esc(r.sub) + '</small></div>' +
                '<span class="pill pill-add">' + esc(r.pill) + '</span></div>';
        }).join('') + '</div>';
        overlay('report', 'Report for GitHub', html, 'OK shows a QR code for your phone.  BACK to close.');
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { focusAddon(parseInt(row.getAttribute('data-i'), 10)); });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); chooseReport(); });
        });
        focusAddon(listIndex);
    }
    function chooseReport() {
        var r = REPORTS[listIndex];
        if (!r) { return; }
        backTo = 'report';
        showReport(r.kind, doctorText);
    }
    function q(v) {
        return encodeURIComponent(v).replace(/%20/g, '+').replace(/%3A/g, ':').replace(/%2C/g, ',').replace(/%2F/g, '/');
    }
    function showReport(kind, doctor) {
        var s = state || {};
        // Short enough for a QR code a phone can read off the screen
        var text = doctor.replace(/ {2,}/g, ' ');
        if (text.length > 1100) { text = text.slice(0, 1100) + '\n…'; }
        var arch = { 'aarch64-k3.10': '64-bit (aarch64-k3.10)', 'armv7sf-k3.2': '32-bit (armv7sf-k3.2)' }[s.build] || 'Not sure';
        var where = { 'appstore': 'App storage', 'user': 'User data' }[s.location] || 'Not sure';
        var tv = (s.model || 'LG TV') + ', ' + (s.webos || 'webOS') + (s.webosRelease ? ' (' + s.webosRelease + ')' : '');
        var form;
        if (kind === 'compat') {
            var works = s.installed && s.mounted && s.opkg && !(s.issues && s.issues.length);
            form = REPO_PATH + '/issues/new?template=compatibility-report.yml' +
                '&title=' + q('[Compat] ' + tv) +
                '&tv=' + q(tv) +
                '&version=' + q(s.version || '') +
                '&result=' + q(works ? 'Works, Entware is installed and packages install' :
                    (s.installed ? 'Works, but with problems (describe below)' : 'It didn\'t install')) +
                '&arch=' + q(arch) +
                '&how=' + q('The TV app') +
                '&location=' + q(where) +
                '&doctor=' + q(text);
        } else {
            form = REPO_PATH + '/issues/new?template=bug-report.yml' +
                '&title=' + q('[Bug] ') +
                '&tv=' + q(tv) +
                '&version=' + q(s.version || '') +
                '&arch=' + q(arch) +
                '&steps=' + q('From the Entware TV app') +
                '&doctor=' + q(text);
        }
        // The GitHub phone app grabs github.com/<owner>/<repo> links and drops the
        // filled-in fields; /login is left to the browser, which forwards to the form
        var url = 'https://github.com/login?return_to=' + encodeURIComponent(form);
        var svg = '';
        try {
            var qr = window.qrcode(0, 'L');
            qr.addData(url);
            qr.make();
            svg = qr.createSvgTag({ cellSize: 4, margin: 16, scalable: true });
        } catch (e) {
            svg = '';
        }
        var what = kind === 'compat' ?
            'Scan this with your phone to open a compatibility report on GitHub, with this TV\'s details and the full check already filled in.  Add anything you\'d like and submit.' :
            'Scan this with your phone to open a bug report on GitHub, with this TV\'s details and the full check already filled in.  Add what went wrong and submit.';
        overlay('message', kind === 'compat' ? 'It works on my TV' : 'Something went wrong',
            '<div class="qr">' + svg + '<div>' +
            (svg ? what : 'Open github.com' + esc(REPO_PATH) + '/issues on your phone and paste the full check from SSH (webos-entware doctor).') +
            '<br><br><pre>' + esc(doctor.split('\n').slice(0, 10).join('\n')) + '</pre></div></div>',
            'Press OK or BACK to go back.');
    }

    // ------------------------------------------------------------------ updates

    // Newer release on GitHub?  The installer asks (app-update --check, from
    // the TV, so no browser limits apply); if it can't answer, GitHub's API
    // is asked directly.  The Update button installs it (app-update), and
    // the Homebrew Channel offers it too.
    function versionParts(v) { return String(v || '').replace(/^v/, '').split('.').map(function (n) { return parseInt(n, 10) || 0; }); }
    function newer(a, b) {
        var x = versionParts(a), y = versionParts(b);
        for (var i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) { return (x[i] || 0) > (y[i] || 0); } }
        return false;
    }
    function checkUpdate(current) {
        runScript('app-update --check --json', function (ok, out) {
            var d = parseJson(out);
            if (d && d.latest) {
                latest = d.newer && newer(d.latest, current) ? d.latest : null;
                if (state) { render(); }
            } else if (!window.ENTWARE_DEMO) {
                checkUpdateApi(current);
            }
        });
    }
    function checkUpdateApi(current) {
        var xhr = new XMLHttpRequest();
        xhr.open('GET', RELEASES_API);
        xhr.timeout = 10000;
        xhr.onload = function () {
            try {
                var tag = JSON.parse(xhr.responseText).tag_name;
                if (tag && newer(tag, current)) {
                    latest = tag.replace(/^v/, '');
                    if (state) { render(); }
                }
            } catch (e) { /* no release yet, or offline */ }
        };
        xhr.send();
    }

    // ------------------------------------------------------------------ remote / keyboard

    // Only the buttons on screen, in order (hidden ones are skipped)
    function buttons() {
        return Array.prototype.slice.call(document.querySelectorAll('.btn')).filter(function (b) {
            return b.style.display !== 'none';
        });
    }
    var current = 0;
    function focusCurrent() {
        var list = buttons();
        if (!list.length) { return; }
        if (current >= list.length) { current = list.length - 1; }
        if (current < 0) { current = 0; }
        list[current].focus();
    }

    function exitApp() {
        if (window.PalmSystem && window.PalmSystem.platformBack) { window.PalmSystem.platformBack(); }
        else { window.close(); }
    }

    function act(btn) {
        if (btn && !overlayMode && !busy) { actions[btn.getAttribute('data-action')](); }
    }

    document.addEventListener('keydown', function (e) {
        var k = e.keyCode;
        if (/^(addons|updates|report|packages|logs|addoninfo|web)$/.test(overlayMode || '')) {
            if (k === KEY.UP) { focusAddon(listIndex - 1); }
            else if (k === KEY.DOWN) { focusAddon(listIndex + 1); }
            else if (k === KEY.ENTER) {
                ({ updates: chooseUpdate, report: chooseReport, packages: choosePackage, logs: chooseLog, addoninfo: chooseAddonInfo, web: chooseWeb }[overlayMode] || chooseAddon)();
            }
            else if (k === KEY.BACK || k === KEY.ESC || k === KEY.BACKSPACE) { closeOverlay(); }
            e.preventDefault();
            return;
        }
        if (overlayMode) {
            if (k === KEY.UP) { scrollPanel(-140); }
            else if (k === KEY.DOWN) { scrollPanel(140); }
            else if (overlayMode === 'busy') {
                // A task keeps running in the background; BACK just closes the app
                if (k === KEY.BACK || k === KEY.ESC) { exitApp(); }
            } else if (k === KEY.ENTER && overlayMode === 'confirm' && onConfirm) {
                acceptConfirm();
            } else if (k === KEY.ENTER || k === KEY.BACK || k === KEY.ESC || k === KEY.BACKSPACE) {
                closeOverlay();
            }
            e.preventDefault();
            return;
        }
        var list = buttons();
        if (k === KEY.DOWN) { current = Math.min(current + 1, list.length - 1); focusCurrent(); e.preventDefault(); }
        else if (k === KEY.UP) { current = Math.max(current - 1, 0); focusCurrent(); e.preventDefault(); }
        else if (k === KEY.ENTER) { act(list[current]); e.preventDefault(); }
        else if (k === KEY.BACK || k === KEY.ESC) { exitApp(); e.preventDefault(); }
    });

    // Magic Remote pointer: hovering moves focus, clicking acts
    Array.prototype.slice.call(document.querySelectorAll('.btn')).forEach(function (btn) {
        btn.addEventListener('mouseover', function () { if (!overlayMode) { current = buttons().indexOf(btn); focusCurrent(); } });
        btn.addEventListener('click', function () { current = buttons().indexOf(btn); act(btn); });
    });
    $('overlay').addEventListener('click', function () {
        if (overlayMode === 'confirm' && onConfirm) { acceptConfirm(); }
        else if (overlayMode === 'message') { closeOverlay(); }
    });
    $('overlay').addEventListener('wheel', function (e) { scrollPanel(e.deltaY > 0 ? 140 : -140); });

    // Refresh when the app comes back to the foreground, unless a task is showing
    function refreshIfIdle() { if (!document.hidden && !busy && !overlayMode) { refresh(); } }
    document.addEventListener('webOSRelaunch', refreshIfIdle);
    document.addEventListener('visibilitychange', refreshIfIdle);
    setInterval(refreshIfIdle, 30000);
    // Left open for a long time: look for a new release every 6 hours
    setInterval(function () { if (state) { checkUpdate(state.version); } }, 6 * 3600 * 1000);

    focusCurrent();
    refresh(function (s) { if (s) { checkUpdate(s.version); autoCheckUpdates(s); maybeWhatsNew(); } });
}());
