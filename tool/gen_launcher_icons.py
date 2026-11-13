# Иконки запуска Tridot: три точки цветами помощников на фоне workspace.
# Цвета — из lib/core/personas/persona_palette.dart (Садо, Лиорио, Нода).
# Запуск из корня репозитория: python3 tool/gen_launcher_icons.py .
import sys
from PIL import Image, ImageDraw
root = sys.argv[1]
BG = (0x13, 0x15, 0x14, 255)
DOTS = [(0xB6, 0x9C, 0xFF, 255), (0x8E, 0xD1, 0xF2, 255), (0xF5, 0xA8, 0xCB, 255)]

def icon(size, inset=0.0, radius=0.22):
    s = 8
    big = size * s
    im = Image.new('RGBA', (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    pad = big * inset
    side = big - 2 * pad
    d.rounded_rectangle([pad, pad, big - pad - 1, big - pad - 1], radius=side * radius, fill=BG)
    # Сетка 24 знака в приложении, растянутая на 80 % плитки.
    area = side * 0.8
    k = area / 24
    ox = pad + (side - area) / 2
    oy = pad + (side - area) / 2
    for i, c in enumerate(DOTS):
        cx = ox + (5 + 7 * i) * k
        cy = oy + 12 * k
        r = 3 * k
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c)
    return im.resize((size, size), Image.LANCZOS)

for name, size in {'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192}.items():
    icon(size).save(f'{root}/android/app/src/main/res/mipmap-{name}/ic_launcher.png', optimize=True)
for size in (16, 32, 64, 128, 256, 512, 1024):
    # macOS: плитка с полями, как у системных значков (824 из 1024).
    icon(size, inset=100 / 1024).save(
        f'{root}/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{size}.png', optimize=True)
icon(256).save(f'{root}/windows/runner/resources/app_icon.ico',
               sizes=[(16, 16), (32, 32), (48, 48), (256, 256)])
