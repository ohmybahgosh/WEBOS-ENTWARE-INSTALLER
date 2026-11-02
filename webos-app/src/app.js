/*
 * Entware TV app.
 *
 * A remote-friendly front end for webos-entware-installer.sh, which ships
 * inside the app. Root commands go through the Homebrew Channel's own root
 * service (luna://org.webosbrew.hbchannel.service/exec), so the app needs no
 * service of its own. Every command is a fixed string: nothing typed or
 * received is ever passed to the shell.
 *
 * Install, repair, uninstall, locate, add-ons and package updates run as background
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
    var overlayMode = null;  // null, 'busy', 'message', 'confirm'
    var onConfirm = null;
    var jobTimer = null;
    var busy = false;        // a status call or task is in flight
    var addons = [];         // last addons --json
    var addonIndex = 0;      // focused row on the Add-ons screen
    var backToAddons = false; // reopen Add-ons after an add-on task's result

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
            sub = s.packages + ' packages.  No problems found.';
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

        // Notes: the rest of the issues, then notes
        var notes = s.issues.slice(1).concat(s.notes).slice(0, 2);
        $('notes').innerHTML = notes.map(function (n) { return '<li>' + esc(n) + '</li>'; }).join('');

        // Buttons for this state
        show('install', true);
        $('install-title').textContent = s.installed ? (s.issues.length ? 'Repair Entware' : 'Check and repair') : 'Install Entware';
        $('install-hint').textContent = s.installed ? 'keeps your packages and settings' : 'about two minutes, needs internet';
        show('upgrade', s.installed && s.mounted);
        show('addons', s.installed && s.mounted);
        show('move', canMove(s));
        show('uninstall', s.installed);
        show('update', !!latest);
        if (latest) { $('update-title').textContent = 'Update to v' + latest; }
        if (current >= buttons().length) { current = buttons().length - 1; }
        if (!overlayMode) { focusCurrent(); }

        // A task started earlier (or from another screen) is still running
        if (s.job === 'running' && !jobTimer) { followJob(s.jobName); }
    }

    // Offer app storage when webOS's user data is getting tight and app
    // storage has room (the same rule doctor uses)
    function canMove(s) {
        return !!(s.installed && s.mounted && s.location === 'user' && s.srcSafe !== false &&
            s.userFreeMB !== null && s.userFreeMB < 150 && s.appFreeMB !== null && s.appFreeMB > 500);
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
        if (backToAddons) { backToAddons = false; openAddons(); return; }
        focusCurrent();
    }
    function confirmThen(title, text, fn) {
        backToAddons = overlayMode === 'addons'; // BACK returns to the list
        onConfirm = fn;
        overlay('confirm', esc(title), esc(text), 'Press OK to go ahead, or BACK to cancel.');
    }
    // OK on a confirmation: go ahead, without returning to the screen behind it
    function acceptConfirm() {
        var fn = onConfirm;
        backToAddons = false;
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
        var m = /^(add|remove) ([a-z0-9]+)$/.exec(name || '');
        if (m) {
            var a = addonById(m[2]);
            return (m[1] === 'add' ? 'Add ' : 'Remove ') + (a ? a.title : m[2]);
        }
        return { install: 'Install and repair', uninstall: 'Uninstall', locate: 'Set up locate', upgrade: 'Update packages',
            'move appstore': 'Move to app storage', 'move user': 'Move to user data' }[name] || name || 'Task';
    }

    function logHtml(lines) {
        return '<pre id="log">' + esc(lines.map(plain).join('\n')) + '</pre>';
    }

    // Start a task in the background, then follow it
    function startJob(name) {
        if (busy || !/^(install|uninstall|locate|upgrade|(add|remove) [a-z0-9]+|move (user|appstore))$/.test(name)) { return; }
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
                backToAddons = /^(add|remove) /.test(j.name || name);
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
            if (addonIndex >= addons.length) { addonIndex = 0; }
            renderAddons();
        });
    }

    function addonPill(a) {
        if (a.state === 'installed') { return a.removable ? '<span class="pill pill-ok">Installed</span>' : '<span class="pill pill-ok">Included</span>'; }
        if (a.state === 'needsSetup') { return '<span class="pill pill-warn">Finish setup</span>'; }
        return '<span class="pill pill-add">Add</span>';
    }

    function renderAddons() {
        var html = '<div class="addons" id="addon-list">' + addons.map(function (a, i) {
            return '<div class="addon' + (i === addonIndex ? ' focus' : '') + '" data-i="' + i + '">' +
                '<div><b>' + esc(a.title) + '</b><small>' + esc(a.about) + '</small></div>' + addonPill(a) + '</div>';
        }).join('') + '</div>';
        overlay('addons', 'Add-ons', html, 'OK adds, finishes setup or removes.  BACK to close.');
        Array.prototype.slice.call(document.querySelectorAll('.addon')).forEach(function (row) {
            row.addEventListener('mouseover', function () { focusAddon(parseInt(row.getAttribute('data-i'), 10)); });
            row.addEventListener('click', function (e) { e.stopPropagation(); focusAddon(parseInt(row.getAttribute('data-i'), 10)); chooseAddon(); });
        });
        focusAddon(addonIndex);
    }

    function focusAddon(i) {
        var rows = document.querySelectorAll('.addon');
        if (!rows.length) { return; }
        addonIndex = Math.max(0, Math.min(i, rows.length - 1));
        for (var r = 0; r < rows.length; r++) { rows[r].className = 'addon' + (r === addonIndex ? ' focus' : ''); }
        // Keep the focused row in view
        var box = $('addon-list'), row = rows[addonIndex];
        if (row.offsetTop < box.scrollTop) { box.scrollTop = row.offsetTop; }
        else if (row.offsetTop + row.offsetHeight > box.scrollTop + box.clientHeight) { box.scrollTop = row.offsetTop + row.offsetHeight - box.clientHeight; }
    }

    function chooseAddon() {
        var a = addons[addonIndex];
        // Ids are short names from the installer's fixed list; anything else is refused
        if (!a || !/^[a-z0-9]+$/.test(a.id)) { return; }
        if (a.state === 'notInstalled') {
            confirmThen('Add ' + a.title + '?', a.about + '.  Installs ' + a.packages + ' from Entware, and needs internet.',
                function () { startJob('add ' + a.id); });
        } else if (a.state === 'needsSetup') {
            confirmThen('Finish setting up ' + a.title + '?', 'It\'s installed, but not set up for webOS yet.  This finishes the setup.',
                function () { startJob('add ' + a.id); });
        } else if (a.removable) {
            confirmThen('Remove ' + a.title + '?', 'Uninstalls ' + a.packages + (a.id === 'locate' ? ', its settings and the hourly refresh' : '') + '.  You can add it again any time.',
                function () { startJob('remove ' + a.id); });
        } else {
            backToAddons = true;
            overlay('message', esc(a.title), esc(a.title + ' is part of the base setup, so it stays installed.  ' + a.about + '.'), 'Press OK or BACK to go back.');
        }
    }

    // ------------------------------------------------------------------ actions

    var actions = {
        install: function () {
            if (!state) { return; }
            if (!state.installed) {
                confirmThen('Install Entware?',
                    'Installs Entware into /mnt/lg/user/opt (about 25 MB), mounts it on /opt at every boot, and adds bash, nano and GNU ls with a few helpers.  ' +
                    'SSH logins switch to bash, and your own shell files are kept.  Uses the recommended ' + buildLabel(state.recommended) + ' build.  ' +
                    'If anything goes wrong, everything is undone.',
                    function () { startJob('install'); });
            } else {
                confirmThen(state.issues.length ? 'Repair Entware?' : 'Check and repair Entware?',
                    'Checks everything and fixes what it finds: the mount, the boot script, the shell setup and the helpers.  Your packages and your own settings are kept.',
                    function () { startJob('install'); });
            }
        },
        upgrade: function () { startJob('upgrade'); },
        addons: function () { addonIndex = 0; openAddons(); },
        move: function () {
            if (!state) { return; }
            confirmThen('Move Entware to app storage?',
                'User data, which webOS needs for itself, has ' + state.userFreeMB + ' MB free.  App storage has ' + state.appFreeMB + ' MB.  ' +
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
        doctor: function () {
            if (busy) { return; }
            busy = true;
            overlay('busy', '<span class="spinner"></span>Full check', logHtml(['Checking…']), '');
            runScript('status', function (ok, out) {
                busy = false;
                overlay('message', 'Full check', logHtml(plain(out).trim().split('\n')), 'Use ▲ ▼ to scroll.  Press OK or BACK to close.');
            });
        },
        report: function () {
            if (busy) { return; }
            busy = true;
            runScript('status', function (ok, out) {
                busy = false;
                showReport(plain(out).trim());
            });
        },
        update: function () {
            luna('luna://com.webos.applicationManager/launch', { id: 'org.webosbrew.hbchannel' }, function () {});
        }
    };

    // A pre-filled bug report on GitHub, as a QR code to scan with a phone
    function q(v) {
        return encodeURIComponent(v).replace(/%20/g, '+').replace(/%3A/g, ':').replace(/%2C/g, ',').replace(/%2F/g, '/');
    }
    function showReport(doctor) {
        var s = state || {};
        // Short enough for a QR code a phone can read off the screen
        var text = doctor.replace(/ {2,}/g, ' ');
        if (text.length > 1100) { text = text.slice(0, 1100) + '\n…'; }
        var arch = { 'aarch64-k3.10': '64-bit (aarch64-k3.10)', 'armv7sf-k3.2': '32-bit (armv7sf-k3.2)' }[s.build] || 'Not sure';
        var form = REPO_PATH + '/issues/new?template=bug-report.yml' +
            '&title=' + q('[Bug] ') +
            '&tv=' + q((s.model || 'LG TV') + ', ' + (s.webos || 'webOS') + (s.webosRelease ? ' (' + s.webosRelease + ')' : '')) +
            '&version=' + q(s.version || '') +
            '&arch=' + q(arch) +
            '&steps=' + q('From the Entware TV app') +
            '&doctor=' + q(text);
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
        overlay('message', 'Report a problem',
            '<div class="qr">' + svg + '<div>' +
            (svg ? 'Scan this with your phone to open a bug report on GitHub, with this TV\'s details and the full check already filled in.  Add what went wrong and submit.'
                 : 'Open github.com' + esc(REPO_PATH) + '/issues on your phone and paste the full check from SSH (webos-entware doctor).') +
            '<br><br><pre>' + esc(doctor.split('\n').slice(0, 10).join('\n')) + '</pre></div></div>',
            'Press OK or BACK to close.');
    }

    // ------------------------------------------------------------------ updates

    // Newer release on GitHub?  Updates themselves come from the Homebrew Channel.
    function versionParts(v) { return String(v || '').replace(/^v/, '').split('.').map(function (n) { return parseInt(n, 10) || 0; }); }
    function newer(a, b) {
        var x = versionParts(a), y = versionParts(b);
        for (var i = 0; i < 3; i++) { if ((x[i] || 0) !== (y[i] || 0)) { return (x[i] || 0) > (y[i] || 0); } }
        return false;
    }
    function checkUpdate(current) {
        if (window.ENTWARE_DEMO) { return; }
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
        if (overlayMode === 'addons') {
            if (k === KEY.UP) { focusAddon(addonIndex - 1); }
            else if (k === KEY.DOWN) { focusAddon(addonIndex + 1); }
            else if (k === KEY.ENTER) { chooseAddon(); }
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

    focusCurrent();
    refresh(function (s) { if (s) { checkUpdate(s.version); } });
}());
