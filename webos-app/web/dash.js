/* The phone dashboard (server.js serves it).  Sign in with the code on the
   TV, or the QR code's #k=, then add, set up and remove add-ons, and see
   or change the services' passwords. */
(function () {
    'use strict';
    var token = '';
    var data = null;
    var polling = null;
    var busy = false;          // a task runs, or a change is on its way: buttons wait
    var reveal = {};           // services whose password shows (just changed, or Show)
    var NAMES = { add: 'Add', remove: 'Remove', password: 'New password for', 'pkg-add': 'Install', 'pkg-remove': 'Remove', upgrade: 'Update' };

    function $(id) { return document.getElementById(id); }
    function el(tag, cls, text) {
        var e = document.createElement(tag);
        if (cls) { e.className = cls; }
        if (text !== undefined) { e.textContent = text; }
        return e;
    }
    function store(v) {
        try { if (v) { sessionStorage.setItem('entware.token', v); } else { sessionStorage.removeItem('entware.token'); } } catch (e) { /* private mode */ }
    }
    function stored() { try { return sessionStorage.getItem('entware.token') || ''; } catch (e) { return ''; } }

    var OFFLINE = 'Can\'t reach the TV.  Is your phone on the same Wi-Fi?  The dashboard also stops after 30 minutes without use: start it again on the TV, under Add-ons.';
    function call(method, url, body) {
        return fetch(url, {
            method: method,
            headers: { 'Content-Type': 'application/json', 'X-Token': token },
            body: body ? JSON.stringify(body) : undefined,
            cache: 'no-store'
        }).then(function (r) {
            return r.json().catch(function () { return {}; }).then(function (j) {
                if (r.status === 401 && url !== '/api/login') { signedOut('Signed out.  Enter the code on the TV to sign in again.'); throw new Error(''); }
                if (!r.ok) { throw new Error(j.error || ('Something went wrong (' + r.status + ').')); }
                return j;
            });
        }, function () { throw new Error(OFFLINE); });
    }

    function show(which) {
        $('login').hidden = which !== 'login';
        $('dash').hidden = which !== 'dash';
        $('out').hidden = which !== 'dash';
        $('reload').hidden = which !== 'dash';
    }
    function signedOut(why) {
        token = ''; store('');
        clearInterval(polling); polling = null;
        show('login');
        $('login-msg').textContent = why || '';
        $('code').value = '';
    }
    function signIn(code) {
        var go = $('login-go');
        $('login-msg').textContent = '';
        if (!code.replace(/[\s-]/g, '')) { $('login-msg').textContent = 'Enter the code shown on the TV.'; return; }
        go.disabled = true; go.textContent = 'Signing in…';
        return call('POST', '/api/login', { code: code }).then(function (j) {
            token = j.token; store(token);
            show('dash');
            refresh();
        }, function (e) { show('login'); $('login-msg').textContent = e.message; })
            .then(function () { go.disabled = false; go.textContent = 'Sign in'; });
    }

    function msg(text, ok) {
        var m = $('dash-msg');
        m.textContent = text || '';
        m.className = 'msg' + (ok ? ' ok' : '');
        if (text) { m.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); }
    }

    function refresh() {
        if (!data) { $('loading').hidden = false; }
        return call('GET', '/api/state').then(function (s) {
            data = s;
            $('loading').hidden = true;
            var tv = s.tv.model ? s.tv.model + ' · ' + s.tv.webos + (s.tv.release ? ' (' + s.tv.release + ')' : '') : 'on your LG TV';
            $('tv').textContent = tv;
            $('free').textContent = s.entware.freeMB !== undefined && s.entware.freeMB !== null ? s.entware.freeMB + ' MB free for Entware' : '';
            busy = s.entware.job === 'running';
            render();
            if (busy) { follow(); }
        }, function (e) { $('loading').hidden = true; if (e.message) { msg(e.message); } });
    }

    function pill(a) {
        if (a.state === 'installed') { return el('span', 'pill pill-ok', a.service ? 'Running' : (a.removable ? 'Installed' : 'Included')); }
        if (a.state === 'needsSetup') { return el('span', 'pill pill-warn', a.id === 'tailscale' ? 'Sign in' : 'Finish setup'); }
        return el('span', 'pill pill-off', 'Not added');
    }

    // Buttons that change something wait while anything else runs
    function button(text, cls, fn, keep) {
        var b = el('button', cls || '', text);
        b.type = 'button';
        if (!keep) { b.className += ' act'; b.disabled = busy; }
        b.addEventListener('click', fn);
        return b;
    }
    function setBusy(on) {
        busy = on;
        Array.prototype.forEach.call(document.querySelectorAll('button.act'), function (b) { b.disabled = on; });
    }

    function task(action, a) {
        if (busy) { return; }
        var what = action === 'add' ? (a.state === 'notInstalled' ? 'Add ' + a.title + '?' : 'Finish setting up ' + a.title + '?') : 'Remove ' + a.title + '?';
        var more = action === 'remove' ? (a.service ? '\n\nIts settings and password are deleted.  Your files in /opt/files stay.' : '') :
            (a.system && a.state === 'notInstalled' ? '\n\nwebOS already has its own (' + a.system + ').  This adds Entware\'s too.' : '');
        if (!window.confirm(what + more)) { return; }
        msg('');
        setBusy(true);
        call('POST', '/api/task', { action: action, id: a.id }).then(function () {
            if (action === 'add' && a.service) { reveal[a.id] = true; }
            follow();
        }, function (e) { setBusy(false); msg(e.message); });
    }

    function follow() {
        if (polling) { return; }
        setBusy(true);
        $('task').hidden = false;
        document.body.className = 'has-task';
        $('task').className = 'task';
        $('task-close').hidden = true;
        var tick = function () {
            call('GET', '/api/task').then(function (j) {
                var m = /^(add|remove|password|pkg-add|pkg-remove|upgrade) ?(.*)$/.exec(j.name || '');
                var name = m ? (NAMES[m[1]] || m[1]) + ' ' + titleOf(m[2]) : (j.name || 'A task');
                var running = j.state === 'running';
                var good = j.state === 'done' && j.exit === 0;
                $('task-title').textContent = name + (running ? '…' : (good ? ': done' : ': didn\'t finish'));
                $('task-log').textContent = (j.log || []).slice(-14).join('\n');
                $('task-log').scrollTop = $('task-log').scrollHeight;
                if (!running) {
                    clearInterval(polling); polling = null;
                    $('task').className = 'task ' + (good ? 'task-ok' : 'task-bad');
                    $('task-close').hidden = false;
                    busy = false;
                    refresh();
                }
            }, function (e) {
                clearInterval(polling); polling = null;
                setBusy(false);
                if (e.message) { msg(e.message); }
            });
        };
        polling = setInterval(tick, 1500);
        tick();
    }
    function titleOf(id) {
        var a = data && data.addons.filter(function (x) { return x.id === id; })[0];
        return a ? a.title : id;
    }

    // Copies without the clipboard API, which browsers only give https pages
    function copy(text, btn) {
        var done = function () { btn.textContent = 'Copied'; setTimeout(function () { btn.textContent = 'Copy'; }, 2000); };
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(text).then(done, function () { copyOld(text, done); });
            return;
        }
        copyOld(text, done);
    }
    function copyOld(text, done) {
        var t = el('textarea');
        t.value = text;
        t.setAttribute('readonly', '');
        t.style.position = 'fixed'; t.style.opacity = '0';
        document.body.appendChild(t);
        t.select(); t.setSelectionRange(0, text.length);
        try { if (document.execCommand('copy')) { done(); } } catch (e) { /* not allowed */ }
        document.body.removeChild(t);
    }

    function loginBox(a, info) {
        var box = el('div', 'login');
        var u = el('div'); u.appendChild(el('span', '', 'User')); u.appendChild(el('code', '', info.user));
        var p = el('div'); p.appendChild(el('span', '', 'Password'));
        var code = el('code', '', reveal[a.id] ? info.password : '••••••••••••');
        p.appendChild(code);
        box.appendChild(u); box.appendChild(p);
        var tools = el('div', 'login-tools');
        tools.appendChild(button(reveal[a.id] ? 'Hide' : 'Show', 'link', function (e) {
            reveal[a.id] = !reveal[a.id];
            code.textContent = reveal[a.id] ? info.password : '••••••••••••';
            e.target.textContent = reveal[a.id] ? 'Hide' : 'Show';
        }, true));
        tools.appendChild(button('Copy', 'link', function (e) { copy(info.password, e.target); }, true));
        box.appendChild(tools);
        return box;
    }

    function passwordForm(a, user) {
        var f = el('form', 'pwform');
        // The service's user, for password managers (and screen readers)
        var u = el('input');
        u.type = 'text'; u.autocomplete = 'username'; u.value = user || ''; u.readOnly = true; u.hidden = true;
        u.setAttribute('aria-hidden', 'true');
        f.appendChild(u);
        var p1 = el('input'), p2 = el('input');
        p1.type = p2.type = 'password';
        p1.autocomplete = p2.autocomplete = 'new-password';
        p1.placeholder = 'New password (12 or more characters)';
        p2.placeholder = 'Type it again';
        p1.setAttribute('aria-label', 'New password'); p2.setAttribute('aria-label', 'New password again');
        f.appendChild(p1); f.appendChild(p2);
        f.appendChild(el('p', 'dim small', 'Letters, numbers and . _ @ # % + = : , ? ~ ! ^ -'));
        var row = el('div', 'row');
        var go = el('button', 'act', 'Set password');
        go.type = 'submit'; go.disabled = busy;
        row.appendChild(go);
        row.appendChild(button('Cancel', 'ghost', function () { f.hidden = true; p1.value = p2.value = ''; }, true));
        f.appendChild(row);
        f.hidden = true;
        f.addEventListener('submit', function (e) {
            e.preventDefault();
            if (p1.value.length < 12) { msg('Use at least 12 characters.'); return; }
            if (!/^[A-Za-z0-9._@#%+=:,?~!^-]+$/.test(p1.value)) { msg('Use only letters, numbers and . _ @ # % + = : , ? ~ ! ^ -'); return; }
            if (p1.value !== p2.value) { msg('The two passwords don\'t match.'); return; }
            setPassword(a, p1.value, go);
        });
        return f;
    }
    function setPassword(a, value, btn) {
        if (busy) { return; }
        if (!value && !window.confirm('Make a new password for ' + a.title + '?\n\nThe old one stops working, and ' + a.title + ' restarts for a moment.')) { return; }
        msg('');
        setBusy(true);
        btn.textContent = 'Changing…';
        call('POST', '/api/password', { id: a.id, password: value || '' }).then(function () {
            reveal[a.id] = true;
            busy = false;
            msg('Changed the password for ' + a.title + '.  It\'s shown below.', true);
            refresh();
        }, function (e) { setBusy(false); btn.textContent = value ? 'Set password' : 'New password'; if (e.message) { msg(e.message); } });
    }

    function serviceCard(a) {
        var card = el('div', 'card');
        card.id = 'svc-' + a.id;
        var head = el('div', 'card-head');
        head.appendChild(el('b', '', a.title));
        head.appendChild(pill(a));
        card.appendChild(head);
        var info = a.info || {};
        if (a.state === 'notInstalled') {
            card.appendChild(el('p', '', a.about + '.'));
        } else {
            (info.lines || []).forEach(function (l) { card.appendChild(el('p', '', l)); });
            if (info.user) { card.appendChild(loginBox(a, info)); }
        }
        var row = el('div', 'row'), form = null;
        if (a.state === 'notInstalled') {
            row.appendChild(button('Add', '', function () { task('add', a); }));
        } else {
            if (info.url) {
                var open = el('a', 'btn', a.id === 'tailscale' ? 'Sign in to Tailscale' : 'Open ' + a.title);
                open.href = info.url; open.target = '_blank'; open.rel = 'noreferrer';
                row.appendChild(open);
            }
            if (a.state === 'needsSetup') { row.appendChild(button(a.id === 'tailscale' ? 'New sign-in link' : 'Finish setup', 'ghost', function () { task('add', a); })); }
            if (info.hasPassword && a.state === 'installed') {
                form = passwordForm(a, info.user);
                row.appendChild(button('New password', 'ghost', function (e) { setPassword(a, '', e.target); }));
                row.appendChild(button('Set my own', 'ghost', function () { form.hidden = !form.hidden; if (!form.hidden) { form.querySelector('input[type=password]').focus(); } }));
            }
            row.appendChild(button('Remove', 'danger', function () { task('remove', a); }));
        }
        card.appendChild(row);
        if (form) { card.appendChild(form); }
        return card;
    }

    function toolRow(a) {
        var r = el('div', 'tool');
        var t = el('div');
        t.appendChild(el('b', '', a.title));
        t.appendChild(el('small', '', a.about + (a.system && a.state === 'notInstalled' ? '.  webOS already has its own.' : '')));
        r.appendChild(t);
        if (!a.removable && a.state === 'installed') { r.appendChild(pill(a)); }
        else if (a.state === 'notInstalled') { r.appendChild(button('Add', '', function () { task('add', a); })); }
        else if (a.state === 'needsSetup') { r.appendChild(button('Finish setup', 'ghost', function () { task('add', a); })); }
        else { r.appendChild(button('Remove', 'danger', function () { task('remove', a); })); }
        return r;
    }

    function render() {
        var s = $('services'), have = $('tools-have'), more = $('tools-more');
        s.textContent = ''; have.textContent = ''; more.textContent = '';
        var n = { svc: 0, have: 0, more: 0 };
        data.addons.forEach(function (a) {
            if (a.service) { s.appendChild(serviceCard(a)); n.svc++; }
            else if (a.state === 'notInstalled') { more.appendChild(toolRow(a)); n.more++; }
            else { have.appendChild(toolRow(a)); n.have++; }
        });
        $('nav-svc').textContent = 'Services (' + n.svc + ')';
        $('nav-tools').textContent = 'Tools (' + (n.have + n.more) + ')';
        $('h-have').hidden = !n.have;
        $('h-more').hidden = !n.more;
    }

    $('login-form').addEventListener('submit', function (e) { e.preventDefault(); signIn($('code').value); });
    $('out').addEventListener('click', function () { call('POST', '/api/logout').catch(function () {}).then(function () { signedOut(); }); });
    $('reload').addEventListener('click', function () { msg(''); refresh(); });
    $('task-close').addEventListener('click', function () { $('task').hidden = true; document.body.className = ''; });

    // The QR code's #k=CODE signs in; it comes off the address straight away
    var k = /[#&]k=([A-Za-z0-9-]+)/.exec(location.hash);
    if (k) {
        history.replaceState(null, '', location.pathname);
        signIn(k[1]);
    } else if ((token = stored())) {
        show('dash');
        refresh();
    } else {
        show('login');
    }
}());
