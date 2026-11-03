#!/usr/bin/env python3
"""Catch issue form mistakes GitHub doesn't report.  An invalid form isn't
shown as an error anywhere: GitHub quietly opens a blank issue instead, and
links that fill in the form's fields stop working."""
import glob, sys
import yaml

bad = []
for path in sorted(glob.glob('.github/ISSUE_TEMPLATE/*.yml')):
    if path.endswith('config.yml'):
        continue
    form = yaml.safe_load(open(path))
    for key in ('name', 'description', 'body'):
        if key not in form:
            bad.append(f'{path}: missing {key}')
    ids = []
    for i, el in enumerate(form.get('body') or []):
        where = f'{path}: body[{i}]'
        if 'id' in el:
            ids.append(el['id'])
        if el.get('type') == 'dropdown':
            opts = el.get('attributes', {}).get('options') or []
            if len(set(map(str, opts))) != len(opts):
                bad.append(f'{where}: options must be unique')
            for o in opts:
                if isinstance(o, bool):
                    bad.append(f'{where}: option {o!r} is a boolean, quote it')
                elif str(o).strip().lower() == 'none':
                    bad.append(f'{where}: "None" is reserved by GitHub and can\'t be an option')
    if len(set(ids)) != len(ids):
        bad.append(f'{path}: ids must be unique')

# The TV app's "Report for GitHub" QR codes fill in the forms by field id.
# Check every field each link sets exists in its form, and every value the app
# picks for a dropdown is one of its options.
import re
app = open('webos-app/src/app.js').read()
links = re.findall(r"template=([\w-]+\.yml)'(.*?);\n", app, re.S)
if not links:
    bad.append('webos-app/src/app.js: could not find the report links')
# Values the app picks from a lookup, like var arch = { ... }[s.build] || 'Not sure'
def lookup(name):
    m = re.search(r"var " + name + r" = \{([^}]*)\}\[s\.\w+\] \|\| '([^']*)'", app)
    return re.findall(r": '([^']*)'", m.group(1)) + [m.group(2)] if m else None
if not lookup('arch'):
    bad.append('webos-app/src/app.js: could not find the build names the report picks')
for template, chain in links:
    form = yaml.safe_load(open('.github/ISSUE_TEMPLATE/' + template))
    fields = {el.get('id'): el for el in form['body'] if el.get('id')}
    for f in re.findall(r"'&(\w+)=' \+ q\(", chain):
        if f not in fields and f != 'title':
            bad.append(f'webos-app/src/app.js: fills in "{f}", which {template} does not have')
    # Values given to a dropdown: literals, or a lookup table like arch
    for f, expr in re.findall(r"'&(\w+)=' \+ q\((.*?)\) \+\s*\n", chain + ' +\n', re.S):
        el = fields.get(f) or {}
        if el.get('type') != 'dropdown':
            continue
        opts = [str(o) for o in el.get('attributes', {}).get('options', [])]
        values = lookup(expr.strip()) if re.fullmatch(r'\s*\w+\s*', expr) else re.findall(r"'((?:[^'\\]|\\.)*)'", expr)
        if values is None:
            bad.append(f'webos-app/src/app.js: could not find the values the app picks for {template}\'s {f} field')
            continue
        for v in values:
            v = v.replace("\\'", "'")
            if v not in opts:
                bad.append(f'webos-app/src/app.js: "{v}" is not an option of {template}\'s {f} field')

print('\n'.join(bad) or 'Issue forms look valid.')
sys.exit(1 if bad else 0)
