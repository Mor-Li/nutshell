# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "numpy"]
# ///
"""把 icon/AppIcon-source.png（正方形图案，没有圆角）做成 macOS 的 app 图标。

做法照 macOS 图标模板：1024 的画布，图案缩到 824 居中，切成苹果那种过渡平滑的圆角方形
（超椭圆，圆角约占边长 22.5%），四周透明，底下垫一点淡阴影。再导出各个尺寸，用系统自带的
iconutil 打成 icon/AppIcon.icns，`make app` 会把它放进 app。

换图标：把新的正方形图案存成 icon/AppIcon-source.png，然后
    uv run scripts/make_icon.py
"""

import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "icon" / "AppIcon-source.png"
OUT_PNG = ROOT / "icon" / "AppIcon.png"
OUT_ICNS = ROOT / "icon" / "AppIcon.icns"

CANVAS, BODY = 1024, 824


def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """超椭圆 |x|^n + |y|^n <= 1，n=5 跟苹果图标的圆角很接近。先画 4 倍大再缩，边缘不起锯齿"""
    big = size * 4
    t = np.linspace(-1, 1, big)
    x, y = np.meshgrid(t, t)
    inside = (np.abs(x) ** n + np.abs(y) ** n) <= 1
    return Image.fromarray((inside * 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)


def main():
    art = Image.open(SOURCE).convert("RGBA").resize((BODY, BODY), Image.LANCZOS)
    mask = squircle_mask(BODY)
    art.putalpha(mask)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2

    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_body = Image.new("RGBA", (BODY, BODY), (0, 0, 0, 90))
    shadow_body.putalpha(mask.point(lambda v: v * 90 // 255))
    shadow.paste(shadow_body, (offset, offset + 10), shadow_body)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))

    canvas.paste(art, (offset, offset), art)
    canvas.save(OUT_PNG)

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for pt in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                px = pt * scale
                name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
                canvas.resize((px, px), Image.LANCZOS).save(iconset / name)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUT_ICNS)], check=True)
    print(f"✅ {OUT_PNG.relative_to(ROOT)}  {OUT_ICNS.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
