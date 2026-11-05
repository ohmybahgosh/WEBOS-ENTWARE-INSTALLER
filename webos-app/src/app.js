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
    var KEY = { UP: 38, DOWN: 40, LEFT: 37, RIGHT: 39, ENTER: 13, BACK: 461, ESC: 27, BACKSPACE: 8, CH_UP: 33, CH_DOWN: 34 };

    // The script ships inside the app: <app dir>/assets/webos-entware-installer.sh
    var appDir = decodeURIComponent(window.location.pathname).replace(/\/[^\/]*$/, '');
    var SCRIPT = appDir + '/assets/webos-entware-installer.sh';

    var state = null;        // last status --json
    var latest = null;       // newest release on GitHub, if newer than this app
    var overlayMode = null;  // null, 'busy', 'loading', 'message', 'confirm', or a list: 'addons', 'report', 'logs', 'addoninfo'
    var onConfirm = null;
    var jobTimer = null;
    var busy = false;        // a status call or task is in flight
    var addons = [];         // last addons --json
    var listIndex = 0;       // focused row on the Add-ons, Package updates or Report screen
    var backTo = '';         // the screen to reopen after a task's result: 'store', 'addons', 'logs', ...
    var upd = null;          // last updates --json
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
            if (b === 'store') { if (store.open) { storeReturn(); } else { focusCurrent(); } }
            else if (b === 'report') { openReportMenu(); }
            else if (b === 'logs') { if (fresh.logs && logData) { renderLogs(); } else { openLogs(); } }
            else if (b === 'addoninfo' && addonInfo && addonInfo.addon) { openAddonInfo(addonInfo.addon); }
            else {
                // Back on the add-on that was open
                if (addonInfo) { listIndex = addonInfo.index; addonInfo = null; }
                if (fresh.addons && addons.length) { renderAddons(); } else { openAddons(); }
            }
            return;
        }
        if (store.open) { storeFocus(); return; }
        focusCurrent();
    }
    function confirmThen(title, text, fn) {
        backTo = store.open ? 'store' : (/^(addons|logs|addoninfo)$/.test(overlayMode || '') ? overlayMode : ''); // BACK returns to the list
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
    function stale() { fresh.addons = fresh.packages = fresh.logs = false; pkgInfo = {}; upd = null; }

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
                backTo = store.open ? 'store' : (/^(add|remove) /.test(jn) ? 'addons' : (/^password /.test(jn) && addonInfo ? 'addoninfo' : ''));
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
        // A group's heading comes into view with its first row
        var prev = row.previousElementSibling, top = prev && prev.className === 'pkg-group' ? prev.offsetTop : row.offsetTop;
        if (top < box.scrollTop) { box.scrollTop = top; }
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
        upgrade: function () { openStore('updates'); },
        addons: function () { listIndex = 0; openAddons(); },
        packages: function () { openStore('browse'); },
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

    // A full screen with three tabs: Browse (every package a person would
    // pick, in categories, with a page for each), Installed (grouped by why
    // it's here) and Updates.  Package names are checked here and again by
    // the installer; searching happens here, so nothing typed reaches a shell.
    var PKG_NAME = /^[A-Za-z0-9][A-Za-z0-9._+-]*$/;
    var CAT = window.ENTWARE_CATALOG || { cats: [], featured: [], blurbs: {}, tips: {} };
    var catalog = null;      // catalog --json: what Browse lists
    var catalogAll = null;   // catalog --json --all: libraries and modules too
    var installedList = null;
    var installedMap = {};
    var pkgInfo = {};        // pkginfo --json, by name, until a task runs
    var catNames = {}, catRules = [], catById = {};
    CAT.cats.forEach(function (c) {
        catById[c.id] = c;
        (c.names || '').split(' ').forEach(function (n) { if (n && !catNames[n]) { catNames[n] = c.id; } });
        if (c.match) { catRules.push([new RegExp(c.match), c.id]); }
    });
    // Drawn icons for the categories: the TV's fonts don't have every symbol
    var ICONS = {
        start: 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z',
        shell: 'M4 5h16v14H4z M7.5 9.5l3 2.5-3 2.5 M12.5 15h4',
        editors: 'M4 20h4L19 9l-4-4L4 16z M13 7l4 4',
        files: 'M3 6.5h6l2 2h10V19H3z',
        downloads: 'M12 3v12 M7 10l5 5 5-5 M4 20h16',
        media: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M10 8.5l5.5 3.5-5.5 3.5z',
        network: 'M4 8h15 M15 4l4 4-4 4 M20 16H5 M9 12l-4 4 4 4',
        vpn: 'M5 11h14v9H5z M8 11V8a4 4 0 0 1 8 0v3 M12 14.5v2',
        servers: 'M4 4h16v7H4z M4 13h16v7H4z M8 7.5h.01 M8 16.5h.01',
        dev: 'M9 4C7 4 6 5 6 7v2.5c0 1-1 2.5-2 2.5 1 0 2 1.5 2 2.5V17c0 2 1 3 3 3 M15 4c2 0 3 1 3 3v2.5c0 1 1 2.5 2 2.5-1 0-2 1.5-2 2.5V17c0 2-1 3-3 3',
        system: 'M3 12h4l3-7 4 14 3-7h4',
        games: 'M7 8h10a4 4 0 0 1 0 8H7a4 4 0 0 1 0-8z M8.5 10.5v3 M7 12h3 M15 11h.01 M17 13h.01',
        other: 'M5 12h.01 M12 12h.01 M19 12h.01',
        libs: 'M12 3l9 5-9 5-9-5z M3 12.5l9 5 9-5 M3 17l9 5 9-5',
        'libs-toggle': 'M4 7h9 M17 7h3 M15 5v4 M4 17h3 M11 17h9 M9 15v4'
    };
    function icon(id) {
        return '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="' + (ICONS[id] || ICONS.other) + '"/></svg>';
    }
    var featuredRank = {};
    CAT.featured.forEach(function (n, i) { featuredRank[n] = i; });

    var store = {
        open: false, tab: 'browse', zone: 'rail', idx: 0, cat: 'start', sort: 'useful', hideInst: false,
        libs: false, query: '', qcat: 'all', group: 'all', page: null, from: null, rows: [], chips: [], rail: [], btns: [], grid: []
    };

    function listJson(out) {
        var i = (out || '').indexOf('[');
        try { return i >= 0 ? JSON.parse(out.slice(i)) : null; } catch (e) { return null; }
    }
    // A long description, cut at a word
    function short(t, n) {
        t = String(t || '');
        if (t.length <= n) { return t; }
        t = t.slice(0, n);
        return t.slice(0, Math.max(t.lastIndexOf(' '), n - 20)).replace(/[\s,.;:(]+$/, '') + '…';
    }
    function kb(n) { return n >= 1048576 ? (Math.round(n / 104857.6) / 10) + ' GB' : (n >= 1024 ? (Math.round(n / 102.4) / 10) + ' MB' : (n || 0) + ' KB'); }
    function names(list, n) { return list.length > n ? list.slice(0, n).join(', ') + ' and ' + (list.length - n) + ' more' : list.join(', '); }

    function catOf(p) {
        if (p.lib) { return 'libs'; }
        if (catNames[p.n]) { return catNames[p.n]; }
        for (var i = 0; i < catRules.length; i++) { if (catRules[i][0].test(p.n)) { return catRules[i][1]; } }
        for (var j = 0; j < CAT.cats.length; j++) {
            var c = CAT.cats[j];
            if (c.sections && (' ' + c.sections + ' ').indexOf(' ' + p.s + ' ') >= 0) { return c.id; }
        }
        return 'other';
    }
    // Builds of one program, like nano, nano-full and nano-plus, or wget-ssl
    // and wget-nossl: with one installed, the others count as installed too
    var VARIANT = /-(full|fuller|plus|tiny|mini|ssl|nossl|openssl|gnutls|mbedtls|wolfssl|nts)$/;
    var FAMILY = { luajit2: 'luajit' };
    var installedFamily = {};
    function family(n) { return FAMILY[n] || n.replace(VARIANT, ''); }
    // The other build of n that's installed, if n itself isn't
    function haveVariant(n) {
        if (installedMap[n]) { return null; }
        var v = installedFamily[family(n)];
        return v && v !== n ? v : null;
    }
    // Installed, another build of it is, or the Homebrew Channel ships it
    // (webOS's own commands are often cut down, so those don't count)
    function isInstalled(p) { return !!(installedMap[p.n] || haveVariant(p.n) || p.w === 2); }
    function blurb(p) { return CAT.blurbs[p.n] || p.d || ''; }
    function rank(p) { return p.n in featuredRank ? featuredRank[p.n] : (CAT.blurbs[p.n] ? 100 : 1000); }
    function byName(x, y) { return x.n < y.n ? -1 : (x.n > y.n ? 1 : 0); }
    function shelf() { return store.libs && catalogAll ? catalogAll : (catalog || []); }
    function updFor(n) {
        if (!upd || !upd.packages) { return null; }
        for (var i = 0; i < upd.packages.length; i++) { if (upd.packages[i].name === n) { return upd.packages[i]; } }
        return null;
    }
    // Marks what's installed, and files each package in a category
    function indexCatalog(list, all) {
        var seen = {};
        (catalog || []).forEach(function (p) { seen[p.n] = 1; });
        list.forEach(function (p) {
            if (all && !seen[p.n]) { p.lib = 1; }
            p.c = catOf(p);
        });
    }

    // What a row says about a package: installed, an update, an add-on for
    // it, or that webOS has a command by that name
    function pkgPill(p) {
        if (installedMap[p.n]) { return updFor(p.n) ? ['Update', 'pill-warn'] : ['Installed', 'pill-ok']; }
        if (haveVariant(p.n)) { return ['Have ' + haveVariant(p.n), 'pill-ok']; }
        if (p.w === 2) { return ['Homebrew has it', 'pill-ok']; }
        if (p.a) { return ['Add-on sets it up', 'pill-addon']; }
        if (p.w) { return ['webOS has one', 'pill-dim']; }
        return null;
    }
    function rowHtml(r, i, z) {
        return '<div class="srow" data-z="' + (z || 'list') + '" data-i="' + i + '"><div class="st"><b>' + esc(r.title) + '</b>' +
            (r.ver ? '<span class="sv">' + esc(r.ver) + '</span>' : '') + (r.sub ? '<p>' + (r.subHtml || esc(r.sub)) + '</p>' : '') + '</div>' +
            (r.size ? '<span class="ssz">' + esc(r.size) + '</span>' : '') +
            (r.pill ? '<span class="pill ' + r.pill[1] + '">' + esc(r.pill[0]) + '</span>' : '') + '</div>';
    }
    function pkgRowFor(p, sub) {
        return { kind: 'pkg', name: p.n, title: p.n, ver: p.v, sub: sub || short(blurb(p), 130), size: kb(p.z), pill: pkgPill(p) };
    }
    function chipHtml(c, i) {
        return '<span class="chip' + (c.on ? ' on' : '') + '" data-z="chips" data-i="' + i + '">' + esc(c.title) + '</span>';
    }

    // ---- opening, and reading what each tab needs from the TV

    function openStore(tab) {
        if (busy) { return; }
        store.open = true;
        store.tab = tab || 'browse';
        store.page = null;
        store.zone = store.tab === 'browse' ? (store.query ? 'list' : 'rail') : (store.tab === 'updates' ? 'list' : 'chips');
        store.idx = 0;
        $('store').className = 'store';
        storeLoad(false, storeRender);
    }
    function closeStore() {
        store.open = false;
        store.page = null;
        $('store').className = 'store hidden';
        $('store').innerHTML = '';
        focusCurrent();
    }
    function hideOverlay() { overlayMode = null; onConfirm = null; $('overlay').className = 'overlay hidden'; }
    function loadFailed(what, out) {
        busy = false;
        store.open = false;
        $('store').className = 'store hidden';
        overlay('message', '<span class="result-bad">' + esc(what) + '</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to close.');
    }
    // Reads what the open tab needs and hasn't got, then calls done
    function storeLoad(refreshUpdates, done) {
        var steps = [];
        if (!fresh.packages || !installedList) {
            steps.push(['installed --json', 'Reading what\'s installed…', function (out) {
                var l = listJson(out);
                if (!l) { return 'Couldn\'t list the packages'; }
                installedList = l;
                installedMap = {};
                installedFamily = {};
                l.forEach(function (p) { installedMap[p.name] = p; });
                l.forEach(function (p) { var f = family(p.name); if (!installedFamily[f] || p.name === f) { installedFamily[f] = p.name; } });
                fresh.packages = true;
            }]);
        }
        if (store.tab === 'browse' && !catalog) {
            steps.push(['catalog --json', 'Reading Entware\'s package list…', function (out) {
                var l = listJson(out);
                if (!l) { return 'Couldn\'t read Entware\'s package list'; }
                catalog = l;
                catalogAll = null;
                indexCatalog(catalog, false);
            }]);
        }
        if (store.tab === 'browse' && store.libs && !catalogAll) {
            steps.push(['catalog --json --all', 'Reading every package, libraries too…', function (out) {
                var l = listJson(out);
                if (!l) { return 'Couldn\'t read Entware\'s package list'; }
                catalogAll = l;
                indexCatalog(catalogAll, true);
            }]);
        }
        if (store.tab === 'updates' && (!upd || refreshUpdates)) {
            var refresh = refreshUpdates || !!(state && (state.updatesAgeHours === null || state.updatesAgeHours >= 24));
            steps.push(['updates --json' + (refresh ? ' --refresh' : ''), refresh ? 'Checking Entware\'s server for updates…' : 'Reading the package list…', function (out) {
                var d = parseJson(out);
                if (!d || !d.packages) { return 'Couldn\'t check for updates'; }
                upd = d;
                if (state) { state.updates = d.packages.length; state.updatesChecked = d.checked; state.updatesAgeHours = d.ageHours; }
            }]);
        }
        if (!steps.length) { done(); return; }
        busy = true;
        (function next() {
            var s = steps.shift();
            if (!s) { busy = false; hideOverlay(); if (store.open) { done(); } return; }
            overlay('loading', '<span class="spinner"></span>Packages', logHtml([s[1]]), 'BACK to close.');
            runScript(s[0], function (ok, out) {
                if (!store.open) { busy = false; return; }
                var err = s[2](out);
                if (err) { loadFailed(err, out); return; }
                next();
            });
        }());
    }

    // ---- drawing

    function storeRender() {
        if (!store.open) { return; }
        var n = { browse: (catalog ? catalog.length : 0), installed: installedList ? installedList.length : 0,
            updates: upd ? upd.packages.length : (state && state.updates) || 0 };
        var tabs = [['browse', 'Browse'], ['installed', 'Installed'], ['updates', 'Updates']];
        var html = '<div class="s-top"><h1>Packages</h1><div class="s-tabs">' + tabs.map(function (t, i) {
            return '<span class="tab' + (store.tab === t[0] ? ' on' : '') + '" data-z="tabs" data-i="' + i + '">' + esc(t[1]) +
                '<span class="n' + (t[0] === 'updates' && n.updates ? ' hot' : '') + '">' + (t[0] === 'browse' && !catalog ? '' : n[t[0]].toLocaleString('en-US')) + '</span></span>';
        }).join('') + '</div><div class="s-search" data-z="tabs" data-i="3"><input id="store-q" type="text" maxlength="40" autocomplete="off" spellcheck="false" placeholder="Search ' +
            (catalog ? catalog.length.toLocaleString('en-US') + ' ' : '') + 'apps and tools…" value="' + esc(store.query) + '"></div></div>';
        store.rows = []; store.chips = []; store.rail = []; store.grid = []; store.btns = [];
        if (store.page) { html += pageHtml(); }
        else if (store.tab === 'browse') { html += store.query ? searchHtml() : browseHtml(); }
        else if (store.tab === 'installed') { html += installedHtml(); }
        else { html += updatesHtml(); }
        html += '<div class="s-foot" id="store-hint"></div>';
        $('store').innerHTML = html;
        storeWire();
        storeFocus();
    }

    function browseHtml() {
        var list = shelf(), counts = {};
        list.forEach(function (p) { counts[p.c] = (counts[p.c] || 0) + 1; });
        var featured = CAT.featured.map(function (n) { return findPkg(n); }).filter(function (p) { return p; });
        store.rail = [{ id: 'start', title: 'Start here', count: featured.length }];
        CAT.cats.forEach(function (c) { if (counts[c.id]) { store.rail.push({ id: c.id, title: c.title, count: counts[c.id] }); } });
        store.rail.push({ id: 'libs-toggle', title: 'Show libraries too', count: store.libs ? 'On' : 'Off' });
        var rail = '<div class="s-rail">' + store.rail.map(function (r, i) {
            return (i === 1 || r.id === 'libs-toggle' ? '<hr>' : '') + '<div class="rc' + (r.id === store.cat ? ' on' : '') + '" data-z="rail" data-i="' + i + '"><span><i>' +
                icon(r.id) + '</i>' + esc(r.title) + '</span><span class="cnt">' + esc(String(r.count)) + '</span></div>';
        }).join('') + '</div>';
        var main;
        if (store.cat === 'start') {
            store.grid = featured;
            main = '<h2>Start here</h2><p class="lead">Handy tools that work well on a TV.  Press OK on one to read about it and install it.</p>' +
                '<div class="s-scroll" id="store-scroll"><div class="s-grid">' + featured.map(function (p, i) {
                    var pill = pkgPill(p);
                    return '<div class="tile" data-z="grid" data-i="' + i + '"><b>' + esc(p.n) + '</b><span class="k">' + esc((catById[p.c] || {}).title || '') + '</span>' +
                        (pill ? '<span class="pill ' + pill[1] + '">' + esc(pill[0]) + '</span>' : '') + '<p>' + esc(short(blurb(p), 110)) + '</p></div>';
                }).join('') + '</div></div>';
        } else {
            var c = catById[store.cat] || catById.other;
            var rows = list.filter(function (p) { return p.c === c.id && !(store.hideInst && isInstalled(p)); });
            rows.sort(store.sort === 'az' ? byName : (store.sort === 'small' ? function (x, y) { return (x.z - y.z) || byName(x, y); } :
                function (x, y) { return (rank(x) - rank(y)) || byName(x, y); }));
            store.chips = [{ id: 'useful', title: 'Most useful', on: store.sort === 'useful' }, { id: 'az', title: 'A to Z', on: store.sort === 'az' },
                { id: 'small', title: 'Smallest', on: store.sort === 'small' }, { id: 'hide', title: 'Hide installed', on: store.hideInst }];
            store.rows = rows.map(function (p) { return pkgRowFor(p); });
            main = '<h2>' + esc(c.title) + '</h2><p class="lead">' + esc(c.lead) + '</p>' +
                '<div class="s-chips">' + store.chips.map(chipHtml).join('') + '<span class="sp">' + rows.length + ' packages</span></div>' +
                '<div class="s-scroll" id="store-scroll">' + (store.rows.length ? store.rows.map(function (r, i) { return rowHtml(r, i); }).join('') :
                    '<p class="lead">Everything here is installed.</p>') + '</div>';
        }
        return '<div class="s-body">' + rail + '<div class="s-main">' + main + '</div></div>';
    }
    function findPkg(n) {
        var l = shelf();
        for (var i = 0; i < l.length; i++) { if (l[i].n === n) { return l[i]; } }
        return null;
    }

    function searchHtml() {
        var q = store.query.toLowerCase(), byCat = {}, hits = [];
        shelf().forEach(function (p) {
            var n = p.n.toLowerCase(), at = n.indexOf(q), s;
            if (at >= 0) { s = n === q ? 0 : (at === 0 ? 1 : 2); }
            else if ((blurb(p) + ' ' + p.d).toLowerCase().indexOf(q) >= 0) { s = 3; }
            else { return; }
            hits.push({ p: p, s: s });
            byCat[p.c] = (byCat[p.c] || 0) + 1;
        });
        if (store.qcat !== 'all' && !byCat[store.qcat]) { store.qcat = 'all'; }
        store.chips = [{ id: 'all', title: 'All ' + hits.length, on: store.qcat === 'all' }];
        CAT.cats.forEach(function (c) { if (byCat[c.id]) { store.chips.push({ id: c.id, title: c.title + ' ' + byCat[c.id], on: store.qcat === c.id }); } });
        hits = hits.filter(function (h) { return store.qcat === 'all' || h.p.c === store.qcat; });
        hits.sort(function (x, y) {
            var a = x.s === 3 ? 1 : 0, b = y.s === 3 ? 1 : 0;
            return (a - b) || (a ? rank(x.p) - rank(y.p) : (x.s - y.s) || (x.p.n.length - y.p.n.length)) || byName(x.p, y.p);
        });
        var named = hits.filter(function (h) { return h.s < 3; }), described = hits.filter(function (h) { return h.s === 3; });
        var html = '<div class="s-chips">' + store.chips.map(chipHtml).join('') + '<span class="sp">' + (store.libs ? 'Libraries included' : 'Libraries hidden') + '</span></div>' +
            '<div class="s-scroll s-wide" id="store-scroll">';
        function mark(t) {
            var i = t.toLowerCase().indexOf(q);
            return i < 0 ? esc(t) : esc(t.slice(0, i)) + '<span class="mark">' + esc(t.slice(i, i + q.length)) + '</span>' + esc(t.slice(i + q.length));
        }
        function group(title, list) {
            if (!list.length) { return; }
            html += '<div class="ghead">' + esc(title) + '<span>' + list.length + (list.length > 150 ? ', showing 150' : '') + '</span></div>';
            list.slice(0, 150).forEach(function (h) {
                var r = pkgRowFor(h.p), b = blurb(h.p), i = b.toLowerCase().indexOf(q);
                if (i < 0) { b = h.p.d; i = b.toLowerCase().indexOf(q); }
                // Keep the word that matched in view
                if (i > 90) { b = '…' + b.slice(Math.max(0, i - 40)); }
                r.sub = short(b, 130);
                r.subHtml = mark(r.sub);
                html += rowHtml(r, store.rows.length);
                store.rows.push(r);
            });
        }
        group('Name matches', named);
        group('Mentioned in the description', described);
        if (!hits.length) { html += '<p class="lead">Nothing matches "' + esc(store.query) + '".</p>'; }
        if (!store.libs) {
            var r = { kind: 'libs', title: 'Search every package, libraries too', sub: 'Libraries, plugins and modules are hidden unless you ask for them' };
            html += rowHtml(r, store.rows.length);
            store.rows.push(r);
        }
        return html + '</div>';
    }

    // What's installed, in groups: on their own, from add-ons, no longer
    // needed, part of Entware, and the libraries others need
    var PKG_GROUPS = [
        { id: 'own', title: 'Installed on their own', short: 'On their own', note: 'press OK on one to remove it' },
        { id: 'addon', title: 'From add-ons', short: 'From add-ons', note: 'remove these with their add-on' },
        { id: 'orphan', title: 'No longer needed', short: 'No longer needed', note: 'nothing uses these now, so they can go' },
        { id: 'base', title: 'Part of Entware', short: 'Entware', note: 'Entware and its shell setup need these' },
        { id: 'lib', title: 'Libraries and helpers', short: 'Libraries', note: 'other packages need these' }
    ];
    function pkgGroup(p) {
        if (p.base) { return 'base'; }
        if (p.addon) { return 'addon'; }
        if (!p.auto) { return 'own'; }
        return p.neededBy ? 'lib' : 'orphan';
    }
    var MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    function when(t) {
        if (!t) { return ''; }
        var d = new Date(t * 1000);
        return MONTHS[d.getMonth()] + ' ' + d.getDate() + (d.getFullYear() !== new Date().getFullYear() ? ', ' + d.getFullYear() : '');
    }
    function installedHtml() {
        var order = {}, counts = {}, sizes = {}, total = 0;
        PKG_GROUPS.forEach(function (g, i) { order[g.id] = i; counts[g.id] = 0; sizes[g.id] = 0; });
        var list = installedList.slice().sort(function (x, y) {
            return (order[pkgGroup(x)] - order[pkgGroup(y)]) || (x.name < y.name ? -1 : (x.name > y.name ? 1 : 0));
        });
        list.forEach(function (p) { var g = pkgGroup(p); counts[g]++; sizes[g] += p.sizeKB || 0; total += p.sizeKB || 0; });
        if (store.group !== 'all' && !counts[store.group]) { store.group = 'all'; }
        store.chips = [{ id: 'all', title: 'All ' + list.length + '  ·  ' + kb(total), on: store.group === 'all' }];
        PKG_GROUPS.forEach(function (g) { if (counts[g.id]) { store.chips.push({ id: g.id, title: g.short + ' ' + counts[g.id], on: store.group === g.id }); } });
        var html = '<div class="s-chips">' + store.chips.map(chipHtml).join('') + '</div><div class="s-scroll s-wide" id="store-scroll">', last = '';
        list.forEach(function (p) {
            var g = pkgGroup(p);
            if (store.group !== 'all' && g !== store.group) { return; }
            if (g !== last) {
                last = g;
                var grp = PKG_GROUPS[order[g]];
                html += '<div class="ghead">' + esc(grp.title) + '<span>' + counts[g] + '  ·  ' + esc(kb(sizes[g])) + '  ·  ' + esc(grp.note) + '</span></div>';
            }
            var meta = [];
            if ((g === 'own' || g === 'orphan') && p.installed) { meta.push('Added ' + when(p.installed) + '.'); }
            if (g === 'lib') { meta.push('Needed by ' + short(p.neededBy, 60) + '.'); }
            if (g === 'orphan') { meta.push('Nothing needs it now.'); }
            var u = updFor(p.name);
            var r = { kind: 'inst', name: p.name, group: g, title: p.name, ver: p.version + (p.section ? '  ·  ' + p.section : ''),
                sub: short((CAT.blurbs[p.name] || p.description || '').replace(/([^.!?])$/, '$1.') + (meta.length ? '  ' + meta.join('  ') : ''), 140),
                size: kb(p.sizeKB),
                pill: u ? ['Update', 'pill-warn'] : { own: ['Remove', 'pill-warn'], orphan: ['Remove', 'pill-warn'], addon: [(p.addonTitle || p.addon) + ' add-on', 'pill-addon'],
                    base: ['Entware', 'pill-dim'], lib: ['Needed', 'pill-dim'] }[g] };
            html += rowHtml(r, store.rows.length);
            store.rows.push(r);
        });
        return html + '</div>';
    }

    function updatesHtml() {
        var p = upd ? upd.packages : [];
        if (p.length > 1) {
            store.rows.push({ kind: 'all', title: 'Update all ' + p.length + ' packages', sub: 'Refreshes the package list, then updates every package.', pill: ['Update all', 'pill-add'] });
        }
        p.forEach(function (x) {
            store.rows.push({ kind: 'upd', name: x.name, installed: x.installed, available: x.available, title: x.name, sub: x.installed + '  →  ' + x.available, pill: ['Update', 'pill-add'] });
        });
        store.rows.push({ kind: 'check', title: 'Check again', sub: 'Downloads the package list from Entware\'s server.' });
        var head = '<p class="lead">' + (p.length ? esc(p.length + (p.length === 1 ? ' package has an update.' : ' packages have updates.')) :
            '<span class="ok">Every package is up to date.</span>') + '  Package list from ' + esc((upd && upd.checked) || 'unknown') +
            (upd && upd.refreshFailed ? ' (Entware\'s server couldn\'t be reached)' : '') + '.</p>';
        return head + '<div class="s-scroll s-wide" id="store-scroll">' + store.rows.map(function (r, i) { return rowHtml(r, i); }).join('') + '</div>';
    }

    // ---- a package's page

    // Entware's descriptions are wrapped by hand, with lists as short lines:
    // join the wrapped lines into paragraphs, and keep the lists as lists
    function descHtml(t) {
        var out = '', para = [], items = [], listy = false;
        function endPara() { if (para.length) { out += '<p>' + esc(para.join(' ')) + '</p>'; para = []; } }
        function endList() {
            if (items.length) { out += '<ul' + (items.length > 4 ? ' class="two"' : '') + '>' + items.map(function (x) { return '<li>' + esc(x) + '</li>'; }).join('') + '</ul>'; }
            items = []; listy = false;
        }
        String(t || '').split('\n').forEach(function (l) {
            l = l.replace(/^\s+|\s+$/g, '');
            if (!l) { endPara(); endList(); return; }
            var bullet = /^[-*•]\s+/.test(l);
            if (bullet || (listy && l.length <= 60 && !/[.;]$/.test(l))) { endPara(); listy = true; items.push(l.replace(/^[-*•]\s+/, '')); return; }
            endList();
            para.push(l);
            if (/:$/.test(l)) { endPara(); listy = true; }
        });
        endPara(); endList();
        return out;
    }
    function storeOpenPage(name) {
        if (busy || !PKG_NAME.test(name)) { return; }
        store.from = { tab: store.tab, zone: store.zone, idx: store.idx, scroll: ($('store-scroll') || {}).scrollTop || 0 };
        if (pkgInfo[name]) { store.page = pkgInfo[name]; store.zone = 'btns'; store.idx = 0; storeRender(); return; }
        busy = true;
        overlay('loading', '<span class="spinner"></span>' + esc(name), logHtml(['Reading about ' + name + '…']), 'BACK to close.');
        runScript('pkginfo ' + name + ' --json', function (ok, out) {
            busy = false;
            if (!store.open) { return; }
            var d = parseJson(out);
            if (!d || !d.name) {
                hideOverlay();
                backTo = 'store';
                overlay('message', '<span class="result-bad">Couldn\'t read about ' + esc(name) + '</span>', logHtml(plain(out).trim().split('\n')), 'Press OK or BACK to go back.');
                return;
            }
            hideOverlay();
            pkgInfo[name] = d;
            store.page = d;
            store.zone = 'btns';
            store.idx = 0;
            storeRender();
        });
    }
    function closePage() {
        var f = store.from || {};
        store.page = null;
        store.tab = f.tab || store.tab;
        store.zone = f.zone || 'list';
        store.idx = f.idx || 0;
        storeRender();
        if ($('store-scroll')) { $('store-scroll').scrollTop = f.scroll || 0; storeFocus(); }
    }
    function pageHtml() {
        var d = store.page, inst = installedMap[d.name], c = catalogEntry(d.name), cat = catById[c ? c.c : catOf({ n: d.name, s: d.section })] || catById.other;
        var u = updFor(d.name), tips = (CAT.tips[d.name] || []).slice(), facts = [];
        var addonOff = d.addon && d.addonState !== 'installed';
        if (!d.installed) {
            var dl = d.sizeKB + d.needsKB, use = d.isizeKB + d.needsIKB;
            facts.push(['Download', kb(dl) + (d.needs.length ? '  (with ' + d.needs.length + (d.needs.length === 1 ? ' more package)' : ' more packages)') : '')]);
            facts.push(['Uses once installed', kb(use)]);
            facts.push(['Free on your TV', '<span class="' + (d.freeKB > use * 3 ? 'ok' : (d.freeKB > use ? 'warn' : 'bad')) + '">' + esc(kb(d.freeKB)) + '</span>']);
            if (d.needs.length) { facts.push(['Also installs', esc(names(d.needs.map(function (x) { return x.name; }), 4))]); }
            // What it needs that's here already, apart from what every package needs
            var have = d.have.filter(function (x) { return !(installedMap[x] && installedMap[x].base); });
            if (have.length) { facts.push(['Already have', esc(names(have, 4))]); }
            if (d.freeKB && d.freeKB < use) { tips.unshift('There isn\'t enough free space for it.  Free some up, or move Entware to app storage.'); }
            else if (use > 51200) { tips.push('It\'s big: about ' + kb(use) + ' once installed, with what it needs.'); }
            if (haveVariant(d.name)) { tips.unshift('You already have ' + haveVariant(d.name) + ', another build of the same program, so you don\'t need this one too.'); }
            if (d.system && !CAT.tips[d.name]) {
                tips.push((d.system.indexOf('/org.webosbrew.hbchannel.service/') >= 0 ? 'The Homebrew Channel already has its own ' + d.system.replace(/.*\//, '') :
                    'webOS already has its own ' + d.system) + '.  Once this is installed, SSH logins use Entware\'s, which comes first on the PATH.');
            }
            if (addonOff) { tips.unshift('The ' + d.addonTitle + ' add-on installs this and sets it up for the TV.'); }
        } else {
            facts.push(['Installed', esc(d.installedVersion) + (u ? '  <span class="warn">(' + esc(u.available) + ' available)</span>' : '')]);
            facts.push(['Uses', kb(inst ? inst.sizeKB : d.isizeKB)]);
            if (d.commands.length) { facts.push(['Commands', esc(names(d.commands, 6))]); }
            if (d.neededBy) { facts.push(['Needed by', esc(short(d.neededBy, 80))]); }
            facts.push(['Free on your TV', esc(kb(d.freeKB))]);
        }
        // What OK can do here
        if (!d.installed) {
            if (addonOff) {
                store.btns.push({ act: 'addon', title: 'Add the ' + d.addonTitle + ' add-on', sub: 'Installs it and sets it up for the TV.  Recommended.', pri: true });
                store.btns.push({ act: 'install', title: 'Install just the package', sub: 'The plain Entware package.  You set it up yourself.' });
            } else {
                store.btns.push({ act: 'install', title: 'Install ' + d.name, sub: 'Downloads ' + kb(d.sizeKB + d.needsKB) + ' and installs it' + (d.needs.length ? ' with what it needs.' : '.'), pri: true });
            }
        } else {
            if (u) { store.btns.push({ act: 'update', title: 'Update to ' + u.available, sub: 'From ' + u.installed + '.  Its settings are kept.', pri: true }); }
            if (d.base) { store.btns.push({ act: 'none', title: 'Part of Entware', sub: 'Entware or its shell setup needs it, so it stays.', off: true }); }
            else if (inst && inst.addon) {
                store.btns.push({ act: 'removeAddon', title: 'Remove the ' + (inst.addonTitle || inst.addon) + ' add-on', sub: d.name + ' came with it, so it goes with the add-on and its setup.' });
            } else if (d.neededBy) {
                store.btns.push({ act: 'none', title: 'Needed by ' + short(d.neededBy, 40), sub: 'Remove ' + (d.neededBy.indexOf(',') >= 0 ? 'those' : 'that') + ' first to remove this.', off: true });
            } else {
                store.btns.push({ act: 'remove', title: 'Remove ' + d.name, sub: 'Packages it needed stay, since others may use them.' });
            }
        }
        if (cat.id !== 'libs') { store.btns.push({ act: 'more', cat: cat.id, title: 'More in ' + cat.title, sub: cat.lead }); }
        var lead = CAT.blurbs[d.name];
        return '<div class="s-page"><div class="pl"><h2>' + esc(d.name) + '</h2><div class="psub">' + esc(cat.title) + '  ·  version ' + esc(d.version) +
            (d.installed ? '  ·  installed' : '  ·  from Entware') + '</div>' +
            '<div class="pdesc" id="page-desc">' + (lead ? '<p class="plead">' + esc(lead) + '</p>' : '') + descHtml(d.description) + '</div>' +
            (tips.length ? '<div class="pbox"><h4>Good to know on your TV</h4><ul>' + tips.map(function (t) { return '<li>' + esc(t) + '</li>'; }).join('') + '</ul></div>' : '') +
            '</div><div class="pr"><table class="facts">' + facts.map(function (f) { return '<tr><td>' + esc(f[0]) + '</td><td>' + f[1] + '</td></tr>'; }).join('') +
            '</table>' + store.btns.map(function (b, i) {
                return '<div class="sbtn' + (b.pri ? ' pri' : '') + (b.off ? ' off' : '') + '" data-z="btns" data-i="' + i + '"><b>' + esc(b.title) + '</b><small>' + esc(b.sub) + '</small></div>';
            }).join('') + '</div></div>';
    }
    function catalogEntry(n) {
        var l = catalogAll || catalog || [];
        for (var i = 0; i < l.length; i++) { if (l[i].n === n) { return l[i]; } }
        return null;
    }

    // ---- focus, keys and the pointer

    function zoneEls(z) { return Array.prototype.slice.call(document.querySelectorAll('#store [data-z="' + z + '"]')); }
    function storeFocus() {
        var all = document.querySelectorAll('#store [data-z]');
        for (var i = 0; i < all.length; i++) { all[i].classList.remove('focus'); }
        var els = zoneEls(store.zone);
        if (!els.length) { return; }
        store.idx = Math.max(0, Math.min(store.idx, els.length - 1));
        var el = els[store.idx];
        el.classList.add('focus');
        var box = $('store-scroll');
        if (box && box.contains(el)) {
            var prev = el.previousElementSibling, top = prev && prev.className === 'ghead' ? prev.offsetTop : el.offsetTop;
            if (store.zone === 'list' && store.idx === 0) { top = 0; }
            if (top < box.scrollTop) { box.scrollTop = top; }
            else if (el.offsetTop + el.offsetHeight > box.scrollTop + box.clientHeight) { box.scrollTop = el.offsetTop + el.offsetHeight - box.clientHeight; }
        }
        $('store-hint').innerHTML = storeHint();
    }
    function hint(list) { return list.map(function (h) { return '<span><span class="k">' + esc(h[0]) + '</span>' + esc(h[1]) + '</span>'; }).join(''); }
    function storeHint() {
        var z = store.zone;
        if (store.page) { return hint([['OK', 'Choose'], ['▲ ▼', 'Move'], ['CH+ / CH−', 'Scroll the description'], ['BACK', 'Back']]); }
        if (z === 'tabs') { return hint([['◀ ▶', 'Switch tabs'], ['OK', store.idx === 3 ? 'Type a search' : 'Open'], ['▼', 'Down to the list'], ['BACK', 'Close']]); }
        if (store.tab === 'browse' && store.query) { return hint([['OK', z === 'chips' ? 'Filter' : 'Read about it'], ['▲ ▼', 'Move'], ['◀ ▶', 'Filters'], ['BACK', 'Clear the search']]); }
        if (store.tab === 'browse') {
            return hint([['OK', z === 'rail' ? 'Open' : (z === 'chips' ? 'Sort or filter' : 'Read about it')], [z === 'grid' ? '◀ ▶ ▲ ▼' : '▲ ▼', 'Move'],
                ['◀', 'Categories'], ['CH+ / CH−', 'Next category'], ['BACK', 'Close']]);
        }
        if (store.tab === 'installed') { return hint([['OK', z === 'chips' ? 'Filter' : 'Details or remove'], ['▲ ▼', 'Move'], ['CH+ / CH−', 'Next group'], ['BACK', 'Close']]); }
        return hint([['OK', 'Update or check'], ['▲ ▼', 'Move'], ['BACK', 'Close']]);
    }
    function setZone(z, i) { store.zone = z; store.idx = i || 0; storeFocus(); }
    function contentZone() {
        if (store.page) { return 'btns'; }
        if (store.tab === 'browse' && !store.query) { return 'rail'; }
        return store.chips.length ? 'chips' : 'list';
    }
    // Shows a tab, then puts the focus on the tabs, or in the tab with down
    function storeTab(i, down) {
        var t = ['browse', 'installed', 'updates'][i];
        if (!t) { return; }
        if (t === store.tab && !store.page) { if (down) { setZone(contentZone(), firstIndex()); } return; }
        store.tab = t;
        store.page = null;
        store.group = 'all';
        storeLoad(false, function () {
            storeRender();
            if (down) { setZone(contentZone(), firstIndex()); } else { setZone('tabs', i); }
        });
    }
    function firstIndex() { return store.tab === 'browse' && !store.query && !store.page ? railIndex(store.cat) : 0; }
    function storeCat(id, keepZone) {
        store.cat = id;
        store.sort = 'useful';
        storeRender();
        if (!keepZone) { setZone('rail', railIndex(id)); }
    }
    function railIndex(id) { for (var i = 0; i < store.rail.length; i++) { if (store.rail[i].id === id) { return i; } } return 0; }
    function nextCat(dir) {
        var ids = store.rail.filter(function (r) { return r.id !== 'libs-toggle'; }).map(function (r) { return r.id; });
        var i = ids.indexOf(store.cat) + dir;
        if (i < 0 || i >= ids.length) { return; }
        var z = store.zone;
        storeCat(ids[i], true);
        setZone(z === 'rail' ? 'rail' : (store.cat === 'start' ? 'grid' : 'list'), z === 'rail' ? railIndex(ids[i]) : 0);
    }
    function jumpGroup(dir) {
        var starts = [];
        store.rows.forEach(function (r, i) { if (!i || r.group !== store.rows[i - 1].group) { starts.push(i); } });
        var at = store.zone === 'list' ? store.idx : -1, to = null;
        if (dir > 0) { starts.forEach(function (s) { if (to === null && s > at) { to = s; } }); }
        else { starts.forEach(function (s) { if (s < at) { to = s; } }); }
        if (to !== null) { setZone('list', to); }
    }
    function toggleLibs() {
        store.libs = !store.libs;
        storeLoad(false, function () { storeRender(); setZone('rail', store.rail.length - 1); });
    }
    function runStoreSearch(v) {
        store.query = String(v || '').replace(/^\s+|\s+$/g, '').slice(0, 40);
        store.qcat = 'all';
        store.page = null;
        store.tab = 'browse';
        storeLoad(false, afterSearch);
    }
    function afterSearch() {
        storeRender();
        if (store.query) { setZone(store.rows.length ? 'list' : 'tabs', store.rows.length ? 0 : 3); }
        else { setZone('rail', railIndex(store.cat)); }
    }

    function storeEnter() {
        var z = store.zone, i = store.idx;
        if (z === 'tabs') {
            if (i === 3) { $('store-q').focus(); return; }
            storeTab(i, true);
            return;
        }
        if (z === 'rail') {
            var r = store.rail[i];
            if (!r) { return; }
            if (r.id === 'libs-toggle') { toggleLibs(); return; }
            if (r.id !== store.cat) { storeCat(r.id); }
            setZone(store.cat === 'start' ? 'grid' : (store.rows.length ? 'list' : 'chips'), 0);
            return;
        }
        if (z === 'chips') {
            var c = store.chips[i];
            if (!c) { return; }
            if (store.tab === 'installed') { store.group = c.id; }
            else if (store.query) { store.qcat = c.id; }
            else if (c.id === 'hide') { store.hideInst = !store.hideInst; }
            else { store.sort = c.id; }
            storeRender();
            setZone('chips', i);
            return;
        }
        if (z === 'grid') { if (store.grid[i]) { storeOpenPage(store.grid[i].n); } return; }
        if (z === 'btns') { pageAction(store.btns[i]); return; }
        var row = store.rows[i];
        if (!row) { return; }
        if (row.kind === 'pkg' || row.kind === 'inst') { storeOpenPage(row.name); }
        else if (row.kind === 'libs') { store.libs = true; storeLoad(false, afterSearch); }
        else if (row.kind === 'check') { storeLoad(true, function () { storeRender(); setZone('list', 0); }); }
        else if (row.kind === 'all') {
            confirmThen('Update all ' + upd.packages.length + ' packages?',
                'Refreshes the package list, then updates every package that has an update.  Your settings are kept.  A service restarts if its package updates.',
                function () { startJob('upgrade'); });
        } else if (row.kind === 'upd' && PKG_NAME.test(row.name)) {
            confirmThen('Update ' + row.name + '?', 'From ' + row.installed + ' to ' + row.available + '.  Its settings are kept.',
                function () { startJob('upgrade ' + row.name); });
        }
    }
    function pageAction(b) {
        var d = store.page;
        if (!b || !d || b.off || !PKG_NAME.test(d.name)) { return; }
        var inst = installedMap[d.name];
        if (b.act === 'more') {
            store.page = null; store.tab = 'browse'; store.query = ''; store.cat = b.cat; store.sort = 'useful';
            storeLoad(false, function () { storeRender(); setZone(store.rows.length ? 'list' : 'rail', store.rows.length ? 0 : railIndex(b.cat)); });
            return;
        }
        if (b.act === 'addon') {
            confirmThen('Add the ' + d.addonTitle + ' add-on?', 'Installs ' + d.name + ' and anything it needs, and sets it up for the TV.  Needs internet.',
                function () { startJob('add ' + d.addon); });
        } else if (b.act === 'install') {
            confirmThen('Install ' + d.name + '?', 'Downloads ' + kb(d.sizeKB + d.needsKB) + (d.needs.length ? ', with ' + d.needs.length + (d.needs.length === 1 ? ' package' : ' packages') + ' it needs,' : '') +
                ' and uses about ' + kb(d.isizeKB + d.needsIKB) + '.  Entware sets it up for webOS where that\'s needed.  Needs internet.',
                function () { startJob('pkg-add ' + d.name); });
        } else if (b.act === 'update') {
            var u = updFor(d.name);
            confirmThen('Update ' + d.name + '?', 'From ' + u.installed + ' to ' + u.available + '.  Its settings are kept.', function () { startJob('upgrade ' + d.name); });
        } else if (b.act === 'removeAddon' && inst) {
            confirmThen('Remove the ' + (inst.addonTitle || inst.addon) + ' add-on?', d.name + ' came with the ' + (inst.addonTitle || inst.addon) +
                ' add-on, so it goes with the add-on, along with its setup.  You can add it again from Add-ons any time.', function () { startJob('remove ' + inst.addon); });
        } else if (b.act === 'remove') {
            confirmThen('Remove ' + d.name + '?', 'Uninstalls ' + d.name + (inst ? ' (' + kb(inst.sizeKB) + ')' : '') +
                '.  Packages it needed stay, since others may use them.  You can install it again any time.', function () { startJob('pkg-remove ' + d.name); });
        }
    }

    function storeBack() {
        if (store.page) { closePage(); return; }
        if (store.tab === 'browse' && store.query) { store.query = ''; afterSearch(); return; }
        closeStore();
    }
    // After a task, or BACK on a question: the same view, read again if a
    // task may have changed what's installed
    function storeReturn() {
        var page = store.page && store.page.name;
        storeLoad(false, function () {
            if (page) {
                var keep = store.from;
                store.page = null;
                storeOpenPage(page);
                store.from = keep;
                return;
            }
            var z = store.zone, i = store.idx;
            storeRender();
            setZone(z, i);
        });
    }

    function storeKey(e) {
        var k = e.keyCode, z = store.zone, i = store.idx, cols = 3;
        e.preventDefault();
        if (k === KEY.BACK || k === KEY.ESC || k === KEY.BACKSPACE) { storeBack(); return; }
        if (k === KEY.ENTER) { storeEnter(); return; }
        if (k === KEY.CH_UP || k === KEY.CH_DOWN) {
            var dir = k === KEY.CH_DOWN ? 1 : -1;
            if (store.page) { $('page-desc').scrollTop += dir * 200; }
            else if (store.tab === 'browse' && !store.query) { nextCat(dir); }
            else if (store.tab === 'installed') { jumpGroup(dir); }
            else { setZone('list', (z === 'list' ? i : 0) + dir * 6); }
            return;
        }
        var L = k === KEY.LEFT, R = k === KEY.RIGHT, U = k === KEY.UP, D = k === KEY.DOWN;
        if (z === 'tabs') {
            if ((L && i > 0) || (R && i < 3)) {
                var to = i + (L ? -1 : 1);
                if (to < 3) { storeTab(to); }
                setZone('tabs', to);
            } else if (D) { setZone(contentZone(), firstIndex()); }
            return;
        }
        if (z === 'rail') {
            if (U && i === 0) { setZone('tabs', 0); }
            else if (U || D) {
                var to2 = i + (U ? -1 : 1);
                if (to2 >= store.rail.length) { return; }
                if (store.rail[to2].id !== 'libs-toggle') { storeCat(store.rail[to2].id); } else { setZone('rail', to2); }
            } else if (R) { storeEnter(); }
            return;
        }
        if (z === 'grid') {
            var n = store.grid.length;
            if (L && i % cols === 0) { setZone('rail', railIndex(store.cat)); }
            else if (L) { setZone('grid', i - 1); }
            else if (R && i + 1 < n && (i + 1) % cols) { setZone('grid', i + 1); }
            else if (U && i < cols) { setZone('tabs', 0); }
            else if (U) { setZone('grid', i - cols); }
            else if (D && i + cols < n) { setZone('grid', i + cols); }
            return;
        }
        if (z === 'chips') {
            if (L && i === 0 && store.tab === 'browse' && !store.query) { setZone('rail', railIndex(store.cat)); }
            else if (L && i > 0) { setZone('chips', i - 1); }
            else if (R && i < store.chips.length - 1) { setZone('chips', i + 1); }
            else if (U) { setZone('tabs', store.tab === 'browse' ? (store.query ? 3 : 0) : (store.tab === 'installed' ? 1 : 2)); }
            else if (D && store.rows.length) { setZone('list', 0); }
            return;
        }
        if (z === 'list') {
            if (U && i === 0) { if (store.chips.length) { setZone('chips', 0); } else { setZone('tabs', store.tab === 'updates' ? 2 : 0); } }
            else if (U) { setZone('list', i - 1); }
            else if (D) { setZone('list', i + 1); }
            else if (L && store.tab === 'browse' && !store.query) { setZone('rail', railIndex(store.cat)); }
            return;
        }
        if (z === 'btns') {
            if (U && i === 0) { setZone('tabs', ['browse', 'installed', 'updates'].indexOf(store.tab)); }
            else if (U) { setZone('btns', i - 1); }
            else if (D) { setZone('btns', i + 1); }
        }
    }

    function storeWire() {
        var q = $('store-q');
        q.addEventListener('keydown', function (e) {
            var k = e.keyCode;
            e.stopPropagation();
            if (k === KEY.ENTER) { e.preventDefault(); q.blur(); runStoreSearch(q.value); }
            else if (k === KEY.DOWN || k === KEY.BACK || k === KEY.ESC) {
                e.preventDefault();
                q.blur();
                if (k === KEY.DOWN) { setZone(contentZone(), 0); }
            }
        });
        Array.prototype.slice.call(document.querySelectorAll('#store [data-z]')).forEach(function (el) {
            var z = el.getAttribute('data-z'), i = parseInt(el.getAttribute('data-i'), 10);
            el.addEventListener('mouseover', function () { if (document.activeElement !== q && (store.zone !== z || store.idx !== i)) { setZone(z, i); } });
            el.addEventListener('click', function (e) { e.stopPropagation(); setZone(z, i); storeEnter(); });
        });
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
    function remember(k, v) {
        try {
            if (v === undefined) { return window.localStorage.getItem(k); }
            window.localStorage.setItem(k, v);
        } catch (e) { /* no storage: just don't remember */ }
        return null;
    }
    function maybeWhatsNew() {
        var n = window.ENTWARE_NOTES;
        if (!n || !n.version) { return; }
        var seen = remember('entware.seenVersion');
        remember('entware.seenVersion', n.version);
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
        if (/^(addons|report|logs|addoninfo|web)$/.test(overlayMode || '')) {
            if (k === KEY.UP) { focusAddon(listIndex - 1); }
            else if (k === KEY.DOWN) { focusAddon(listIndex + 1); }
            else if (k === KEY.ENTER) {
                ({ report: chooseReport, logs: chooseLog, addoninfo: chooseAddonInfo, web: chooseWeb }[overlayMode] || chooseAddon)();
            }
            else if (k === KEY.BACK || k === KEY.ESC || k === KEY.BACKSPACE) { closeOverlay(); }
            e.preventDefault();
            return;
        }
        if (overlayMode) {
            if (k === KEY.UP) { scrollPanel(-140); }
            else if (k === KEY.DOWN) { scrollPanel(140); }
            else if (overlayMode === 'loading') {
                // Reading for the Packages screen: BACK gives up on it
                if (k === KEY.BACK || k === KEY.ESC) { hideOverlay(); closeStore(); }
            } else if (overlayMode === 'busy') {
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
        if (store.open) { storeKey(e); return; }
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
    function refreshIfIdle() { if (!document.hidden && !busy && !overlayMode && !store.open) { refresh(); } }
    document.addEventListener('webOSRelaunch', refreshIfIdle);
    document.addEventListener('visibilitychange', refreshIfIdle);
    setInterval(refreshIfIdle, 30000);
    // Left open for a long time: look for a new release every 6 hours
    setInterval(function () { if (state) { checkUpdate(state.version); } }, 6 * 3600 * 1000);

    focusCurrent();
    refresh(function (s) { if (s) { checkUpdate(s.version); autoCheckUpdates(s); maybeWhatsNew(); } });
}());
