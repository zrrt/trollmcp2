# 生成 TrollAgent 图标主题变体（blue / original / white / outset）
# 基于现有巨魔蓝 AppIcon 做 HSL 变换，产出 60@2x / 60@3x / 1024 三档
import io, os
from PIL import Image, ImageEnhance, ImageOps

BASE = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Resources'
SRC_2X = os.path.join(BASE, 'AppIcon60x60@2x.png')   # 120
SRC_3X = os.path.join(BASE, 'AppIcon60x60@3x.png')   # 180
SRC_1024 = os.path.join(BASE, 'AppIcon1024x1024.png')

def hsv_variant(img, dh=0, ds=0, dv=0):
    """按 HSL 偏移生成变体（仅处理非透明像素）"""
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    px = img.load()
    op = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            import colorsys
            h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            h = (h + dh) % 1.0
            s = max(0.0, min(1.0, s + ds))
            v = max(0.0, min(1.0, v + dv))
            rr, gg, bb = colorsys.hsv_to_rgb(h, s, v)
            op[x, y] = (int(rr * 255), int(gg * 255), int(bb * 255), a)
    return out

def white_variant(img, strength=0.85):
    """向白色方向混合（浅色主题）"""
    out = Image.new('RGBA', img.size, (0, 0, 0, 0))
    px = img.load()
    op = out.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            # 白色混合：主色保留一点，其余拉亮
            nr = int(r + (255 - r) * strength)
            ng = int(g + (255 - g) * strength)
            nb = int(b + (255 - b) * strength)
            op[x, y] = (nr, ng, nb, a)
    return out

def dark_variant(img, factor=0.45, sat_boost=0.15):
    """深色变体：压暗 + 提饱和（深蓝主题）"""
    return hsv_variant(img, dh=0, ds=sat_boost, dv=-factor)

def make(src_path, out_path, mode):
    img = Image.open(src_path).convert('RGBA')
    if mode == 'original':
        out = hsv_variant(img, dh=0.02, ds=-0.05, dv=0.03)  # 轻微色相偏移
    elif mode == 'white':
        out = white_variant(img, strength=0.82)
    elif mode == 'outset':
        out = dark_variant(img, factor=0.38, sat_boost=0.10)
    else:  # blue = 原样
        out = img.copy()
    out.save(out_path, 'PNG')
    return out.size

themes = ['blueIcon', 'originalIcon', 'whiteIcon', 'outsetIcon']
for t in themes:
    for suffix, src in [('60x60@2x', SRC_2X), ('60x60@3x', SRC_3X), ('1024x1024', SRC_1024)]:
        if t == 'blueIcon':
            # blue 直接用原文件复制
            continue
        mode = t.replace('Icon', '')
        out_path = os.path.join(BASE, f'{t}-{suffix}.png')
        size = make(src, out_path, mode)
        print(f'{t}-{suffix}.png {size[0]}x{size[1]}')

# blue 套复制
for suffix, src in [('60x60@2x', SRC_2X), ('60x60@3x', SRC_3X), ('1024x1024', SRC_1024)]:
    dst = os.path.join(BASE, f'blueIcon-{suffix}.png')
    if not os.path.exists(dst):
        img = Image.open(src).convert('RGBA')
        img.save(dst, 'PNG')
        print(f'blueIcon-{suffix}.png copied')
print('DONE')
