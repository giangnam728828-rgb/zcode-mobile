#!/usr/bin/env python3
"""Regenerate every launcher / splash / in-app icon from one source image.

    python3 tools/make_icons.py path/to/art.png

The source is cropped to the same square the app asset uses, then written to:

  android/app/src/main/res/mipmap-*/            legacy + adaptive launcher icons
  android/app/src/main/res/drawable*/           native launch image
  assets/brand/app_icon.png                     splash + sign-in tile
  web/icons/, web/favicon.png                   PWA icons for the web preview

Adaptive icons keep the sharp art inside the 72% safe zone and let a blurred
copy of the same art fill the rest, so no launcher mask ever shows a hard edge.
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFilter

# Face-centred square in the 1024x1024 source. Change this if the art changes.
CROP = (153, 51, 972, 870)
DENSITIES = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}


def rounded(im, radius_ratio):
    w, h = im.size
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, w - 1, h - 1], radius=int(w * radius_ratio), fill=255)
    out = im.convert('RGBA')
    out.putalpha(mask)
    return out


def circle(im):
    w, h = im.size
    mask = Image.new('L', (w, h), 0)
    ImageDraw.Draw(mask).ellipse([0, 0, w - 1, h - 1], fill=255)
    out = im.convert('RGBA')
    out.putalpha(mask)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('source', help='square-ish source image (1024px recommended)')
    ap.add_argument('--root', default=os.getcwd(), help='Flutter project root')
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    res = os.path.join(root, 'android/app/src/main/res')

    master = Image.open(args.source).convert('RGB').crop(CROP).resize(
        (1024, 1024), Image.LANCZOS)

    for name, k in DENSITIES.items():
        legacy, fore = int(48 * k), int(108 * k)
        mip = os.path.join(res, 'mipmap-%s' % name)
        os.makedirs(mip, exist_ok=True)

        rounded(master.resize((legacy, legacy), Image.LANCZOS), 0.20).save(
            os.path.join(mip, 'ic_launcher.png'))
        circle(master.resize((legacy, legacy), Image.LANCZOS)).save(
            os.path.join(mip, 'ic_launcher_round.png'))

        bg = master.resize((fore, fore), Image.LANCZOS).filter(
            ImageFilter.GaussianBlur(fore * 0.05))
        bg.save(os.path.join(mip, 'ic_launcher_background.png'))

        fg = bg.copy()
        inset = int(fore * 0.72)
        sharp = master.resize((inset, inset), Image.LANCZOS)
        m = Image.new('L', (inset, inset), 0)
        ImageDraw.Draw(m).rectangle([0, 0, inset - 1, inset - 1], fill=255)
        m = m.filter(ImageFilter.GaussianBlur(inset * 0.02))
        off = (fore - inset) // 2
        fg.paste(sharp, (off, off), m)
        fg.save(os.path.join(mip, 'ic_launcher_foreground.png'))

        drw = os.path.join(res, 'drawable-%s' % name)
        os.makedirs(drw, exist_ok=True)
        side = int(96 * k)
        rounded(master.resize((side, side), Image.LANCZOS), 0.22).save(
            os.path.join(drw, 'launch_image.png'))

    os.makedirs(os.path.join(res, 'drawable'), exist_ok=True)
    rounded(master.resize((96, 96), Image.LANCZOS), 0.22).save(
        os.path.join(res, 'drawable/launch_image.png'))

    brand = os.path.join(root, 'assets/brand')
    os.makedirs(brand, exist_ok=True)
    master.resize((512, 512), Image.LANCZOS).save(
        os.path.join(brand, 'app_icon.png'), optimize=True)

    icons = os.path.join(root, 'web/icons')
    if os.path.isdir(icons):
        master.resize((512, 512), Image.LANCZOS).convert('RGB').save(
            os.path.join(icons, 'Icon-512.png'))
        master.resize((192, 192), Image.LANCZOS).convert('RGB').save(
            os.path.join(icons, 'Icon-192.png'))
        for s in (192, 512):
            canvas = Image.new('RGB', (s, s), (124, 191, 232))
            inner = int(s * 0.72)
            canvas.paste(master.resize((inner, inner), Image.LANCZOS),
                         ((s - inner) // 2, (s - inner) // 2))
            canvas.save(os.path.join(icons, 'Icon-maskable-%d.png' % s))
        master.resize((64, 64), Image.LANCZOS).convert('RGB').save(
            os.path.join(root, 'web/favicon.png'))

    print('icons written under', root)


if __name__ == '__main__':
    main()
