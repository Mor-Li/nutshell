"""把 Gemini 回答里的 Markdown 在终端里渲染出来（标题、加粗、列表、表格、代码块）。

难点是既要一边收一边显示，又不能破坏"整段对话原样留在终端里、Cmd+A 能全选"这一条。
做法是按"块"来：一个段落、一个列表、一张表、一个代码块各算一块。

- 还没收完的那一块，在屏幕最下面临时显示，随收随刷新；
- 一块收完了，把临时显示擦掉，正式渲染一遍打出来，从此不再动它。

所以已经打出去的内容只增不改，滚动历史是完整的。临时显示的那块最多占一屏
（太长就只显示末尾），这样擦的时候不会擦不干净。
"""

from __future__ import annotations

import re

from rich.console import Console, Group
from rich.live import Live
from rich.markdown import Heading, Markdown
from rich.segment import Segment
from rich.text import Text

FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
LIST_RE = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")


class _LeftHeading(Heading):
    """rich 默认把标题居中，在聊天里看着很怪，改成靠左。"""

    def __rich_console__(self, console, options):
        self.text.justify = "left"
        yield self.text


class ChatMarkdown(Markdown):
    elements = {**Markdown.elements, "heading_open": _LeftHeading}

    def __init__(self, text: str):
        # hyperlinks=False：链接显示成"文字 (网址)"，复制出去网址不会丢。
        # ansi_dark：代码高亮用终端自己的配色、不铺背景色，深色浅色主题都看得清。
        super().__init__(text, hyperlinks=False, code_theme="ansi_dark")


class _Trimmed:
    """渲染一块，去掉首尾的空行（rich 给列表、表格、代码块自带空行，块之间的空行我们自己加）。

    给了 max_lines 就只留最后几行，保证临时显示的那块不超过一屏。
    """

    def __init__(self, renderable, max_lines: int | None = None):
        self.renderable = renderable
        self.max_lines = max_lines

    def __rich_console__(self, console, options):
        lines = console.render_lines(self.renderable, options, pad=False)

        def blank(line) -> bool:
            return not "".join(segment.text for segment in line).strip()

        while lines and blank(lines[0]):
            lines.pop(0)
        while lines and blank(lines[-1]):
            lines.pop()
        if self.max_lines:
            lines = lines[-self.max_lines :]
        for line in lines:
            yield from line
            yield Segment.line()


def split_blocks(text: str) -> tuple[list[str], str]:
    """把收到的文字切成（已经收完的块，还没收完的尾巴）。

    在空行处切，但两种情况不切：代码块里面的空行；列表项之间的空行（切了的话
    有序列表的编号会从头数）。判断"下一行是不是还属于这个列表"需要看到下一行，
    所以空行后面的内容没到之前，先不切。
    """
    lines = text.split("\n")
    tail_incomplete = lines.pop()  # 最后一行还没收到换行符
    done: list[str] = []
    current: list[str] = []
    fence: str | None = None

    def next_content(index: int) -> str | None:
        for later in lines[index + 1 :]:
            if later.strip():
                return later
        # 没换行的那一行要够长才看得出是不是列表项
        return tail_incomplete if len(tail_incomplete.strip()) >= 4 else None

    for index, line in enumerate(lines):
        match = FENCE_RE.match(line)
        if fence is None and match:
            fence = match.group(1)
        elif fence is not None and match and match.group(1).startswith(fence) and line.strip() == match.group(1):
            fence = None

        if line.strip() or fence is not None:
            current.append(line)
            continue
        if not current:
            continue
        # 空行：看要不要在这里切
        if LIST_RE.match(current[0]):
            following = next_content(index)
            if following is None:
                # 还看不出来，这个空行连同后面的都留到下次再判断
                rest = lines[index:] + [tail_incomplete]
                return done, "\n".join(current + rest)
            if LIST_RE.match(following) or following.startswith((" ", "\t")):
                current.append(line)
                continue
        done.append("\n".join(current))
        current = []

    return done, "\n".join(current + [tail_incomplete])


class StreamRenderer:
    """一边收一边渲染。用法：feed(一小段文字) 反复调，最后 finish()。"""

    def __init__(self):
        self.console = Console()
        self.pending = ""
        self.printed_any = False
        self.live: Live | None = None

    def feed(self, piece: str) -> None:
        blocks, self.pending = split_blocks(self.pending + piece)
        if blocks:
            self._stop_live()
            for block in blocks:
                self._print_block(block)
        if self.pending.strip():
            if self.live is None:
                self.live = Live(console=self.console, transient=True, refresh_per_second=10)
                self.live.start()
            # 留两行余量；块前面空一行，跟上一块隔开
            height = max(self.console.size.height - 2, 5)
            body = _Trimmed(ChatMarkdown(self.pending), height)
            self.live.update(Group(Text(""), body) if self.printed_any else body)

    def finish(self) -> None:
        self._stop_live()
        if self.pending.strip():
            self._print_block(self.pending)
        self.pending = ""

    def _stop_live(self) -> None:
        if self.live is not None:
            self.live.stop()
            self.live = None

    def _print_block(self, block: str) -> None:
        if self.printed_any:
            self.console.print()
        self.console.print(_Trimmed(ChatMarkdown(block)))
        self.printed_any = True


def print_markdown(text: str) -> None:
    """一次性渲染一整段（接着上次聊时，把之前的回答打出来用）。"""
    renderer = StreamRenderer()
    renderer.feed(text + "\n\n")
    renderer.finish()
