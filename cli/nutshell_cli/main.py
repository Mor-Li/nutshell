"""Nutshell 终端版：在终端里跟 Gemini 纯聊天。

就是一问一答，没有工具、没有 agent。设计上最要紧的一条：**整段对话原样留在终端
里**——不开全屏界面、不清屏、打出去的内容只增不改，这样 Cmd+A 全选复制就是完整的
聊天记录，可以直接贴给 Claude 落盘。回答里的 Markdown 会渲染好再显示（见 render.py），
`--raw` 或聊天中 `/raw` 可以改回原样打纯文字。拖进来的文件在终端里显示的是完整路径，
Claude 拿到记录也能自己去读。

后端默认走公司网关（跟 Nutshell 浮窗共用 ~/.config/nutshell/config.json 里的网关、
模型和 systemPrompt）；`--own` 或聊天中 `/own` 切到自己的 Google AI Studio key。
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from . import attach

CONFIG_DIR = Path.home() / ".config/nutshell"
CONFIG_PATH = CONFIG_DIR / "config.json"
CHATS_DIR = CONFIG_DIR / "chats"
HISTORY_PATH = CONFIG_DIR / "cli_history"

GOOGLE_BASE_URL = "https://generativelanguage.googleapis.com/v1beta/openai/"
#: 自己的 Google AI Studio key 叫这个名字，写在仓库根目录的 .env 里（.env 不进 git）
OWN_KEY_ENV = "GEMINI_AI_STUDIO_KEY_NUTSHELL"
#: 这个包是 editable 装的，所以顺着文件位置往上两层就是仓库根目录
DOTENV_PATH = Path(__file__).resolve().parents[2] / ".env"

#: 附件超过这个量先问一句再发，免得手滑把整个家目录拖进去
CONFIRM_TOKENS = 200_000
CONFIRM_IMAGES = 60

MAX_RETRIES = 6

#: 给每段对话自动起标题用的 prompt（挑历史对话时列表里显示的就是它）。
#: {opening} 会换成这段对话的开头几轮（每条只取前面一截）。
TITLE_PROMPT = """下面是一段聊天的开头几轮。给这段聊天起个简短的标题，一句话，不超过 20 个字，让我一眼看出聊的是什么。只回标题本身，别的不要说。

{opening}"""
#: 起标题只看前几轮、每条只看前面这么多字，够看出在聊什么就行。
#: 看几轮而不是只看第一句，是因为第一句常常只是"hi"。
TITLE_ROUNDS = 3
TITLE_MESSAGE_CHARS = 1500

#: 输出被重定向到文件或管道时不加颜色码，免得记录里混进乱码
DIM = "\033[2m" if sys.stdout.isatty() else ""
RESET = "\033[0m" if sys.stdout.isatty() else ""

HELP = """\
命令（只在一行开头敲才算）：
  /own        切到自己的 Google AI Studio key（仓库 .env 里的 GEMINI_AI_STUDIO_KEY_NUTSHELL）
  /work       切回公司网关
  /model 名字  换模型；不带名字就显示当前模型
  /models     列出当前这把 key 能用的 Gemini 模型
  /copy       复制上一条回答（Markdown 原文）
  /copyall    复制整段聊天记录（Markdown 原文；终端滚动历史不够长时也用它）
  /raw        开关 Markdown 渲染：关掉以后回答按原样打纯文字
  /new        开一段新对话
  /resume     列出以前的对话（带自动起的标题），上下键挑一段接着聊
  /exit       退出（Ctrl+D 也行）
