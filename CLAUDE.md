# Nutshell

macOS 浮窗小工具：复制点东西、按一下快捷键（BTT 发 HTTP 到本机 8823 端口），
鼠标旁弹一扇浮窗用大白话解读剪贴板内容，可追问、可开多扇窗、有历史存档。
Swift + SPM，不用 Xcode 工程。

## 常用命令

- `make install` — 编译 + 打包 + 装到 `~/Applications/Nutshell.app` + 启动
- `make run` — 跑构建目录里的版本（调试用）
- `curl -s http://127.0.0.1:8823/explain` — 手动触发一次解读
- `curl -s http://127.0.0.1:8823/reload` — 改完 `~/.config/nutshell/config.json` 后热加载
- `source ~/.zshrc && uv run scripts/explain_repo.py` — 重新生成逐文件解读 + 下面的仓库代码地图（增量，只重算改过的）

## 硬性约束

- 根目录的 `README.md` 是人写的门面，`scripts/explain_repo.py` 的目录产物叫
  `EXPLAIN.md`，就是为了永远不碰它——别把产物命名改回 README。
- 下面「仓库代码地图」一段由 `scripts/explain_repo.py` 自动维护，别手工编辑
  （下次跑会整段覆盖）；改标题等于让脚本在文件末尾另起一份新的。

## 仓库代码地图

- `Info.plist` — 定义应用包名、版本、无 Dock 后台形态(`LSUIElement`)及权限声明；发版或申请新系统权限时动它。
- `Makefile` — 负责编译打包 macOS .app 及管理本地启停；仅在调整构建流程、资源复制逻辑或签名规则时修改。
- `Package.swift` — SPM 包管理配置文件，定义项目构建目标、平台版本和资源路径；仅在引入第三方依赖包、修改 macOS 最低版本限制或调整资源目录映射时修改。
- `README.md` — 项目文档与架构地图，当新增功能、修改配置字段、调整触发接口或重构文件目录时需同步更新此文件。
- `Sources/` — 存放项目所有 Swift 源码模块，凡涉及修改应用本体业务逻辑、后台机制或底层交互的纯代码需求均由此进入。
  - `Nutshell/` — 包含应用的所有 Swift 核心业务逻辑，修改生命周期、HTTP触发、剪贴板抓取、LLM通信或浮窗原生调度时进入此目录。
    - `AppDelegate.swift` — 负责管理应用生命周期、状态栏菜单、HTTP触发路由、隐藏主菜单（支持⌘C/V/W）及多浮窗（`ExplainWindowController`）的创建与排布；增改应用全局状态、触发入口、多窗口调度或历史菜单逻辑时修改此文件。
    - `CloseHotKey.swift` — 实现 `CloseHotKey` 用 Carbon 拦截全局 ⌘W 关闭浮窗。更改关闭快捷键或修复热键注册逻辑时修改。
    - `Config.swift` — 定义 `Config` 结构体及默认 Prompt，通过 `ConfigStore` 处理 JSON 配置读写与 Shell API Key 解析；增删配置字段或修改默认参数时修改此文件。
    - `ExplainWindowController.swift` — 负责单扇浮窗及单次对话的控制器；当需要修改抓词提问(`captureAndAsk`)、多轮追问流式调度(`send`)、上下文渲染装配或单条会话存盘逻辑时修改此文件。
    - `InputCapture.swift` — 负责读取剪贴板（`InputCapture.capture`），将文本、图片、PDF及文件解析为模型输入（`CapturedInput`）；需新增剪贴板格式支持、修改文件提取逻辑或调整图片压缩算法时改动此文件。
    - `LLMClient.swift` — 实现`LLMClient`处理流式请求与多模态组装；增改API参数、调整SSE解析或错误重试逻辑时修改此文件。
    - `MarkdownView.swift` — 负责基于WKWebView渲染Markdown。修改流式输出节流频率、与内嵌JS通信逻辑或外部链接跳转规则时动此文件。
    - `PopoverPanel.swift` — 负责 `PopoverPanel` 浮窗 UI。修改按钮、输入框布局、焦点逻辑或 `frame` 定位算法时动它。
    - `Resources/` — 存放浮窗的 Web 前端资源，涉及修改 WKWebView 视觉样式、前端渲染逻辑或 JS 交互时请查看此目录。
      - `viewer.html` — WKWebView 浮窗前端模板，负责 Markdown 与聊天气泡渲染、自动滚动，修改视觉样式或 `nsRender` 等 JS 接口时动它。
    - `SessionStore.swift` — 管理对话历史JSON存取与索引，修改落盘结构(StoredSession)、读写逻辑或标题生成(makeTitle)时动它。
    - `TriggerServer.swift` — 实现 `TriggerServer` 监听本地 HTTP 端口接收触发请求，修改 HTTP 响应、路径解析或端口冲突报错时改动此文件。
    - `main.swift` — 程序入口，实例化 AppDelegate 并以 .accessory 模式启动；仅更改应用基础运行形态时修改。
- `scripts/` — 独立于主工程的开发辅助脚本；处理脱机调试 Prompt 或自动化生成 AI 仓库上下文等周边维护任务。
  - `explain_repo.py` — 负责调用 LLM 增量生成全仓代码解读及 CLAUDE.md 仓库地图；当需要调整自动化文档生成逻辑、修改 LLM Prompt 或变更解析的文件类型范围时修改此文件。
  - `try-prompt.sh` — 独立于 App 在终端测试 prompt 的脚本；仅需调整 CLI 传参、API 负载组装或流式响应解析逻辑时修改。
