# Nutshell

选中 → 复制 → 按一下 → 鼠标旁边冒出一个小窗，用大白话给你讲清楚刚才那段是啥。

每按一次都开一扇**新**窗，可以同时开好几扇：这边解读着一段论文，那边再复制一段报错接着按，两份解读并排摆着对照看。看完点 ×（或 ⌘W / Esc）挨个收掉。

名字取自英文谚语 *in a nutshell*（一句话说清、简而言之）。

---

## 它解决什么问题

看英文论文、看别人甩过来的一大段技术文档、看一封云里雾里的邮件——
以前得切到浏览器、打开某个 AI 网页、粘进去、等、再切回来。切来切去，思路就断了。

现在：复制，按一下快捷键，答案就浮在你正在看的东西旁边。不切窗口，不打断。

## 能喂给它什么

不只是文字。复制什么它就认什么：

| 你复制的东西 | 它怎么处理 |
|---|---|
| 一段文字 | 直接解读 |
| 一个 PDF 文件 | 提取文字后解读 |
| 扫描版 PDF（没有文字层） | 自动把前几页渲染成图片，看图讲 |
| 一张图 / 一张截图 | 走多模态，看图讲 |
| Word、RTF、HTML | 交给系统自带的 `textutil` 转成纯文本 |
| .txt/.md/.json/.csv/源码 | 直接读 |
| 一次选中好几个文件 | 文本拼在一起，图片最多带 6 张 |

## 聊过的都留着

窗底下有个输入框，回车就能接着追问，它记得前面聊了什么。

**每答完一轮就自动存一次盘**，存在 `~/.config/nutshell/sessions/`，一次对话一个 JSON 文件。
**只增不删**——不设上限、不自动清理，攒多少留多少。

想回到之前某段对话，点浮窗左上角那个小钟：

```
┌─────────────────────────────────────┐
│ 🕘  gemini-3.1-pro-preview    ⧉  ✕ │  ← 点这个钟
├─────────────────────────────────────┤
   ┌───────────────────────────────┐
   │  ＋ 新对话（重读剪贴板）        │
   │ ───────────────────────────── │
   │  今天                          │
   │  ✓ SSE 断线重连那段…    15:04  │
   │    Transformer 注意力…  11:22  │
   │  昨天                          │
   │    这封邮件在说啥…      22:10  │
   │ ───────────────────────────── │
   │  共 37 条 · 在访达中打开        │
   │  清空历史…                     │
   └───────────────────────────────┘
```

点哪条切哪条：窗里恢复成当时的样子，模型那边的上下文也一起接上，直接在底下接着问。
打勾的那条就是你现在待着的这段。

几个细节：

- 标题是剪贴板开头那几个字，自动取的，不用起名
- **按住 Option**，某一条会变成「删除这条」
- 菜单默认只列最近 30 条（列太多会拖出屏幕）；全部都在那个文件夹里，菜单底下有直达访达的入口。想多列几条就改配置里的 `historyMenuCount`
- 图片也一起存，所以切回一段看图的对话，模型还看得见那张图

按快捷键**永远是开一段新的**——这条没变，日常那个「复制→按一下」的手感不受影响。

## 装

```bash
make install
```

编译 + 打包 + 装到 `~/Applications/Nutshell.app` + 启动。

它**没有界面**——不在 Dock 里，默认也不占菜单栏，就一个后台进程听着端口。想确认它在不在跑：

```bash
pgrep -x Nutshell
```

**不需要任何系统权限**——它只读剪贴板，而读剪贴板是白给的。

开机自启（装完跑一次就行）：

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'$HOME'/Applications/Nutshell.app", hidden:true}'
```

## 配 BetterTouchTool（左右键同时按）

程序常驻在后台，听着本机的 `8823` 端口。任何能发 HTTP 请求的东西都能叫醒它，BTT 只是其中一种。

1. 打开 BTT，左上角选 **Normal Mouse**（或你在用的那个鼠标设备）
2. 点 **+** 添加新触发，触发方式选 **Left & Right Click**（左右键同时点）
3. 右边加动作，选 **Execute Terminal Command (Async, non-blocking)**
4. 命令填：

```bash
curl -s http://127.0.0.1:8823/explain
```

**建议再多加一步，连 Cmd+C 都省了**：在上面第 3 步之前，先加两个动作，让 BTT 替你按复制——

1. 动作一：**Send Keyboard Shortcut** → `⌘C`
2. 动作二：**Delay Next Action** → `0.08` 秒（给前台 app 一点时间把内容放进剪贴板）
3. 动作三：才是上面那条 `curl`

这样配完，你只要**选中 → 左右键一起按**，一步到位。

## 四条命令管住它

```bash
curl -s http://127.0.0.1:8823/explain   # 触发（BTT 绑的就是这条）
curl -s http://127.0.0.1:8823/history   # 直接叫出历史清单（想再绑个手势的话）
curl -s http://127.0.0.1:8823/reload    # 改完配置重新加载
pkill -x Nutshell                       # 退出
```

## 改 prompt / 换模型

配置文件在 `~/.config/nutshell/config.json`。
改完打一下 `curl -s http://127.0.0.1:8823/reload`，**不用重新编译，也不用重启**。

最常改的几个：

