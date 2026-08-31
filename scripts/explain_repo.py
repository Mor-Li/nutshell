#!/usr/bin/env -S uv run
# /// script
# requires-python = ">=3.11"
# dependencies = ["tiktoken", "rich"]
# ///
"""给仓库里每个代码文件和每一层文件夹生成一份通俗解读，并维护 CLAUDE.md 里的仓库地图。

从 SkillTron 的 `scripts/explain_repo.py` 移植（2026-08-31），机制原样保留，
为 Nutshell 这个仓库改了四处水土：

1. **自包含**：SkillTron 版 import 它自己引擎里的 `call_llm`；这里把那套的精简版
   （429 独立退避、永久失败判据、降级链、结果缓存）直接内嵌，一个文件拎着就走。
   依赖用 PEP 723 内联声明，`uv run scripts/explain_repo.py` 即跑。
2. **视野换成 Swift 项目**：`.swift` / `.html` / `.sh` + 点名 Makefile、Info.plist。
3. **目录产物叫 `EXPLAIN.md`，不叫 `README.md`**。SkillTron 约定「README 一律自动
   生成」；本仓根目录的 README.md 是人写的门面（安装说明、BTT 配置、设计取舍），
   被生成器覆盖就是事故——SkillTron 自己就撞过两回（frontend/design、data/），
   靠排除名单救的。换个名字把这类事故从根上消掉。
4. **LLM 配置直接读 Nutshell 自己的 `~/.config/nutshell/config.json`**（浮窗 app
   与本脚本打同一个网关），环境变量可逐项覆盖，机器上零额外配置。

## 两条产物线

- **长篇解读**（给人看）：`AppDelegate.swift` → 同级 `AppDelegate.md`，每个目录
  一份 `EXPLAIN.md`。全部不进 git（见 `.gitignore`），纯粹给人回头审阅用。
- **仓库地图**（给 AI agent 看）：每个文件/目录一句「负责什么、什么时候动它」，
  拼成缩进树写进 `CLAUDE.md` 的「仓库代码地图」一段。agent 开局读地图，
  不用每次重新把仓库摸一遍。

## 增量：一棵默克尔树

- **文件的 hash** = 它内容的 sha256
- **目录的 hash** = 它下面所有子项「路径:hash」排序后的 sha256

于是改一个文件，它的 hash 变 → 它的解读重生成 → 父目录的组合 hash 跟着变 →
一路传播到根。没被碰过的分支一个都不会重跑。

## 分层并发：先文件，再从最深的目录往上

目录的解读要吃它下面各文件与各子目录**已经生成好**的解读，所以调度分层：
一层跑完才能跑上一层。父目录抢先跑就会汇总到一半的东西——这是 SkillTron
的思路来源 `understand-everything` 里一个真实的静默降质 bug，此处按深度分层解决。

## 失败绝不写文件

解读失败就抛异常：不写文件、也不更新该节点的 hash。下次自然重试。
（前身把错误信息写进 `.md`，而增量判据是「文件在不在」，那份错误就永远留在文档里了。）
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import tiktoken
from rich.console import Console
from rich.progress import (
    BarColumn,
    MofNCompleteColumn,
    Progress,
    SpinnerColumn,
    TextColumn,
    TimeElapsedColumn,
)

ROOT = Path(__file__).resolve().parent.parent

#: 缓存目录，四样东西一个屋檐：`index.json` 记解读的 hash，`map.json` 记地图的
#: hash 和句子，`prompts/` 存每个节点**最后一次实际发出去的 prompt 全文**，
#: `llm/` 是 prompt 级结果缓存。
#:
#: 存 prompt 不是为了省事，是为了能查。SkillTron 那边有两个 bug 都只在产物里露出
#: 一点端倪（模型虚构了不存在的模块、模型反问「你说的是哪个文件夹」），排查时
#: 手上没有当时发出去的东西，只能照着代码重新渲染一遍去猜。存下来之后，
#: 出问题第一件事就是打开它看，不用猜。
CACHE_DIR = ROOT / ".explain-cache"
CACHE_PATH = CACHE_DIR / "index.json"
PROMPT_DIR = CACHE_DIR / "prompts"
LLM_CACHE_DIR = CACHE_DIR / "llm"

# ══════════════════════════════════════════════════════════════════════
#  内嵌的 LLM 客户端（SkillTron `engine/llm.py` 的精简版）
# ══════════════════════════════════════════════════════════════════════
#
# 砍掉了图片、validate 回调、成本记账；留下的都是拿真实事故换来的行为：
#
# - **429 不计入重试次数**，走自己的退避档位（15s 起步）。限流不是「这次请求
#   有问题」，是「现在没位置」；拿 2 秒去敲它等于把重试全浪费在同一个瞬间。
# - **永久失败（4xx、安全过滤）直接换下一个模型**，不在同一家身上耗满次数——
#   重试发的是一模一样的字节，再打几次只是把「没救了」推迟几分钟得出。
# - **200 但正文为空，有下家就立刻换**：安全过滤器拦了、或推理模型把 token
#   预算烧光，两者都是确定性的，重试救不了，换家往往就过。
# - **只缓存成功的结果**：把「这个 prompt 会失败」记下来等于把偶发故障永久化。

#: OpenAI 兼容端点、模型、key 的解析顺序：环境变量 > Nutshell 的 config.json。
#: 端点故意不写默认值进源码（这是公开仓库，网关地址不进代码）。
ENV_BASE_URL = "NUTSHELL_LLM_BASE_URL"
ENV_MODEL = "NUTSHELL_LLM_MODEL"
NUTSHELL_CONFIG = Path.home() / ".config" / "nutshell" / "config.json"

#: 主模型走投无路时依次换家。两级都是各家旗舰——降级只在主模型已经出事时发生，
#: 而那一次往往正是最难的一次（内容敏感把主模型逼退了），换个更弱的模型接手
#: 等于用一份更差的产物换几分钱。主模型撞名时会被去重。
FALLBACK_MODELS = ("gpt-5.6-sol", "claude-opus-5")

#: 推理模型会先烧一大段思考 token，预算给小了就返回空 content——32768 是坑换来的。
MAX_TOKENS = 32768

#: 单次请求最多等多久。推理模型单次跑几分钟是常态。
TIMEOUT = 600.0

#: 撞限流时的退避档位，跟普通失败的退避**故意差一个数量级**；用完最后一档就重复它。
_THROTTLE_BACKOFF = (15.0, 30.0, 60.0, 90.0, 120.0)

#: 这些状态码值得重试（408/425/429 会自愈；5xx 是上游的事；529 是 Anthropic
#: 的 overloaded_error，不在任何 RFC 里，不加就会被判成永久失败一次都不试）。
_RETRYABLE_STATUS = frozenset({408, 425, 429, 500, 502, 503, 504, 529})

#: 「再打一次也是这个结果」的两类特征：4xx（除掉三个会自愈的），
#: 以及内容安全的明文标记（留给把状态码藏起来、只在正文里说原因的上游）。
_PERMANENT_PATTERNS = (
    re.compile(r"(?:http|status|code).{0,12}?4(?!08|25|29)\d{2}\b", re.I),
    re.compile(r"PROHIBITED_CONTENT|content[_ -]?(?:policy|filter)", re.I),
)


def looks_permanent(detail: str) -> bool:
    """这次失败是不是永久的。宁可漏判（白重试几次）不可错判（本能成的被放弃）。"""
    return any(p.search(detail) for p in _PERMANENT_PATTERNS)


def _redact(text: str) -> str:
    """打掉可能混进报错的 key（上游的错误正文里常带着 masked key）。"""
    return re.sub(r"sk-[A-Za-z0-9_*-]+", "[REDACTED]", text)


@dataclass(frozen=True)
class LLMConfig:
    base_url: str
    model: str
    api_key: str


def resolve_llm_config() -> LLMConfig:
    """端点/模型/key 各自独立解析：环境变量 > `~/.config/nutshell/config.json`。

    key 的链条最长：`LITELLM_API_KEY` > `ANTHROPIC_AUTH_TOKEN` >
    config.json 的 `apiKey` 字段 > config.json 的 `apiKeyEnvVar` 指的那个变量。
    非交互 shell（cron / git hook）不 source ~/.zshrc，key 常常就是这么丢的，
    所以缺谁报错里都写清楚去哪补。
    """
    cfg = {}
    try:
        cfg = json.loads(NUTSHELL_CONFIG.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        pass

    base_url = os.environ.get(ENV_BASE_URL) or cfg.get("baseURL") or ""
    model = os.environ.get(ENV_MODEL) or cfg.get("model") or ""
    api_key = (
        os.environ.get("LITELLM_API_KEY")
        or os.environ.get("ANTHROPIC_AUTH_TOKEN")
        or cfg.get("apiKey")
        or os.environ.get(cfg.get("apiKeyEnvVar") or "", "")
        or ""
    )

    missing = []
    if not base_url:
        missing.append(f"端点（设 {ENV_BASE_URL}，或 config.json 的 baseURL）")
    if not model:
        missing.append(f"模型（设 {ENV_MODEL}，或 config.json 的 model）")
    if not api_key:
        missing.append(
            "API key（`source ~/.zshrc` 后重跑让 LITELLM_API_KEY 生效，"
            "或写进 config.json 的 apiKey）"
        )
    if missing:
        raise SystemExit(
            "LLM 配置不全，缺：\n  - " + "\n  - ".join(missing)
            + f"\n（config.json 在 {NUTSHELL_CONFIG}）"
        )
    return LLMConfig(base_url=base_url, model=model, api_key=api_key)


@dataclass(frozen=True)
class LLMResult:
    text: str
    model_used: str
    attempts: int


def _http_once(prompt: str, model: str, cfg: LLMConfig) -> tuple[str, str, str]:
    """打一次 `/chat/completions`。返回 (kind, text, detail)。

    kind ∈ ok / throttled / retryable / permanent / empty。纯 stdlib urllib——
    这一层要做的就是「POST 一个 json，读回一个 json」，不值得为它加依赖。
    `temperature` 不设，照上游默认来。
    """
    body = json.dumps(
        {
            "model": model,
            "max_tokens": MAX_TOKENS,
            "messages": [{"role": "user", "content": prompt}],
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        cfg.base_url.rstrip("/") + "/chat/completions",
        data=body,
        headers={
            "Authorization": f"Bearer {cfg.api_key}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = _redact(f"HTTP {exc.code}：{(exc.read() or b'').decode('utf-8', 'replace')}")[:300]
        if exc.code == 429:
            return ("throttled", "", detail)
        if looks_permanent(detail) or exc.code not in _RETRYABLE_STATUS:
            return ("permanent", "", detail)
        return ("retryable", "", detail)
    except TimeoutError:
        return ("retryable", "", f"超时（{TIMEOUT:.0f}s）")
    except urllib.error.URLError as exc:
        reason = getattr(exc, "reason", exc)
        return ("retryable", "", _redact(f"连接失败：{reason}")[:300])
    except (OSError, json.JSONDecodeError) as exc:
        # 连接建好之后断在半路（RemoteDisconnected / IncompleteRead / reset）
        # 不会被 URLError 接住，得单独兜——SkillTron 2026-08-12 被这一类
        # 冒穿整条调用链带走过一轮训练。
        return ("retryable", "", _redact(f"连接中断：{type(exc).__name__}: {exc}")[:300])

    # 有些网关把上游错误包在 HTTP 200 里，只在 body 的 error 字段体现
    if isinstance(payload, dict) and payload.get("error"):
        detail = _redact(f"上游错误：{payload['error']}")[:300]
        return ("permanent" if looks_permanent(detail) else "retryable", "", detail)

    try:
        text = (payload["choices"][0]["message"]["content"] or "").strip()
    except (KeyError, IndexError, TypeError) as exc:
        return ("retryable", "", f"返回结构不认识（{type(exc).__name__}）：{str(payload)[:200]}")

    if not text:
        return ("empty", "", "HTTP 200 但 content 为空（安全拦截或推理烧光预算）")
    return ("ok", text, "")


def _cache_key(prompt: str, model: str) -> str:
    """同一个 key = 发出去的东西逐字节相同 = 结果可以复用。
    只放真正决定输出的东西；重试参数描述「怎么去拿」，不进 key。"""
    payload = json.dumps(
        {"prompt": prompt, "model": model, "max_tokens": MAX_TOKENS}, sort_keys=True
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def _cache_read(key: str) -> str | None:
    try:
        data = json.loads((LLM_CACHE_DIR / f"{key}.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    text = data.get("text")
    return text if isinstance(text, str) and text else None


def _cache_write(key: str, text: str, model_used: str, prompt: str) -> None:
    """写缓存（prompt 存全文，出问题时能查「当时到底发了什么」）。
    临时文件 + rename：16 路并发下半截 json 会被下次读取当成损坏。"""
    try:
        LLM_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path = LLM_CACHE_DIR / f"{key}.json"
        tmp = path.with_suffix(".tmp")
        tmp.write_text(
            json.dumps(
                {"model_used": model_used, "prompt": prompt, "text": text},
                ensure_ascii=False,
                indent=1,
            ),
            encoding="utf-8",
        )
        os.replace(tmp, path)
    except OSError:
        pass


def call_llm(
    prompt: str,
    *,
    cfg: LLMConfig,
    model: str | None = None,
    max_retries: int = 3,
    backoff: tuple[float, ...] = (),
    max_total_backoff: float | None = None,
    log_prefix: str = "llm",
    cache: bool = False,
) -> LLMResult:
    """调一次大模型拿一段文本，全链（主模型 + 降级链）都失败才抛 RuntimeError。

    `max_retries` 是**每个模型**的尝试次数；429 不计入，由 `max_total_backoff`
    这把时间闸兜底——次数管「试几回」，时间管「最多耗多久」，两把独立的闸。
    """
    primary = model or cfg.model
    chain = list(dict.fromkeys((primary, *FALLBACK_MODELS)))  # 保序去重

    # 查缓存放在一切之前：命中时不碰网络（顺带让没配 key 的机器也能靠缓存跑完）
    key = _cache_key(prompt, primary) if cache else ""
    if key and (hit := _cache_read(key)) is not None:
        return LLMResult(text=hit, model_used=primary, attempts=0)

    failures: list[str] = []
    waited = 0.0
    attempts = 0

    for model_index, current in enumerate(chain):
        attempt = 0
        throttled = 0
        while attempt < max_retries:
            attempt += 1
            attempts += 1
            kind, text, detail = _http_once(prompt, current, cfg)

            if kind == "ok":
                if key:
                    _cache_write(key, text, current, prompt)
                if current != primary:
                    print(f"[{log_prefix}] ⚠️ 结果由降级模型 {current} 产出", file=sys.stderr)
                return LLMResult(text=text, model_used=current, attempts=attempts)

            failures.append(f"{current} 第{attempt}次：{detail}")

            if kind == "permanent":
                break  # 换下一个模型，别在同一家身上耗满次数

            if kind == "empty" and model_index < len(chain) - 1:
                break  # 空正文是确定性的，有下家就立刻换；最后一家才用重试赌偶发

            if kind == "throttled":
                throttled += 1
                attempt -= 1  # 限流不算这个模型的尝试次数
                attempts -= 1
                wait = _THROTTLE_BACKOFF[min(throttled, len(_THROTTLE_BACKOFF)) - 1]
                if max_total_backoff is not None and waited + wait > max_total_backoff:
                    break
                waited += wait
                time.sleep(wait)
                continue

            if attempt < max_retries:
                wait = (
                    backoff[min(attempt, len(backoff)) - 1]
                    if backoff
                    else float(min(2 * attempt, 10))
                )
                if max_total_backoff is not None and waited + wait > max_total_backoff:
                    break
                waited += wait
                time.sleep(wait)

    raise RuntimeError(
        f"[{log_prefix}] 模型链 {' → '.join(chain)} 全部失败；" + "；".join(failures[-3:])
    )


# ══════════════════════════════════════════════════════════════════════
#  视野：这个仓库里哪些东西要解读
# ══════════════════════════════════════════════════════════════════════

#: 只解读这些后缀。产物 md 与源文件同名同级（`AppDelegate.swift` → `AppDelegate.md`），
#: 后缀必须能唯一还原——同名不同后缀的两个源文件会撞车。
#: `.md` 故意不加：源文件若是 `.md`，产物路径会算出源文件自己，原地覆盖手写文档。
#: `.py` 目前只有本脚本自己——它也该上地图，agent 得知道「更新文档来找它」。
SOURCE_SUFFIXES = (".swift", ".html", ".sh", ".py")

#: 按后缀抓不到、但必须上地图的文件，逐个点名。跟后缀 glob 走同一趟 ls-files，
#: 没被 git 跟踪的自然不会混进视野。
#:
#: `Info.plist` 带点，产物是 `Info.md`——查过仓库根没有别的 `Info.*`，不撞。
#: （SkillTron 版警告过点名文件带点的撞车风险，判据是「with_suffix 后是否与
#: 别的源文件的产物同路径」，这里逐个核对过。）
EXTRA_SOURCES = ("Makefile", "Info.plist")

#: 只上仓库地图、不进解读链的文件：人写的文档。
#: 为什么不能进解读链：`.md` 源文件的产物路径就是它自己，见 SOURCE_SUFFIXES。
MAP_ONLY_GLOBS = ("README.md",)

#: 视野黑名单：这些前缀底下就算有源文件也整棵不解读。
#: 本仓的 `build/`、`.build/` 都在 gitignore 里，ls-files 天然抓不到，暂时没有要拉黑的。
EXCLUDED_PREFIXES: tuple[str, ...] = ()

#: 文件夹总览的文件名。**跟 SkillTron 版不同，那边叫 README.md**：
#: 那边的约定是「视野内的 README 一律归生成器重写」，而本仓根目录的 README.md
#: 是人写的门面（装法、BTT 配置、设计说明），绝不能被生成器覆盖。
#: 换个不撞的名字，把「哪份 README 是人写的」这个问题从根上消掉。
FOLDER_DOC = "EXPLAIN.md"

#: 并发度。公司网关 2026-08-04 压测 20/40 并发全通，批量脚本默认开 16；
#: 撞限流的那些自己退避重试即可。
DEFAULT_CONCURRENCY = 16

#: 每次失败后等多久。表用完就一直重复最后一档（60s），配合下面的总预算收口。
BACKOFF = (5.0, 10.0, 20.0, 30.0, 45.0, 60.0)

#: 单个节点累计最多等 30 分钟。到点就判这一份失败，而不是无声挂住。
MAX_TOTAL_BACKOFF = 1800.0

#: 每个模型的尝试次数上限。给得大是因为真正收口的是上面那个时间预算。
MAX_RETRIES = 40

#: 喂给模型的内容上限。超了按比例截断每一份，而不是丢掉后面几份——
#: 目录概览缺一角比每份都短一点糟糕得多。
MAX_INPUT_TOKENS = 200_000

# ══════════════════════════════════════════════════════════════════════
#  Prompt —— 骨架版，等墨哥调（2026-08-31 从 SkillTron 版改写）
# ══════════════════════════════════════════════════════════════════════

#: 【骨架版，等墨哥调】背景段，三个 prompt 共用。从 SkillTron 的 skill training
#: 背景换成了 Nutshell 的介绍（照 README 的说法压缩的）。
_BACKGROUND = """\
嗨 Gemini，我写了一个 macOS 小工具叫 Nutshell：平时看到一段看不懂的东西（文字、
代码、PDF、截图都行），复制一下、按一下快捷键，鼠标旁边就冒出一个小浮窗，用
大白话讲清楚刚才那段是啥，还能在浮窗里接着追问。它是个 Swift 写的常驻后台程序：
不进 Dock、监听本机一个端口，BetterTouchTool 发个 HTTP 请求就能触发；读剪贴板、
调 OpenAI 兼容的 LLM 网关流式输出，浮窗用 WKWebView 渲染 markdown，支持多轮
对话和历史存档。"""

#: 【骨架版，等墨哥调】单个文件的长篇解读。
#: 占位符：{path} 文件路径；{tree} 全仓目录树；{lang} 代码围栏语言；{code} 全部源码。
#: 「我的水平」那段从 SkillTron 版的 Python 视角改成了 Swift/AppKit 视角。
FILE_PROMPT = (
    _BACKGROUND
    + """

