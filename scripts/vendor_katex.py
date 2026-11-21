"""把 KaTeX（网页上排数学公式的库）拉下来，整理成浮窗能直接内联的两个文件。

浮窗的网页是一整串 HTML 塞进去的，没有文件路径可依靠，所以字体不能按相对路径去找。
这里把 KaTeX 的 woff2 字体转成 base64 直接写进 CSS，产物放进 Sources/Nutshell/Resources/：
  katex.min.js           原样拷贝
  katex.inline.min.css   字体已内联的样式表

用法：uv run scripts/vendor_katex.py [版本号]，默认 0.16.22。需要本机有 npm。
"""

import base64
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

VERSION = sys.argv[1] if len(sys.argv) > 1 else "0.16.22"
OUT = Path(__file__).resolve().parent.parent / "Sources/Nutshell/Resources"

with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(["npm", "pack", f"katex@{VERSION}"], cwd=tmp, check=True, capture_output=True)
    with tarfile.open(Path(tmp) / f"katex-{VERSION}.tgz") as tar:
        tar.extractall(tmp, filter="data")
    dist = Path(tmp) / "package/dist"

    css = (dist / "katex.min.css").read_text()

    # 每个 @font-face 的 src 原本列了 woff2、woff、ttf 三份，只留 woff2，换成 data URI
    def inline(match: re.Match) -> str:
        name = match.group(1)
        data = base64.b64encode((dist / "fonts" / f"{name}.woff2").read_bytes()).decode()
        return f'src:url(data:font/woff2;base64,{data}) format("woff2")'

    css, count = re.subn(r'src:url\(fonts/(KaTeX_[A-Za-z0-9-]+)\.woff2\)[^;}]*', inline, css)
    if count == 0 or "url(fonts/" in css:
        sys.exit("KaTeX 的 CSS 格式变了，字体没替换干净，检查一下正则")

    (OUT / "katex.inline.min.css").write_text(css)
    shutil.copy(dist / "katex.min.js", OUT / "katex.min.js")
    print(f"KaTeX {VERSION}：内联了 {count} 个字体，写到 {OUT}")
