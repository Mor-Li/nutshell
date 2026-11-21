# Nutshell

macOS 上的浮窗小工具。复制点东西、按一下快捷键，鼠标旁边弹出一扇浮窗，用大白话解读剪贴板里的内容。可以在窗里接着追问，可以同时开好几扇窗，聊过的对话都会存档。另外带一个终端版，在终端里直接跟模型来回聊。

浮窗版用 Swift 写，靠 SwiftPM 构建，没有 Xcode 工程。终端版用 Python 写，靠 uv 管理。两者共用同一份配置文件。

快捷键本身不归这个程序管。BetterTouchTool 收到手势后，往本机 8823 端口发一个 HTTP 请求，Nutshell 收到请求就开窗。

## 一、每个文件夹放什么

| 位置 | 放什么 |
|---|---|
| `Sources/Nutshell/` | 浮窗版的全部 Swift 源码，一个文件管一件事，分工见下一节 |
| `Sources/Nutshell/Resources/` | 浮窗里显示正文的那张网页 `viewer.html`，和它用的 Markdown 解析库 `marked.min.js`、数学公式排版库 KaTeX（`katex.min.js` 和字体已内联的 `katex.inline.min.css`）。打包时原样带进 app，加载时全部内联进网页，不联网 |
| `Tests/NutshellTests/` | 浮窗版的自动化测试。不弹窗、不联网，模型接口是假的 |
| `cli/` | 终端版。`cli/nutshell_cli/` 是源码，`pyproject.toml` 和 `uv.lock` 是依赖声明 |
| `icon/` | app 图标。`AppIcon-source.png` 是纯棕色底上的扁平风图案（2026-11-20 用 GPT Image 2.5 生成：裂开的榛子里冒出一个对话气泡），`AppIcon.png` 和 `AppIcon.icns` 由 `scripts/make_icon.py` 生成，`make app` 把 icns 放进 app。用户不要图标外面那圈圆角方块底板（2026-11-21），所以脚本把底色抠掉，只留图案本身。之前那版写实风的原图在提交 8127efc 里 |
| `scripts/` | 开发时用的辅助脚本，不随 app 发布。`explain_repo.py` 生成代码解读和本文件末尾的地图，`try-prompt.sh` 在终端里单独试 prompt，`make_icon.py` 把 `icon/AppIcon-source.png` 的纯色底抠掉、只留图案，打成 icns（`uv run scripts/make_icon.py`），`vendor_katex.py` 拉 KaTeX 并把字体转成 base64 写进 CSS（`uv run scripts/vendor_katex.py [版本号]`，升级 KaTeX 时用） |
| `demo/` | README 里那段演示动画和顶上横幅图的源文件。`demo.html` 是动画（一台 MacBook、两只手、⌘A ⌘C、两指连点、浮窗弹出，每一刻由 `renderAt(t)` 算出），`banner.html` 是横幅，`render.py` 用本机 Chrome 逐帧截图再用 ffmpeg 拼成 GIF（`uv run demo/render.py`，`--banner` 出横幅，`--stills 2,4.2 --out 某临时目录` 只截静帧看效果）。动画里浮窗的样子照着真实浮窗画的，真实浮窗改了外观，这里也要跟着改 |
| `assets/` | README 用的图：`banner-en.png`、`banner-zh.png`、`nutshell-demo-en.gif`、`nutshell-demo-zh.gif`，都由 `demo/render.py` 生成，不要手改 |
| `docs/explain/` | `explain_repo.py` 生成的逐文件、逐目录通俗解读，给人翻阅用。里面的层级照搬仓库本身。不进 git |
| 根目录 | `Package.swift` 是构建配置，`Info.plist` 是 app 的身份信息，`Makefile` 是打包安装命令，`README.md`（英文，GitHub 默认显示这份）和 `README.zh-CN.md`（中文）是给人看的使用说明，两份顶上互相链接，`AGENTS.md` 是本文件，`.env` 放终端版直连 Gemini 用的密钥（不进 git） |
| `.build/` 和 `build/` | 构建产物，前者是 SwiftPM 的中间文件，后者是打好的 `Nutshell.app`。都不进 git，随时可删 |

## 二、浮窗版的源码怎么分工

