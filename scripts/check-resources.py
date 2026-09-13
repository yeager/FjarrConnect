#!/usr/bin/env python3
"""Validate localization parity, icons, and the macOS-only target contract."""
import json
import re
import struct
from pathlib import Path
root = Path(__file__).resolve().parent.parent
baseline = None
for lang in ('en', 'sv', 'da', 'nb'):
    path = root / 'Resources' / f'{lang}.lproj' / 'Localizable.strings'
    keys = re.findall(r'^"([^"]+)"\s*=', path.read_text(), re.M)
    assert len(keys) == len(set(keys)), f'Duplicate keys: {lang}'
    if baseline is None:
        baseline = set(keys)
    assert set(keys) == baseline, f'Localization mismatch: {lang}'
icon_dir = root / 'Resources/Assets.xcassets/AppIcon.appiconset'
for entry in json.loads((icon_dir / 'Contents.json').read_text())['images']:
    data = (icon_dir / entry['filename']).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', data[16:24])
    expected = int(entry['size'].split('x')[0]) * int(entry['scale'][0])
    assert width == height == expected, entry['filename']
spec = (root / 'project.yml').read_text()
assert 'ARCHS: "arm64 x86_64"' in spec
assert set(re.findall(r'platform: (\w+)', spec)) == {'macOS'}
print('Localization, icon sizes, and macOS architecture settings are valid.')
