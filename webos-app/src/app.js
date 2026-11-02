/*
 * Entware TV app.
 *
 * A remote-friendly front end for webos-entware-installer.sh, which ships
 * inside the app. Root commands go through the Homebrew Channel's own root
 * service (luna://org.webosbrew.hbchannel.service/exec), so the app needs no
 * service of its own. Every command is a fixed string: nothing typed or
 * received is ever passed to the shell.
 *
 * Install, repair, uninstall, locate and package updates run as background
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
        if (s.freeMB !== null) {
            html += row('Free space', s.freeMB < 50 ? '<span class="bad">' + esc(s.freeMB + ' MB') + '</span>' : esc(s.freeMB + ' MB'));
        }
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
        show('locate', s.installed && s.mounted && s.locate !== 'ready');
        show('uninstall', s.installed);
        show('update', !!latest);
        if (latest) { $('update-title').textContent = 'Update to v' + latest; }
        if (current >= buttons().length) { current = buttons().length - 1; }
        if (!overlayMode) { focusCurrent(); }

        // A task started earlier (or from another screen) is still running
        if (s.job === 'running' && !jobTimer) { followJob(s.jobName); }
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
        focusCurrent();
    }
    function confirmThen(title, text, fn) {
        onConfirm = fn;
        overlay('confirm', esc(title), esc(text), 'Press OK to go ahead, or BACK to cancel.');
    }
    // Scroll a long log or report in the open panel
    function scrollPanel(by) {
        var pre = $('overlay-body').querySelector('pre');
        if (pre) { pre.scrollTop += by; }
    }

    // ------------------------------------------------------------------ tasks

    function jobTitle(name) {
        return { install: 'Install and repair', uninstall: 'Uninstall', locate: 'Set up locate', upgrade: 'Update packages' }[name] || name || 'Task';
    }

    function logHtml(lines) {
        return '<pre id="log">' + esc(lines.map(plain).join('\n')) + '</pre>';
    }

    // Start a task in the background, then follow it
    function startJob(name) {
        if (busy) { return; }
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
        locate: function () { startJob('locate'); },
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
        if (overlayMode) {
            if (k === KEY.UP) { scrollPanel(-140); }
            else if (k === KEY.DOWN) { scrollPanel(140); }
            else if (overlayMode === 'busy') {
                // A task keeps running in the background; BACK just closes the app
                if (k === KEY.BACK || k === KEY.ESC) { exitApp(); }
            } else if (k === KEY.ENTER && overlayMode === 'confirm' && onConfirm) {
                var fn = onConfirm;
                closeOverlay();
                fn();
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
        if (overlayMode === 'confirm' && onConfirm) { var fn = onConfirm; closeOverlay(); fn(); }
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