按一次快捷键，事情是这样流转的。

1. **进门**。`main.swift` 启动程序。`TriggerServer.swift` 守着 8823 端口等请求。`AppDelegate.swift` 是总调度，收到请求后决定开新窗还是弹历史清单，并管着所有开着的窗。`CloseHotKey.swift` 在有窗开着时接管 ⌘W。
2. **读输入**。`InputCapture.swift` 看剪贴板里是文字、图片、PDF 还是文件，整理成能发给模型的样子。
3. **一扇窗一段对话**。`ExplainWindowController.swift` 管一扇窗里的整段对话：发问、追问、流式收字、出错后的重试、存档。
4. **调模型**。`LLMClient.swift` 负责发请求和流式收字，被限流时自动重试。
5. **窗口界面**。`PopoverPanel.swift` 是浮窗本体，管顶栏按钮、窗口定位和底部打字区的布局。`ComposerViews.swift` 是打字区的两个零件：能自己长高的多行输入框，和输入框上面那根可以拖的分隔线。`MarkdownView.swift` 是显示正文的那块，里面跑着 `Resources/viewer.html`。
6. **存取**。`SessionStore.swift` 把对话存成文件、读回来。`Config.swift` 读写配置，默认 prompt 也在这个文件顶部。

## 三、仓库外面的东西

用户的数据都不在仓库里，在 `~/.config/nutshell/`。

| 位置 | 放什么 |
|---|---|
| `~/.config/nutshell/config.json` | 配置：网关地址、模型、prompt、窗口大小、端口。浮窗版和终端版共用 |
| `~/.config/nutshell/sessions/` | 浮窗版的聊天记录。一段对话一个 JSON 文件，文件名开头是时间。`index.json` 是标题索引。只增不删 |
| `~/.config/nutshell/chats/` | 终端版的聊天记录，同样一段对话一个 JSON 文件 |
| `~/.config/nutshell/cli_history` | 终端版里按上下键能翻到的输入历史 |
| `~/Applications/Nutshell.app` | 装好的浮窗版。已加进系统登录项，开机自启动 |

## 四、常用命令

- 发新版本：改 `Info.plist` 里的 `CFBundleShortVersionString`，`make app` 后把 `build/Nutshell.app` 用 `ditto -c -k --keepParent` 压成 zip，打 `vX.Y.Z` 标签，用 `gh release create` 发布并附上 zip，发布说明照 README 的 News 写，中英都写。app 只做了临时签名，下载的人第一次打开要右键「打开」或者跑 `xattr -dr com.apple.quarantine`，发布说明里要写
- `make install` 编译、打包、装到 `~/Applications/Nutshell.app` 并重启。重启会关掉当时开着的浮窗，对话都已存档，从历史里能翻回来
- `make test` 跑自动化测试
- `make run` 跑构建目录里的版本，调试用
- `curl -s http://127.0.0.1:8823/explain` 手动触发一次解读
- `curl -s http://127.0.0.1:8823/reload` 改完 `config.json` 后热加载
- `uv tool install --editable ./cli` 安装终端版，之后敲 `nutshell` 或 `nut`
- `source ~/.zshrc && uv run scripts/explain_repo.py` 重新生成 `docs/explain/` 和本文件末尾的地图。增量的，只重算改过的文件

## 五、改完怎么验证

- 先跑 `make test`。改了界面行为或对话流程，就在 `Tests/NutshellTests/` 里补对应的测试。
- 测试必须用 `make test` 跑，不要直接敲 `swift test`。`make test` 会把存档目录指到临时文件夹，直接跑的话测试会拒绝执行，免得假对话混进真实的历史。
- 不要在用户的屏幕上弹出真窗口、再用模拟鼠标键盘去点。浮窗一被点就会接管键盘，他正在别处打的字会被吞掉，开着窗的期间 ⌘W 也会被它截走。2026-11-16 这样试过，踩了这个坑。
- 需要看界面长什么样时，在测试里把窗口设成全透明再渲染成图片，参考 `ComposerTests.swift` 的 `setUp`。
- 模拟"答到一半断网"这类情况，用 `TestSupport.swift` 里的 `FakeLLM`。

## 六、硬性约束

