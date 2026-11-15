import glob, os, re
from PIL import Image, ImageDraw, ImageFont

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
files = sorted(glob.glob(f"{OUT}/option-*.png"), key=lambda p: int(re.search(r"option-(\d+)", p).group(1)))
SIZES = [512, 128, 64, 32]
PAD = 24
LABEL_W = 220
try:
    font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 26)
    small = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
except Exception:
    font = small = ImageFont.load_default()

half_w = sum(SIZES) + PAD * (len(SIZES) + 1)
row_h = 512 + PAD * 2
W = LABEL_W + half_w * 2
H = row_h * len(files) + 50
sheet = Image.new("RGB", (W, H), (255, 255, 255))
d = ImageDraw.Draw(sheet)
d.rectangle((LABEL_W + half_w, 0, W, H), fill=(30, 30, 32))
d.rectangle((0, 0, LABEL_W, H), fill=(236, 236, 240))
d.text((LABEL_W + PAD, 14), "light background: 512 / 128 / 64 / 32 px", fill=(60, 60, 60), font=small)
d.text((LABEL_W + half_w + PAD, 14), "dark background: 512 / 128 / 64 / 32 px", fill=(200, 200, 200), font=small)
for r, f in enumerate(files):
    icon = Image.open(f).convert("RGBA")
    y0 = 50 + r * row_h
    name = os.path.basename(f)[:-4].replace("option-", "")
    num, _, rest = name.partition("-")
    d.text((PAD, y0 + 230), f"{num}.", fill=(20, 20, 20), font=font)
    d.text((PAD, y0 + 266), rest, fill=(20, 20, 20), font=font)
    for half in range(2):
        x = LABEL_W + half * half_w + PAD
        for s in SIZES:
            im = icon.resize((s, s), Image.LANCZOS)
            sheet.paste(im, (x, y0 + PAD + (512 - s) // 2), im)
            x += s + PAD
sheet.save(f"{OUT}/icon-options.png")
print(sheet.size)