现在我这个文件的 path 是：{path}

整个目录的 tree：

{tree}

当前这个文件的所有代码：

```{lang}
{code}
```

请你给我解读一下 `{path}` 这个文件在整个系统中的一个作用是什么？
此外有一个背景是，我自己主要写 Python，Swift、AppKit、macOS 系统编程基本不懂，
HTML/JS 前端也只是一知半解。所以我也想学习一下这个文件里用到的语言特性和系统
框架的用法：为什么要这么写？用简单朴素的写法行不行，为什么？
他是怎么实现这些功能的，代码上用了哪些方法，哪些类？
整个代码文件中各个部分的逻辑关系是什么样子的？互相如何调用？结合具体代码也讲一下。
通俗易懂地给我解读一下。"""
)

#: 【骨架版，等墨哥调】文件夹总览。
FOLDER_PROMPT = (
    _BACKGROUND
    + """

现在我这个文件夹的 path 是：{path}

整个目录的 tree：

{tree}

这个文件夹底下每个文件是干什么的，你之前已经逐个给我解读过了，就是下面这些：

{file_summaries}

它下面还有几个子文件夹，每个子文件夹的总览你也已经写好了，是下面这些：

{subfolder_summaries}

请你给我解读一下 `{path}` 这个文件夹在整个系统中的作用是什么？通俗易懂地讲。
以及这个文件夹下面的子文件以及各个子文件夹大概是干啥的？
如果我要改不同的部分，应该分别去哪里找？