回车发送，Option+回车 或 Esc 再回车 换行。粘贴多行不会被拆开发。
每收完一条回答就自动存盘。连按两次 Ctrl+C 退出，退出时会告诉你怎么接着聊。
拖文件、图片、PDF、文件夹进来，会把内容原地附上。"""


# ── 配置和后端 ──────────────────────────────────────────────────────────


def load_config() -> dict:
    config = {
        "baseURL": "https://llm-gateway.xiaoice.com/v1",
        "model": "gemini-4-argon",
        "apiKeyEnvVar": "LITELLM_API_KEY",
        "apiKey": "",
        "systemPrompt": "",
        "maxTokens": 32768,
        "temperature": 0.6,
    }
    if CONFIG_PATH.exists():
        config.update(json.loads(CONFIG_PATH.read_text()))
    return config


def read_dotenv() -> dict[str, str]:
    """读仓库根目录的 .env：一行一个 `名字=值`，值两头的引号和空格去掉。"""
    values = {}
    if DOTENV_PATH.exists():
        for line in DOTENV_PATH.read_text().splitlines():
            line = line.strip().removeprefix("export ")
            if "=" in line and not line.startswith("#"):
                name, _, value = line.partition("=")
                values[name.strip()] = value.strip().strip("'\"").strip()
    return values


def read_key(env_var: str) -> str:
    """依次找：环境变量 → 仓库 .env → 开个 zsh 去 source ~/.zshrc 再取（从别处启动时环境变量可能没带过来）。"""
    if os.environ.get(env_var):
        return os.environ[env_var]
    if read_dotenv().get(env_var):
        return read_dotenv()[env_var]
    result = subprocess.run(
        ["zsh", "-c", f'source ~/.zshrc >/dev/null 2>&1; printf %s "${env_var}"'],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


@dataclass
class Backend:
    name: str  # work / own
    label: str
    base_url: str
    key: str
    key_env: str


def make_backend(name: str, config: dict) -> Backend:
    if name == "own":
        return Backend("own", "自己的 key", GOOGLE_BASE_URL, read_key(OWN_KEY_ENV), OWN_KEY_ENV)
    key = config.get("apiKey") or read_key(config["apiKeyEnvVar"])
    return Backend("work", "公司网关", config["baseURL"], key, config["apiKeyEnvVar"])


def current_time_line() -> str:
    """跟 app 里 `LLMClient.currentTimeLine` 一个格式，照抄 Gemini 官方系统提示词那句。"""
    now = datetime.now().astimezone()
    mins = int(now.utcoffset().total_seconds() // 60)
    zone = "GMT"
    if mins:
        zone += ("+" if mins > 0 else "-") + str(abs(mins) // 60)
        if abs(mins) % 60:
            zone += f":{abs(mins) % 60:02d}"
    hour = now.hour % 12 or 12
    return f"Current time is {now:%A, %B} {now.day}, {now.year} at {hour}:{now:%M %p} {zone}."


# ── 一段对话 ────────────────────────────────────────────────────────────


class Chat:
    """一段对话。每条消息存 role、content（发给模型的，附件已展开）和 raw（用户敲的原话）。"""

    def __init__(self, path: Path | None = None):
        self.messages: list[dict] = []
        #: 模型起的标题，没起之前是空的
        self.ai_title = ""
        self._lock = threading.Lock()
        self._title_thread: threading.Thread | None = None
        self.path = path or CHATS_DIR / f"{datetime.now():%Y%m%d-%H%M%S}.json"

    @classmethod
    def load(cls, path: Path) -> Chat:
        chat = cls(path)
        data = json.loads(path.read_text())
        chat.messages = data["messages"]
        chat.ai_title = data.get("title", "")
        return chat

    @classmethod
    def saved(cls) -> list[Path]:
        """存过的所有对话，最近聊过的排最前。"""
        return sorted(CHATS_DIR.glob("*.json"), key=lambda f: f.stat().st_mtime, reverse=True)

    @classmethod
    def latest(cls) -> Chat | None:
        files = cls.saved()
        return cls.load(files[0]) if files else None

    @classmethod
    def find(cls, chat_id: str) -> Chat | None:
        """按编号找对话。编号就是存档文件名（如 20261112-020828），只敲前面一截也行。"""
        for path in cls.saved():
            if path.stem.startswith(chat_id):
                return cls.load(path)
        return None

    @property
    def id(self) -> str:
        return self.path.stem

    def title(self, width: int = 50) -> str:
        """模型起的标题；还没起的话先拿第一句话顶着。"""
        if self.ai_title:
            return self.ai_title
        for m in self.messages:
            if m["role"] == "user":
                first = " ".join(str(m.get("raw", "")).split())
                return first if len(first) <= width else first[:width] + "…"
        return "（空）"

    def save(self, backend: Backend, model: str) -> None:
        CHATS_DIR.mkdir(parents=True, exist_ok=True)
        with self._lock:
            self.path.write_text(
                json.dumps(
                    {"title": self.ai_title, "backend": backend.name, "model": model, "messages": self.messages},
                    ensure_ascii=False,
                    indent=1,
                )
            )

    def make_title(self, backend: Backend, model: str) -> None:
        """让模型给这段对话起个标题，存进存档。出错就算了，列表里会退回显示第一句话。"""
        from openai import OpenAI

        opening = "\n\n".join(
            ("我：" if m["role"] == "user" else "Gemini：") + str(m.get("raw", m["content"]))[:TITLE_MESSAGE_CHARS]
            for m in self.messages[: TITLE_ROUNDS * 2]
        )
        try:
            client = OpenAI(base_url=backend.base_url, api_key=backend.key, max_retries=2, timeout=60)
            response = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": TITLE_PROMPT.format(opening=opening)}],
                max_tokens=2048,
                # 起标题图个快，不用使劲想
                reasoning_effort="low",
            )
            title = " ".join((response.choices[0].message.content or "").split()).strip("\"'“”《》#* ")
        except Exception:
            return
        if title:
            self.ai_title = title[:60]
            mtime = self.path.stat().st_mtime if self.path.exists() else None
            self.save(backend, model)
            if mtime:  # 补标题不算"最近聊过"，排序还按原来的时间
                os.utime(self.path, (mtime, mtime))

    def title_in_background(self, backend: Backend, model: str) -> None:
        # 前几轮每聊一轮就重起一次标题（开头常常只是寒暄，聊两轮才看得出主题），之后就定下来不动了
        settled = self.ai_title and len(self.messages) > TITLE_ROUNDS * 2
        running = self._title_thread is not None and self._title_thread.is_alive()
        if settled or running:
            return
        self._title_thread = threading.Thread(target=self.make_title, args=(backend, model), daemon=True)
        self._title_thread.start()

    def wait_title(self, timeout: float = 20) -> None:
        if self._title_thread is not None:
            self._title_thread.join(timeout)

    def transcript(self) -> str:
        lines = []
        for m in self.messages:
            if m["role"] == "user":
                lines.append(f"你> {m.get('raw', m['content'])}")
            else:
                lines.append(f"Gemini>\n{m['content']}")
        return "\n\n".join(lines) + "\n"

    def api_messages(self, system_prompt: str) -> list[dict]:
        system = current_time_line()
        if system_prompt:
            system = system_prompt + "\n\n" + system
        out = [{"role": "system", "content": system}]
        for m in self.messages:
            out.append({"role": m["role"], "content": _materialize(m["content"])})
        return out


def _materialize(content: str | list[dict]) -> str | list[dict]:
    if isinstance(content, str):
        return content
    parts = []
    for p in content:
        if p["type"] == "text":
            parts.append({"type": "text", "text": p["text"]})
        elif Path(p["path"]).exists():
            parts.append({"type": "image_url", "image_url": {"url": attach.data_url(p)}})
        else:
            parts.append({"type": "text", "text": f"[图片已不在原处：{p['path']}]"})
    return parts


# ── 发请求 ──────────────────────────────────────────────────────────────


class Spinner:
    """等第一个字的时候在 stderr 上转圈。收到字就把这一行擦掉，不留在聊天记录里。"""

    def __init__(self):
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self):
        if sys.stderr.isatty():
            self._thread.start()
        else:
            self._stop.set()
        return self

    def stop(self):
        if not self._stop.is_set():
            self._stop.set()
            self._thread.join()
            sys.stderr.write("\r\033[K")
            sys.stderr.flush()

    def __exit__(self, *exc):
        self.stop()

    def _run(self):
        frames = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        start = time.time()
        i = 0
        while not self._stop.wait(0.1):
            sys.stderr.write(f"\r{DIM}{frames[i % len(frames)]} 思考中 {time.time() - start:.0f}s{RESET}")
            sys.stderr.flush()
            i += 1


class NoEcho:
    """除了「你>」等输入的时候，其余时间都关掉终端回显。

    不关的话，等回答时敲的字会直接印进回答中间，把聊天记录弄脏。关了以后敲的字不显示，
    但没丢——留在输入缓冲里，下一个「你>」出来时自动带上。Ctrl+C 照常能打断。
    「你>」那里由 prompt_toolkit 自己接管终端，用完会还原成进来时的状态（也就是不回显）。
    """

    def __init__(self):
        self._saved = None

    def off(self):
        if not sys.stdin.isatty():
            return
        import termios

        fd = sys.stdin.fileno()
        if self._saved is None:
            self._saved = termios.tcgetattr(fd)
        attrs = termios.tcgetattr(fd)
        attrs[3] &= ~termios.ECHO
        termios.tcsetattr(fd, termios.TCSADRAIN, attrs)

    def on(self):
        if self._saved is not None:
            import termios

            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, self._saved)


echo = NoEcho()


def ask(chat: Chat, backend: Backend, model: str, config: dict, render: bool) -> str:
    """把整段对话发出去，回答一边收一边打到 stdout，返回完整回答。Ctrl+C 打断时返回已收到的部分。

    render 为真时把 Markdown 渲染好再显示，否则原样打纯文字。
    """
    from openai import APIConnectionError, APIStatusError, OpenAI

    renderer = None
    if render:
        from .render import StreamRenderer

        renderer = StreamRenderer()

    client = OpenAI(base_url=backend.base_url, api_key=backend.key, max_retries=0, timeout=600)
    messages = chat.api_messages(config.get("systemPrompt", ""))
    received = ""

    for attempt in range(1, MAX_RETRIES + 1):
        spinner = Spinner()
        try:
            with spinner:
                stream = client.chat.completions.create(
                    model=model,
                    messages=messages,
                    max_tokens=config.get("maxTokens", 32768),
                    temperature=config.get("temperature", 0.6),
                    reasoning_effort="high",
                    stream=True,
                )
                for chunk in stream:
                    for choice in chunk.choices:
                        piece = choice.delta.content if choice.delta else None
                        if piece:
                            spinner.stop()
                            if renderer:
                                renderer.feed(piece)
                            else:
                                sys.stdout.write(piece)
                                sys.stdout.flush()
                            received += piece
            if renderer:
                renderer.finish()
            return received
        except KeyboardInterrupt:
            spinner.stop()
            if renderer:
                renderer.finish()
            print(f"\n{DIM}（打断了）{RESET}")
            return received
        except (APIStatusError, APIConnectionError) as exc:
            spinner.stop()
            if renderer:
                renderer.finish()
            status = getattr(exc, "status_code", None)
            retryable = status is None or status == 429 or status >= 500
            if received or not retryable or attempt == MAX_RETRIES:
                raise
            delay = min(2**attempt, 30)
            reason = "撞到限流" if status == 429 else f"出错了（{status or '连不上'}）"
            sys.stderr.write(f"{DIM}{reason}，{delay} 秒后重试（{attempt}/{MAX_RETRIES - 1}）{RESET}\n")
            time.sleep(delay)
    return received


def describe_error(exc: Exception, backend: Backend) -> str:
    status = getattr(exc, "status_code", None)
    message = getattr(exc, "message", None) or str(exc)
    hint = ""
    if status == 401 or not backend.key:
        where = f"{DOTENV_PATH} 里" if backend.name == "own" else "~/.zshrc 里"
        hint = f"\n检查一下 {where}的 {backend.key_env} 有没有设好。"
    elif status == 404:
        hint = "\n可能是模型名不对，敲 /models 看看这把 key 能用哪些。"
    return f"[{backend.label}报错] {message}{hint}"


# ── 交互 ────────────────────────────────────────────────────────────────


def make_prompt_session():
    from prompt_toolkit import PromptSession
    from prompt_toolkit.history import FileHistory
    from prompt_toolkit.key_binding import KeyBindings

    bindings = KeyBindings()

    @bindings.add("enter")
    def _(event):
        event.current_buffer.validate_and_handle()

    @bindings.add("escape", "enter")
    def _(event):
        event.current_buffer.insert_text("\n")

    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    return PromptSession(
        history=FileHistory(str(HISTORY_PATH)),
        key_bindings=bindings,
        multiline=True,
        prompt_continuation="   ",
    )


def confirm(question: str) -> bool:
    echo.on()
    try:
        return input(f"{question} [y/N] ").strip().lower() in {"y", "yes"}
    except (EOFError, KeyboardInterrupt):
        return False
    finally:
        echo.off()


def copy_to_clipboard(text: str) -> None:
    subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True)


def list_models(backend: Backend) -> None:
    from openai import OpenAI

    client = OpenAI(base_url=backend.base_url, api_key=backend.key, max_retries=0, timeout=30)
    names = sorted(m.id.removeprefix("models/") for m in client.models.list())
    names = [n for n in names if "gemini" in n.lower()] or names
    print("\n".join(names))


def send(chat: Chat, text: str, backend: Backend, model: str, config: dict, interactive: bool, render: bool) -> None:
    expanded = attach.expand(text)
    if expanded.has_attachments:
        tokens = attach.text_tokens(expanded.content)
        print(f"{DIM}附上：{RESET}")
        for line in expanded.summary:
            print(f"{DIM}  {line}{RESET}")
        images = f"、{expanded.images} 张图" if expanded.images else ""
        print(f"{DIM}  共约 {tokens / 1000:.1f}k token{images}{RESET}")
        too_big = tokens > CONFIRM_TOKENS or expanded.images > CONFIRM_IMAGES
        if too_big and interactive and not confirm("附件有点大，确定发吗？"):
            print("没发。")
            return

    chat.messages.append({"role": "user", "content": expanded.content, "raw": text})
    print("\nGemini>")
    try:
        reply = ask(chat, backend, model, config, render)
    except Exception as exc:
        chat.messages.pop()
        print(describe_error(exc, backend))
        return
    if not reply:
        chat.messages.pop()
        return
    print("" if render else "\n")
    chat.messages.append({"role": "assistant", "content": reply})
    chat.save(backend, model)
    if interactive:
        chat.title_in_background(backend, model)


PICK_LIMIT = 20


def choose(rows: list[str]) -> int | None:
    """上下键选一行，回车确定，Esc 或 Ctrl+C 取消。选完把列表擦掉，不留在聊天记录里。"""
    from prompt_toolkit.application import Application
    from prompt_toolkit.key_binding import KeyBindings
    from prompt_toolkit.layout import Layout, Window
    from prompt_toolkit.layout.controls import FormattedTextControl

    index = 0

    def text():
        out = [("fg:ansibrightblack", "上下键选，回车确定，Esc 取消\n")]
        for i, row in enumerate(rows):
            out.append(("reverse" if i == index else "", ("❯ " if i == index else "  ") + row + "\n"))
        return out

    bindings = KeyBindings()

    @bindings.add("up")
    @bindings.add("k")
    def _(event):
        nonlocal index
        index = (index - 1) % len(rows)

    @bindings.add("down")
    @bindings.add("j")
    def _(event):
        nonlocal index
        index = (index + 1) % len(rows)

    @bindings.add("enter")
    def _(event):
        event.app.exit(result=index)

    @bindings.add("escape")
    @bindings.add("c-c")
    @bindings.add("q")
    def _(event):
        event.app.exit(result=None)

    app = Application(
        layout=Layout(Window(FormattedTextControl(text, show_cursor=False), height=len(rows) + 1)),
        key_bindings=bindings,
        full_screen=False,
        erase_when_done=True,
    )
    return app.run()


def pick_chat(backend: Backend, model: str) -> Chat | None:
    """列出最近的对话，上下键挑一段。取消返回 None。"""
    import shutil
    from concurrent.futures import ThreadPoolExecutor

    size = shutil.get_terminal_size()
    files = Chat.saved()[: max(min(PICK_LIMIT, size.lines - 3), 3)]
    if not files:
        print("还没有存过的对话。")
        return None
    chats = [Chat.load(f) for f in files]

    # 以前存的对话可能还没标题，这里一口气补上
    untitled = [c for c in chats if not c.ai_title and c.messages]
    if untitled and backend.key:
        sys.stderr.write(f"{DIM}正在给 {len(untitled)} 段旧对话起标题…{RESET}")
        sys.stderr.flush()
        with ThreadPoolExecutor(max_workers=16) as pool:
            list(pool.map(lambda c: c.make_title(backend, model), untitled))
        sys.stderr.write("\r\033[K")
        sys.stderr.flush()

    rows = []
    for chat in chats:
        when = datetime.fromtimestamp(chat.path.stat().st_mtime).strftime("%m-%d %H:%M")
        rows.append(f"{when}  {len(chat.messages) // 2:>3} 轮  {chat.title()}"[: size.columns - 4])

    if not sys.stdin.isatty():
        for number, row in enumerate(rows, 1):
            print(f"{number:>3}  {row}")
        answer = sys.stdin.readline().strip()
        return chats[int(answer) - 1] if answer.isdigit() and 1 <= int(answer) <= len(chats) else None

    picked = choose(rows)
    return chats[picked] if picked is not None else None


def print_history(chat: Chat, render: bool) -> None:
    """接着聊的时候，把之前的记录重新打一遍，这样终端里还是完整的对话。"""
    print(f"\n{DIM}接着聊「{chat.title()}」（{chat.id}），之前的记录：{RESET}\n")
    if not render:
        print(chat.transcript())
        return
    from .render import print_markdown

    for message in chat.messages:
        if message["role"] == "user":
            print(f"你> {message.get('raw', message['content'])}\n")
        else:
            print("Gemini>")
            print_markdown(message["content"])
            print()


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="nutshell",
        description="在终端里跟 Gemini 纯聊天。拖文件、图片、PDF、文件夹进来，内容原地附上。",
    )
    parser.add_argument("--own", action="store_true", help=f"走自己的 Google AI Studio key（仓库 .env 里的 {OWN_KEY_ENV}），默认走公司网关")
    parser.add_argument("-m", "--model", help="模型名，默认用 Nutshell 配置里的")
    parser.add_argument("-c", "--continue", dest="latest", action="store_true", help="接着最近的那段对话聊")
    parser.add_argument("-r", "--resume", nargs="?", const="", metavar="编号", help="接着以前的某段对话聊：不带编号就列出来让你挑，带编号直接接上")
    parser.add_argument("-p", "--print", dest="once", metavar="消息", help="只问这一句，打印回答就退出")
    parser.add_argument("--raw", action="store_true", help="不渲染 Markdown，回答按原样打纯文字")
    args = parser.parse_args()

    config = load_config()
    backend = make_backend("own" if args.own else "work", config)
    model = args.model or config["model"]
    resumed = None
    if args.resume:
        resumed = Chat.find(args.resume)
        if resumed is None:
            sys.exit(f"没找到编号是 {args.resume} 的对话。敲 nutshell -r 看有哪些。")
    elif args.resume == "":
        resumed = pick_chat(backend, model)
        if resumed is None:
            return
    elif args.latest:
        resumed = Chat.latest()
    chat = resumed or Chat()
    #: 输出被重定向到文件或管道时不渲染，拿到的就是 Markdown 原文
    render = sys.stdout.isatty() and not args.raw

    if args.once is not None:
        send(chat, args.once, backend, model, config, interactive=False, render=render)
        return

    print(f"Nutshell · {model} · {backend.label}")
    print(f"{DIM}回车发送，Option+回车换行，拖文件进来自动附上。/help 看命令，连按两次 Ctrl+C 退出。{RESET}")
    if resumed and chat.messages:
        print_history(chat, render)

    session = make_prompt_session()
    echo.off()
    last_interrupt = 0.0
    try:
        while True:
            try:
                text = session.prompt("\n你> ")
            except KeyboardInterrupt:
                # 第一下只清掉正在敲的字，两秒内再按一下才退出，免得手滑
                if time.time() - last_interrupt < 2:
                    break
                last_interrupt = time.time()
                print(f"{DIM}再按一次 Ctrl+C 退出{RESET}")
                continue
            except EOFError:
                break
            text = text.strip()
            if not text:
                continue

            command, _, rest = text.partition(" ")
            if command == "/exit":
                break
            elif command == "/help":
                print(HELP)
            elif command in {"/own", "/work"}:
                backend = make_backend(command[1:], config)
                note = "" if backend.key else f"（但 ${backend.key_env} 是空的，发了会报错）"
                print(f"已切到{backend.label}{note}")
            elif command == "/model":
                if rest.strip():
                    model = rest.strip()
                print(f"当前模型：{model}（{backend.label}）")
            elif command == "/models":
                try:
                    list_models(backend)
                except Exception as exc:
                    print(describe_error(exc, backend))
            elif command == "/copy":
                replies = [m["content"] for m in chat.messages if m["role"] == "assistant"]
                if replies:
                    copy_to_clipboard(replies[-1])
                    print("已复制上一条回答。")
                else:
                    print("还没有回答可复制。")
            elif command == "/copyall":
                copy_to_clipboard(chat.transcript())
                print(f"已复制整段聊天记录（{len(chat.messages)} 条）。")
            elif command == "/raw":
                render = not render
                print("Markdown 渲染已打开。" if render else "Markdown 渲染已关掉，回答按原样打纯文字。")
            elif command == "/new":
                chat = Chat()
                print("开了一段新对话。")
            elif command == "/resume":
                echo.on()
                try:
                    picked = Chat.find(rest.strip()) if rest.strip() else pick_chat(backend, model)
                finally:
                    echo.off()
                if picked:
                    chat = picked
                    print_history(chat, render)
                elif rest.strip():
                    print(f"没找到编号是 {rest.strip()} 的对话。")
            else:
                send(chat, text, backend, model, config, interactive=True, render=render)

    finally:
        echo.on()
    if chat.messages:
        chat.wait_title()
        name = f"「{chat.ai_title}」" if chat.ai_title else ""
        print(f"\n对话{name}已保存。接着聊：nutshell -r {chat.id}")

if __name__ == "__main__":
    main()
