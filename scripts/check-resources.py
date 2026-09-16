#!/usr/bin/env python3
"""Validate localization parity, icons, and the macOS-only target contract."""
import argparse
from collections import Counter
import json
import re
import struct
import subprocess
from pathlib import Path


def read_strings(path):
    """Parse our UTF-8 .strings tables without hiding malformed or duplicate entries."""
    quoted = r'"(?:[^"\\\n]|\\.)*"'
    token = re.compile(r'\s+|/\*.*?\*/|//[^\n]*|(' + quoted + r')\s*=\s*(' + quoted + r')\s*;', re.S)
    source = path.read_text(encoding='utf-8')
    result = {}
    offset = 0
    while offset < len(source):
        match = token.match(source, offset)
        assert match, f'{path}: invalid syntax at line {source[:offset].count(chr(10)) + 1}'
        if match[1]:
            key, value = json.loads(match[1]), json.loads(match[2])
            assert key not in result, f'{path}: duplicate key {key}'
            assert value.strip(), f'{path}: empty translation for {key}'
            result[key] = value
        offset = match.end()
    return result


def placeholders(value):
    # Preserve argument type, width and position; escaped percent signs consume no argument.
    tokens = re.findall(r'%%|%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hlLzjt])?[@diuoxXfFeEgGaAcCsSp]', value)
    assert ''.join(tokens).count('%') == value.count('%'), f'Invalid format placeholder: {value}'
    return Counter(token for token in tokens if token != '%%')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', type=Path, help='Also compare every compiled translation in a macOS app with its source')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
languages = {'en', 'sv', 'da', 'nb', 'de', 'fi', 'fr', 'es', 'ja'}
assert {path.stem for path in (root / 'Resources').glob('*.lproj')} == languages
for table in ('Localizable.strings', 'InfoPlist.strings'):
    baseline = read_strings(root / 'Resources/en.lproj' / table)
    for lang in sorted(languages):
        relative = Path(f'{lang}.lproj') / table
        translations = read_strings(root / 'Resources' / relative)
        assert translations.keys() == baseline.keys(), f'{relative}: missing {baseline.keys() - translations.keys()}, extra {translations.keys() - baseline.keys()}'
        for key, value in translations.items():
            assert placeholders(value) == placeholders(baseline[key]), f'{relative}: mismatched format placeholders for {key}'
        if args.app:
            compiled = args.app / 'Contents/Resources' / relative
            data = subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(compiled)])
            assert json.loads(data) == translations, f'{compiled}: packaged translations differ from source'
    print(f'{table}: {len(baseline)} strings validated in all {len(languages)} languages.')
icon_dir = root / 'Resources/Assets.xcassets/AppIcon.appiconset'
for entry in json.loads((icon_dir / 'Contents.json').read_text())['images']:
    data = (icon_dir / entry['filename']).read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    width, height = struct.unpack('>II', data[16:24])
    expected = int(entry['size'].split('x')[0]) * int(entry['scale'][0])
    assert width == height == expected, entry['filename']
spec = (root / 'project.yml').read_text()
assert 'ARCHS: "$(NATIVE_ARCH_ACTUAL)"' in spec
assert '- package: RoyalVNCKit\n        embed: true' in spec
assert set(re.findall(r'platform: (\w+)', spec)) == {'macOS'}
print('Localization, icon sizes, and macOS architecture settings are valid.')