"""
)

# ──────────────────────────────────────────────────────────────────────
# 仓库地图的两个 prompt。跟上面两个是**两种东西，各服务各的**，别想着合并：
# 上面产出给人看的长篇（几千字、带例子），落成一份份独立 md 慢慢读；
# 这里产出给 AI agent 看的一句话，全仓拼成一张地图进 CLAUDE.md，
# 让 agent 开局就知道「这个需求该改哪个文件」。
# 从长篇里截前 120 字凑不出来：截出来全是开场白，信息密度极低。

#: 【骨架版，等墨哥调】地图里文件那一行。
#: 占位符：{path} 文件路径；{tree} 全仓目录树；{lang}/{code} 同 FILE_PROMPT。
MAP_PROMPT = (
    _BACKGROUND
    + """

这个文件的 path 是：{path}

整个目录的 tree：

{tree}

它的全部代码：

```{lang}
{code}
```

用一句话说清楚这个文件负责什么、什么情况下需要动它。

这句话会进 CLAUDE.md，是给 AI coding agent 看的仓库地图，不是给人看的文档。
agent 拿它来判断「手上这个需求该改哪个文件」，所以要写得能支撑这个判断：
说清楚职责边界，必要时点出关键的类名或函数名。

不要寒暄，不要讲语法，不要评价这个设计好不好。
50 字以内，直接给这一句，前后不要任何多余的话。"""
)

#: 【骨架版，等墨哥调】地图里**目录**那一行。目录没有源码可读，喂的是底下每个
#: 子项已经生成好的那句话，让它往上收一层——比拼全部源码便宜两个量级。
#: 占位符：{path} 目录路径；{children} 直属子项的一句话，每行一条。
MAP_FOLDER_PROMPT = (
    _BACKGROUND
    + """

