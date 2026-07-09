from PIL import Image, ImageDraw, ImageFilter
RES = "C:/Users/user/Downloads/m/Moffy/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png"
OUT = "store_icon_512.png"
S = 512
bg_col = (0xEB, 0x8C, 0x58)  # #EB8C58 launcher background (一致)

img = Image.new("RGBA", (S, S), bg_col + (255,))
# ほんのり中央を明るく（奥行き・単調さ回避。ベースはランチャーと同一のテラコッタ）
glow = Image.new("L", (S, S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([S*0.12, S*0.02, S*0.88, S*0.78], fill=90)
glow = glow.filter(ImageFilter.GaussianBlur(80))
light = Image.new("RGBA", (S, S), (0xF6, 0xA9, 0x70, 255))  # 少し明るいテラコッタ
img = Image.composite(light, img, glow)

fg = Image.open(RES).convert("RGBA")
target = 452  # 512に対し余白~30px（Playの角丸で欠けない安全域）
fg = fg.resize((target, target), Image.LANCZOS)
x = (S - target) // 2
y = (S - target) // 2 - 8  # 少し上に（巣が下・卵が中央）
img.alpha_composite(fg, (x, y))

img.save(OUT, "PNG", optimize=True)  # 32-bit(RGBA/opaque)
print("saved", OUT, img.size)
