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

# The TV app's "Report a problem" QR code fills in bug-report.yml by field id.
# Check every field it sets exists, and every build name it picks is an option.
import re
app = open('webos-app/src/app.js').read()
form = yaml.safe_load(open('.github/ISSUE_TEMPLATE/bug-report.yml'))
fields = {el.get('id'): el for el in form['body'] if el.get('id')}
for f in re.findall(r"'&(\w+)=' \+ q\(", app):
    if f not in fields and f != 'title':
        bad.append(f'webos-app/src/app.js: fills in "{f}", which bug-report.yml does not have')
arch = [str(o) for o in fields.get('arch', {}).get('attributes', {}).get('options', [])]
m = re.search(r"var arch = \{([^}]*)\}\[s\.build\] \|\| '([^']*)'", app)
if not m:
    bad.append('webos-app/src/app.js: could not find the build names the report picks')
else:
    for name in re.findall(r": '([^']*)'", m.group(1)) + [m.group(2)]:
        if name not in arch:
            bad.append(f'webos-app/src/app.js: build "{name}" is not an option of the arch field')

print('\n'.join(bad) or 'Issue forms look valid.')
sys.exit(1 if bad else 0)
