// The phone dashboard (webos-app/web): sign-in, its checks, and the commands
// it hands the installer, against a fake installer.  Then the page itself in
// a phone-sized browser, when Playwright is there.
// Usage: node tests/web-test.js [screenshot folder]
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const { spawn } = require('child_process');

const ROOT = path.join(__dirname, '..');
const WEB = path.join(ROOT, 'webos-app', 'web');
const OUT = path.resolve(process.argv[2] || path.join(__dirname, 'ui-out'));
const T = fs.mkdtempSync(path.join(os.tmpdir(), 'entware-web-'));
const DIR = path.join(T, 'state');
fs.mkdirSync(DIR);
fs.writeFileSync(path.join(DIR, 'code'), 'ACDE3479\n');
const CALLS = path.join(T, 'calls');

// A fake installer: logs each call (and any input), answers like the real one
const FAKE = path.join(T, 'fake.sh');
fs.writeFileSync(FAKE, `#!/bin/sh
input=""
[ "$1" = password ] && case " $* " in *" --stdin "*) IFS= read -r input ;; esac
echo "$* | $input" >> "${CALLS}"
case "$1 $2" in
  "addons --json") cat << 'J'
[{"id":"htop","title":"htop","packages":"htop","about":"See what's using the CPU","removable":true,"service":false,"password":false,"system":"","state":"notInstalled"},
 {"id":"curl","title":"curl","packages":"curl","about":"Fetch URLs","removable":true,"service":false,"password":false,"system":"/usr/bin/curl","state":"notInstalled"},
 {"id":"nano","title":"nano with syntax colors","packages":"nano-full","about":"Colors","removable":false,"service":false,"password":false,"system":"","state":"installed"},
 {"id":"tailscale","title":"Tailscale","packages":"tailscale","about":"Reach the TV from anywhere","removable":true,"service":true,"password":false,"system":"","state":"needsSetup"},
 {"id":"filebrowser","title":"File Browser","packages":"filebrowser","about":"Manage files","removable":true,"service":true,"password":true,"system":"","state":"installed"},
 {"id":"samba","title":"Samba file sharing","packages":"samba4-server wsdd2","about":"Share files","removable":true,"service":true,"password":true,"system":"","state":"notInstalled"}]
J
  ;;
  "status --json") echo '{"version":"2.13.0","model":"OLED65C2PUA","webos":"webOS 25","webosRelease":"10.3.1","ip":"192.168.50.96","packages":121,"freeMB":1312,"location":"appstore","job":"none","jobName":""}' ;;
  "info filebrowser") echo '{"id":"filebrowser","title":"File Browser","state":"installed","service":true,"hasPassword":true,"url":"http://192.168.50.96:8090","user":"admin","password":"Xk4mP9qL2vR7nT3w","lines":["Open http://192.168.50.96:8090 in a browser on your phone or computer."]}' ;;
  "info tailscale") echo '{"id":"tailscale","title":"Tailscale","state":"needsSetup","service":true,"hasPassword":false,"url":"https://login.tailscale.com/a/fake123","user":"","password":"","lines":["Not signed in yet. Open the sign-in link (on the TV, scan the QR code) and sign in to Tailscale."]}' ;;
  "job-status --json") echo '{"state":"done","name":"add htop","exit":0,"log":["[SUCCESS] Added htop."]}' ;;
  "job add"|"job remove") echo "Started: $2 $3." ;;
  "password filebrowser") [ "$input" = "fail-me-please-123" ] && { echo "[ERROR] It broke."; exit 1; }; echo "[SUCCESS] Changed the password for File Browser." ;;
esac
`, { mode: 0o755 });

