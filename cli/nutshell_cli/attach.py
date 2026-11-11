"""把消息里拖进来的路径换成文件内容。

终端里拖文件进来，各家终端写法不一样：
- VS Code 终端：'/Users/limo/a b.pdf'        单引号包起来
- Terminal.app / iTerm：/Users/limo/a\\ b.pdf  空格前加反斜杠
- 也有用双引号的
这里三种都认。认出来、并且磁盘上真有这个东西，才算附件；不存在的原样留在文字里。

换进去的位置就是原来路径所在的位置（in place），所以"先看 A 再看 B，比较一下"
这种话发过去，顺序不会乱。

消息内容用一串 part 表示：
    {"type": "text", "text": "..."}
    {"type": "image", "path": "/abs/path", "page": None 或 PDF 页码}
图片只记路径，真正发请求时才读盘编码（见 `data_url`），这样存档小、续聊时也能重新读。
"""

from __future__ import annotations

import base64
import io
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

IMAGE_EXTS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".heif"}
PDF_EXTS = {".pdf"}
#: 这些交给 macOS 自带的 textutil 转纯文字
TEXTUTIL_EXTS = {".doc", ".docx", ".rtf", ".rtfd", ".odt", ".wordml", ".webarchive"}
#: 拖文件夹进来时跳过的目录（不在 git 仓库里时才用得上，在仓库里直接按 .gitignore 走）
SKIP_DIRS = {"node_modules", "__pycache__", ".venv", "venv", ".build", "build", "dist", ".git"}

#: 图片和 PDF 页发出去前，最长边压到多少像素。2048 看小字够清楚，又不至于一页好几兆。
MAX_SIDE = 2048
JPEG_QUALITY = 92

#: 三种写法：'单引号'、"双引号"、裸路径（以 / 或 ~/ 开头，允许 \ 转义空格）
PATH_RE = re.compile(r"""(?<!\S)(?:'([^']+)'|"([^"]+)"|((?:~/|/)(?:\\.|[^\s'"])+))""")
#: 裸路径后面跟着的中英文标点，先去掉再试一次（"看下 /a/b.md。"）
TRAILING_PUNCT = "。，,.;；:：)）]】!！?？"


@dataclass
class Expanded:
    """展开后的一条消息。没有附件时 `content` 就是原字符串。"""

    content: str | list[dict]
    #: 给人看的附件清单，每项一行
    summary: list[str] = field(default_factory=list)
    images: int = 0

    @property
    def has_attachments(self) -> bool:
        return bool(self.summary)


def expand(text: str) -> Expanded:
    parts: list[dict] = []
    summary: list[str] = []
    pos = 0
    for match in PATH_RE.finditer(text):
        path, end = _resolve(match)
        if path is None:
            continue
        _add_text(parts, text[pos : match.start()])
        _expand_path(path, parts, summary)
        pos = end
    if not summary:
        return Expanded(content=text)
    _add_text(parts, text[pos:])
    images = sum(1 for p in parts if p["type"] == "image")
    return Expanded(content=parts, summary=summary, images=images)


def _resolve(match: re.Match) -> tuple[Path | None, int]:
    """把正则命中的那段变成真实存在的路径；不存在返回 None。第二个值是这段在原文里的结束位置。"""
    if match.group(1) is not None or match.group(2) is not None:
        raw = match.group(1) if match.group(1) is not None else match.group(2)
        path = Path(raw).expanduser()
        return (path if path.exists() else None), match.end()

    # 裸路径：中文里路径后面常常直接跟标点和下文（"看下 /a/b.md。然后…"），中间没有空格。
    # 先试整段，不行再从右往左、在每个标点前面截断试一次。只在标点处截，绝不在 / 处截，
    # 不然 "/Users/limo/不存在的文件" 会被截成 "/Users/limo/" 把整个家目录附上去。
    raw = match.group(3)
    cuts = [len(raw)] + [i for i in range(len(raw) - 1, 0, -1) if raw[i] in TRAILING_PUNCT]
    for cut in cuts:
        path = Path(re.sub(r"\\(.)", r"\1", raw[:cut])).expanduser()
        if path.exists():
            return path, match.start(3) + cut
    return None, match.end()


def _add_text(parts: list[dict], text: str) -> None:
    if not text:
        return
    if parts and parts[-1]["type"] == "text":
        parts[-1]["text"] += text
    else:
        parts.append({"type": "text", "text": text})


def _expand_path(path: Path, parts: list[dict], summary: list[str]) -> None:
    path = path.resolve()
    if path.is_dir():
        files = list_dir(path)
        _add_text(parts, f'\n<folder path="{path}" files="{len(files)}">\n')
        pages = 0
        for f in files:
            pages += _expand_file(f, str(f.relative_to(path)), parts)
        _add_text(parts, "</folder>\n")
        extra = f"，含 {pages} 张图" if pages else ""
        summary.append(f"{path}/（文件夹，{len(files)} 个文件{extra}）")
    else:
        pages = _expand_file(path, str(path), parts)
        if path.suffix.lower() in PDF_EXTS:
            summary.append(f"{path}（PDF {pages} 页，按页截图）")
        else:
            summary.append(str(path))