```jsonc
{
  // 发给模型的话。{content} 会被替换成你复制的内容。
  "promptTemplate": "用通俗易懂的大白话讲一下下面讲的是什么东西：\n\n{content}\n\n用通俗易懂的大白话讲一下上面讲的是什么东西。",

  // 复制的是图片时用这句（没有 {content}）
  "imagePromptTemplate": "用通俗易懂的大白话讲一下这张图里讲的是什么东西。",

  // 任何 OpenAI 兼容的 /chat/completions 都行：官方、自建网关、
  // 公司内部代理、本机的 Ollama（http://localhost:11434/v1）
  "baseURL": "https://api.openai.com/v1",
  "model": "gpt-5.4",

  // 去 shell 环境里读哪个变量当 key（不想走环境变量就直接填 apiKey 字段）
  "apiKeyEnvVar": "OPENAI_API_KEY"
}
```

看图那条要求模型支持多模态；纯文字的话什么模型都能跑。

**调 prompt 的快捷办法**（不用反复重启 app）：

```bash
./scripts/try-prompt.sh "要解读的内容"
```

它直接拿配置文件里的 prompt 和模型打一次网关，结果打在终端里，不经过 app。
满意了再 `curl -s http://127.0.0.1:8823/reload` 让 app 生效。

其余可调项：

| 字段 | 作用 |
|---|---|
| `window.width` / `height` | 浮窗大小 |
| `window.fontSize` | 正文字号 |
| `window.gap` | 浮窗离鼠标多远 |
| `port` | 触发端口，撞车了就换一个 |
| `maxInputChars` | 一次最多发多少字符（防手滑全选一本书） |
| `maxImages` | 一次最多带几张图 |
| `maxScannedPDFPages` | 扫描版 PDF 最多看前几页 |
| `showMenuBarIcon` | 默认 `false`。改成 `true` 会在菜单栏放个气泡图标，里面有打开配置/重载/退出 |
| `systemPrompt` | 系统提示词，默认空 |
| `historyMenuCount` | 历史菜单里列几条，默认 30（磁盘上的对话一条都不会删） |
| `rateLimitRetries` | 撞 429 自动重试几次，默认 6；填 0 就是不重试直接报错 |
| `rateLimitRetryDelay` | 两次重试之间等几秒，默认 2 |

API key 可以不写进配置文件：程序会 `source ~/.zshrc` 去读 `$OPENAI_API_KEY`（变量名按 `apiKeyEnvVar` 改），key 换了也能自动跟上（撞 401 会自动重读一次）。想写死也行，填 `apiKey` 字段。

## 窗口怎么用

- **再按一次快捷键** → 再开一扇新窗解读当前剪贴板，旧窗不动。窗口可以同时开好几扇，同一位置连着按会自动错开摆放，不会叠死
- **⌘W** → 关一扇。开着好几扇时，关你点过的那扇，都没点过就关最新弹的——连着按就从上往下挨个收。浮窗露着脸的期间 ⌘W 归它——系统级热键直接截胡，后面的 Chrome / VS Code 压根收不到，tab 不会被误关；最后一扇一关，⌘W 立刻物归原主
- 点右上角 **×**，或点过浮窗之后按 **Esc** → 关掉那一扇
- 点窗口任意位置 → 光标自动进底部输入框，**可以接着追问**（多轮对话，它记得前面聊了什么）
- 点右上角**复制图标** → 把整段回答拷走
- 正文里划选一段 → **Cmd+C** 只拷这一段（输入框里 Cmd+V 粘贴、Cmd+A 全选、Cmd+Z 撤销也都能用）
- 拖顶部那条 → 挪窗；拖边角 → 改大小
- 窗口浮在最上层，但**不抢焦点**——弹出来的时候你原来那个 app 还是前台的

## 为什么要常驻后台

因为要快。如果每次按快捷键才现启动程序、现建窗口，按下去到看见窗至少半秒到一秒起步——那还没开始等模型呢。常驻着就是按下即出。

## 排查

**按了没反应**：先确认进程在不在，再确认端口是不是它在听：

```bash
pgrep -x Nutshell && lsof -nP -iTCP:8823 -sTCP:LISTEN
```

端口要是被别的程序占了，Nutshell 会直接弹框告诉你（不会闷声不响）。换个 `port` 即可。

**说找不到 API key**：

```bash
source ~/.zshrc && echo ${OPENAI_API_KEY: -4}
```

有值就正常。没值说明 key 没配好，或者不在 `~/.zshrc` 这条链路上。

**撞 429 被限流**：不用管，它自己会重试——每 2 秒一次，最多 6 次，窗里会显示第几次。

429 常见的那句 `Limit type: max_parallel_requests. Current limit: 2` 说的不是「你按太快了」，
而是**这个 key 同一时刻能跑几个请求**已经占满了——多半是你在别处跑着批量任务，
或者这个 key 是跟别人共用的。这种水位几秒就松，所以等着就行。
真要等不及，改 `rateLimitRetries` 和 `rateLimitRetryDelay`。

## 目录

```
Sources/Nutshell/
  main.swift            启动，注册成不进 Dock 的后台程序
  AppDelegate.swift     总调度：触发、对话历史、可选的菜单栏图标
  TriggerServer.swift   听 127.0.0.1:8823，BTT 用 curl 叫醒它
  InputCapture.swift    看剪贴板里是文字/PDF/图片/文件，分别处理
  LLMClient.swift       调网关，SSE 流式收字
  PopoverPanel.swift    浮窗本体 + 自适应定位 + 追问输入框
  MarkdownView.swift    WKWebView 壳，负责渲染
  SessionStore.swift    对话历史落盘（一次对话一个 JSON，只增不删）
  Config.swift          配置读写（prompt 常量在文件顶部）
  Resources/
    viewer.html         渲染页（样式、思考动画、自动滚动）
    marked.min.js       markdown 解析库，内嵌进 app，不联网
```

## License

MIT，随便用。
