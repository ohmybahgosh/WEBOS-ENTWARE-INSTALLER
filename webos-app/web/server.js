/* The Entware phone dashboard: manage add-ons and service passwords from a
   phone or computer on the same network, like TiviBro's web editor.

   The TV app starts it ('webos-entware web start') and shows a QR code of
   http://<TV address>:<port>/#k=<code>.  Scanning it signs the phone in; the
   code is also shown on the TV for typing.  It only answers addresses on the
   home network (and Tailscale's), locks an address out for a minute after
   five wrong codes, and stops by itself after 30 minutes without use.

   Everything it changes goes through the installer, with fixed commands and
   names it checks first: 'addons --json', 'info <name> --json', 'job add
   <name>', 'job remove <name>', 'password <name> [--stdin]' and
   'job-status --json'.  A password someone types reaches the installer on
   standard input, never on a command line.

   Usage: node server.js --dir <state folder> --script <installer> [--port <n>]
   Plain ES5, for the older Node on older webOS. */
'use strict';
var http = require('http');
var fs = require('fs');
var path = require('path');
var crypto = require('crypto');
var spawn = require('child_process').spawn;

function arg(name, def) {
    var i = process.argv.indexOf('--' + name);
    return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : def;
}
var DIR = arg('dir', '');
var SCRIPT = arg('script', '');
var FIRST_PORT = +arg('port', '8095');
var IDLE_MS = +arg('idle', String(30 * 60 * 1000));
var HERE = __dirname;
if (!DIR || !SCRIPT) { console.error('Usage: node server.js --dir <folder> --script <installer> [--port <n>]'); process.exit(2); }
var CODE = String(fs.readFileSync(path.join(DIR, 'code'), 'utf8')).trim();
if (!/^[A-Z0-9]{6,16}$/.test(CODE)) { console.error('No code in ' + DIR); process.exit(2); }

var NAME = /^[a-z0-9]{1,20}$/;
var PASSWORDS = ['samba', 'filebrowser', 'transmission', 'syncthing'];
// The same characters the installer allows
var PASSWORD = /^[A-Za-z0-9._@#%+=:,?~!^-]{12,64}$/;
var tokens = {};          // token: last used
var fails = {};           // address: { n, until }
var lastUse = Date.now();
var known = [];           // add-on names from the last list

/* Codes are read off a TV across the room: look-alike characters count as
   the same, and spaces and dashes don't count */
var LOOK = { O: '0', Q: '0', I: '1', L: '1', S: '5', Z: '2', B: '8', G: '6', V: 'U' };
function fold(p) { return String(p || '').replace(/[\s-]/g, '').toUpperCase().replace(/[OQILSZBGV]/g, function (c) { return LOOK[c]; }); }
function same(a, b) {
    var x = Buffer.from(fold(a)), y = Buffer.from(fold(b));
    return x.length === y.length && crypto.timingSafeEqual(x, y);
}

// The home network, the TV itself and Tailscale's addresses, and nothing else
function local(addr) {
    var a = String(addr || '').replace(/^::ffff:/, '');
    if (a === '::1' || /^fe80:/i.test(a) || /^f[cd][0-9a-f]{2}:/i.test(a)) { return true; }
    var m = /^(\d+)\.(\d+)\.\d+\.\d+$/.exec(a);
    if (!m) { return false; }
    var x = +m[1], y = +m[2];
    return x === 10 || x === 127 || (x === 192 && y === 168) || (x === 172 && y >= 16 && y <= 31) ||
        (x === 169 && y === 254) || (x === 100 && y >= 64 && y <= 127);
}

function send(res, code, body, type) {
    var data = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body);
    res.writeHead(code, {
        'Content-Type': type || 'application/json; charset=utf-8',
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
        'X-Frame-Options': 'DENY',
        'Referrer-Policy': 'no-referrer',
        'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'"
    });
    res.end(data);
}
function readJSON(req, cb) {
    var body = '', done = false;
    req.on('data', function (d) {
        body += d;
        if (body.length > 4096 && !done) { done = true; cb(new Error('too big')); req.destroy(); }
    });
    req.on('end', function () {
        if (done) { return; }
        done = true;
        try { cb(null, JSON.parse(body || '{}')); } catch (e) { cb(e); }
    });
}

