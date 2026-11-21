// Writes whatsnew.js for the TV app: this version's section of CHANGELOG.md,
// as { version, md, i18n: { es: md, ru: md } }, with the same section from
// each translated changelog (docs/changelog.es.md and so on), so What's new
// shows in the app's language.  As in LG-USB-2-ETH0 and FW Block.
// Usage: node gen-whatsnew.js <CHANGELOG.md> <version> <out file> [lang=changelog ...]
'use strict';
const fs = require('fs');

// One version's section of a changelog, as markdown, or '' when it has none
function section(changelog, version) {
    let text;
    try { text = fs.readFileSync(changelog, 'utf8'); } catch (e) { return ''; }
    const out = [];
    let on = false;
    for (const line of text.replace(/\r/g, '').split('\n')) {
        if (/^## /.test(line)) { if (on) { break; } on = line.startsWith('## [' + version + ']'); continue; }
        if (on) { out.push(line); }
    }
    return out.join('\n').trim();
}

// Its ### headings and how many items each has, to compare the languages
function shape(md) {
    const s = [];
    for (const line of md.split('\n')) {
        const h = line.match(/^### (.+)/);
        if (h) { s.push({ title: h[1].trim(), items: 0 }); continue; }
        if (/^- /.test(line) && s.length) { s[s.length - 1].items++; }
    }
    return s.map((x) => x.title + ':' + x.items).join(' ');
}

if (require.main === module) {
    const [changelog, version, out, ...langs] = process.argv.slice(2);
    const md = section(changelog, version);
    let data = null;
    if (md) {
        data = { version, md, i18n: {} };
        for (const arg of langs) {
            const [lang, file] = arg.split('=');
            const t = section(file, version);
            if (t) { data.i18n[lang] = t; } else { console.log(`No ${lang} section for ${version} in ${file}: What's new shows in English there`); }
        }
    }
    fs.writeFileSync(out, '// Made by gen-whatsnew.js from CHANGELOG.md\nwindow.ENTWARE_NOTES = ' + JSON.stringify(data, null, 2) + ';\n');
    console.log(data ? `Wrote ${out}` : `No CHANGELOG section for ${version}; ${out} is empty`);
}

module.exports = { section, shape };
