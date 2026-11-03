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
        ['jq', 'jq', 'jq', true, 'notInstalled']
    ].map(([id, title, packages, removable, state]) => ({ id, title, packages, removable, state, about: 'About ' + title }));
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
    window.ENTWARE_CALLS = [];
    window.ENTWARE_DEMO = function (args, cb) {
        window.ENTWARE_CALLS.push(args);
        const reply = (out) => setTimeout(() => cb(true, out, ''), 30);
        if (args === 'status --json') { return reply(JSON.stringify(Object.assign({}, base, { updates: UPDATES.length, updatesChecked: '2026-11-02 20:58', updatesAgeHours: 0, job: job ? job.state : 'none', jobName: job ? job.name : '' }))); }
        if (args === 'addons --json') { return reply(JSON.stringify(ADDONS)); }
        if (/^updates --json( --refresh)?$/.test(args)) {
            return reply(JSON.stringify({ checked: '2026-11-02 20:58', ageHours: 0, refreshFailed: false, packages: UPDATES }));
        }
        if (args === 'status') { return reply('Entware status\n  Everything looks right.\n'); }
        let m = /^job (add|remove|move|upgrade) ([A-Za-z0-9._+-]+)$/.exec(args) || /^job (install|uninstall|locate|upgrade|app-update)$/.exec(args);
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
                if (a) { ADDONS.find((x) => x.id === a[2]).state = a[1] === 'add' ? 'installed' : 'notInstalled'; }
                if (job.name === 'move appstore') { Object.assign(base, { location: 'appstore', userFreeMB: 181, appFreeMB: 1639, freeMB: 1639 }); }
            }
            return reply(JSON.stringify({ state: job.state, name: job.name, exit: job.state === 'done' ? 0 : null, started: 1, log }));
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
    check('opens with every add-on', (await page.$$('.addon')).length === 11);
    check('the first row has focus', await page.$eval('.addon', (r) => r.classList.contains('focus')));
    check('states show as Included, Finish setup and Add', await page.$eval('#addon-list', (l) => /Included/.test(l.textContent) && /Finish setup/.test(l.textContent) && /Add/.test(l.textContent)));
    await page.screenshot({ path: path.join(OUT, '3-addons.png') });
    await press(page, 'ArrowDown', 10);
    const inView = await page.$eval('#addon-list', (l) => {
        const r = l.querySelector('.addon.focus');
        return r.offsetTop >= l.scrollTop && r.offsetTop + r.offsetHeight <= l.scrollTop + l.clientHeight + 1;
    });
    check('the list scrolls to keep the focused row in view', inView && /jq/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await page.screenshot({ path: path.join(OUT, '4-addons-scrolled.png') });

    // Add htop, then cancel: back to the list
    await press(page, 'ArrowUp', 5); // htop
    check('focus lands on htop', /htop/.test(await page.$eval('.addon.focus', (r) => r.textContent)));
    await press(page, 'Enter');
    check('asks before adding', /Add htop\?/.test(await overlayTitle(page)));
    await page.screenshot({ path: path.join(OUT, '5-confirm-add.png') });
    await press(page, 'Escape');
    await page.waitForSelector('.addon.focus');
    check('BACK on the question returns to the list, same row', /htop/.test(await page.$eval('.addon.focus', (r) => r.textContent)));

    // Add it for real
    await press(page, 'Enter');
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('runs the add-on as a background task', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job add htop'));
    check('the result names the add-on', /Add htop: done/.test(await overlayTitle(page)));
    await page.screenshot({ path: path.join(OUT, '6-added.png') });
    await press(page, 'Enter');
    await page.waitForSelector('.addon');
    check('closing the result returns to Add-ons, with htop installed', await page.$$eval('.addon', (rs) => /Installed/.test(rs[5].textContent)));

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
    await press(page, 'Escape');
    check('BACK closes Add-ons', await page.$eval('#overlay', (o) => o.classList.contains('hidden')));

    console.log('== Package updates');
    check('the button says how many updates there are', /2 updates available/.test(await page.textContent('#upgrade-hint')));
    let order4 = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order4.indexOf('upgrade'));
    await press(page, 'Enter');
    await page.waitForFunction(() => document.getElementById('overlay-title').textContent === 'Package updates' && document.querySelector('.addon'));
    let rows = await page.$$eval('.addon b', (bs) => bs.map((b) => b.textContent));
    check('it lists Update all, each package and Check again', rows.join('|') === 'Update all 2 packages|htop|curl|Check again');
    check('each package shows its versions', await page.$eval('#addon-list', (l) => /3\.4\.1-1\s+→\s+3\.4\.2-1/.test(l.textContent)));
    check('and when the list is from', /Package list from 2026-11-02 20:58/.test(await page.textContent('#overlay-body')));
    await page.screenshot({ path: path.join(OUT, '10-package-updates.png') });
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    check('asks before updating one package', /Update htop\?/.test(await overlayTitle(page)) && /3\.4\.1-1 to 3\.4\.2-1/.test(await page.textContent('#overlay-body')));
    await press(page, 'Enter');
    await page.waitForFunction(() => /done/.test(document.getElementById('overlay-title').textContent), null, { timeout: 8000 });
    check('updates just that package in the background', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('job upgrade htop') && /Update htop: done/.test(await overlayTitle(page)));
    await press(page, 'Enter');
    await page.waitForFunction(() => document.getElementById('overlay-title').textContent === 'Package updates' && document.querySelector('.addon'));
    rows = await page.$$eval('.addon b', (bs) => bs.map((b) => b.textContent));
    check('then returns to the list, without htop', rows.join('|') === 'curl|Check again');
    await press(page, 'ArrowDown');
    await press(page, 'Enter');
    await page.waitForFunction(() => document.getElementById('overlay-title').textContent === 'Package updates' && document.querySelector('.addon'));
    check('Check again downloads the package list', (await page.evaluate(() => window.ENTWARE_CALLS)).includes('updates --json --refresh'));
    await press(page, 'Escape');
    check('BACK closes it', await page.$eval('#overlay', (o) => o.classList.contains('hidden')));
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

    console.log('== Full check');
    const order2 = await page.$$eval('.btn', (bs) => bs.filter((b) => b.style.display !== 'none').map((b) => b.getAttribute('data-action')));
    await press(page, 'ArrowUp', 10);
    await press(page, 'ArrowDown', order2.indexOf('doctor'));
    await press(page, 'Enter');
    await page.waitForFunction(() => /Full check/.test(document.getElementById('overlay-title').textContent) && /Everything/.test(document.getElementById('overlay-body').textContent));
    check('Full check shows the report', true);
    await page.screenshot({ path: path.join(OUT, '7-full-check.png') });
    check('no page errors', errors.length === 0);
    if (errors.length) { console.log(errors.join('\n')); }

    await browser.close();
    console.log(failures ? '== ' + failures + ' failed' : '== all passed');
    process.exit(failures ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
