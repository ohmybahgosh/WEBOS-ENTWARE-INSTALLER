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
  "job-status --json")
    # Running for the first two checks after a task starts, then done
    n=$(cat "${CALLS}.polls" 2>/dev/null || echo 9); echo $((n + 1)) > "${CALLS}.polls"
    if [ "$n" -lt 2 ]; then echo '{"state":"running","name":"add htop","exit":null,"log":["[INFO] Adding htop..."]}'
    else echo '{"state":"done","name":"add htop","exit":0,"log":["[INFO] Adding htop...","[SUCCESS] Added htop."]}'; fi ;;
  "job add"|"job remove") echo 0 > "${CALLS}.polls"; echo "Started: $2 $3." ;;
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
    check('a password with a space is refused', r.status === 400 && /12 to 64/.test(r.json.error) && calls() === '');
    r = await req('POST', '/api/password', { id: 'filebrowser', password: '-starts-with-dash' }, tok, port2);
    check('and so is one starting with -, which would read as an option', r.status === 400 && calls() === '');
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
        // As the TV's address on a home network: not a secure context, so no clipboard API
        await page.addInitScript(() => { Object.defineProperty(window, 'isSecureContext', { get: () => false }); });
        const errors = [];
        page.on('pageerror', (e) => errors.push(e.message));
        await page.goto('http://127.0.0.1:' + port2 + '/#k=ACDE3479');
        await page.waitForSelector('#services .card');
        check('the QR code\'s #k= signs in, and comes off the address', !/k=/.test(page.url()) && await page.isVisible('#dash'));
        check('it shows the TV and Entware\'s free space', /OLED65C2PUA/.test(await page.textContent('#tv')) && /1312 MB free for Entware/.test(await page.textContent('#free')));
        check('a bar jumps to Services and Tools, with how many', /Services \(3\)/.test(await page.textContent('#nav-svc')) && /Tools \(3\)/.test(await page.textContent('#nav-tools')));
        const cards = await page.$$eval('#services .card', (cs) => cs.map((c) => c.textContent));
        check('services show as running, sign in or not added', cards.some((c) => /File Browser.*Running/.test(c)) && cards.some((c) => /Tailscale.*Sign in/.test(c)) && cards.some((c) => /Samba.*Not added/.test(c)));
        check('tools on the TV come first, then the ones to add', /nano/.test(await page.textContent('#tools-have')) && /htop/.test(await page.textContent('#tools-more')) && !/htop/.test(await page.textContent('#tools-have')));
        check('a tool webOS already has says so', /webOS already has its own/.test(await page.textContent('#tools-more')));
        check('the password is hidden until you show it', !/Xk4mP9qL2vR7nT3w/.test(await page.textContent('#services')));
        await page.click('#svc-filebrowser >> text=Show password');
        check('the button says what it does, and turns into Hide password', /Hide password/.test(await page.textContent('#svc-filebrowser .login')));
        check('and Show reveals it', /Xk4mP9qL2vR7nT3w/.test(await page.textContent('#svc-filebrowser')));
        await page.click('#svc-filebrowser >> text=Copy password');
        check('Copy password works on a plain http page too', /Copied/.test(await page.textContent('#svc-filebrowser .login .chips')));
        check('the user has its own Copy, on its line', await page.$eval('#svc-filebrowser .field .value', (v) => /admin/.test(v.textContent) && /Copy/.test(v.textContent)));
        check('the password\'s buttons sit right under it, not off to a corner', await page.$eval('#svc-filebrowser .login', (l) => {
            const pw = l.querySelector('.pw').getBoundingClientRect(), b = l.querySelector('.chips button').getBoundingClientRect();
            return b.top >= pw.bottom && b.top - pw.bottom < 30 && Math.abs(b.left - pw.left) < 4;
        }));
        check('Open names the service and opens it in a new tab', await page.$eval('#svc-filebrowser a.btn', (a) => /Open File Browser/.test(a.textContent) && a.target === '_blank' && a.href === 'http://192.168.50.96:8090/'));
        check('nothing scrolls sideways on a small phone', await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
        await page.screenshot({ path: path.join(OUT, 'web-dashboard.png'), fullPage: true });

        const F = '#svc-filebrowser .pwform';
        check('the password form stays out of the way until you ask', !(await page.isVisible(F)));
        await page.click('#svc-filebrowser >> text=Change password');
        check('Change password opens it, with a random option and your own', await page.isVisible(F) && /Make a random one for me/.test(await page.textContent(F)) && /or type your own/.test(await page.textContent(F)));
        check('Save waits until the password is good', await page.$eval(F + ' button[type=submit]', (b) => b.disabled));
        await page.fill(F + ' input[type=password] >> nth=0', 'has space 1');
        check('the list says what\'s wrong as you type', await page.$$eval(F + ' .rules li', (ls) => ls[0].className === 'bad' && ls[1].className === 'bad'));
        await page.click(F + ' >> text=Show');
        check('Show shows what you typed, in both fields', await page.$$eval(F + ' input:not([hidden])', (is) => is.length === 2 && is.every((i) => i.type === 'text')) && /Hide/.test(await page.textContent(F + ' .eye')));
        const mine = 'My$own&pass|"2026"!';
        await page.fill(F + ' input >> nth=1', mine);
        await page.fill(F + ' input >> nth=2', mine + 'x');
        check('two that differ are caught', await page.$$eval(F + ' .rules li', (ls) => ls[0].className === 'ok' && ls[1].className === 'ok' && ls[2].className === 'bad') && await page.$eval(F + ' button[type=submit]', (b) => b.disabled));
        await page.fill(F + ' input >> nth=2', mine);
        await page.$eval(F, (f) => f.scrollIntoView({ block: 'center' }));
        await page.screenshot({ path: path.join(OUT, 'web-password-form.png') });
        check('and with all three right, Save is ready', !(await page.$eval(F + ' button[type=submit]', (b) => b.disabled)));
        fs.writeFileSync(CALLS, '');
        await page.click(F + ' >> text=Save my password');
        await page.waitForFunction(() => /Password changed/.test(document.getElementById('svc-filebrowser').textContent));
        check('symbols are fine, and it reaches the installer as typed', calls().indexOf('--stdin | ' + mine) >= 0);
        check('the card says it changed', /Password changed/.test(await page.textContent('#svc-filebrowser')));
        await page.waitForSelector('#svc-filebrowser .login');
        check('and the new password shows, without tapping Show', /Xk4mP9qL2vR7nT3w/.test(await page.textContent('#svc-filebrowser .login')));

        page.on('dialog', (d) => d.accept());
        await page.click('#svc-filebrowser >> text=Change password');
        await page.fill(F + ' input >> nth=1', 'fail-me-please-123');
        await page.fill(F + ' input >> nth=2', 'fail-me-please-123');
        await page.click(F + ' >> text=Save my password');
        await page.waitForFunction((f) => /It broke/.test(document.querySelector(f).textContent), F);
        check('when the TV can\'t change it, the form says why, right there', /It broke/.test(await page.textContent(F + ' .msg')) && await page.isVisible(F));
        fs.writeFileSync(CALLS, '');
        await page.click(F + ' >> text=Make a random one for me');
        for (let i = 0; i < 50 && !/^password filebrowser -y \| $/m.test(calls()); i++) { await sleep(100); }
        await page.waitForFunction(() => /Password changed/.test(document.getElementById('svc-filebrowser').textContent) && !document.querySelector('#svc-filebrowser .pwform:not([hidden])'));
        check('Make a random one for me asks first, then changes it', /^password filebrowser -y \| $/m.test(calls()));
        await page.screenshot({ path: path.join(OUT, 'web-password.png') });
        fs.writeFileSync(CALLS, '');
        await page.click('#tools-more button:has-text("Add") >> nth=0');
        await page.waitForSelector('#task:not([hidden])');
        await page.waitForFunction(() => /…/.test(document.getElementById('task-title').textContent));
        check('while a task runs, its progress shows and the other buttons wait', await page.$$eval('button.act', (bs) => bs.length > 3 && bs.every((b) => b.disabled)));
        await page.screenshot({ path: path.join(OUT, 'web-task.png') });
        await page.waitForFunction(() => /done/.test(document.getElementById('task-title').textContent), null, { timeout: 10000 });
        check('Add starts the task and follows it to the end', /^job add htop/m.test(calls()) && /Added htop/.test(await page.textContent('#task-log')));
        await page.waitForFunction(() => Array.prototype.every.call(document.querySelectorAll('button.act'), (b) => !b.disabled));
        check('then the buttons come back, and Close hides the result', await page.isVisible('#task-close'));
        await page.click('#task-close');
        check('Close hides the result', !(await page.isVisible('#task')));

        await page.click('#reload');
        await page.waitForSelector('#svc-filebrowser');
        check('Refresh reloads from the TV', (await page.$$('#services .card')).length === 3);

        await page.click('#out');
        await page.waitForSelector('#login', { state: 'visible', timeout: 3000 }).catch(() => {});
        check('Sign out goes back to the code', await page.isVisible('#login') && !(await page.isVisible('#dash')));
        await page.click('#login-go');
        check('Sign in with no code asks for it', /Enter the code/.test(await page.textContent('#login-msg')));
        await page.fill('#code', 'WRONG999');
        await page.click('#login-go');
        await page.waitForFunction(() => /isn.t the code/.test(document.getElementById('login-msg').textContent));
        check('a wrong code says where the right one is', /on the TV/.test(await page.textContent('#login-msg')));
        await page.screenshot({ path: path.join(OUT, 'web-login.png') });
        await page.fill('#code', 'acde 3479');
        await page.click('#login-go');
        await page.waitForSelector('#services .card');
        check('typing the code signs in', await page.isVisible('#dash'));

        const small = await b.newPage({ viewport: { width: 320, height: 640 } });
        small.on('pageerror', (e) => errors.push(e.message));
        await small.goto('http://127.0.0.1:' + port2 + '/#k=ACDE3479');
        await small.waitForSelector('#services .card');
        check('nothing scrolls sideways at 320 pixels either', await small.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth));
        await small.close();

        srv2.kill('SIGTERM');
        await sleep(400);
        await page.click('#reload');
        await page.waitForFunction(() => document.getElementById('dash-msg-text').textContent.length > 0);
        check('when the dashboard has stopped, it says how to get it back, where you can see it', /Can.t reach the TV/.test(await page.textContent('#dash-msg-text')) && /start it again on the TV/.test(await page.textContent('#dash-msg-text')) &&
            await page.$eval('#dash-msg', (m) => { const r = m.getBoundingClientRect(); return getComputedStyle(m).position === 'fixed' && r.top >= 0 && r.bottom <= window.innerHeight; }));
        check('no page errors', errors.length === 0);
        if (errors.length) { console.log(errors.join('\n')); }
        await b.close();
    }

    // A third one, left alone
    const srv3 = spawn(process.execPath, [path.join(WEB, 'server.js'), '--dir', DIR, '--script', FAKE, '--port', '18095', '--idle', '3000'], { stdio: 'inherit' });
    for (let i = 0; i < 50 && !fs.existsSync(path.join(DIR, 'port')); i++) { await sleep(100); }
    await sleep(5000);
    check('it stops by itself when nobody uses it', !fs.existsSync(path.join(DIR, 'port')));
    srv2.kill(); srv3.kill();
    fs.rmSync(T, { recursive: true, force: true });
    console.log(fails ? '== ' + fails + ' failed' : '== all passed');
    process.exit(fails ? 1 : 0);
})();