let fails = 0;
function check(name, ok) { console.log((ok ? '  PASS ' : '  FAIL ') + name); if (!ok) { fails++; } }
function req(method, url, body, token, port) {
    return new Promise((resolve) => {
        const r = http.request({ host: '127.0.0.1', port, path: url, method, headers: Object.assign({ 'Content-Type': 'application/json' }, token ? { 'X-Token': token } : {}) }, (res) => {
            let d = '';
            res.on('data', (c) => { d += c; });
            res.on('end', () => { let j = null; try { j = JSON.parse(d); } catch (e) { /* not JSON */ } resolve({ status: res.statusCode, body: d, json: j, headers: res.headers }); });
        });
        r.on('error', (e) => resolve({ status: 0, body: String(e) }));
        if (body !== undefined) { r.write(typeof body === 'string' ? body : JSON.stringify(body)); }
        r.end();
    });
}
const calls = () => (fs.existsSync(CALLS) ? fs.readFileSync(CALLS, 'utf8') : '');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
    console.log('== Phone dashboard server');
    const srv = spawn(process.execPath, [path.join(WEB, 'server.js'), '--dir', DIR, '--script', FAKE, '--port', '18095'], { stdio: 'inherit' });
    for (let i = 0; i < 50 && !fs.existsSync(path.join(DIR, 'port')); i++) { await sleep(100); }
    const port = +fs.readFileSync(path.join(DIR, 'port'), 'utf8');
    check('it writes its port and pid once it listens', port >= 18095 && +fs.readFileSync(path.join(DIR, 'pid'), 'utf8') === srv.pid);

    let r = await req('GET', '/', undefined, '', port);
    check('serves the page, with no caching and no framing', r.status === 200 && /Enter the code/.test(r.body) && r.headers['cache-control'] === 'no-store' && r.headers['x-frame-options'] === 'DENY' && /default-src 'self'/.test(r.headers['content-security-policy']));
    r = await req('GET', '/../server.js', undefined, '', port);
    check('and nothing but its own files', r.status === 404);
    r = await req('GET', '/api/state', undefined, '', port);
    check('the API needs a sign-in', r.status === 401);
    r = await req('GET', '/api/state', undefined, 'not-a-token', port);
    check('a made-up token is refused', r.status === 401);

    for (let i = 0; i < 4; i++) { await req('POST', '/api/login', { code: 'WRONG123' }, '', port); }
    r = await req('POST', '/api/login', { code: 'WRONG123' }, '', port);
    check('a wrong code is refused', r.status === 401);
    r = await req('POST', '/api/login', { code: 'ACDE3479' }, '', port);
    check('five wrong codes lock that address out for a minute, even with the right one', r.status === 429 && /Wait/.test(r.json.error));
    srv.kill('SIGTERM');
    await sleep(400);
    check('it stops cleanly, removing its port and pid', !fs.existsSync(path.join(DIR, 'port')) && !fs.existsSync(path.join(DIR, 'pid')));

    const srv2 = spawn(process.execPath, [path.join(WEB, 'server.js'), '--dir', DIR, '--script', FAKE, '--port', '18095', '--idle', '6000'], { stdio: 'inherit' });
    for (let i = 0; i < 50 && !fs.existsSync(path.join(DIR, 'port')); i++) { await sleep(100); }
    const port2 = +fs.readFileSync(path.join(DIR, 'port'), 'utf8');
    r = await req('POST', '/api/login', { code: 'acde-3479' }, '', port2);
    check('the code is read loosely: lower case and dashes are fine', r.status === 200 && /^[0-9a-f]{48}$/.test(r.json.token));
    const tok = r.json.token;
    r = await req('POST', '/api/login', { code: 'ACDE 3A79' }, '', port2);
    check('and A for 4 is still wrong', r.status === 401);

    r = await req('GET', '/api/state', undefined, tok, port2);
    check('the state has the TV, the add-ons and each service\'s login', r.status === 200 && r.json.tv.model === 'OLED65C2PUA' && r.json.addons.length === 6 &&
        r.json.addons.find((a) => a.id === 'filebrowser').info.password === 'Xk4mP9qL2vR7nT3w' && !r.json.addons.find((a) => a.id === 'samba').info);

    fs.writeFileSync(CALLS, '');
    r = await req('POST', '/api/task', { action: 'add', id: 'htop' }, tok, port2);
    check('adding an add-on starts it as the installer\'s background task', r.status === 200 && /^job add htop \| $/m.test(calls()));
    r = await req('POST', '/api/task', { action: 'add', id: 'emacs' }, tok, port2);
    check('it only names add-ons from the installer\'s list', r.status === 400);
    r = await req('POST', '/api/task', { action: 'install', id: 'htop' }, tok, port2);
    check('and only adds or removes', r.status === 400);
    r = await req('POST', '/api/task', { action: 'add', id: 'htop;reboot' }, tok, port2);
    check('names that aren\'t names are refused', r.status === 400 && !/reboot/.test(calls()));

    fs.writeFileSync(CALLS, '');
    r = await req('POST', '/api/password', { id: 'filebrowser', password: 'My-own pass 2026' }, tok, port2);
    check('a password with characters outside the safe set is refused', r.status === 400 && /12 to 64/.test(r.json.error) && calls() === '');
    r = await req('POST', '/api/password', { id: 'filebrowser', password: 'short-1' }, tok, port2);
    check('and so is a short one', r.status === 400);
    r = await req('POST', '/api/password', { id: 'tailscale', password: 'long-enough-pass-1' }, tok, port2);
    check('only services with a password take one', r.status === 400);
    r = await req('POST', '/api/password', { id: 'filebrowser', password: 'My-own_pass#2026' }, tok, port2);
    check('your own password goes to the installer on standard input, not its command line', r.status === 200 && /^password filebrowser -y --stdin \| My-own_pass#2026$/m.test(calls()) && r.json.info.user === 'admin');
    fs.writeFileSync(CALLS, '');
    r = await req('POST', '/api/password', { id: 'filebrowser' }, tok, port2);
    check('with none, the installer makes a random one', r.status === 200 && /^password filebrowser -y \| $/m.test(calls()));
    r = await req('POST', '/api/password', { id: 'filebrowser', password: 'fail-me-please-123' }, tok, port2);
    check('when the installer fails, its error comes back', r.status === 409 && /It broke/.test(r.json.error));
    r = await req('POST', '/api/login', '{"code":"' + 'x'.repeat(5000) + '"}', '', port2);
    check('an oversized request is refused', r.status === 0 || r.status === 400);

    // The page, on a phone
    let pw = null;
    try { pw = require('playwright'); } catch (e) { console.log('  (Playwright isn\'t installed, so the page itself isn\'t checked)'); }
    if (pw) {
        console.log('== Phone dashboard page');
        fs.mkdirSync(OUT, { recursive: true });
        const b = await pw.chromium.launch();
        const page = await b.newPage({ viewport: { width: 390, height: 844 }, deviceScaleFactor: 2 });
        const errors = [];
        page.on('pageerror', (e) => errors.push(e.message));
        await page.goto('http://127.0.0.1:' + port2 + '/#k=ACDE3479');
        await page.waitForSelector('#services .card');
        check('the QR code\'s #k= signs in, and comes off the address', !/k=/.test(page.url()) && await page.isVisible('#dash'));
        check('it shows the TV', /OLED65C2PUA/.test(await page.textContent('#tv')));
        const cards = await page.$$eval('#services .card', (cs) => cs.map((c) => c.textContent));
        check('services show as running, sign in or not added', cards.some((c) => /File Browser.*Running/.test(c)) && cards.some((c) => /Tailscale.*Sign in/.test(c)) && cards.some((c) => /Samba.*Not added/.test(c)));
        check('the password is hidden until you show it', !/Xk4mP9qL2vR7nT3w/.test(await page.textContent('#services')));
        await page.click('text=Show');
        check('and Show reveals it', /Xk4mP9qL2vR7nT3w/.test(await page.textContent('#services')));
        check('a tool webOS already has says so', /webOS already has one/.test(await page.textContent('#tools')));
        await page.screenshot({ path: path.join(OUT, 'web-dashboard.png'), fullPage: true });
        await page.click('text=Set my own');
        await page.fill('.pwform.open input >> nth=0', 'My-own_pass#2026');
        await page.fill('.pwform.open input >> nth=1', 'My-own_pass#2026');
        fs.writeFileSync(CALLS, '');
        await page.click('text=Set password');
        await page.waitForFunction(() => /Changed the password/.test(document.getElementById('dash-msg').textContent));
        check('Set my own changes it', /--stdin \| My-own_pass#2026/.test(calls()));
        page.on('dialog', (d) => d.accept());
        fs.writeFileSync(CALLS, '');
        await page.click('#tools button:has-text("Add") >> nth=0');
        await page.waitForFunction(() => /done/.test(document.getElementById('task-title').textContent));
        check('Add starts the task and follows it to the end', /^job add htop/m.test(calls()) && /Added htop/.test(await page.textContent('#task-log')));
        await page.click('#out');
        await page.waitForSelector('#login', { state: 'visible', timeout: 3000 }).catch(() => {});
        check('Sign out goes back to the code', await page.isVisible('#login'));
        await page.fill('#code', 'WRONG999');
        await page.click('text=Sign in');
        await page.waitForFunction(() => document.getElementById('login-msg').textContent.length > 0);
        check('a wrong code says where the right one is', /on the TV/.test(await page.textContent('#login-msg')));
        await page.screenshot({ path: path.join(OUT, 'web-login.png') });
        check('no page errors', errors.length === 0);
        if (errors.length) { console.log(errors.join('\n')); }
        await b.close();
    }

    await sleep(8500);
    check('it stops by itself when nobody uses it', !fs.existsSync(path.join(DIR, 'port')));
    srv2.kill();
    fs.rmSync(T, { recursive: true, force: true });
    console.log(fails ? '== ' + fails + ' failed' : '== all passed');
    process.exit(fails ? 1 : 0);
})();
