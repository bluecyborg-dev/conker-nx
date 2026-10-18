#!/usr/bin/env python3
"""contact_sheet.py OUT.png FRAME.bmp... [--cols N]

Frame dumps as one labelled image (320x240 thumbnails, 6 per row by default),
so a run's progress can be reviewed in one look: which scene each dump shows,
where a load or a cutscene starts. Needs Pillow (.venv/bin/python -I).

    ls run/live/d | grep -v fxaa | awk 'NR%5==0' | sed 's|^|run/live/d/|' \\
        | xargs .venv/bin/python -I tools/contact_sheet.py /tmp/sheet.png
"""
import argparse
from PIL import Image, ImageDraw

W, H, LABEL = 320, 240, 14


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("frames", nargs="+")
    ap.add_argument("--cols", type=int, default=6)
    a = ap.parse_args()
    rows = (len(a.frames) + a.cols - 1) // a.cols
    sheet = Image.new("RGB", (W * a.cols, (H + LABEL) * rows), "gray")
    d = ImageDraw.Draw(sheet)
    for i, f in enumerate(a.frames):
        x, y = (i % a.cols) * W, (i // a.cols) * (H + LABEL)
        sheet.paste(Image.open(f).convert("RGB").resize((W, H)), (x, y + LABEL))
        d.text((x + 2, y + 1), f.split("/")[-1], fill="white")
    sheet.save(a.out)


if __name__ == "__main__":
    main()
