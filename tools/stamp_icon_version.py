#!/usr/bin/env python3
"""
把版本号合成到 App 图标右下角。
用法：
    python tools/stamp_icon_version.py \
        --input app/TrollVNC/TrollVNC/Assets.xcassets/AppIcon.appiconset/AppIcon-base.png \
        --output app/TrollVNC/TrollVNC/Assets.xcassets/AppIcon.appiconset/AppIcon.png \
        --version 4.41
"""
import argparse
import os
import sys
from PIL import Image, ImageDraw, ImageFont


FONT_CANDIDATES = [
    # Windows
    r"C:\Windows\Fonts\arialbd.ttf",
    r"C:\Windows\Fonts\msyhbd.ttc",
    # macOS
    "/System/Library/Fonts/Helvetica.ttc",
    "/System/Library/Fonts/Avenir.ttc",
    "/Library/Fonts/Arial Bold.ttf",
    # Linux
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    "/usr/share/fonts/truetype/freefont/FreeSansBold.ttf",
]


def find_font(size: int):
    for path in FONT_CANDIDATES:
        if path and os.path.isfile(path):
            try:
                return ImageFont.truetype(path, size=size)
            except Exception:
                pass
    return ImageFont.load_default()


def stamp_version(input_path: str, output_path: str, version: str) -> None:
    img = Image.open(input_path).convert("RGBA")
    w, h = img.size

    # 比例尺寸（以高为基准，适配不同分辨率图标）
    font_size = max(12, int(h * 0.055))
    badge_h = max(22, int(h * 0.085))
    padding = max(6, int(h * 0.045))
    inner_pad = max(4, int(badge_h * 0.22))
    radius = int(badge_h * 0.35)

    font = find_font(font_size)

    text = f"v{version}"
    draw = ImageDraw.Draw(img)
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]

    badge_w = text_w + inner_pad * 2
    badge_x = w - badge_w - padding
    badge_y = h - badge_h - padding

    # 深色半透明胶囊
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)
    overlay_draw.rounded_rectangle(
        [badge_x, badge_y, badge_x + badge_w, badge_y + badge_h],
        radius=radius,
        fill=(0, 0, 0, 185),
    )
    img = Image.alpha_composite(img, overlay)

    # 文字居中
    draw = ImageDraw.Draw(img)
    text_x = badge_x + (badge_w - text_w) // 2
    text_y = badge_y + (badge_h - text_h) // 2
    draw.text((text_x, text_y), text, font=font, fill=(255, 255, 255, 255))

    # 确保输出目录存在
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    img.save(output_path, "PNG")
    print(f"[stamp] {input_path} -> {output_path}  ({w}x{h}, version={version})")


def main():
    parser = argparse.ArgumentParser(description="Stamp version badge onto app icon")
    parser.add_argument("--input", required=True, help="Source icon PNG")
    parser.add_argument("--output", required=True, help="Output icon PNG")
    parser.add_argument("--version", required=True, help="Version string, e.g. 4.41")
    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Error: input not found: {args.input}", file=sys.stderr)
        sys.exit(1)

    stamp_version(args.input, args.output, args.version)


if __name__ == "__main__":
    main()
