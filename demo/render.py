# /// script
# requires-python = ">=3.11"
# dependencies = ["playwright"]
# ///
"""把 demo.html 逐帧截图，拼成 README 用的 GIF。

动画的每一刻都由 demo.html 里的 renderAt(t) 算出来，这里按固定帧率一帧一帧地截，
再交给 ffmpeg 生成调色板、压成 GIF。浏览器用本机装的 Google Chrome，不用另外下载。

用法：
    uv run demo/render.py                       # 中英两版 GIF 都出，放进 assets/
    uv run demo/render.py --lang en             # 只出英文版
    uv run demo/render.py --banner              # 出 README 顶上的横幅图 assets/banner-<lang>.png
    uv run demo/render.py --stills 1.8,4.2,9 --out /tmp/x   # 只截这几刻的静帧看效果，不出 GIF
"""

import argparse
import subprocess
import tempfile
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
PAGE = HERE / "demo.html"
BANNER = HERE / "banner.html"
ASSETS = HERE.parent / "assets"
W, H = 1200, 750


def open_page(browser, lang: str, scale: float):
    page = browser.new_page(viewport={"width": W, "height": H}, device_scale_factor=scale)
    page.goto(f"{PAGE.as_uri()}?lang={lang}&capture=1")
    page.wait_for_function("typeof window.renderAt === 'function'")
    page.evaluate("document.fonts.ready")
    return page


def shoot(page, t: float, path: Path):
    page.evaluate(f"window.renderAt({t})")
    page.locator("#stage").screenshot(path=str(path))


def make_gif(frames: Path, fps: int, width: int, out: Path):
    # 试过几种抖动：sierra 最大（8.4MB），不抖动会在米色背景上出色带，bayer 5 又小又顺（6.2MB）
    pattern = str(frames / "f%04d.png")
    palette = frames / "palette.png"
    scale = f"fps={fps},scale={width}:-1:flags=lanczos"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", pattern,
                    "-vf", f"{scale},palettegen=max_colors=256:stats_mode=diff", str(palette)], check=True)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(fps), "-i", pattern, "-i", str(palette),
                    "-lavfi", f"{scale}[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                    "-loop", "0", str(out)], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lang", choices=["en", "zh", "both"], default="both")
    ap.add_argument("--fps", type=int, default=20)
    ap.add_argument("--width", type=int, default=880, help="GIF 的宽度（像素），880 正好是 README 正文的显示宽度")
    ap.add_argument("--stills", help="逗号分隔的时间点（秒），只截静帧")
    ap.add_argument("--banner", action="store_true", help="只出横幅图")
    ap.add_argument("--out", type=Path, default=ASSETS, help="产物放哪")
    args = ap.parse_args()
    langs = ["en", "zh"] if args.lang == "both" else [args.lang]
    args.out.mkdir(parents=True, exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        if args.banner:
            for lang in langs:
                page = browser.new_page(viewport={"width": 1280, "height": 400}, device_scale_factor=2)
                page.goto(f"{BANNER.as_uri()}?lang={lang}")
                page.evaluate("document.fonts.ready")
                out = args.out / f"banner-{lang}.png"
                page.locator("#banner").screenshot(path=str(out))
                print(out)
                page.close()
            browser.close()
            return
        for lang in langs:
            if args.stills:
                page = open_page(browser, lang, 1)
                for t in [float(x) for x in args.stills.split(",")]:
                    path = args.out / f"still-{lang}-{t:05.2f}.png"
                    shoot(page, t, path)
                    print(path)
                page.close()
                continue

            page = open_page(browser, lang, 2)   # 两倍分辨率截，再缩小，细线和小字更干净
            duration = page.evaluate("window.DURATION")
            n = round(duration * args.fps)
            with tempfile.TemporaryDirectory() as tmp:
                frames = Path(tmp)
                for i in range(n):
                    shoot(page, i / args.fps, frames / f"f{i:04d}.png")
                out = args.out / f"nutshell-demo-{lang}.gif"
                make_gif(frames, args.fps, args.width, out)
            print(f"{out}  {out.stat().st_size / 1e6:.1f} MB，{n} 帧")
            page.close()
        browser.close()


if __name__ == "__main__":
    main()
