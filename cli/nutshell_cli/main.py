"""Nutshell 终端版：在终端里跟 Gemini 纯聊天。

就是一问一答，没有工具、没有 agent。设计上最要紧的一条：**整段对话原样留在终端
里**——不开全屏界面、不清屏、回答按纯文字一边收一边打，这样 Cmd+A 全选复制就是
完整的聊天记录，可以直接贴给 Claude 落盘。拖进来的文件在终端里显示的是完整路径，
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

#: 输出被重定向到文件或管道时不加颜色码，免得记录里混进乱码
DIM = "\033[2m" if sys.stdout.isatty() else ""
RESET = "\033[0m" if sys.stdout.isatty() else ""

HELP = """\
命令（只在一行开头敲才算）：
  /own        切到自己的 Google AI Studio key（仓库 .env 里的 GEMINI_AI_STUDIO_KEY_NUTSHELL）
  /work       切回公司网关
  /model 名字  换模型；不带名字就显示当前模型
  /models     列出当前这把 key 能用的 Gemini 模型
  /copy       复制上一条回答
  /copyall    复制整段聊天记录（终端滚动历史不够长时用）
  /new        开一段新对话
  /exit       退出（Ctrl+D 也行）
回车发送，Option+回车 或 Esc 再回车 换行。粘贴多行不会被拆开发。
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
        self.path = path or CHATS_DIR / f"{datetime.now():%Y%m%d-%H%M%S}.json"

    @classmethod
    def latest(cls) -> Chat | None:
        files = sorted(CHATS_DIR.glob("*.json"))
        if not files:
            return None
        chat = cls(files[-1])
        chat.messages = json.loads(files[-1].read_text())["messages"]
        return chat

    def save(self, backend: Backend, model: str) -> None:
        CHATS_DIR.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(
                {"backend": backend.name, "model": model, "messages": self.messages},
                ensure_ascii=False,
                indent=1,
            )
        )

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


def ask(chat: Chat, backend: Backend, model: str, config: dict) -> str:
    """把整段对话发出去，回答一边收一边打到 stdout，返回完整回答。Ctrl+C 打断时返回已收到的部分。"""
    from openai import APIConnectionError, APIStatusError, OpenAI

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
                            sys.stdout.write(piece)
                            sys.stdout.flush()
                            received += piece
            return received
        except KeyboardInterrupt:
            spinner.stop()
            print(f"\n{DIM}（打断了）{RESET}")
            return received
        except (APIStatusError, APIConnectionError) as exc:
            spinner.stop()
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


def send(chat: Chat, text: str, backend: Backend, model: str, config: dict, interactive: bool) -> None:
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
        reply = ask(chat, backend, model, config)
    except Exception as exc:
        chat.messages.pop()
        print(describe_error(exc, backend))
        return
    if not reply:
        chat.messages.pop()
        return
    print("\n")
    chat.messages.append({"role": "assistant", "content": reply})
    chat.save(backend, model)


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="nutshell",
        description="在终端里跟 Gemini 纯聊天。拖文件、图片、PDF、文件夹进来，内容原地附上。",
    )
    parser.add_argument("--own", action="store_true", help=f"走自己的 Google AI Studio key（仓库 .env 里的 {OWN_KEY_ENV}），默认走公司网关")
    parser.add_argument("-m", "--model", help="模型名，默认用 Nutshell 配置里的")
    parser.add_argument("-c", "--continue", dest="resume", action="store_true", help="接着上一段对话聊")
    parser.add_argument("-p", "--print", dest="once", metavar="消息", help="只问这一句，打印回答就退出")
    args = parser.parse_args()

    config = load_config()
    backend = make_backend("own" if args.own else "work", config)
    model = args.model or config["model"]
    chat = (Chat.latest() if args.resume else None) or Chat()

    if args.once is not None:
        send(chat, args.once, backend, model, config, interactive=False)
        return

    print(f"Nutshell · {model} · {backend.label}")
    print(f"{DIM}回车发送，Option+回车换行，拖文件进来自动附上。/help 看命令，Ctrl+D 退出。{RESET}")
    if args.resume and chat.messages:
        print(f"\n{DIM}接着 {chat.path.name} 聊，之前的记录：{RESET}\n")
        print(chat.transcript())

    session = make_prompt_session()
    echo.off()
    try:
        while True:
            try:
                text = session.prompt("\n你> ")
            except KeyboardInterrupt:
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
            elif command == "/new":
                chat = Chat()
                print("开了一段新对话。")
            else:
                send(chat, text, backend, model, config, interactive=True)

    finally:
        echo.on()

if __name__ == "__main__":
    main()
