"""Draw every measured target onto its screenshot so marker placement can be
checked by eye before the deck is built.

    python tools/training-deck/check_overlays.py [out_dir]
"""
import json, sys, pathlib
from PIL import Image, ImageDraw

SHOTS = pathlib.Path(__file__).resolve().parents[2] / 'docs/training/diecast/shots'
import tempfile
out = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(tempfile.gettempdir()) / 'training-deck-overlay'
out.mkdir(parents=True, exist_ok=True)
for j in sorted(SHOTS.glob('*.json')):
    shot = json.loads(j.read_text(encoding='utf-8'))
    im = Image.open(SHOTS / shot['image']).convert('RGB')
    d = ImageDraw.Draw(im)
    for name, r in shot['targets'].items():
        d.rectangle([r['x'], r['y'], r['x'] + r['w'], r['y'] + r['h']], outline=(255, 180, 0), width=2)
        d.text((r['x'] + 3, r['y'] + 2), name, fill=(255, 60, 60))
    im.save(out / shot['image'])
    print(out / shot['image'])