def _expand_file(path: Path, label: str, parts: list[dict]) -> int:
    """把一个文件放进 parts，返回放了几张图。"""
    ext = path.suffix.lower()

    if ext in IMAGE_EXTS:
        _add_text(parts, f"\n[图片 {label}]\n")
        parts.append({"type": "image", "path": str(path), "page": None})
        return 1

    if ext in PDF_EXTS:
        try:
            count = pdf_page_count(path)
        except Exception as exc:  # 加密、损坏的 PDF
            _add_text(parts, f"\n[打不开 PDF {label}：{exc}]\n")
            return 0
        _add_text(parts, f'\n<pdf path="{label}" pages="{count}">\n')
        for page in range(1, count + 1):
            _add_text(parts, f"[第 {page} 页]\n")
            parts.append({"type": "image", "path": str(path), "page": page})
        _add_text(parts, "\n</pdf>\n")
        return count

    if ext in TEXTUTIL_EXTS:
        text = _textutil(path)
    else:
        text = read_text(path)
    if text is None:
        _add_text(parts, f"\n[跳过 {label}：不是文本文件]\n")
        return 0
    _add_text(parts, f'\n<file path="{label}">\n{text.rstrip()}\n</file>\n')
    return 0


def list_dir(root: Path) -> list[Path]:
    """文件夹里的所有文件。在 git 仓库里就按 git 的规矩来（.gitignore 忽略的不要），否则自己走一遍。"""
    try:
        out = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"],
            capture_output=True,
            check=True,
        ).stdout.decode("utf-8", "replace")
        files = [root / rel for rel in out.split("\0") if rel]
        return sorted(f for f in files if f.is_file() and f.name != ".DS_Store")
    except (subprocess.CalledProcessError, FileNotFoundError):
        pass

    files = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d not in SKIP_DIRS)
        files.extend(Path(dirpath) / name for name in filenames if not name.startswith("."))
    return sorted(files)


def read_text(path: Path) -> str | None:
    """能当文字读就返回文字，二进制返回 None。"""
    data = path.read_bytes()
    if b"\x00" in data[:8192]:
        return None
    for encoding in ("utf-8", "gb18030"):
        try:
            return data.decode(encoding)
        except UnicodeDecodeError:
            continue
    return None


def _textutil(path: Path) -> str | None:
    result = subprocess.run(
        ["textutil", "-convert", "txt", "-stdout", str(path)], capture_output=True
    )
    if result.returncode != 0:
        return None
    return result.stdout.decode("utf-8", "replace")


# ── 图片编码 ────────────────────────────────────────────────────────────

_cache: dict[tuple, str] = {}


def pdf_page_count(path: Path) -> int:
    import pymupdf

    with pymupdf.open(path) as doc:
        if doc.needs_pass:
            raise ValueError("有密码")
        return doc.page_count


def data_url(part: dict) -> str:
    """把一个 image part 读盘、压到 MAX_SIDE、编成 data URL。同一文件同一页只编一次。"""
    path = Path(part["path"])
    key = (str(path), part.get("page"), path.stat().st_mtime)
    if key not in _cache:
        if part.get("page"):
            image = _render_pdf_page(path, part["page"])
        else:
            image = _open_image(path)
        _cache[key] = "data:image/jpeg;base64," + base64.b64encode(_to_jpeg(image)).decode()
    return _cache[key]


def _render_pdf_page(path: Path, page_number: int):
    import pymupdf
    from PIL import Image

    with pymupdf.open(path) as doc:
        page = doc[page_number - 1]
        zoom = MAX_SIDE / max(page.rect.width, page.rect.height)
        pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
        return Image.frombytes("RGB", (pix.width, pix.height), pix.samples)


def _open_image(path: Path):
    from PIL import Image, ImageOps

    if path.suffix.lower() in {".heic", ".heif"}:
        # Pillow 不认 HEIC，先用系统自带的 sips 转成 JPEG
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "converted.jpg"
            subprocess.run(
                ["sips", "-s", "format", "jpeg", str(path), "--out", str(out)],
                capture_output=True,
                check=True,
            )
            image = Image.open(out)
            image.load()
    else:
        image = Image.open(path)
        image.seek(0)  # GIF 只取第一帧
    image = ImageOps.exif_transpose(image)
    image.thumbnail((MAX_SIDE, MAX_SIDE))
    return image


def _to_jpeg(image) -> bytes:
    from PIL import Image

    if image.mode in ("RGBA", "LA", "P"):
        image = image.convert("RGBA")
        background = Image.new("RGB", image.size, "white")
        background.paste(image, mask=image.split()[-1])
        image = background
    elif image.mode != "RGB":
        image = image.convert("RGB")
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=JPEG_QUALITY)
    return buffer.getvalue()


def text_tokens(content: str | list[dict]) -> int:
    """估这条消息的文字有多少 token（图片另算）。"""
    import tiktoken

    encoding = tiktoken.get_encoding("o200k_base")
    if isinstance(content, str):
        return len(encoding.encode(content, disallowed_special=()))
    return sum(
        len(encoding.encode(p["text"], disallowed_special=())) for p in content if p["type"] == "text"
    )
