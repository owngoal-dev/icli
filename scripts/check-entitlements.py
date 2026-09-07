#!/usr/bin/env python3
"""Keep the complete documented signing profile aligned with the plist."""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
profile = plistlib.loads((root / 'Resources/icli.entitlements').read_bytes())
document = (root / 'docs/entitlements.md').read_text()
rows = {}
for line in document.splitlines():
    if not line.startswith('| `'):
        continue
    columns = line.split('|')
    key = columns[1].strip().strip('`')
    assert key not in rows, 'duplicate entitlement documentation: ' + key
    rows[key] = re.findall(r'`([^`]+)`', columns[2])
assert set(rows) == set(profile), f'entitlement inventory differs: {set(rows) ^ set(profile)}'
for key, value in profile.items():
    expected = value if isinstance(value, list) else [str(value).lower() if isinstance(value, bool) else value]
    assert rows[key] == expected, f'incorrect documented value for {key}: {rows[key]}'
print(f'PASS all {len(profile)} entitlements and exact values documented')
