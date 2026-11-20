#!/usr/bin/env node
// Checks the TV app's translations (webos-app/src/i18n.js): every text the
// app shows has a Russian and a Spanish version with the same {placeholders},
// and every message from the installer the app shows (the full check's
// problems and notes, and the add-on address lines) matches a pattern.
// Usage: node tests/check-i18n.js
'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const SRC = path.join(ROOT, 'webos-app', 'src');
const INSTALLER = fs.readFileSync(path.join(ROOT, 'webos-entware-installer.sh'), 'utf8');

const win = { navigator: { language: 'en' }, localStorage: { getItem: () => null, setItem: () => {} } };
const load = (f) => new Function('window', fs.readFileSync(path.join(SRC, f), 'utf8'))(win);
['i18n.js', 'catalog.js', 'commands.js'].forEach(load);
const I = win.ENT_I18N;

// Every text, by where it comes from
const texts = new Map();
const add = (t, from) => { if (t && !texts.has(t)) { texts.set(t, from); } };
const app = fs.readFileSync(path.join(SRC, 'app.js'), 'utf8');
const re = /\bT\(\s*'((?:[^'\\]|\\.)*)'/g;
let m;
while ((m = re.exec(app))) { add(m[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\'), 'app.js'); }
// The phone dashboard's too: it shows in the phone's language
const WEB = path.join(ROOT, 'webos-app', 'web');
const dash = fs.readFileSync(path.join(WEB, 'dash.js'), 'utf8');
re.lastIndex = 0;
while ((m = re.exec(dash))) { add(m[1].replace(/\\'/g, "'").replace(/\\\\/g, '\\'), 'web/dash.js'); }
[[path.join(SRC, 'index.html'), 'index.html'], [path.join(WEB, 'index.html'), 'web/index.html']].forEach(([f, from]) => {
    const html = fs.readFileSync(f, 'utf8').replace(/<script[\s\S]*?<\/script>/g, '');
    html.replace(/>([^<>]+)</g, (x, t) => { t = t.trim(); if (/[A-Za-z]/.test(t) && !/^(github\.com|WEBOS-ENTWARE-INSTALLER$)/.test(t)) { add(t, from); } });
});
const C = win.ENTWARE_CATALOG;
C.cats.forEach((c) => { add(c.title, 'catalog.js'); add(c.lead, 'catalog.js'); });
Object.values(C.blurbs).forEach((b) => add(b, 'catalog.js'));
Object.values(C.tips || {}).forEach((l) => l.forEach((t) => add(t, 'catalog.js')));
Object.values(win.ENTWARE_COMMANDS).forEach((c) => {
    add(c.title, 'commands.js'); add(c.lead, 'commands.js');
    c.groups.forEach((g) => { add(g[0], 'commands.js'); g[1].forEach((r) => add(r[1], 'commands.js')); });
});
INSTALLER.split('\n').forEach((l) => {
    const a = /^[a-z0-9]+\|([^|]+)\|[^|]*\|(yes|no)\|(.+)$/.exec(l);
    if (a) { add(a[1], 'installer add-ons'); add(a[3], 'installer add-ons'); }
});
add('Auto ({lang})', 'i18n.js');

// The installer's messages, with each variable filled in with an example
const msgs = [];
// (a number where one is counted: before MB, or a count of packages)
const sample = (s) => s.replace(/\\"/g, '"').replace(/\\\\/g, '\\').replace(/\$\(\([^)]*\)\)/g, '512')
    .replace(/\$\((?:[^()]|\([^()]*\))*\)(?= MB)/g, '512').replace(/\$[A-Za-z_]+(?= package)/g, '3').replace(/\$\([^)]*\)/g, 'sh /opt/bin/webos-entware install')
    .replace(/\$\{[^}]*\}/g, '/mnt/lg/user/opt').replace(/\$[A-Za-z_][A-Za-z0-9_]*/g, '/opt/files');
INSTALLER.split('\n').forEach((l, i) => {
    let a = /^\s*(?:\[[^\]]*\]\s*(?:&&|\|\|)\s*|[a-z_]+ \|\| |.*\) )?(issue|note) "(.*)"\s*;?;?$/.exec(l) || /^\s*(issue|note) "(.*)"$/.exec(l);
    // The boot script's notes go to the boot log, which stays in English
    if (a && !/boot script started|gave up:|already mounted|^mounted|failed to mount|refused to mount|started Entware services/.test(a[2])) { msgs.push([i + 1, sample(a[2])]); }
    a = /info_line "(.*)"/.exec(l);
    if (a && a[1] !== '$AD_ABOUT.') { msgs.push([i + 1, sample(a[1])]); }
});

// The dashboard server's own messages
fs.readFileSync(path.join(WEB, 'server.js'), 'utf8').replace(/error: '((?:[^'\\]|\\.)*)'(?: \+ ([^+]+) \+ '((?:[^'\\]|\\.)*)')?/g, (x, a, v, b) => {
    a = a.replace(/\\'/g, "'");
    if (v) { msgs.push(['server.js', a + '30' + b.replace(/\\'/g, "'")]); } else { add(a, 'web/server.js'); }
});
// (and what it says when a task's output is empty)
fs.readFileSync(path.join(WEB, 'server.js'), 'utf8').replace(/\|\| '((?:[^'\\]|\\.)*)' \}/g, (x, a) => { add(a.replace(/\\'/g, "'"), 'web/server.js'); });

let fails = 0;
function fail(msg) { console.log('  FAIL ' + msg); fails++; }
const vars = (t) => (t.match(/\{(\w+)\}/g) || []).sort().join(' ');
Object.keys(I.dicts).forEach((lang) => {
    const d = I.dicts[lang];
    let missing = 0;
    texts.forEach((from, t) => {
        if (!Object.prototype.hasOwnProperty.call(d, t)) { fail(lang + ': not translated (' + from + '): ' + t); missing++; }
        else if (vars(d[t]) !== vars(t)) { fail(lang + ': placeholders differ: ' + t + ' -> ' + d[t]); }
    });
    Object.keys(d).forEach((t) => { if (!texts.has(t)) { fail(lang + ': no longer used: ' + t); } });
    const pats = I.scripts[lang];
    msgs.forEach(([line, msg]) => {
        if (!pats.some((p) => p[0].test(msg))) { fail(lang + ': installer message not translated (line ' + line + '): ' + msg); }
    });
    if (!missing) { console.log('  PASS ' + lang + ': all ' + texts.size + ' texts, and ' + msgs.length + ' installer messages'); }
});
console.log(fails ? '== ' + fails + ' failed' : '== all passed');
process.exit(fails ? 1 : 0);
