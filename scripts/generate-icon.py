#!/usr/bin/env python3
"""Regenerate Mac icon assets from icon.svg (pip install cairosvg pillow)."""
from pathlib import Path
import json
import cairosvg
from PIL import Image
root = Path(__file__).resolve().parent.parent
cairosvg.svg2png(url=str(root / 'icon.svg'), write_to=str(root / 'icon.png'), output_width=1024, output_height=1024)
master = Image.open(root / 'icon.png')
folder = root / 'Resources/Assets.xcassets/AppIcon.appiconset'
for icon in json.loads((folder / 'Contents.json').read_text())['images']:
    size = int(icon['size'].split('x')[0]) * int(icon['scale'][0])
    master.resize((size, size), Image.Resampling.LANCZOS).save(folder / icon['filename'])
master.save(root / 'icon.icns', format='ICNS')
