# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow", "numpy", "scipy"]
# ///
"""把 icon/AppIcon-source.png 做成 macOS 的 app 图标。

原图是纯色底上画着一个图案。这里把纯色底抠掉，只留图案本身，四周透明，
不套 macOS 常见的那种圆角方块底板（2026-11-21 定的：不要外面那一圈框）。
底色取自原图四个角。抠完把图案缩到 1024 画布里居中，垫一点很淡的投影，
再导出各个尺寸，用系统自带的 iconutil 打成 icon/AppIcon.icns，`make app` 会把它放进 app。

换图标：把新的图案（纯色底、图案和底色反差够大）存成 icon/AppIcon-source.png，然后
    uv run scripts/make_icon.py
"""

import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "icon" / "AppIcon-source.png"
OUT_PNG = ROOT / "icon" / "AppIcon.png"
OUT_ICNS = ROOT / "icon" / "AppIcon.icns"

CANVAS = 1024
BODY = 900          # 图案最长边占多少，四周留一点给投影
THRESHOLD = 25      # 跟底色的颜色差超过这个就算图案


def cut_out(path: Path) -> Image.Image:
    rgb = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    h, w, _ = rgb.shape
    k = max(8, h // 100)
    bg = np.concatenate([rgb[:k, :k], rgb[:k, -k:], rgb[-k:, :k], rgb[-k:, -k:]]).reshape(-1, 3).mean(0)

    dist = np.linalg.norm(rgb - bg, axis=2)
    mask = dist > THRESHOLD
    # 去掉零星噪点，只留够大的几块（果子和气泡），再把块里的洞补上
    labels, n = ndimage.label(mask)
    sizes = ndimage.sum(mask, labels, range(1, n + 1))
    mask = np.isin(labels, 1 + np.flatnonzero(sizes > mask.size * 0.002))
    mask = ndimage.binary_fill_holes(mask)

    # 边缘柔化防锯齿，半透明的边上把混进去的底色减掉，不然白气泡会有一圈棕边
    alpha = np.asarray(Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(2))) / 255.0
    a = np.clip(alpha, 1e-3, 1)[..., None]
    fg = np.clip((rgb - (1 - a) * bg) / a, 0, 255)
    rgba = np.dstack([fg, alpha * 255]).astype(np.uint8)

    ys, xs = np.nonzero(alpha > 0.01)
    return Image.fromarray(rgba, "RGBA").crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))


def main():
    art = cut_out(SOURCE)
    scale = BODY / max(art.size)
    art = art.resize((round(art.width * scale), round(art.height * scale)), Image.LANCZOS)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = ((CANVAS - art.width) // 2, (CANVAS - art.height) // 2)

    # 投影跟着图案的形状走，不是方块
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    silhouette = Image.new("RGBA", art.size, (0, 0, 0, 0))
    silhouette.putalpha(art.getchannel("A").point(lambda v: v * 70 // 255))
    shadow.paste(silhouette, (offset[0], offset[1] + 10), silhouette)
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(12)))

    canvas.paste(art, offset, art)
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
