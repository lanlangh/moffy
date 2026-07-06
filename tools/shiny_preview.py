"""色違い(shiny)確認用の書き出しスクリプト。

各 Mofi(20種 × ベビー/アダルト)に色相回転を適用し、shiny_preview/ に出力する:
  - mofi_<id>_1_shiny.png / _2_shiny.png（40枚・個別確認用）
  - _MONTAGE_babies.png / _MONTAGE_adults.png（通常｜色違いの一覧）

真の情報源はアプリ側の kShinyHueOverride
  （lib/features/collection/domain/mofi_models.dart）。本スクリプトの OVERRIDE は
  それと手動で同期する（既定150°）。色相回転は egg_visuals.dart の _shinyHueFilter と
  同一計算（feColorMatrix hue-rotate）。

使い方: python tools/shiny_preview.py
"""
import math
import os
from PIL import Image, ImageDraw, ImageFont

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MOFI = os.path.join(REPO, "assets", "images", "mofi")
OUT = os.path.join(REPO, "shiny_preview")
DEFAULT_DEG = 150.0

# kShinyHueOverride と同期（species_id: 角度）。ユーザーFBで濁る子を個別調整する。
# 参考(見せた案): critter_01 桃=300 / 青=205, dragon_02 青炎=210 / 紫炎=265。
OVERRIDE = {
    # 'critter_01': 300,
}

IDS = [f"{fam}_{i:02d}" for fam in ("slime", "critter", "dragon", "beast")
       for i in range(1, 6)]


def hue_deg(sid):
    return OVERRIDE.get(sid, DEFAULT_DEG)


def hue_matrix(deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return (0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928, 0,
            0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283, 0,
            0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072, 0)


def shiny(im, deg):
    r, g, b, al = im.split()
    sh = Image.merge("RGB", (r, g, b)).convert("RGB", hue_matrix(deg))
    return Image.merge("RGBA", (*sh.split(), al))


def montage(stage, name):
    mini, pad, lh = 104, 8, 16
    cw, ch, cols, rows = mini * 2 + pad * 3, mini + lh + pad, 4, 5
    g = Image.new("RGBA", (cw * cols, ch * rows), (0xFB, 0xF6, 0xEA, 255))
    d = ImageDraw.Draw(g)
    try:
        font = ImageFont.truetype("arial.ttf", 13)
    except Exception:
        font = ImageFont.load_default()
    for k, sid in enumerate(IDS):
        r, c = divmod(k, cols)
        x, y = c * cw, r * ch
        im = Image.open(os.path.join(MOFI, f"mofi_{sid}_{stage}.png")).convert("RGBA").resize((mini, mini), Image.LANCZOS)
        g.paste(im, (x + pad, y + pad), im)
        sh = shiny(im, hue_deg(sid))
        g.paste(sh, (x + pad * 2 + mini, y + pad), sh)
        d.text((x + pad, y + pad + mini + 1), sid, fill=(0x3A, 0x32, 0x2B), font=font)
    g.convert("RGB").save(os.path.join(OUT, name))


def main():
    os.makedirs(OUT, exist_ok=True)
    for sid in IDS:
        for st in (1, 2):
            im = Image.open(os.path.join(MOFI, f"mofi_{sid}_{st}.png")).convert("RGBA")
            shiny(im, hue_deg(sid)).save(os.path.join(OUT, f"mofi_{sid}_{st}_shiny.png"))
    montage(1, "_MONTAGE_babies.png")
    montage(2, "_MONTAGE_adults.png")
    print(f"wrote shiny_preview/ ({len(os.listdir(OUT))} files). OVERRIDE={OVERRIDE}")


if __name__ == "__main__":
    main()
