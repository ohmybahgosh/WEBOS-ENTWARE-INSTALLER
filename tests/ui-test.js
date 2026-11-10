#!/usr/bin/env node
/*
 * Drives the TV app in headless Chromium at 1920x1080, with the remote's
 * keys, against a fake installer (window.ENTWARE_DEMO), and saves
 * screenshots. Fails on any page error, on a card that overflows, or when
 * a screen doesn't behave.
 *
 * Usage: node tests/ui-test.js [app folder] [screenshot folder]
 *   app folder         webos-app/dist after a build (default), or webos-app/src
 *   screenshot folder  default: tests/ui-out
 * Needs: npm install playwright (and its Chromium)
 */
'use strict';
const path = require('path');
const fs = require('fs');
const { chromium } = require('playwright');

const ROOT = path.join(__dirname, '..');
const APP = path.resolve(process.argv[2] || path.join(ROOT, 'webos-app', 'dist'));
const OUT = path.resolve(process.argv[3] || path.join(__dirname, 'ui-out'));
fs.mkdirSync(OUT, { recursive: true });

// The fake installer: answers the app's fixed commands like the real one
function demo(scenario) {
    const ADDONS = [
        ['nano', 'nano with syntax colors', 'nano-full', false, 'installed'],
        ['locate', 'locate', 'mlocate', true, 'notInstalled'],
        ['certs', 'HTTPS certificates', 'ca-bundle', false, 'installed'],
        ['git', 'git', 'git git-http', true, 'needsSetup'],
        ['python', 'Python 3', 'python3 python3-pip', true, 'notInstalled'],
        ['htop', 'htop', 'htop', true, 'notInstalled'],
        ['tmux', 'tmux', 'tmux', true, 'installed'],
        ['ncdu', 'ncdu', 'ncdu', true, 'notInstalled'],
        ['rsync', 'rsync', 'rsync', true, 'notInstalled'],
        ['curl', 'curl', 'curl', true, 'notInstalled'],
        ['jq', 'jq', 'jq', true, 'notInstalled'],
        ['banner', 'Login banner', 'neofetch', true, 'notInstalled'],
        ['tailscale', 'Tailscale', 'tailscale', true, 'needsSetup'],
        ['filebrowser', 'File Browser', 'filebrowser', true, 'installed']
    ].map(([id, title, packages, removable, state]) => ({ id, title, packages, removable, state, service: id === 'tailscale' || id === 'filebrowser', about: 'About ' + title }));
    const INFO = {
        tailscale: { url: 'https://login.tailscale.com/a/fake123', user: '', password: '', lines: ['Not signed in yet. Open the sign-in link (on the TV, scan the QR code) and sign in to Tailscale.'] },
        filebrowser: { hasPassword: true, url: 'http://192.168.1.50:8090', user: 'admin', password: 'Xk4mP9qL2vR7nT3w', lines: ['Open http://192.168.1.50:8090 in a browser on your phone or computer.'] }
    };
    let UPDATES = [{ name: 'htop', installed: '3.4.1-1', available: '3.4.2-1' }, { name: 'curl', installed: '8.11.1-1', available: '8.12.0-1' }];
    const base = {
        version: '2.8.0', model: 'OLED55C2PUA', webos: 'webOS 25', webosRelease: '10.2.1', firmware: '33.21.30',
        kernel: 'aarch64', kernelBits: 64, ip: '192.168.1.50', root: true, homebrewChannel: true, telnet: true,
        installed: true, build: 'aarch64-k3.10', buildLabel: '64-bit (aarch64-k3.10)', recommended: 'aarch64-k3.10',
        mounted: true, opkg: true, packages: 42, diskUsed: '61.2M', freeMB: 120, location: 'user', locationChoice: 'auto', srcSafe: true, userFreeMB: 120, appFreeMB: 1700, bootScript: true, bootLog: 'done',
        bash: true, shellFiles: true, helpers: true, tvHelpers: true, nano: 'on', certs: 'yes', locate: 'notInstalled',
        locateDb: '', job: 'none', jobName: '', issues: [], notes: []
    };
    if (scenario === 'update') { window.ENTWARE_LATEST = '9.9.9'; }
    if (scenario === 'fresh') { Object.assign(base, { installed: false, mounted: false, opkg: false, packages: null, diskUsed: '' }); }
    let job = null;
    const INSTALLED = [
        { name: 'bash', version: '5.3-2', sizeKB: 1217, auto: false, neededBy: '', base: true, addon: '', section: 'shells', description: 'The GNU Bourne Again SHell', installed: 1761000000 },
        { name: 'libncurses', version: '6.4-3', sizeKB: 300, auto: true, neededBy: 'bash, htop', base: false, addon: '', section: 'libs', description: 'Terminal handling library', installed: 1761000000 },
        { name: 'tmux', version: '3.5a-1', sizeKB: 812, auto: false, neededBy: '', base: false, addon: 'tmux', addonTitle: 'tmux', section: 'utils', description: 'Terminal multiplexer', installed: 1762000000 },
        { name: 'jq', version: '1.7.1-1', sizeKB: 250, auto: false, neededBy: '', base: false, addon: '', section: 'utils', description: 'Command-line JSON processor', installed: 1762100000 },
        { name: 'libfoo', version: '1.0-1', sizeKB: 40, auto: true, neededBy: '', base: false, addon: '', section: 'libs', description: 'Leftover library', installed: 1761500000 }
    ];
    const ALL = [
        { name: 'btop', version: '1.4.5-1', description: 'Resource monitor' },
        { name: 'htop', version: '3.4.1-1', description: 'Interactive processes viewer' },
        { name: 'tmux', version: '3.5a-1', description: 'Terminal multiplexer' }
    ];
    // catalog --json: what Browse lists (libfoo and libncurses only with --all)
    const CATALOG = [
        { n: 'aria2', v: '1.37.0-4', s: 'net', z: 840, i: 1940, d: 'aria2 is a lightweight multi-protocol download utility', a: '', w: 0 },
        { n: 'bash', v: '5.3-2', s: 'utils', z: 700, i: 1217, d: 'The GNU Bourne Again SHell', a: '', w: 0 },
        { n: 'curl', v: '8.12.0-1', s: 'net', z: 90, i: 200, d: 'A client-side URL transfer utility', a: 'curl', w: 1 },
        { n: 'ffmpeg', v: '6.1.4-1', s: 'multimedia', z: 109, i: 250, d: 'FFmpeg can record, convert and stream digital audio and video', a: '', w: 0 },
        { n: 'htop', v: '3.4.1-1', s: 'admin', z: 130, i: 290, d: 'Htop is an ncursed-based process viewer', a: 'htop', w: 0 },
        { n: 'jq', v: '1.7.1-1', s: 'utils', z: 120, i: 250, d: 'Command-line JSON processor', a: 'jq', w: 0 },
        { n: 'jq-full', v: '1.7.1-1', s: 'utils', z: 300, i: 700, d: 'Command-line JSON processor, with all its options', a: '', w: 0 },
        { n: 'nethack', v: '3.6.7-1', s: 'games', z: 900, i: 2100, d: 'The classic dungeon game', a: '', w: 0 },
        { n: 'rclone', v: '1.73.2-1', s: 'net', z: 22905, i: 69320, d: 'Rclone is a command line program to sync files and directories to and from: Google Drive', a: 'rclone', w: 0 },
        { n: 'rsync', v: '3.4.1-3', s: 'net', z: 231, i: 470, d: 'rsync copies files fast', a: 'rsync', w: 2 },
        { n: 'tmux', v: '3.5a-1', s: 'utils', z: 414, i: 812, d: 'Terminal multiplexer', a: 'tmux', w: 0 },
        { n: 'unzip', v: '6.0-9', s: 'utils', z: 112, i: 260, d: 'InfoZIP unzip program', a: '', w: 1 }
    ];
    const LIBS = [
        { n: 'libfoo', v: '1.0-1', s: 'libs', z: 20, i: 40, d: 'Leftover library, foo', a: '', w: 0 },
        { n: 'libncurses', v: '6.4-3', s: 'libs', z: 150, i: 300, d: 'Terminal handling library', a: '', w: 0 }
    ];
    const DESCS = { rclone: 'Rclone is a command line program to sync files and directories to and from:\nGoogle Drive\nDropbox\nMicrosoft OneDrive\nAmazon S3\nBackblaze B2\nThe local filesystem',
        aria2: 'aria2 is a lightweight multi-protocol & multi-source command-line download\nutility' };
    const NEEDS = { aria2: [{ name: 'libssh2', sizeKB: 100, isizeKB: 300 }] };
    function pkgInfo(n) {
        const c = CATALOG.concat(LIBS).find((x) => x.n === n), i = INSTALLED.find((x) => x.name === n);
        if (!c && !i) { return 'There\'s no package called ' + n + ' in Entware\'s list.'; }
        const ad = c && c.a ? ADDONS.find((x) => x.id === c.a) : null, needs = i ? [] : (NEEDS[n] || []);
        return JSON.stringify({ name: n, version: c ? c.v : i.version, installed: !!i, installedVersion: i ? i.version : '', section: c ? c.s : i.section,
            sizeKB: c ? c.z : 0, isizeKB: c ? c.i : i.sizeKB, description: DESCS[n] || (c ? c.d : i.description),
            addon: c ? c.a : '', addonTitle: c && c.a ? (ad ? ad.title : c.a) : '', addonState: c && c.a ? (ad ? ad.state : (i ? 'installed' : 'notInstalled')) : '',
            base: !!(i && i.base), neededBy: i ? i.neededBy : '', system: c && c.w ? '/usr/bin/' + n : '', freeKB: 1700000, have: ['libc', 'libncurses'],
            needs, needsKB: needs.reduce((t, x) => t + x.sizeKB, 0), needsIKB: needs.reduce((t, x) => t + x.isizeKB, 0), commands: i ? [n] : [] });
    }
    const TASKS = [{ id: '1762200000-0-install', name: 'install', when: '2026-11-03 20:00', exit: 0 }];
    window.ENTWARE_CALLS = [];
    window.ENTWARE_DEMO = function (args, cb) {
        window.ENTWARE_CALLS.push(args);
        const reply = (out) => setTimeout(() => cb(true, out, ''), 30);
        if (args === 'status --json') { return reply(JSON.stringify(Object.assign({}, base, { updates: UPDATES.length, updatesChecked: '2026-11-02 20:58', updatesAgeHours: 0, job: job ? job.state : 'none', jobName: job ? job.name : '' }))); }
        if (args === 'addons --json') { return reply(JSON.stringify(ADDONS)); }
        if (args === 'web start --json') { return reply(JSON.stringify({ running: true, port: 8095, url: 'http://192.168.1.50:8095', code: 'ACDE3479' })); }
        if (args === 'web stop --json') { return reply(JSON.stringify({ running: false, port: null, url: '', code: '' })); }
        const inf = /^info ([a-z0-9]+) --json$/.exec(args);
        if (inf && INFO[inf[1]]) {
            const a = ADDONS.find((x) => x.id === inf[1]);
            return reply(JSON.stringify(Object.assign({ id: a.id, title: a.title, state: a.state, service: true }, INFO[inf[1]])));
        }
        if (args === 'app-update --check --json') {
            const latest = window.ENTWARE_LATEST || base.version;
            return reply(JSON.stringify({ current: base.version, command: base.version, latest, newer: latest !== base.version, notes: '', error: '' }));
        }
        if (/^updates --json( --refresh)?$/.test(args)) {
            return reply(JSON.stringify({ checked: '2026-11-02 20:58', ageHours: 0, refreshFailed: false, packages: UPDATES }));
        }
        if (args === 'status') { return reply('Entware status\n  Everything looks right.\n'); }
        if (args === 'installed --json') { return reply(JSON.stringify(INSTALLED)); }
        if (args === 'catalog --json') { return reply(JSON.stringify(CATALOG)); }
        if (args === 'catalog --json --all') { return reply(JSON.stringify(CATALOG.concat(LIBS))); }
        const pi = /^pkginfo ([A-Za-z0-9._+-]+) --json$/.exec(args);
        if (pi) { return reply(pkgInfo(pi[1])); }
        let s = /^search ([A-Za-z0-9._+-]+) --json$/.exec(args);
        if (s) { return reply(JSON.stringify(ALL.filter((x) => x.name.indexOf(s[1]) >= 0 || x.description.toLowerCase().indexOf(s[1]) >= 0).map((x) => Object.assign({ installed: !!INSTALLED.find((i) => i.name === x.name) }, x)))); }
        if (args === 'logs --json') { return reply(JSON.stringify({ boot: ['20:00:01 boot script started', '20:00:02 mounted /opt'], current: 'none', tasks: TASKS })); }
        s = /^log ([A-Za-z0-9._+-]+) --json$/.exec(args);
        if (s) { return reply(JSON.stringify({ id: s[1], log: ['[INFO] Installing...', '[SUCCESS] Entware installed successfully!'] })); }
        let m = /^job (add|remove|password|move|upgrade|pkg-add|pkg-remove) ([A-Za-z0-9._+-]+)$/.exec(args) || /^job (install|uninstall|locate|upgrade|app-update)$/.exec(args);
        if (m) {
            job = { name: m[2] ? m[1] + ' ' + m[2] : m[1], state: 'running', polls: 0 };
            return reply('Started: ' + job.name + '.');
        }
        if (args === 'job-status --json') {
            job.polls++;
            const log = ['[INFO] Working on ' + job.name + '...'];
            if (job.polls > 1) {
                job.state = 'done';
                log.push('[SUCCESS] Done.');
                const up = /^upgrade ?(.*)$/.exec(job.name);
                if (up) { UPDATES = up[1] ? UPDATES.filter((x) => x.name !== up[1]) : []; }
                const a = /^(add|remove) (.*)$/.exec(job.name);
                const ad = a && ADDONS.find((x) => x.id === a[2]);
                if (ad) { ad.state = a[1] === 'add' ? 'installed' : 'notInstalled'; }
                if (a && !ad && a[1] === 'add') { INSTALLED.push({ name: a[2], version: '1.0-1', sizeKB: 69320, auto: false, neededBy: '', base: false, addon: a[2], addonTitle: a[2], section: 'net', description: 'From its add-on', installed: 1762200000 }); }
                const pk = /^pkg-(add|remove) (.*)$/.exec(job.name);
                if (pk && pk[1] === 'add') { INSTALLED.push({ name: pk[2], version: (CATALOG.find((x) => x.n === pk[2]) || { v: '3.4.1-1' }).v, sizeKB: 400, auto: false, neededBy: '', base: false, addon: '', section: 'admin', description: 'Interactive processes viewer', installed: 1762200000 }); }
                if (pk && pk[1] === 'remove') { INSTALLED.splice(INSTALLED.findIndex((x) => x.name === pk[2]), 1); }
                if (job.name === 'move appstore') { Object.assign(base, { location: 'appstore', userFreeMB: 181, appFreeMB: 1639, freeMB: 1639 }); }
            }
            // While it runs: how far opkg has got (job_progress in the installer)
            const progress = job.state === 'running' && /^upgrade/.test(job.name) ? { total: 2, unpacked: 1, configured: 0, phase: 'unpack', current: 'htop' } : null;
            return reply(JSON.stringify({ state: job.state, name: job.name, exit: job.state === 'done' ? 0 : null, started: 1, now: 75, quiet: 200, workKB: 10, progress, log }));
        }
        return reply('unexpected: ' + args);
    };
}

