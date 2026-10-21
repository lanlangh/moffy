# 使い方: py -3 tools/process_egg_art.py <元画像.png> <出力.png>
# 例:    py -3 tools/process_egg_art.py assets/images/egg_raw/egg_blank_src.png assets/images/egg/egg_blank.png
# 必要: Pillow（pip install pillow）
# 卵画像の後処理（ecf8f23 / c8c98a6 と同じ工程）:
#   内容で切り抜き → 512キャンバスに上下14pxの余白で中央寄せ → 焦げ茶インク輪郭 #4A3B2E（約6px）を焼き込み
import sys
from PIL import Image, ImageChops, ImageFilter
src, dst = sys.argv[1], sys.argv[2]
FINAL, PAD, OUTLINE, INK = 512, 14, 6, (0x4A, 0x3B, 0x2E)
SS = 2  # 2倍で作業して最後に縮小（輪郭をなめらかに）
im = Image.open(src).convert("RGBA")
bbox = im.getchannel("A").point(lambda v: 255 if v > 20 else 0).getbbox()
im = im.crop(bbox)
target_h = (FINAL - PAD * 2 - OUTLINE * 2) * SS  # 輪郭込みで上下PADに収める
scale = target_h / im.height
work = im.resize((round(im.width * scale), target_h), Image.LANCZOS)
canvas = Image.new("RGBA", (FINAL * SS, FINAL * SS), (0, 0, 0, 0))
canvas.paste(work, ((FINAL * SS - work.width) // 2, (PAD + OUTLINE) * SS), work)
# 円形の膨張で輪郭マスクを作る
mask = canvas.getchannel("A").point(lambda v: 255 if v > 128 else 0)
r = OUTLINE * SS
dil = Image.new("L", mask.size, 0)
for dx in range(-r, r + 1):
    for dy in range(-r, r + 1):
        if dx * dx + dy * dy <= r * r:
            dil = ImageChops.lighter(dil, ImageChops.offset(mask, dx, dy))
dil = dil.filter(ImageFilter.GaussianBlur(1.2))
ink = Image.new("RGBA", mask.size, INK + (0,))
ink.putalpha(dil)
out = Image.alpha_composite(ink, canvas).resize((FINAL, FINAL), Image.LANCZOS)
out.save(dst, optimize=True)
print("saved", dst, out.size, "content bbox", out.getchannel("A").point(lambda v: 255 if v > 20 else 0).getbbox())