这个目录的 path 是：{path}

它底下每一项是干什么的，你已经逐条写好了：

{children}

用一句话说清楚这个目录整体负责什么、什么样的需求该到这里来找。

这句话会进 CLAUDE.md 的仓库地图，跟上面那些子项的说明排在一起，是给 AI coding
agent 看的。它先看目录这一句决定要不要往里翻，所以要写出这个目录的职责边界，
别只是把子项罗列一遍。

不要寒暄，不要评价设计好坏。
50 字以内，直接给这一句，前后不要任何多余的话。"""
)

#: 地图写进 CLAUDE.md 的哪一段。认这一行标题，把它到下一个 `## ` 之间整段换掉。
#: 改这行标题等于放弃旧 section（下次跑会在文件末尾再追加一份，旧的从此不更新、
#: 变成一份会骗人的过期地图）——真要改，先手工把 CLAUDE.md 里的旧标题一起改掉。
MAP_SECTION = "## 仓库代码地图"

#: 地图的缓存，跟解读的 `index.json` 分开——两套 prompt 不同、产物不同，
#: 共用会互相判定对方过期，两边来回全量重跑。它比 index.json 多存每句话的正文：
#: 地图产物是一份汇总文件，没法从产物反推「这行当初是哪个文件生成的」。
MAP_CACHE_PATH = CACHE_DIR / "map.json"

#: 地图的「出厂版本」，文件和目录各算各的：调目录的措辞不该把文件那批也拖去重跑。
MAP_FILE_VERSION = hashlib.sha256(MAP_PROMPT.encode("utf-8")).hexdigest()[:16]
MAP_DIR_VERSION = hashlib.sha256(MAP_FOLDER_PROMPT.encode("utf-8")).hexdigest()[:16]

CLAUDE_MD = ROOT / "CLAUDE.md"

#: 产物的「出厂版本」：本脚本自身的内容 hash。改 prompt 或生成逻辑都会变 → 全量
#: 重算。连无关注释也算进去是有意的：两种错的代价完全不对称——多算一轮是几分钟
#: 加几毛钱，漏算一轮是整仓解读基于坏逻辑而读起来完全正常。
GENERATOR_VERSION = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()[:16]


#: 代码围栏的语言标注，按文件名/后缀认。认不出就留空（裸围栏也能渲染）。
def fence_lang(rel: str) -> str:
    name = Path(rel).name
    if name == "Makefile":
        return "make"
    if name.endswith(".plist"):
        return "xml"
    return {".swift": "swift", ".html": "html", ".sh": "bash", ".py": "python"}.get(
        Path(rel).suffix, ""
    )


# ------------------------------------------------------------------ 节点


@dataclass(frozen=True)
class Node:
    """一个待解读的东西：一个源文件，或者一个目录。"""

    rel: str
    """相对仓库根的路径。目录用 posix 风格，根目录是 `"."`。"""

    is_dir: bool
    children: tuple[str, ...] = ()
    """只对目录有意义：直属子节点的 rel（含文件与子目录）。"""

    @property
    def depth(self) -> int:
        return 0 if self.rel == "." else len(Path(self.rel).parts)


def tracked_sources(include_map_only: bool = False) -> list[str]:
    """git 跟踪的源文件。

    用 `git ls-files` 而不是自己走目录树：它天然排除了 gitignore 掉的东西
    （`build/`、`.build/`、我们自己生成的那些 `.md`），自己走目录树就得把
    这套排除规则再实现一遍，两套规则迟早不一致。

    `include_map_only=True` 是地图链专用的宽视野：多出 `MAP_ONLY_GLOBS`
    （人写的 README）。解读链保持窄视野——`.md` 进解读链会原地覆盖自己。
    """
    out = subprocess.run(
        [
            "git",
            "-C",
            str(ROOT),
            "ls-files",
            "--",
            *[f"*{s}" for s in SOURCE_SUFFIXES],
            *EXTRA_SOURCES,
            *(MAP_ONLY_GLOBS if include_map_only else ()),
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    # ls-files 报的是 git 索引：删除还没 commit 的文件仍然在列，磁盘上却已经
    # 没有了，后面 read_bytes 直接炸。按真实存在过滤。
    return sorted(
        line
        for line in out.stdout.splitlines()
        if line.strip()
        and not line.startswith(EXCLUDED_PREFIXES)
        and (ROOT / line).is_file()
    )


def build_tree(paths: list[str]) -> dict[str, Node]:
    """源文件清单 → 全部节点（文件 + 它们的每一层祖先目录）。"""
    nodes: dict[str, Node] = {}
    children: dict[str, set[str]] = {}

    for rel in paths:
        nodes[rel] = Node(rel=rel, is_dir=False)
        parts = Path(rel).parts
        for i in range(len(parts)):
            parent = "." if i == 0 else str(Path(*parts[:i]).as_posix())
            child = str(Path(*parts[: i + 1]).as_posix())
            children.setdefault(parent, set()).add(child)

    for parent, kids in children.items():
        nodes[parent] = Node(rel=parent, is_dir=True, children=tuple(sorted(kids)))
    return nodes


def compute_hashes(nodes: dict[str, Node]) -> dict[str, str]:
    """自底向上算默克尔 hash。"""
    done: dict[str, str] = {}

    def visit(rel: str) -> str:
        if rel in done:
            return done[rel]
        node = nodes[rel]
        if not node.is_dir:
            digest = hashlib.sha256((ROOT / rel).read_bytes()).hexdigest()
        else:
            parts = [f"{child}:{visit(child)}" for child in node.children]
            digest = hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()
        done[rel] = digest
        return digest

    for rel in nodes:
        visit(rel)
    return done


# ------------------------------------------------------------------ 产物路径


def doc_path(node: Node) -> Path:
    """这个节点的解读该写到哪。"""
    if node.is_dir:
        return ROOT / node.rel / FOLDER_DOC if node.rel != "." else ROOT / FOLDER_DOC
    return (ROOT / node.rel).with_suffix(".md")


# ------------------------------------------------------------------ 输入组装


_ENCODING = tiktoken.get_encoding("o200k_base")


def _tokens(text: str) -> int:
    # disallowed_special=()：源码里出现 <|endoftext|> 这类字面量会让默认行为抛异常，
    # 而那只是一段普通文本。
    return len(_ENCODING.encode(text, disallowed_special=()))


def fit(chunks: list[tuple[str, str]], budget: int) -> str:
    """把若干「标题 + 正文」拼成一段，超预算时**按比例**截断每一份。

    不是丢掉后面几份：那样目录概览会缺角，而缺了哪一角读的人并不知道。
    """
    rendered = [f"### {title}\n\n{body}" for title, body in chunks]
    total = sum(_tokens(r) for r in rendered)
    if total <= budget or not rendered:
        return "\n\n".join(rendered)

    ratio = budget / total
    out = []
    for r in rendered:
        keep = max(50, int(_tokens(r) * ratio))
        ids = _ENCODING.encode(r, disallowed_special=())
        out.append(_ENCODING.decode(ids[:keep]) + "\n\n_（为控制长度已截断）_")
    return "\n\n".join(out)


def render_tree(paths: list[str]) -> str:
    """仓库的目录树，每次调用都原样附在 prompt 里当全局定位。

    **目录名必须出现。** SkillTron 版的第一版只打了文件名、靠缩进表示层级，
    模型收到一堆并列的同名文件根本不知道自己在看哪个包，于是开始虚构不存在的
    模块——这类产物读起来通顺、语气笃定，只有逐条核对才发现在描述不存在的东西。
    """
    lines: list[str] = []
    seen: set[str] = set()
    for rel in sorted(paths):
        parts = Path(rel).parts
        for i in range(len(parts) - 1):
            folder = "/".join(parts[: i + 1])
            if folder not in seen:
                seen.add(folder)
                lines.append("  " * i + parts[i] + "/")
        lines.append("  " * (len(parts) - 1) + parts[-1])
    return "\n".join(lines)


def build_prompt(node: Node, nodes: dict[str, Node], tree: str) -> str:
    if not node.is_dir:
        code = (ROOT / node.rel).read_text(encoding="utf-8", errors="replace")
        return FILE_PROMPT.format(path=node.rel, tree=tree, lang=fence_lang(node.rel), code=code)

    files: list[tuple[str, str]] = []
    folders: list[tuple[str, str]] = []
    for child in node.children:
        child_doc = doc_path(nodes[child])
        if not child_doc.exists():
            continue
        body = child_doc.read_text(encoding="utf-8", errors="replace").strip()
        if nodes[child].is_dir:
            folders.append((f"{child}/", body))
        else:
            files.append((child, body))

    budget = MAX_INPUT_TOKENS - _tokens(FOLDER_PROMPT) - _tokens(tree)
    half = budget // 2
    return FOLDER_PROMPT.format(
        path=node.rel,
        tree=tree,
        file_summaries=fit(files, half) or "（这一层没有直属文件）",
        subfolder_summaries=fit(folders, budget - half) or "（这一层没有子文件夹）",
    )


# ------------------------------------------------------------------ 解读


def _archive_prompt(node: Node, prompt: str) -> None:
    """把这次实际发出去的 prompt 存下来，**发之前存**。

    发之后存的话，最想看它的那种情况（调用炸了、结果不对）恰好存不下来。
    """
    PROMPT_DIR.mkdir(parents=True, exist_ok=True)
    name = node.rel.replace("/", "__") or "ROOT"
    (PROMPT_DIR / f"{name}.md").write_text(prompt, encoding="utf-8")


def explain(node: Node, nodes: dict[str, Node], tree: str, cfg: LLMConfig, model: str | None) -> None:
    """解读一个节点并落盘。**失败直接抛**——不写半截文件、不更新 hash。"""
    prompt = build_prompt(node, nodes, tree)
    _archive_prompt(node, prompt)
    result = call_llm(
        prompt,
        cfg=cfg,
        model=model,
        max_retries=MAX_RETRIES,
        backoff=BACKOFF,
        max_total_backoff=MAX_TOTAL_BACKOFF,
        log_prefix=f"explain:{node.rel}",
        cache=True,  # 同样的代码就该得到同样的解读
    )
    doc = doc_path(node)
    doc.parent.mkdir(parents=True, exist_ok=True)
    doc.write_text(result.text.strip() + "\n", encoding="utf-8")


# ------------------------------------------------------------------ 调度


def load_cache() -> dict:
    try:
        data = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def stale_nodes(
    nodes: dict[str, Node], hashes: dict[str, str], cache: dict, force: bool
) -> list[Node]:
    """挑出要重算的。判据两个取或：hash 对不上，**或**产物不在了。
    后者是为了自愈——产物被手动删掉时，光看 hash 会认为「算过了」，洞永远补不上。
    """
    known = {} if force else cache.get("nodes", {})
    out = []
    for rel, node in sorted(nodes.items()):
        doc = doc_path(node)
        if known.get(rel) != hashes[rel] or not doc.exists():
            out.append(node)
    return out


def run(targets: list[Node], nodes, hashes, cache, *, concurrency, cfg, model) -> int:
    """按深度分层跑。返回失败数。"""
    tree = render_tree(sorted(r for r, n in nodes.items() if not n.is_dir))
    console = Console()
    saved = dict(cache.get("nodes", {}))
    failures: list[tuple[str, str]] = []

    # 文件全在第 0 层；目录按深度从深到浅。层内并发，层间等齐。
    layers: list[list[Node]] = []
    files = [n for n in targets if not n.is_dir]
    if files:
        layers.append(files)
    dirs = [n for n in targets if n.is_dir]
    for depth in sorted({n.depth for n in dirs}, reverse=True):
        layers.append([n for n in dirs if n.depth == depth])

    with Progress(
        SpinnerColumn(),
        TextColumn("[bold blue]{task.description}"),
        BarColumn(),
        MofNCompleteColumn(),
        TimeElapsedColumn(),
        console=console,
    ) as progress:
        task = progress.add_task("解读中", total=len(targets))
        for layer in layers:
            kind = "文件" if not layer[0].is_dir else f"目录（深度 {layer[0].depth}）"
            progress.update(task, description=f"{kind} × {len(layer)}")

            with ThreadPoolExecutor(max_workers=concurrency) as pool:
                futures = {pool.submit(explain, n, nodes, tree, cfg, model): n for n in layer}
                for future, node in futures.items():
                    try:
                        future.result()
                        saved[node.rel] = hashes[node.rel]
                        progress.console.print(f"  [green]✓[/] {node.rel}")
                    except Exception as exc:  # noqa: BLE001 —— 一份失败不该让整轮白跑
                        failures.append((node.rel, str(exc).splitlines()[0][:160]))
                        progress.console.print(f"  [red]✗[/] {node.rel}：{failures[-1][1]}")
                    finally:
                        progress.advance(task)

            # 每层跑完就落盘：中途被 Ctrl-C 时，已经花掉的钱不白花。
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            CACHE_PATH.write_text(
                json.dumps(
                    {"generator_version": GENERATOR_VERSION, "model": model or "", "nodes": saved},
                    ensure_ascii=False,
                    indent=1,
                ),
                encoding="utf-8",
            )

    if failures:
        console.print(f"\n[red]{len(failures)} 份没跑成：[/]")
        for rel, why in failures[:20]:
            console.print(f"  {rel}：{why}")
    return len(failures)


# ------------------------------------------------------------------ 仓库地图


def render_map(lines: dict[str, str]) -> str:
    """把 `{路径: 一句话}` 排成带缩进的目录树。缩进本身是信息：
    一眼能看出哪些文件是一伙的、模块怎么分的。"""
    nodes = build_tree(sorted(lines))
    out: list[str] = []

    def walk(rel: str, depth: int) -> None:
        node = nodes[rel]
        if not node.is_dir:
            out.append(f"{'  ' * depth}- `{Path(rel).name}` — {lines[rel]}")
            return
        if rel != ".":  # 根目录不占一行，它的孩子就是最外层
            # 目录也有自己的一句话。少了它，agent 只能靠目录名猜这里装的是什么。
            desc = lines.get(rel)
            out.append(f"{'  ' * depth}- `{Path(rel).name}/`" + (f" — {desc}" if desc else ""))
        for child in node.children:
            walk(child, depth + (0 if rel == "." else 1))

    walk(".", 0)
    return "\n".join(out)


def replace_section(text: str, title: str, body: str) -> str:
    """把 `text` 里 `title` 这一段的内容换成 `body`，段落边界是下一个 `## `。

    找不到这个标题就追加到文件末尾——第一次跑就是走这条路。
    `startswith("## ")` 的尾随空格不能省：少了它 `### 三级标题` 也会被当成
    段落结束，地图一旦出现三级标题就会被从中间腰斩。
    """
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.strip() == title), None)
    if start is None:
        if not text.strip():
            return f"{title}\n\n{body}\n"
        return text.rstrip("\n") + f"\n\n{title}\n\n{body}\n"
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines)
    )
    return "\n".join(lines[: start + 1] + ["", body, ""] + lines[end:]).rstrip("\n") + "\n"


def load_map_cache(nodes: dict[str, Node]) -> dict:
    """读地图缓存，按 prompt 版本分别作废（文件句归 MAP_FILE_VERSION 管，
    目录句归 MAP_DIR_VERSION 管——只改目录 prompt 时文件那批不跟着重跑）。
    顺手把已经不存在的路径丢掉：指向不存在路径的行比没有那行更糟，agent 会照着去找。
    """
    try:
        data = json.loads(MAP_CACHE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}

    alive = {
        rel: (MAP_DIR_VERSION if node.is_dir else MAP_FILE_VERSION)
        == data.get("dir_version" if node.is_dir else "file_version")
        for rel, node in nodes.items()
    }
    lines = {r: v for r, v in data.get("lines", {}).items() if alive.get(r)}
    return {
        "lines": lines,
        "nodes": {r: v for r, v in data.get("nodes", {}).items() if r in lines},
    }


def build_map(
    cfg: LLMConfig,
    model: str | None,
    concurrency: int,
    console: Console,
    force: bool,
    dry_run: bool = False,
) -> int:
    """生成/更新仓库地图，写进 CLAUDE.md 的 `MAP_SECTION` 那一段。返回失败数。"""
    nodes = build_tree(tracked_sources(include_map_only=True))
    hashes = compute_hashes(nodes)
    cache = load_map_cache(nodes)
    known_hash = {} if force else cache.get("nodes", {})
    lines: dict[str, str] = {
        rel: line for rel, line in cache.get("lines", {}).items() if rel in nodes
    }

    stale = [n for n in nodes.values() if known_hash.get(n.rel) != hashes[n.rel] or n.rel not in lines]
    n_file = sum(1 for n in stale if not n.is_dir)
    console.print(
        f"地图：{len(nodes)} 个节点，其中 [bold]{len(stale)}[/] 个要重新生成"
        f"（{n_file} 个文件 + {len(stale) - n_file} 个目录）"
    )

    # 干看模式必须退在写 CLAUDE.md 之前——地图这条线最后一步会改一个入库文件，
    # `--dry-run` 的承诺是「什么都不动」。
    if dry_run:
        for node in sorted(stale, key=lambda n: (not n.is_dir, n.rel)):
            console.print(f"  {'📁' if node.is_dir else '📄'} {node.rel}")
        return 0

    # 分批：文件全在第一批（彼此不依赖），目录按深度从深到浅——
    # 目录那句是拿子项的句子汇总的，子项必须先跑完。
    batches: list[list[Node]] = []
    files = [n for n in stale if not n.is_dir]
    if files:
        batches.append(files)
    dirs = [n for n in stale if n.is_dir]
    for depth in sorted({n.depth for n in dirs}, reverse=True):
        batches.append([n for n in dirs if n.depth == depth])

    tree = render_tree(sorted(r for r, n in nodes.items() if not n.is_dir))

    def assemble(node: Node) -> str:
        if not node.is_dir:
            return MAP_PROMPT.format(
                path=node.rel,
                tree=tree,
                lang=fence_lang(node.rel),
                code=(ROOT / node.rel).read_text(encoding="utf-8", errors="replace"),
            )
        kids = [
            f"- `{c}{'/' if nodes[c].is_dir else ''}` — {lines[c]}"
            for c in node.children
            if c in lines
        ]
        return MAP_FOLDER_PROMPT.format(
            path=node.rel if node.rel != "." else "（仓库根目录）",
            children="\n".join(kids) or "（这一层是空的）",
        )

    def persist() -> None:
        MAP_CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        MAP_CACHE_PATH.write_text(
            json.dumps(
                {
                    "file_version": MAP_FILE_VERSION,
                    "dir_version": MAP_DIR_VERSION,
                    "model": model or "",
                    # 只记跑成功的那些的 hash：失败的留着旧 hash 会被当成
                    # 「算过了」，那个洞永远补不上。
                    "nodes": {r: hashes[r] for r in lines},
                    "lines": lines,
                },
                ensure_ascii=False,
                indent=1,
            ),
            encoding="utf-8",
        )

    failures = 0
    if stale:
        with Progress(
            SpinnerColumn(),
            TextColumn("[bold blue]{task.description}"),
            BarColumn(),
            MofNCompleteColumn(),
            TimeElapsedColumn(),
            console=console,
        ) as progress:
            task = progress.add_task("生成地图", total=len(stale))
            for i, batch in enumerate(batches, 1):
                kind = "文件" if not batch[0].is_dir else f"第 {batch[0].depth} 层目录"
                progress.update(
                    task, description=f"第 {i}/{len(batches)} 批：{len(batch)} 个{kind}　总进度"
                )
                with ThreadPoolExecutor(max_workers=concurrency) as pool:
                    futures = {
                        pool.submit(
                            call_llm,
                            assemble(n),
                            cfg=cfg,
                            model=model,
                            max_retries=MAX_RETRIES,
                            backoff=BACKOFF,
                            max_total_backoff=MAX_TOTAL_BACKOFF,
                            log_prefix=f"map:{n.rel}",
                            cache=True,
                        ): n
                        for n in batch
                    }
                    for future in as_completed(futures):
                        node = futures[future]
                        try:
                            # 折成一行：这句话要进 markdown 列表项，自带换行会把
                            # 后半截甩出列表、破坏缩进结构。
                            lines[node.rel] = " ".join(future.result().text.split())
                            progress.console.print(f"  [green]✓[/] {node.rel}")
                        except Exception as exc:  # noqa: BLE001 —— 一句失败不该让整轮白跑
                            failures += 1
                            progress.console.print(
                                f"  [red]✗[/] {node.rel}：{str(exc).splitlines()[0][:120]}"
                            )
                        finally:
                            progress.advance(task)
                            persist()  # 每句跑完立刻存，中途 Ctrl-C 花掉的钱不白花

    body = render_map(lines)
    # CLAUDE.md 可能还不存在（第一次跑）：从空文件开始，replace_section 会追加整段。
    original = CLAUDE_MD.read_text(encoding="utf-8") if CLAUDE_MD.exists() else ""
    CLAUDE_MD.write_text(replace_section(original, MAP_SECTION, body), encoding="utf-8")

    tok = len(_ENCODING.encode(body, disallowed_special=()))
    console.print(f"\n地图已写入 {CLAUDE_MD.name} 的「{MAP_SECTION.lstrip('# ')}」一段")
    console.print(f"  {len(lines)} 行，约 {tok:,} token")
    if failures:
        console.print(f"  [red]{failures} 句没跑成，下次会自动补[/]")
    return failures


def map_preview(prefix: str, limit: int, cfg: LLMConfig, model: str | None, console: Console) -> int:
    """拿 `MAP_PROMPT` 跑一小片文件，把结果按地图的样子打出来，**不写任何文件**。

    调 prompt 专用。一次跑一片而不是单个文件：地图的价值在于几十行摆在一起时
    风格是否统一、粒度是否一致，只看一行判断不了。
    """
    nodes = build_tree(tracked_sources(include_map_only=True))
    prefix = prefix.rstrip("/")
    hits = [
        n
        for r, n in sorted(nodes.items())
        if not n.is_dir and (r == prefix or r.startswith(prefix + "/"))
    ]
    if not hits:
        console.print(f"[red]{prefix} 底下没有源文件[/]")
        return 1

    picked = hits[:limit]
    tree = render_tree(sorted(r for r, n in nodes.items() if not n.is_dir))
    console.print(f"[dim]{prefix} 底下 {len(hits)} 个文件，本次跑前 {len(picked)} 个…[/]\n")

    results: list[tuple[str, str]] = []
    with ThreadPoolExecutor(max_workers=min(len(picked), DEFAULT_CONCURRENCY)) as pool:
        futures = {
            pool.submit(
                call_llm,
                MAP_PROMPT.format(
                    path=n.rel,
                    tree=tree,
                    lang=fence_lang(n.rel),
                    code=(ROOT / n.rel).read_text(encoding="utf-8", errors="replace"),
                ),
                cfg=cfg,
                model=model,
                max_retries=MAX_RETRIES,
                backoff=BACKOFF,
                max_total_backoff=MAX_TOTAL_BACKOFF,
                log_prefix=f"map:{n.rel}",
                cache=True,
            ): n
            for n in picked
        }
        for future in as_completed(futures):
            node = futures[future]
            try:
                results.append((node.rel, " ".join(future.result().text.split())))
            except Exception as exc:  # noqa: BLE001
                results.append((node.rel, f"【失败】{str(exc).splitlines()[0][:80]}"))

    console.print("[bold]地图长这样（这就是会进 CLAUDE.md 的东西）：[/]\n")
    for rel, line in sorted(results):
        console.print(f"- `{rel}` — {line}", highlight=False, markup=False)

    lengths = [len(line) for _, line in results]
    console.print(
        f"\n[dim]{len(results)} 行；每行 {min(lengths)}–{max(lengths)} 字"
        f"（要的是 50 以内、且彼此接近）。没有写任何文件。[/]"
    )
    return 0


def build_explanations(
    console: Console,
    *,
    cfg: LLMConfig,
    force: bool,
    only: str | None,
    dry_run: bool,
    concurrency: int,
    model: str | None,
) -> int:
    """跑解读：每个源文件一份同名 md、每个目录一份 EXPLAIN.md。返回失败数。"""
    nodes = build_tree(tracked_sources())
    if not nodes:
        console.print("[yellow]没有找到任何源文件[/]")
        return 0

    hashes = compute_hashes(nodes)
    cache = load_cache()
    # 生成逻辑或模型换了 → 旧产物是用另一套东西做出来的，全部作废。
    if cache.get("generator_version") != GENERATOR_VERSION:
        if cache:
            console.print("[yellow]explain_repo.py 变了（prompt 或生成逻辑），本轮全量重算[/]")
        cache = {"nodes": dict.fromkeys(cache.get("nodes", {}), "")}
    elif cache.get("model") != (model or ""):
        if cache:
            console.print("[yellow]模型变了，本轮全量重算[/]")
        cache = {}

    targets = stale_nodes(nodes, hashes, cache, force)
    if only:
        prefix = only.rstrip("/")
        targets = [n for n in targets if n.rel == prefix or n.rel.startswith(prefix + "/")]
    if not targets:
        console.print(f"[green]全部是最新的[/]（{len(nodes)} 个节点）")
        return 0

    n_files = sum(1 for n in targets if not n.is_dir)
    console.print(
        f"要解读 [bold]{len(targets)}[/] 个：{n_files} 个文件 + "
        f"{len(targets) - n_files} 个目录（共 {len(nodes)} 个节点）"
    )
    if dry_run:
        for node in targets:
            console.print(f"  {'📁' if node.is_dir else '📄'} {node.rel}")
        return 0

    return run(targets, nodes, hashes, cache, concurrency=concurrency, cfg=cfg, model=model)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--all", action="store_true", help="忽略缓存，全部重算")
    parser.add_argument("--concurrency", type=int, default=DEFAULT_CONCURRENCY)
    parser.add_argument("--model", default=None, help="覆盖默认模型（config.json 的 model）")
    parser.add_argument("--dry-run", action="store_true", help="只报要算什么，不真调模型")
    parser.add_argument(
        "--only",
        default=None,
        help="只解读这个路径前缀下的节点。放量前拿一个小目录冒烟用——"
        "改 prompt 之后先跑它，别一上来就全仓调用。",
    )
    parser.add_argument(
        "--map-preview",
        default=None,
        metavar="路径前缀",
        help="拿 MAP_PROMPT 跑这个前缀下的头几个文件，把「仓库地图」的样子打到"
        "终端，不写任何文件。调 MAP_PROMPT 专用。",
    )
    parser.add_argument(
        "--map-limit", type=int, default=5, help="--map-preview 一次跑几个文件（默认 5）"
    )
    # `--map-only` 与 `--no-map` 是同一个选择的两端，同时给等于什么都不跑，直接拦。
    side = parser.add_mutually_exclusive_group()
    side.add_argument(
        "--map-only",
        action="store_true",
        help=f"只跑仓库地图（写进 CLAUDE.md 的「{MAP_SECTION.lstrip('# ')}」一段），跳过解读。",
    )
    side.add_argument(
        "--no-map",
        action="store_true",
        help="只跑解读，不碰 CLAUDE.md 里的仓库地图。",
    )
    args = parser.parse_args()

    console = Console()
    # --dry-run 不碰网络，不该被「没配 key」拦住——想看清单的机器未必有 key。
    # --map-preview 例外：它的用途就是真调模型看样子，必须解析配置。
    cfg = resolve_llm_config() if args.map_preview or not args.dry_run else None

    if args.map_preview:
        return map_preview(args.map_preview, args.map_limit, cfg, args.model, console)

    # 默认两个产物一起跑。SkillTron 的教训：同一个入口藏两套产物、默认静默只做
    # 一半，跑完 CLAUDE.md 纹丝不动还什么都不提示——那是接口的错，不是人记性的错。
    failed = 0
    if not args.map_only:
        failed += build_explanations(
            console,
            cfg=cfg,
            force=args.all,
            only=args.only,
            dry_run=args.dry_run,
            concurrency=args.concurrency,
            model=args.model,
        )

    if args.no_map:
        pass  # 明确点名不要，不必再解释一遍
    elif args.only:
        # `--only` 是冒烟用的，后面接一趟全量地图违背它的用意。但必须说出来——
        # 悄悄跳过正是上面那段要防的病，换个地方犯不算修好。
        console.print(
            f"[dim]--only {args.only} 是冒烟模式，跳过地图（只要地图：--map-only）[/]"
        )
    else:
        console.print()
        failed += build_map(
            cfg, args.model, args.concurrency, console, args.all, dry_run=args.dry_run
        )

    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