- 根目录的 `README.md` 和 `README.zh-CN.md` 是人写的门面，生成脚本不许碰它们。脚本的目录产物叫 `EXPLAIN.md` 就是为了躲开它们。
- README 有中英两份，内容要保持一致：改了一份就同步另一份，News 两边各加一条。英文版是默认的那份（用户 2026-11-21）。GitHub 仓库简介也是英文在前、中文在后。
- 说明文件只有 `AGENTS.md` 这一份，不建 `CLAUDE.md`。
- 下面「仓库代码地图」一节由 `scripts/explain_repo.py` 自动维护，不要手工编辑，下次跑会整段覆盖。标题也不要改，改了脚本会在文件末尾另起一份。
- 不要去改正文那块网页视图的大小来配合底部打字区。网页视图固定从顶栏铺到窗口底，被打字区盖住的一截由 `MarkdownView` 裁掉，再用 `nsBottomInset` 告诉页面底部让出多高。直接改大小的做法出过毛病：分隔线往下拖回去之后，线上面会留一块空白不画。`TranscriptInsetTests.swift` 守着这条。
- 数学公式在 `viewer.html` 里靠两个 marked 扩展认出来（`mathBlock` 和 `mathInline`），认的是 `$…$`、`$$…$$`、`\(…\)`、`\[…\]` 四种写法。公式必须在 marked 解析时整段截下来交给 KaTeX，不能等 marked 出完 HTML 再找，那时 `\\` 已经被吃成 `\`、`_x_` 已经变成斜体。单个 `$` 的规则是为了躲开钱数（"$5 到 $10"），改它之前先跑 `MathRenderingTests.swift`。
- 浮窗正文里有两种给程序看的记号，改动时两边要一起改。`<!--ns-user-->` 包着用户说的话，网页据此画成气泡。`<!--ns-failed-->` 贴在正文末尾，表示最后一轮没答成，网页据此显示「重试」按钮。写记号的是 `ExplainWindowController.swift`，认记号的是 `viewer.html`。

## 仓库代码地图

- `Info.plist` — macOS 应用包配置清单（Bundle ID、隐藏 Dock 的 `LSUIElement`、系统权限声明）；调整版本号、系统要求或新增权限文案时修改。
- `Makefile` — 负责将 Swift 产物和资源组装为签名 `.app`、安装启停及隔离跑测；改构建打包、签名或测试命令时动它。
- `Package.swift` — 定义 SwiftPM 构建配置、源码与测试 target 及资源打包规则；增删第三方依赖、调整系统版本或编译设置时修改。
- `README.md` — 项目使用文档与目录地图；变更安装/BTT 配置、config.json 字段、浮窗交互、CLI 命令或源码文件结构时同步更新。
- `Sources/` — Swift Package 源码根目录，存放应用本体全部业务代码与资源；除工程配置外的所有功能与界面开发均来此查找。
  - `Nutshell/` — 应用核心源码与内嵌资源目录，承载从触发捕获、LLM 交互到浮窗渲染的全部业务逻辑；所有功能与界面改动均在此处。
    - `AppDelegate.swift` — 应用总控（`AppDelegate`）：统筹菜单栏、HTTP 触发路由、多浮窗调度与历史菜单交互；改全局入口或窗口管理时动它。
    - `CloseHotKey.swift` — 封装 `CloseHotKey` 类，在浮窗显示时通过 Carbon 临时拦截全局 ⌘W 以关闭浮窗；修改关闭快捷键或全局按键拦截逻辑时改这里。
    - `ComposerViews.swift` — 提供浮窗底部的自适应高度多行输入框（`InputTextView`）与可拖拽分隔线（`DividerHandle`）；修改输入框排版、占位符或分隔线拖拽交互时改这里。
    - `Config.swift` — 定义 `Config` 与 `ConfigStore`，负责读写配置、默认提示词及读取环境变量 API Key；增改配置项或默认参数时修改。
    - `ExplainWindowController.swift` — 编排单扇浮窗的对话状态机与生命周期（剪贴板开场、追问、流式拼接、失败重试、会话存取）；改单窗交互流程时动它。
    - `InputCapture.swift` — `InputCapture`：读取剪贴板并将文件（PDF/图片/文档）、截图或文本转为模型输入；改输入解析、支持格式或图片压缩时动它。
    - `LLMClient.swift` — `LLMClient` 负责调用 `/chat/completions` 流式接口、系统时间注入及 429 重试；修改请求载荷、SSE 解析或报错文案时改它。
    - `MarkdownView.swift` — 封装 `WKWebView` 桥接 `viewer.html` 渲染对话，改流式节流、Swift-JS 通信或链接拦截时动它。
    - `PopoverPanel.swift` — 定义不抢焦点的浮窗容器 `PopoverPanel`；需调整顶栏、输入框高度与按键行为、焦点策略或鼠标旁定位算法（`frame`）时修改。
    - `Resources/` — 存放打包进应用的静态资源，目前主要是浮窗 Web 前端模板；改页面样式、排版渲染或 JS 桥接时来这里。
      - `viewer.html` — WKWebView 页面模板，负责对话气泡、图片与 Markdown 渲染及 `ns*` 桥接函数；改排版样式、展开/重试交互或网页桥接时动它。
    - `SessionStore.swift` — `SessionStore` 负责对话历史与索引的 JSON 持久化及标题生成，改存档结构或历史管理时动它。
    - `TriggerServer.swift` — `TriggerServer` 监听本地 HTTP 端口解析请求路径并回调；需改触发协议、解析请求参数或调整监听报错时修改。
    - `main.swift` — 应用入口，以无 Dock 图标模式启动 `NSApplication` 并挂载 `AppDelegate`；仅调整应用级激活策略或启动引导时需修改。
- `Tests/` — 存放自动化测试套件与测试桩，用于验证各模块功能与防止回归；新增特性或修复逻辑时需要在此补充用例。
  - `NutshellTests/` — 包含浮窗 UI 布局、交互及对话状态恢复的自动化测试与桩工具；修改视图行为或对话流时需在此增改用例。
    - `ComposerTests.swift` — 测试 `PopoverPanel` 底部输入区（`InputTextView` 自动长高与回车发送、`DividerHandle` 拖拽调高），修改输入区交互或布局时同步更新。
    - `RetryTests.swift` — 用 FakeLLM 测试回答中断后的重试按钮渲染、半截回答清理、消息回滚及历史恢复；修改中断重试逻辑时同步更新。
    - `TestSupport.swift` — 提供测试辅助函数（视图查找、沙箱校验、异步等待）与 `FakeLLM` 模拟接口；需调整测试桩行为或共用工具时修改。
    - `TranscriptInsetTests.swift` — 测试 `MarkdownView` 与输入框重叠布局及高度避让逻辑，修改 `extendPage`、底栏高度联动或点击穿透时需更新。
- `cli/` — Nutshell 独立终端版（Python 实现），负责脱离 macOS GUI 的纯命令行问答交互；修改 CLI 工具及其打包配置时看这里。
  - `nutshell_cli/` — Nutshell 独立终端版的 Python 核心包；涉及命令行对话、附件解析或终端流式渲染时进此目录。
    - `__init__.py` — `nutshell_cli` 包标识与模块文档，仅在需暴露包级 API 或版本号时修改。
    - `attach.py` — 解析 CLI 消息中的路径并展开为文本、图片或 PDF 附件（`expand`、`data_url`），改路径识别、目录过滤或媒体编码时动它。
    - `main.py` — 终端版入口与主循环，负责后端配置切换、对话存档与自动起标题（`Chat`）、流式请求（`ask`）及斜杠命令，改 CLI 交互或存档时动它。
    - `render.py` — 负责 CLI 终端的流式 Markdown 渲染（`StreamRenderer`）；需改终端输出样式、分块切分或实时刷新逻辑时修改。
- `scripts/` — 独立于 App 运行时的本地开发辅助与自动化脚本，需终端直调 LLM 调试提示词或自动更新仓库文档时查此目录。
  - `explain_repo.py` — 增量生成 `docs/explain/` 代码解读并维护 `AGENTS.md` 仓库地图，改解读提示词、文件扫描范围或批量 LLM 调用策略时动它。
  - `try-prompt.sh` — 绕过 App 读 `config.json` 直调 LLM 的终端调试脚本；改配置结构或提示词拼装逻辑时需同步更新。
