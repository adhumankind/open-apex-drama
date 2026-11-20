import os
from PIL import Image

# 尺寸规格列表 (iOS 官方 AppIcon.appiconset 规范)
SPECS = [
    ('Icon-App-20x20@1x.png', (20, 20)),
    ('Icon-App-20x20@2x.png', (40, 40)),
    ('Icon-App-20x20@3x.png', (60, 60)),
    ('Icon-App-29x29@1x.png', (29, 29)),
    ('Icon-App-29x29@2x.png', (58, 58)),
    ('Icon-App-29x29@3x.png', (87, 87)),
    ('Icon-App-40x40@1x.png', (40, 40)),
    ('Icon-App-40x40@2x.png', (80, 80)),
    ('Icon-App-40x40@3x.png', (120, 120)),
    ('Icon-App-60x60@2x.png', (120, 120)),
    ('Icon-App-60x60@3x.png', (180, 180)),
    ('Icon-App-76x76@1x.png', (76, 76)),
    ('Icon-App-76x76@2x.png', (152, 152)),
    ('Icon-App-83.5x83.5@2x.png', (167, 167)),
    ('Icon-App-1024x1024@1x.png', (1024, 1024)),
]

src_path = r'C:\Users\AD\.gemini\antigravity\brain\47c92c70-669b-4aca-bb53-bc99ff148b3c\red_crystal_app_icon_perfect_bleed_1795138607767.jpg'
master_img = Image.open(src_path).convert('RGB')
print(f"Master image size: {master_img.size}, mode: {master_img.mode}")

iconset_dir = r'd:\zcode项目\红果苹果\ios\Runner\Assets.xcassets\AppIcon.appiconset'
os.makedirs(iconset_dir, exist_ok=True)

for filename, size in SPECS:
    resized = master_img.resize(size, Image.Resampling.LANCZOS)
    out_file = os.path.join(iconset_dir, filename)
    resized.save(out_file, format='PNG')
    print(f"Generated {filename} -> {size}")

# 同步更新应用内 assets/images/logo.png
logo_path = r'd:\zcode项目\红果苹果\assets\images\logo.png'
master_img.save(logo_path, format='PNG')
print(f"Updated application logo at {logo_path}")
