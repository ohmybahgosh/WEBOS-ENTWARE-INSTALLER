/* The phone dashboard (server.js serves it).  Sign in with the code on the
   TV, or the QR code's #k=, then add, set up and remove add-ons, and see
   or change the services' passwords. */
(function () {
    'use strict';
    var token = '';
    var data = null;
    var polling = null;
    var NAMES = { add: 'Add', remove: 'Remove', password: 'New password for' };

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

    function call(method, url, body) {
        return fetch(url, {
            method: method,
            headers: { 'Content-Type': 'application/json', 'X-Token': token },
            body: body ? JSON.stringify(body) : undefined,
            cache: 'no-store'
        }).then(function (r) {
            return r.json().catch(function () { return {}; }).then(function (j) {
                if (r.status === 401 && url !== '/api/login') { signedOut(); throw new Error('Please sign in again.'); }
                if (!r.ok) { throw new Error(j.error || ('Error ' + r.status)); }
                return j;
            });
        });
    }

    function show(which) {
        $('login').hidden = which !== 'login';
        $('dash').hidden = which !== 'dash';
        $('out').hidden = which !== 'dash';
    }
    function signedOut() {
        token = ''; store('');
        show('login');
        $('code').focus();
    }
    function signIn(code) {
        $('login-msg').textContent = '';
        return call('POST', '/api/login', { code: code }).then(function (j) {
            token = j.token; store(token);
            show('dash');
            refresh();
        }, function (e) { show('login'); $('login-msg').textContent = e.message; });
    }

    function msg(text, ok) {
        var m = $('dash-msg');
        m.textContent = text || '';
        m.className = 'msg' + (ok ? ' ok' : '');
    }

    function refresh() {
        return call('GET', '/api/state').then(function (s) {
            data = s;
            var tv = s.tv.model ? s.tv.model + ' · ' + s.tv.webos + (s.tv.release ? ' (' + s.tv.release + ')' : '') : 'on your LG TV';
            $('tv').textContent = tv + (s.entware.freeMB !== undefined && s.entware.freeMB !== null ? ' · ' + s.entware.freeMB + ' MB free' : '');
            render();
            if (s.entware.job === 'running') { follow(); }
        }, function (e) { msg(e.message); });
    }

    function pill(a) {
        if (a.state === 'installed') { return el('span', 'pill pill-ok', a.service ? 'Running' : (a.removable ? 'Installed' : 'Included')); }
        if (a.state === 'needsSetup') { return el('span', 'pill pill-warn', a.id === 'tailscale' ? 'Sign in' : 'Finish setup'); }
        return el('span', 'pill pill-off', 'Not added');
    }

    function button(text, cls, fn) {
        var b = el('button', cls || '', text);
        b.type = 'button';
        b.addEventListener('click', fn);
        return b;
    }

    function task(action, a) {
        var what = action === 'add' ? (a.state === 'notInstalled' ? 'Add ' + a.title + '?' : 'Finish setting up ' + a.title + '?') : 'Remove ' + a.title + '?';
        var more = action === 'remove' ? (a.service ? '\n\nIts settings and password are deleted.  Your files in /opt/files stay.' : '') :
            (a.system && a.state === 'notInstalled' ? '\n\nwebOS already has its own at ' + a.system + '.  This adds Entware\'s too.' : '');
        if (!window.confirm(what + more)) { return; }
        msg('');
        call('POST', '/api/task', { action: action, id: a.id }).then(follow, function (e) { msg(e.message); });
    }

    function follow() {
        if (polling) { return; }
        $('task').hidden = false;
        var tick = function () {
            call('GET', '/api/task').then(function (j) {
                var m = /^(add|remove|password|pkg-add|pkg-remove|upgrade) ?(.*)$/.exec(j.name || '');
                $('task-title').textContent = (m ? (NAMES[m[1]] || m[1]) + ' ' + m[2] : (j.name || 'Task')) + (j.state === 'running' ? '…' : (j.exit === 0 ? ': done' : ': didn\'t finish'));
                $('task-log').textContent = (j.log || []).slice(-14).join('\n');
                if (j.state !== 'running') {
                    clearInterval(polling); polling = null;
                    refresh();
                }
            }, function () { clearInterval(polling); polling = null; });
        };
        polling = setInterval(tick, 1500);
        tick();
    }

    function loginBox(info) {
        var box = el('div', 'login'), shown = false;
        var u = el('div'); u.appendChild(el('span', '', 'User')); u.appendChild(el('code', '', info.user));
        var p = el('div'); p.appendChild(el('span', '', 'Password'));
        var code = el('code', '', '••••••••••••');
        p.appendChild(code);
        p.appendChild(button('Show', 'link', function (e) {
            shown = !shown;
            code.textContent = shown ? info.password : '••••••••••••';
            e.target.textContent = shown ? 'Hide' : 'Show';
        }));
        if (navigator.clipboard) {
            p.appendChild(button('Copy', 'link', function (e) {
                navigator.clipboard.writeText(info.password).then(function () { e.target.textContent = 'Copied'; }, function () { /* not allowed */ });
            }));
        }
        box.appendChild(u); box.appendChild(p);
        return box;
    }

    function passwordForm(a, card) {
        var f = el('form', 'pwform');
        var p1 = el('input'), p2 = el('input');
        p1.type = p2.type = 'password';
        p1.autocomplete = p2.autocomplete = 'new-password';
        p1.placeholder = 'New password (12 or more)';
        p2.placeholder = 'Again';
        var go = el('button', '', 'Set password');
        go.type = 'submit';
        f.appendChild(p1); f.appendChild(p2); f.appendChild(go);
        f.appendChild(el('p', 'dim', 'Letters, numbers and . _ @ # % + = : , ? ~ ! ^ -'));
        f.addEventListener('submit', function (e) {
            e.preventDefault();
            if (p1.value !== p2.value) { msg('The two passwords don\'t match.'); return; }
            setPassword(a, p1.value, go);
        });
        card.appendChild(f);
        return f;
    }
    function setPassword(a, value, btn) {
        if (!value && !window.confirm('Make a new password for ' + a.title + '?  The old one stops working, and ' + a.title + ' restarts.')) { return; }
        msg(''); btn.disabled = true;
        var was = btn.textContent;
        btn.textContent = 'Changing…';
        call('POST', '/api/password', { id: a.id, password: value || '' }).then(function () {
            msg('Changed the password for ' + a.title + '.', true);
            refresh();
        }, function (e) { msg(e.message); btn.disabled = false; btn.textContent = was; });
    }

    function serviceCard(a) {
        var card = el('div', 'card');
        var head = el('div', 'card-head');
        head.appendChild(el('b', '', a.title));
        head.appendChild(pill(a));
        card.appendChild(head);
        var info = a.info || {};
        if (a.state === 'notInstalled') {
            card.appendChild(el('p', '', a.about + '.'));
        } else {
            (info.lines || []).forEach(function (l) { card.appendChild(el('p', '', l)); });
            if (info.user) { card.appendChild(loginBox(info)); }
        }
        var row = el('div', 'row');
        if (a.state === 'notInstalled') {
            row.appendChild(button('Add', '', function () { task('add', a); }));
        } else {
            if (info.url) {
                var open = el('a', 'btn', a.id === 'tailscale' ? 'Sign in to Tailscale' : 'Open');
                open.href = info.url; open.target = '_blank'; open.rel = 'noreferrer';
                row.appendChild(open);
            }
            if (a.state === 'needsSetup') { row.appendChild(button(a.id === 'tailscale' ? 'New sign-in link' : 'Finish setup', 'ghost', function () { task('add', a); })); }
            if (info.user) {
                var form = null;
                row.appendChild(button('New password', 'ghost', function (e) { setPassword(a, '', e.target); }));
                row.appendChild(button('Set my own', 'ghost', function () {
                    form = form || passwordForm(a, card);
                    form.className = form.className.indexOf('open') >= 0 ? 'pwform' : 'pwform open';
                }));
            }
            row.appendChild(button('Remove', 'danger', function () { task('remove', a); }));
        }
        card.appendChild(row);
        return card;
    }

    function toolRow(a) {
        var r = el('div', 'tool');
        var t = el('div');
        t.appendChild(el('b', '', a.title));
        t.appendChild(el('small', '', a.about + (a.system && a.state === 'notInstalled' ? '.  webOS already has one.' : '')));
        r.appendChild(t);
        if (!a.removable && a.state === 'installed') { r.appendChild(pill(a)); }
        else if (a.state === 'notInstalled') { r.appendChild(button('Add', '', function () { task('add', a); })); }
        else if (a.state === 'needsSetup') { r.appendChild(button('Finish setup', 'ghost', function () { task('add', a); })); }
        else { r.appendChild(button('Remove', 'danger', function () { task('remove', a); })); }
        return r;
    }

    function render() {
        var s = $('services'), t = $('tools');
        s.textContent = ''; t.textContent = '';
        data.addons.forEach(function (a) {
            if (a.service) { s.appendChild(serviceCard(a)); } else { t.appendChild(toolRow(a)); }
        });
    }

    $('login-form').addEventListener('submit', function (e) { e.preventDefault(); signIn($('code').value); });
    $('out').addEventListener('click', function () { call('POST', '/api/logout').catch(function () {}).then(signedOut); });

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