// Runs the installer: sh <script> <args>, with optional input
function run(args, input, cb) {
    var env = {};
    Object.keys(process.env).forEach(function (k) { if (k !== 'LD_PRELOAD' && k !== 'LD_LIBRARY_PATH') { env[k] = process.env[k]; } });
    env.PATH = '/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin';
    // Without input, standard input is /dev/null: luna-send gives up on a closed pipe
    var p = spawn('sh', [SCRIPT].concat(args), { env: env, cwd: '/', stdio: [input ? 'pipe' : 'ignore', 'pipe', 'pipe'] });
    var out = '', err = '', finished = false;
    var timer = setTimeout(function () { try { p.kill(); } catch (e) { /* gone */ } }, 120000);
    p.stdout.on('data', function (d) { if (out.length < 262144) { out += d; } });
    p.stderr.on('data', function (d) { if (err.length < 65536) { err += d; } });
    p.on('error', function (e) { if (!finished) { finished = true; clearTimeout(timer); cb(e, out, err); } });
    p.on('close', function (code) { if (!finished) { finished = true; clearTimeout(timer); cb(code === 0 ? null : new Error('exit ' + code), out, err); } });
    if (input) {
        p.stdin.on('error', function () { /* it didn't read */ });
        p.stdin.end(input);
    }
}
function plain(s) { return String(s || '').replace(/\x1b\[[0-9;?]*[A-Za-z]/g, '').trim(); }
function json(s) {
    var t = String(s || ''), i = t.search(/[[{]/);
    try { return i >= 0 ? JSON.parse(t.slice(i)) : null; } catch (e) { return null; }
}

// Everything the dashboard shows, in one go
function state(cb) {
    run(['addons', '--json'], '', function (e1, out1) {
        var addons = json(out1);
        if (!Array.isArray(addons)) { return cb(new Error(plain(out1) || 'Couldn\'t list the add-ons.')); }
        known = addons.map(function (a) { return a.id; });
        run(['status', '--json'], '', function (e2, out2) {
            var s = json(out2) || {};
            var want = addons.filter(function (a) { return a.service && a.state !== 'notInstalled'; });
            var left = want.length, info = {};
            function done() {
                addons.forEach(function (a) { if (info[a.id]) { a.info = info[a.id]; } });
                cb(null, {
                    tv: { model: s.model || '', webos: s.webos || '', release: s.webosRelease || '', ip: s.ip || '' },
                    entware: { version: s.version || '', packages: s.packages, freeMB: s.freeMB, location: s.location || '', job: s.job || 'none', jobName: s.jobName || '' },
                    addons: addons
                });
            }
            if (!left) { return done(); }
            want.forEach(function (a) {
                run(['info', a.id, '--json'], '', function (e3, out3) {
                    info[a.id] = json(out3);
                    if (--left === 0) { done(); }
                });
            });
        });
    });
}

function api(req, res, u, who) {
    if (u === '/api/login' && req.method === 'POST') {
        var fl = fails[who] || { n: 0, until: 0 };
        if (fl.until > Date.now()) { return send(res, 429, { error: 'Too many wrong codes.  Wait ' + Math.ceil((fl.until - Date.now()) / 1000) + ' seconds.' }); }
        return readJSON(req, function (err, j) {
            if (err || !j || typeof j.code !== 'string') { return send(res, 400, { error: 'bad request' }); }
            if (!same(j.code, CODE)) {
                fl.n++;
                if (fl.n >= 5) { fl.until = Date.now() + 60000; fl.n = 0; }
                fails[who] = fl;
                return send(res, 401, { error: 'That isn\'t the code.  It\'s on the TV, under Add-ons, Manage from your phone.' });
            }
            delete fails[who];
            var token = crypto.randomBytes(24).toString('hex');
            tokens[token] = Date.now();
            send(res, 200, { token: token });
        });
    }
    var tok = req.headers['x-token'];
    if (!tok || !tokens[tok]) { return send(res, 401, { error: 'Please sign in' }); }
    tokens[tok] = Date.now();
    if (u === '/api/state' && req.method === 'GET') {
        return state(function (e, s) { if (e) { return send(res, 500, { error: e.message }); } send(res, 200, s); });
    }
    if (u === '/api/task' && req.method === 'GET') {
        return run(['job-status', '--json'], '', function (e, out) { send(res, 200, json(out) || { state: 'none' }); });
    }
    if (u === '/api/task' && req.method === 'POST') {
        return readJSON(req, function (err, j) {
            if (err || !j || !/^(add|remove)$/.test(j.action) || !NAME.test(j.id || '') || known.indexOf(j.id) < 0) { return send(res, 400, { error: 'bad request' }); }
            run(['job', j.action, j.id], '', function (e, out, er) {
                if (e) { return send(res, 409, { error: plain(out + er) || 'It didn\'t start.' }); }
                send(res, 200, { ok: true });
            });
        });
    }
    if (u === '/api/password' && req.method === 'POST') {
        return readJSON(req, function (err, j) {
            if (err || !j || PASSWORDS.indexOf(j.id) < 0) { return send(res, 400, { error: 'bad request' }); }
            var mine = typeof j.password === 'string' && j.password !== '';
            if (mine && !PASSWORD.test(j.password)) {
                return send(res, 400, { error: 'Use 12 to 64 letters, numbers and . _ @ # % + = : , ? ~ ! ^ -' });
            }
            run(['password', j.id, '-y'].concat(mine ? ['--stdin'] : []), mine ? j.password + '\n' : '', function (e, out, er) {
                if (e) { return send(res, 409, { error: plain(out + er).split('\n').filter(function (l) { return /ERROR|WARN/.test(l); }).join(' ') || 'It didn\'t change.' }); }
                run(['info', j.id, '--json'], '', function (e2, out2) { send(res, 200, { ok: true, info: json(out2) }); });
            });
        });
    }
    if (u === '/api/logout' && req.method === 'POST') { delete tokens[tok]; return send(res, 200, { ok: true }); }
    send(res, 404, { error: 'not found' });
}

var FILES = { '/': ['index.html', 'text/html; charset=utf-8'], '/dash.js': ['dash.js', 'application/javascript; charset=utf-8'],
    '/dash.css': ['dash.css', 'text/css; charset=utf-8'], '/icon.png': ['icon.png', 'image/png'] };

var server = http.createServer(function (req, res) {
    var who = req.socket.remoteAddress || '';
    if (!local(who)) { req.destroy(); return; }
    lastUse = Date.now();
    var u = String(req.url || '/').split('?')[0];
    try {
        if (req.method === 'GET' && FILES[u]) {
            return fs.readFile(path.join(HERE, FILES[u][0]), function (err, buf) {
                if (err) { return send(res, 404, 'missing', 'text/plain'); }
                send(res, 200, buf, FILES[u][1]);
            });
        }
        if (u.indexOf('/api/') === 0) { return api(req, res, u, who); }
        send(res, 404, 'not found', 'text/plain');
    } catch (e) {
        try { send(res, 500, { error: 'server error' }); } catch (x) { /* closed */ }
    }
});

function cleanup() {
    try { fs.unlinkSync(path.join(DIR, 'port')); } catch (e) { /* gone */ }
    try { fs.unlinkSync(path.join(DIR, 'pid')); } catch (e) { /* gone */ }
}
function quit() { cleanup(); process.exit(0); }
process.on('SIGTERM', quit);
process.on('SIGINT', quit);
process.on('SIGHUP', function () { /* the app's task ending doesn't stop it */ });

// The first free port from FIRST_PORT up
var port = FIRST_PORT;
server.on('error', function (e) {
    if (e.code === 'EADDRINUSE' && port < FIRST_PORT + 9) { port++; return server.listen(port, '0.0.0.0'); }
    console.error('Couldn\'t listen: ' + (e.code || e.message));
    cleanup();
    process.exit(1);
});
server.on('listening', function () {
    fs.writeFileSync(path.join(DIR, 'pid'), String(process.pid));
    fs.writeFileSync(path.join(DIR, 'port'), String(port));
});
server.listen(port, '0.0.0.0');

// Stops after IDLE_MS without a request; sessions last 12 hours at most
setInterval(function () {
    var now = Date.now();
    Object.keys(tokens).forEach(function (t) { if (now - tokens[t] > 12 * 3600 * 1000) { delete tokens[t]; } });
    if (now - lastUse > IDLE_MS) { quit(); }
}, Math.min(15000, Math.max(1000, IDLE_MS / 3)));