let failures = 0;
function check(name, cond) {
    console.log((cond ? '  PASS ' : '  FAIL ') + name);
    if (!cond) { failures++; }
}

(async () => {
    const browser = await chromium.launch();
    async function open(scenario) {
        const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
        const errors = [];
        page.on('pageerror', (e) => errors.push(String(e)));
        page.on('console', (m) => { if (m.type() === 'error' && !/qrcode/.test(m.text())) { errors.push(m.text()); } });
        await page.addInitScript(demo, scenario);
        await page.goto('file://' + path.join(APP, 'index.html'));
        await page.waitForFunction(() => !/Checking/.test(document.getElementById('headline').textContent));
        return { page, errors };
    }
    const press = async (page, key, n) => { for (let i = 0; i < (n || 1); i++) { await page.keyboard.press(key); await page.waitForTimeout(60); } };
    const visible = (page, action) => page.$eval('[data-action="' + action + '"]', (b) => b.style.display !== 'none');
    const overlayTitle = (page) => page.$eval('#overlay-title', (e) => e.textContent);
    const overflows = (page) => page.$eval('#status', (c) => c.scrollHeight > c.clientHeight + 1);

    console.log('== Not installed');
    let { page, errors } = await open('fresh');
    check('says Entware isn\'t installed', /isn't installed/.test(await page.textContent('#headline')));
    check('offers Install, hides Add-ons and Uninstall', !(await visible(page, 'addons')) && !(await visible(page, 'uninstall')) && /Install Entware/.test(await page.textContent('#install-title')));
    await page.screenshot({ path: path.join(OUT, '1-not-installed.png') });
    check('no page errors', errors.length === 0);
    await page.close();

    console.log('== Installed');
    ({ page, errors } = await open('ready'));
    check('says Entware is ready', /ready/.test(await page.textContent('#headline')));
    check('the status card fits', !(await overflows(page)));
    check('shows Add-ons', await visible(page, 'addons'));
    await page.waitForFunction(() => window.ENTWARE_CALLS.indexOf('app-update --check --json') >= 0);
    await page.waitForTimeout(100);
    check('no Update button when the app is the newest release', !(await visible(page, 'update')));
    // With every button showing, including an update, the column still clears the footer
    const clears = await page.evaluate(() => {
        document.querySelectorAll('.btn').forEach((b) => { b.style.display = ''; });
        const bs = Array.prototype.filter.call(document.querySelectorAll('.btn'), (b) => b.style.display !== 'none');
        const last = bs[bs.length - 1].getBoundingClientRect().bottom;
        const ok = last <= document.querySelector('footer').getBoundingClientRect().top - 8;
        document.querySelector('[data-action="update"]').style.display = 'none';
        return ok;
    });
    check('every button fits above the footer, even with an update showing', clears);
    await page.screenshot({ path: path.join(OUT, '2-ready.png') });

    console.log('== Add-ons screen');
    const order = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    await press(page, 'ArrowDown', order.indexOf('addons'));
    await press(page, 'Enter');
    await page.waitForSelector('.addon');
    check('opens with Manage from your phone, then every add-on', (await page.$$('.addon')).length === 15 && /Manage from your phone/.test(await page.$eval('.addon', (r) => r.textContent)));
    check('the first row has focus', await page.$eval('.addon', (r) => r.classList.contains('focus')));
    await press(page, 'Enter');
    await page.waitForFunction(() => /Manage from your phone/.test(document.getElementById('overlay-title').textContent) && document.querySelector('.qr svg'));
    check('it starts the phone dashboard and shows its QR code, address and code', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('web start --json') &&
        /ACDE 3479/.test(await page.textContent('.web-code')) && /192\.168\.1\.50:8095/.test(await page.textContent('#overlay-body')));
    await page.screenshot({ path: path.join(OUT, '17-phone-dashboard.png') });
    await press(page, 'Escape');
    await page.waitForSelector('#addon-list .addon.focus');
    check('BACK leaves it running and returns to the list', !(await page.evaluate(() => window.ENTWARE_CALLS)).includes('web stop --json') && /Manage from your phone/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'Enter');
    await page.waitForSelector('.web-code');
    await press(page, 'Enter');
    await page.waitForSelector('#addon-list .addon.focus');
    check('OK on Stop stops it', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('web stop --json'));
    await press(page, 'ArrowDown');
    check('states show as Included, Finish setup and Add', await page.$eval('#addon-list', (l) => /Included/.test(l.textContent) && /Finish setup/.test(l.textContent) && /Add/.test(l.textContent)));
    await page.screenshot({ path: path.join(OUT, '3-addons.png') });
    await press(page, 'ArrowDown', 11);  // from nano
    const inView = await page.$eval('#addon-list', (l) => {
        const r = l.querySelector('.addon.focus');
        return r.offsetTop >= l.scrollTop && r.offsetTop + r.offsetHeight <= l.scrollTop + l.clientHeight + 1;
    });
    check('the list scrolls to keep the focused row in view', inView && /Login banner/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await page.screenshot({ path: path.join(OUT, '4-addons-scrolled.png') });
    await press(page, 'Enter');
    const bannerBody = await page.textContent('#overlay-body');
    check('the login banner says it downloads neofetch from GitHub and checks it', /Add Login banner/.test(await overlayTitle(page)) && /GitHub/.test(bannerBody) && /checksum/.test(bannerBody));
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');

    // Add htop, then cancel: back to the list
    await press(page, 'ArrowUp', 6); // htop
    check('focus lands on htop', /htop/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'Enter');
    check('asks before adding', /Add htop\?/.test(await overlayTitle(page)));
    await page.screenshot({ path: path.join(OUT, '5-confirm-add.png') });
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');
    check('BACK on the question returns to the list, same row', /htop/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    check('without reading the add-ons again', (await page.evaluate(() => window.ENTWARE_CALLS.filter((c) => c === 'addons --json').length)) === 1);

    // Add it for real
    await press(page, 'Enter');
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('runs the add-on as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job add htop'));
    check('the result names the add-on', /Add htop: done/.test(await overlayTitle(page)));
    await page.screenshot({ path: path.join(OUT, '6-added.png') });
    await press(page, 'Enter');
    await page.waitForSelector('.addon');
    check('closing the result returns to Add-ons, with htop installed', await page.$$eval('.addon', (rs) => /Installed/.test(rs[6].textContent)));

    // Base packages can't be removed
    await press(page, 'ArrowUp', 5);
    await press(page, 'Enter');
    check('nano explains it stays', /nano with syntax colors/.test(await overlayTitle(page)) && /base setup/.test(await page.textContent('#overlay-body')));
    await press(page, 'Enter');
    await page.waitForSelector('.addon');

    // Remove tmux
    await press(page, 'ArrowDown', 6);
    await press(page, 'Enter');
    check('asks before removing', /Remove tmux\?/.test(await overlayTitle(page)));
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('removes as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job remove tmux'));
    await press(page, 'Enter');
    await page.waitForSelector('.addon');

    // A network service opens with its address, password and a QR code
    check('a service shows Running, and Tailscale asks you to sign in', await page.$eval('#addon-list', (l) => /Running/.test(l.textContent) && /Sign in/.test(l.textContent)));
    await press(page, 'ArrowDown', 20);
    await press(page, 'Enter');
    await page.waitForFunction(() => /File Browser/.test(document.getElementById('overlay-title').textContent) && document.querySelector('.cred'));
    check('a running service shows its address, login and a QR code', /Xk4mP9qL2vR7nT3w/.test(await page.textContent('.cred')) && /admin/.test(await page.textContent('.cred')) && !!(await page.$('.qr svg')) && (await page.evaluate(() => window.ENTWARE_CALLS)).includes('info filebrowser --json'));
    check('with New random password, Manage from your phone and Remove', await page.$$eval('.addon', (rs) => rs.length === 3 && /New random password/.test(rs[0].textContent) && /Manage from your phone/.test(rs[1].textContent) && /Remove File Browser/.test(rs[2].textContent)));
    await page.screenshot({ path: path.join(OUT, '16-addon-info.png') });
    await press(page, 'Enter');
    check('asks before making a new password, and says how to pick your own', /New random password for File Browser\?/.test(await overlayTitle(page)) && /password filebrowser --ask/.test(await page.textContent('#overlay-body')));
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('which runs as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job password filebrowser') && /New password for File Browser: done/.test(await overlayTitle(page)));
    await press(page, 'Enter');
    await page.waitForFunction(() => /File Browser/.test(document.getElementById('overlay-title').textContent) && document.querySelector('.cred'));
    check('and closing it returns to File Browser, to see the new one', true);
    await press(page, 'ArrowDown', 2);
    await press(page, 'Enter');
    check('asks before removing it, and says files stay', /Remove File Browser\?/.test(await overlayTitle(page)) && /files in \/opt\/files stay/.test(await page.textContent('#overlay-body')));
    await press(page, 'Escape');
    await page.waitForFunction(() => /File Browser/.test(document.getElementById('overlay-title').textContent) && document.querySelector('.cred'));
    check('BACK on the question returns to the service', true);
    await press(page, 'Escape');
    await page.waitForSelector('#addon-list .addon.focus');
    check('BACK returns to Add-ons, on the same row', /File Browser/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'ArrowUp');
    await press(page, 'Enter');
    await page.waitForFunction(() => /Tailscale/.test(document.getElementById('overlay-title').textContent) && document.querySelector('.qr svg'));
    check('Tailscale shows a QR code of its sign-in link, and can get a new one', /login\.tailscale\.com/.test(await page.textContent('#overlay-body')) && /Get a new sign-in link/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('which runs its setup again as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job add tailscale'));
    await press(page, 'Enter');
    await page.waitForSelector('#addon-list .addon.focus');
    check('and afterwards it\'s back on Tailscale in the list', /Tailscale/.test(await page.$eval('.addon.focus', (r) => r.textContent)) && /Running/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'Escape');
    check('BACK closes Add-ons', await page.$eval('#overlay', (o) => o.classList.contains('hidden')));

    console.log('== Package updates');
    check('the button says how many updates there are', /2 updates available/.test(await page.textContent('#upgrade-hint')));
    let order4 = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order4.indexOf('upgrade'));
    await press(page, 'Enter');
    await page.waitForFunction(() => document.querySelector('#store .tab.on') && /Updates/.test(document.querySelector('#store .tab.on').textContent) && document.querySelector('#store .srow'));
    let rows = await page.$$eval('#store .srow b', (bs) => bs.map((b) => b.textContent));
    check('Package updates opens Packages on its Updates tab: Update all, each package and Check again', rows.join('|') === 'Update all 2 packages|htop|curl|Check again');
    check('each package shows its versions', /3\.4\.1-1\s+→\s+3\.4\.2-1/.test(await page.textContent('#store-scroll')));
    check('and when the list is from', /Package list from 2026-11-02 20:58/.test(await page.textContent('#store')));
    check('the tab shows the count', /Updates\s*2/.test(await page.$eval('#store .tab.on', (t) => t.textContent)));
    await page.screenshot({ path: path.join(OUT, '10-package-updates.png') });
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    check('asks before updating one package', /Update htop\?/.test(await overlayTitle(page)) && /3\.4\.1-1 to 3\.4\.2-1/.test(await page.textContent('#overlay-body')));
    await press(page, 'Enter');
    await page.waitForSelector('#jobprog .jstep');
    const prog = await page.$eval('#jobprog', (e) => e.textContent);
    check('while it runs: which package, how far, how long, and how long since anything changed', /Downloading 1 of 2:\s+htop/.test(prog) && /25%/.test(prog) && /1:14/.test(prog) && /Nothing new for 3 min/.test(prog));
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('updates just that package in the background', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job upgrade htop') && /Update htop: done/.test(await overlayTitle(page)));
    await press(page, 'Enter');
    await page.waitForFunction(() => document.getElementById('overlay').classList.contains('hidden') && document.querySelectorAll('#store .srow').length === 2);
    rows = await page.$$eval('#store .srow b', (bs) => bs.map((b) => b.textContent));
    check('then returns to the list, without htop', rows.join('|') === 'curl|Check again');
    await press(page, 'ArrowDown', 5);
    await press(page, 'Enter');
    await page.waitForFunction(() => window.ENTWARE_CALLS.includes('updates --json --refresh') && document.getElementById('overlay').classList.contains('hidden'));
    check('Check again downloads the package list', true);
    await press(page, 'Escape');
    check('BACK closes it', await page.$eval('#store', (s) => s.classList.contains('hidden')));
    await page.waitForFunction(() => /1 update available/.test(document.getElementById('upgrade-hint').textContent));
    check('and the button now says 1 update', true);

    console.log('== Move to app storage');
    check('the main screen shows where Entware is and both free spaces', await page.$eval('#facts', (t) => /user data/.test(t.textContent) && /1700 MB apps/.test(t.textContent)));
    check('Move to app storage shows when user data is tight', await visible(page, 'move'));
    check('a notice says it can move to app storage', await page.$eval('#notes', (n) => /Move it to app storage: 1700 MB free/.test(n.textContent)));
    check('the status card still fits with the notice', !(await overflows(page)));
    await page.screenshot({ path: path.join(OUT, '2b-move-notice.png') });
    let order3 = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order3.indexOf('move'));
    await press(page, 'Enter');
    check('asks before moving, with both free spaces', /Move Entware to app storage\?/.test(await overlayTitle(page)) && /120 MB/.test(await page.textContent('#overlay-body')) && /1700 MB/.test(await page.textContent('#overlay-body')));
    await page.screenshot({ path: path.join(OUT, '8-confirm-move.png') });
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('moves as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job move appstore') && /Move to app storage: done/.test(await overlayTitle(page)));
    await press(page, 'Enter');
    await page.waitForFunction(() => /app storage/.test(document.getElementById('facts').textContent));
    check('afterwards it shows app storage, and the button is gone', !(await visible(page, 'move')));
    check('and the notice is gone', !(await page.$eval('#notes', (n) => /Move it to app storage/.test(n.textContent))));

    console.log('== App update');
    await page.close();
    ({ page, errors } = await open('update'));
    await page.waitForFunction(() => document.querySelector('[data-action="update"]').style.display !== 'none');
    check('the app asks the installer whether a newer release is out', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('app-update --check --json'));
    check('and says which version you have', /you have v2\.8\.0/.test(await page.textContent('#update-hint')));
    check('a newer release shows Update to v9.9.9 first', /Update to v9\.9\.9/.test(await page.textContent('#update-title')) &&
        (await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none')[0].getAttribute('data-action'))) === 'update');
    check('every button still fits above the footer', await page.evaluate(() => {
        const bs = Array.prototype.filter.call(document.querySelectorAll('.btn'), (b) => b.style.display !== 'none');
        return bs[bs.length - 1].getBoundingClientRect().bottom <= document.querySelector('footer').getBoundingClientRect().top - 8;
    }));
    await page.screenshot({ path: path.join(OUT, '9-update-available.png') });
    await press(page, 'ArrowUp', 10);
    await press(page, 'Enter');
    check('asks before updating, and says what happens', /Update the app to v9\.9\.9\?/.test(await overlayTitle(page)) && /checks it against the release/.test(await page.textContent('#overlay-body')));
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('updates as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job app-update') && /Update the app: done/.test(await overlayTitle(page)));
    await press(page, 'Enter');

    console.log('== SSH commands');
    const order5 = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    check('SSH commands shows once Entware is installed', order5.includes('commands'));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order5.indexOf('commands'));
    await press(page, 'Enter');
    await page.waitForFunction(() => /SSH commands/.test(document.getElementById('overlay-title').textContent));
    check('it opens on tv, with the TV\'s groups', /tv: the TV/.test(await page.textContent('.ctab.on')) &&
        (await page.$$eval('.cgroup', (g) => g.map((x) => x.textContent).join('|'))) === 'Overview|Apps|The screen|System|Files|Automation');
    check('the commands fit the panel', !(await overflows(page)));
    await page.screenshot({ path: path.join(OUT, '20-commands-tv.png') });
    const top0 = await page.$eval('.cmdref', (d) => d.scrollTop);
    await press(page, 'ArrowDown', 2);
    check('DOWN scrolls the list', (await page.$eval('.cmdref', (d) => d.scrollTop)) > top0);
    await press(page, 'ArrowRight');
    check('RIGHT switches to ent', /ent: Entware/.test(await page.textContent('.ctab.on')) && /ent install/.test(await page.textContent('.cmdref')));
    await page.screenshot({ path: path.join(OUT, '21-commands-ent.png') });
    await press(page, 'ArrowLeft');
    check('LEFT goes back to tv', /tv: the TV/.test(await page.textContent('.ctab.on')));
    await press(page, 'Escape');
    check('BACK closes it', await page.$eval('#overlay', (o) => o.classList.contains('hidden')));
    // Every command in tv help and ent help is on the screen
    {
        const sh = fs.readFileSync(path.join(ROOT, 'webos-entware-installer.sh'), 'utf8');
        const listed = await page.evaluate(() => [].concat(...['tv', 'ent'].map((t) => window.ENTWARE_COMMANDS[t].groups.map((g) => g[1].map((r) => r[0])).flat())));
        const want = (sh.match(/^ {2}(tv|ent) [a-z]+/gm) || []).map((l) => l.trim());
        const missing = [...new Set(want)].filter((w) => !listed.some((c) => c === w || c.startsWith(w + ' ')));
        check('every command in tv help and ent help is on the SSH commands screen' + (missing.length ? ': missing ' + missing.join(', ') : ''), want.length > 40 && missing.length === 0);
    }

    console.log('== Full check');
    const order2 = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order2.indexOf('doctor'));
    await press(page, 'Enter');
    await page.waitForFunction(() => /Full check and logs/.test(document.getElementById('overlay-title').textContent));
    check('Full check and logs lists the check, the boot log and recent tasks', await page.$$eval('.addon', (rs) => rs.length === 3 && /Full check/.test(rs[0].textContent) && /Boot log/.test(rs[1].textContent) && /Install and repair/.test(rs[2].textContent)));
    await page.screenshot({ path: path.join(OUT, '12-logs.png') });
    await press(page, 'Enter');
    await page.waitForFunction(() => /Full check/.test(document.getElementById('overlay-title').textContent) && /Everything/.test(document.getElementById('overlay-body').textContent));
    check('Full check shows the report', true);
    await page.screenshot({ path: path.join(OUT, '7-full-check.png') });
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');
    check('BACK returns to the logs list', /Full check and logs/.test(await overlayTitle(page)));
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    check('the boot log shows', /Boot log/.test(await overlayTitle(page)) && /mounted \/opt/.test(await page.textContent('#overlay-body')));
    const logReads = await page.evaluate(() => window.ENTWARE_CALLS.filter((c) => c === 'logs --json').length);
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');
    check('and BACK shows the list again without reading the logs again', (await page.evaluate(() => window.ENTWARE_CALLS.filter((c) => c === 'logs --json').length)) === logReads);
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    await page.waitForFunction(() => /Install and repair/.test(document.getElementById('overlay-title').textContent));
    check('a recent task shows its log', /installed successfully/.test(await page.textContent('#overlay-body')) && (await page.evaluate(() => window.ENTWARE_CALLS)).includes('log 1762200000-0-install --json'));
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');
    await press(page, 'Escape');

    console.log('== Report for GitHub');
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order2.indexOf('report'));
    await press(page, 'Enter');
    await page.waitForFunction(() => /Report for GitHub/.test(document.getElementById('overlay-title').textContent));
    check('offers a compatibility report and a bug report', await page.$$eval('.addon', (rs) => rs.length === 2 && /It works on my TV/.test(rs[0].textContent) && /Something went wrong/.test(rs[1].textContent)));
    await page.screenshot({ path: path.join(OUT, '10-report-menu.png') });
    await press(page, 'Enter');
    check('It works on my TV shows a QR code for a compatibility report', /It works on my TV/.test(await overlayTitle(page)) && !!(await page.$('#overlay-body svg')) && /compatibility report/.test(await page.textContent('#overlay-body')));
    await page.screenshot({ path: path.join(OUT, '11-report-compat.png') });
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');
    check('BACK returns to the choice, same row', /Report for GitHub/.test(await overlayTitle(page)) && /It works/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    check('Something went wrong shows a QR code for a bug report', /Something went wrong/.test(await overlayTitle(page)) && !!(await page.$('#overlay-body svg')) && /bug report/.test(await page.textContent('#overlay-body')));
    await press(page, 'Escape');
    await press(page, 'Escape');
    check('BACK again closes it', await page.$eval('#overlay', (o) => o.className.indexOf('hidden') >= 0));

    console.log('== Packages');
    const shown = () => page.evaluate(() => document.getElementById('overlay').classList.contains('hidden') && !document.getElementById('store').classList.contains('hidden'));
    const focused = () => page.$eval('#store .focus', (e) => e.textContent);
    const settle = () => page.waitForFunction(() => document.getElementById('overlay').classList.contains('hidden') && document.querySelector('#store .focus'));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order2.indexOf('packages'));
    await press(page, 'Enter');
    await page.waitForFunction(() => document.querySelector('#store .tile'));
    check('Packages opens full screen on Browse, at Start here', await shown() && /Browse\s*12/.test(await page.$eval('#store .tab.on', (t) => t.textContent)) &&
        /Start here/.test(await page.$eval('#store .rc.on', (r) => r.textContent)));
    let tiles = await page.$$eval('#store .tile', (ts) => ts.map((t) => t.textContent));
    check('Start here shows the picks that are in Entware, in order', tiles.map((t) => t.split(/\s/)[0].replace(/(System|Files|Shell|Downloads|Media|Fun).*/, '')).join(' ') === 'htop rclone tmux aria2 ffmpeg rsync jq curl nethack');
    check('rsync, which the Homebrew Channel ships, counts as already on the TV', /Homebrew has it/.test(tiles[5]));
    check('with a plain one-liner, and what is installed or has an add-on', /Google Drive, Dropbox/.test(tiles[1]) && /Add-on sets it up/.test(tiles[0]) && /Installed/.test(tiles[2]) && !/Installed|Add-on/.test(tiles[3]));
    let rail = await page.$$eval('#store .rc', (rs) => rs.map((r) => r.textContent));
    check('the categories list what is in each, and libraries are off', rail.join('|') === 'Start here9|Shell & terminal4|Files & backup3|Downloads & torrents2|Media & audio1|System & monitoring1|Fun & games1|Show libraries tooOff');
    check('each category has a drawn icon', (await page.$$eval('#store .rc i svg path', (ps) => ps.filter((p) => p.getAttribute('d')).length)) === 8);
    check('the catalog and what is installed are read once', (await page.evaluate(() => window.ENTWARE_CALLS.filter((c) => c === 'catalog --json').length)) === 1);
    await page.screenshot({ path: path.join(OUT, '13-packages.png') });
    await press(page, 'ArrowDown');
    await settle();
    check('▼ on the categories shows the next one straight away', /Shell & terminal/.test(await page.textContent('#store h2')) &&
        (await page.$$eval('#store .srow b', (bs) => bs.map((b) => b.textContent))).join(' ') === 'tmux jq bash jq-full');
    check('picks first, each marked installed, and another build of one that\'s installed says so', (await page.$$eval('#store .srow .pill', (ps) => ps.map((p) => p.textContent))).join('|') === 'Installed|Installed|Installed|Have jq');
    await press(page, 'ArrowRight');
    await press(page, 'ArrowUp');
    await press(page, 'ArrowRight', 3);
    check('the sort and filter chips are above the list', /^Hide installed/.test(await focused()));
    await press(page, 'Enter');
    await settle();
    check('Hide installed hides other builds of what\'s installed too', !(await page.$('#store .srow')) && /Everything here is installed/.test(await page.textContent('#store .s-main')));
    await press(page, 'Enter');
    await settle();
    check('and shows them again', (await page.$$('#store .srow')).length === 4);
    await press(page, 'ArrowLeft', 4);
    check('◀ from the chips goes back to the categories', /Shell & terminal/.test(await focused()));
    await press(page, 'PageDown');
    await settle();
    let fr = await page.$$eval('#store .srow', (rs) => rs.map((r) => r.textContent));
    check('CH+ goes to the next category', /Files & backup/.test(await page.textContent('#store h2')) && fr.length === 3);
    check('what the Homebrew Channel or webOS already has says so', /^rsync.*Homebrew has it/.test(fr[1]) && /^unzip.*webOS has one/.test(fr[2]));
    await press(page, 'PageDown');
    await settle();
    await press(page, 'ArrowRight');
    check('▶ goes into the list', /^aria2/.test(await focused()));
    await page.screenshot({ path: path.join(OUT, '13b-packages-category.png') });
    await press(page, 'Enter');
    await page.waitForSelector('#store .s-page');
    let pg = await page.textContent('#store .s-page');
    pg = pg.replace(/\s+/g, ' ');
    check('OK opens its page: the whole description, sizes and what else it installs', /multi-source command-line download utility/.test(pg) &&
        pg.indexOf('Download940 KB (with 1 more package)') >= 0 && /Also installslibssh2/.test(pg) && /Free on your TV1\.6 GB/.test(pg));
    check('with Install as the first choice', /^Install aria2/.test(await focused()));
    await page.screenshot({ path: path.join(OUT, '15-package-page.png') });
    await press(page, 'Enter');
    check('asks before installing, with what it downloads', /Install aria2\?/.test(await overlayTitle(page)) && /Downloads 940 KB, with 1 package it needs/.test(await page.textContent('#overlay-body')));
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('installs it as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job pkg-add aria2'));
    await press(page, 'Enter');
    await page.waitForFunction(() => document.getElementById('overlay').classList.contains('hidden') && /Remove aria2/.test((document.querySelector('#store .s-page') || {}).textContent || ''));
    check('closing the result shows its page again, now installed, with Remove', /installed/.test(await page.textContent('#store .psub')));
    await press(page, 'Escape');
    await settle();
    check('BACK goes back to the list, on the same package, now Installed', /^aria2.*Installed/.test(await focused()));
    check('without reading the whole catalog again', (await page.evaluate(() => window.ENTWARE_CALLS.filter((c) => c === 'catalog --json').length)) === 1);
    await press(page, 'PageUp');
    await settle();
    await press(page, 'Enter');
    await page.waitForSelector('#store .s-page');
    check('rclone\'s list of clouds shows as a list', (await page.$$eval('#store .pdesc li', (ls) => ls.map((l) => l.textContent))).slice(0, 2).join('|') === 'Google Drive|Dropbox');
    check('its add-on comes first, then the plain package', (await page.$$eval('#store .sbtn b', (bs) => bs.map((b) => b.textContent))).join('|') === 'Add the rclone add-on|Install just the package|More in Files & backup');
    check('with tips for the TV', /sets it up for the TV/.test(await page.textContent('#store .pbox')) && /Use web browser/.test(await page.textContent('#store .pbox')));
    await press(page, 'Enter');
    check('asks before adding the add-on', /Add the rclone add-on\?/.test(await overlayTitle(page)));
    await press(page, 'Escape');
    await settle();
    check('BACK on the question shows the page again', /^Add the rclone add-on/.test(await focused()));
    await press(page, 'Escape');
    await settle();

    console.log('== Packages: search');
    await press(page, 'ArrowUp', 2);
    check('▲ from the list goes up to the sort chips, then the tabs', /^Browse/.test(await focused()));
    await page.focus('#store-q');
    await page.keyboard.type('top');
    await press(page, 'Enter');
    await page.waitForFunction(() => document.querySelector('#store .ghead'));
    await settle();
    check('a search lists name matches, with the word marked', /Name matches/.test(await page.textContent('#store')) && /^htop/.test(await focused()) && (await page.$eval('#store .srow .mark', (m) => m.textContent)) === 'top');
    check('and offers to search libraries too', /Search every package, libraries too/.test(await page.textContent('#store-scroll')));
    await page.screenshot({ path: path.join(OUT, '14-packages-search.png') });
    await page.focus('#store-q');
    await page.keyboard.press('Control+A');
    await page.keyboard.type('foo');
    await press(page, 'Enter');
    await settle();
    check('nothing in what Browse lists', /Nothing matches "foo"/.test(await page.textContent('#store')) && /^Search every package/.test(await focused()));
    await press(page, 'Enter');
    await page.waitForFunction(() => window.ENTWARE_CALLS.includes('catalog --json --all') && /libfoo/.test(document.getElementById('store').textContent));
    await settle();
    check('searching libraries too finds it, in its own category', /^libfoo/.test(await focused()) && /Libraries & modules 1/.test(await page.textContent('#store .s-chips')) && /Libraries included/.test(await page.textContent('#store')));
    await press(page, 'Escape');
    await settle();
    rail = await page.$$eval('#store .rc', (rs) => rs.map((r) => r.textContent));
    check('BACK clears the search, and the libraries now have a category', !(await page.$eval('#store-q', (q) => q.value)) && rail.indexOf('Libraries & modules2') >= 0 && rail.indexOf('Show libraries tooOn') >= 0);

    console.log('== Packages: installed');
    await press(page, 'ArrowUp', 15);
    await press(page, 'ArrowRight');
    await page.waitForFunction(() => /Installed/.test(document.querySelector('#store .tab.on').textContent) && document.querySelector('#store .srow'));
    await settle();
    await press(page, 'ArrowDown');
    let chips = await page.$$eval('#store .chip', (cs) => cs.map((c) => c.textContent));
    check('Installed groups what\'s here, with a chip for each group', chips.join('|') === 'All 6  ·  2.9 MB|On their own 2|From add-ons 1|No longer needed 1|Entware 1|Libraries 1');
    check('in order: on their own, add-ons, no longer needed, Entware, libraries', (await page.$$eval('#store .srow b', (bs) => bs.map((b) => b.textContent))).join(' ') === 'aria2 jq tmux libfoo bash libncurses');
    check('each says what OK does', (await page.$$eval('#store .srow .pill', (ps) => ps.map((p) => p.textContent))).join('|') === 'Remove|Remove|tmux add-on|Remove|Entware|Needed' &&
        /Needed by bash, htop/.test(await page.$$eval('#store .srow', (rs) => rs[5].textContent)));
    await page.screenshot({ path: path.join(OUT, '16-packages-installed.png') });
    await press(page, 'ArrowDown');
    await press(page, 'PageDown');
    check('CH+ jumps to the next group', /^tmux/.test(await focused()));
    await press(page, 'Enter');
    await page.waitForSelector('#store .s-page');
    check('an add-on\'s package is removed with its add-on', /^Remove the tmux add-on/.test(await focused()));
    await press(page, 'Enter');
    check('and asks first', /Remove the tmux add-on\?/.test(await overlayTitle(page)));
    await press(page, 'Escape');
    await settle();
    await press(page, 'Escape');
    await settle();
    await press(page, 'PageDown', 2);
    check('to Part of Entware', /^bash/.test(await focused()));
    await press(page, 'Enter');
    await page.waitForSelector('#store .s-page');
    check('bash says it stays, and OK on that does nothing', /^Part of Entware/.test(await focused()));
    await press(page, 'Enter');
    check('(it stays on the page)', await shown() && !!(await page.$('#store .s-page')));
    await press(page, 'Escape');
    await settle();
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    await page.waitForSelector('#store .s-page');
    check('a library says what needs it', /^Needed by bash, htop/.test(await focused()));
    await press(page, 'Escape');
    await settle();
    await press(page, 'ArrowUp', 6);
    check('▲ from the top of the list goes to the group chips', /^All 6/.test(await focused()));
    await press(page, 'ArrowRight');
    await press(page, 'Enter');
    await settle();
    check('a group chip shows just that group', (await page.$$eval('#store .srow b', (bs) => bs.map((b) => b.textContent))).join(' ') === 'aria2 jq');
    await press(page, 'Escape');
    check('BACK closes Packages', await page.$eval('#store', (s) => s.classList.contains('hidden')) && /Packages/.test(await page.evaluate(() => document.activeElement.textContent)));
    check('no page errors', errors.length === 0);
    if (errors.length) { console.log(errors.join('\n')); }
    await page.close();

    console.log('== What\'s new');
    ({ page, errors } = await open('ready'));
    check('nothing shows the first time, or when the version hasn\'t changed', await page.$eval('#overlay', (o) => o.className.indexOf('hidden') >= 0));
    await page.evaluate(() => window.localStorage.setItem('entware.seenVersion', '1.0.0'));
    await page.reload();
    await page.waitForFunction(() => /What's new/.test(document.getElementById('overlay-title').textContent));
    const notes = await page.evaluate(() => window.ENTWARE_NOTES);
    check('after an update, what\'s new in this version shows once', notes && notes.notes.length > 0 && (await page.$$('.whatsnew li')).length === notes.notes.length);
    await page.screenshot({ path: path.join(OUT, '15-whats-new.png') });
    await page.reload();
    await page.waitForFunction(() => !/Checking/.test(document.getElementById('headline').textContent));
    await page.waitForTimeout(300);
    check('and not again', await page.$eval('#overlay', (o) => o.className.indexOf('hidden') >= 0));
    check('no page errors', errors.length === 0);
    if (errors.length) { console.log(errors.join('\n')); }

    await browser.close();
    console.log(failures ? '== ' + failures + ' failed' : '== all passed');
    process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
