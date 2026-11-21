# Nutshell

**English** | [中文](README.zh-CN.md)

Select → copy → press once → a small window pops up next to your cursor and explains, in plain words, what you just copied.

Every press opens a **new** window, and you can keep several open at once: one explaining a paragraph of a paper, another explaining an error message you copied a moment later, side by side for comparison. When you are done, close them one by one with × (or ⌘W / Esc).

The name comes from the English idiom *in a nutshell*.

---

## News

- **2026-11-21** Math rendering in the popup: `$…$`, `$$…$$`, `\(…\)` and `\[…\]` are all typeset, while prices ("$5 to $10") and `$` inside code stay as plain text. Works offline, with the library and fonts bundled into the app. New flat-style icon, without the rounded-square frame around it.
- **2026-11-20** Pasted content is no longer truncated, and the title bar shows how many tokens the conversation has used. The input box grows as you type and can be resized by dragging. If an answer breaks off halfway, a "↻ Retry" button appears below it. The app gets its own icon.
- **2026-11-12** New terminal version: chat with Gemini back and forth in the terminal, drag files in to attach their contents, see answers rendered as Markdown, and resume earlier conversations at any time.
- **2026-11-11** Every request now carries the current time, so the model no longer treats 2026 as "the future".
- **2026-09-06** When explaining an image, the bubble shows the image itself. The same gesture can also open history: trigger it while holding ⌥, or when the clipboard hasn't changed.
- **2026-08-31** Every trigger opens a new window, so you can compare several side by side. Your own messages are drawn as chat bubbles.
- **2026-08-30** ⌘W closes the popup: while a popup is open it borrows ⌘W, so Chrome tabs behind it are no longer closed by accident.
- **2026-08-16** Fixed ⌘C and ⌘V: copying selected text and pasting into the input box now work.
- **2026-08-14** Automatic retry when rate-limited (HTTP 429): once every 2 seconds, up to 6 times.
- **2026-08-13** First release: select, copy, press once, and a popup next to the cursor explains it in plain words.

## What problem it solves

Reading an English paper, a long technical document someone sent you, or a confusing email used to mean: switch to the browser, open some AI website, paste, wait, switch back. All that switching breaks your train of thought.

Now: copy, press a shortcut, and the answer floats right next to what you are reading. No window switching, no interruption.

## What you can feed it

Not just text. It recognizes whatever you copy:

| What you copy | How it handles it |
|---|---|
| A piece of text | Explains it directly |
| A PDF file | Extracts the text, then explains |
| A scanned PDF (no text layer) | Renders the first few pages as images and explains from those |
| An image / a screenshot | Sends it to a multimodal model and explains the picture |
| Word, RTF, HTML | Converts to plain text with the built-in `textutil` |
| .txt/.md/.json/.csv/source code | Reads it directly |
| Several files selected at once | Text is concatenated, up to 6 images are attached |

## Everything you chat about is kept

There is an input box at the bottom of the window. Press Return to ask a follow-up, and it remembers what was said before.

**Each finished round is saved to disk automatically**, under `~/.config/nutshell/sessions/`, one JSON file per conversation.
**Append only**: no limit, no automatic cleanup, everything is kept.

To go back to an earlier conversation, click the little clock in the top-left corner of the popup:

```
┌─────────────────────────────────────┐
│ 🕘  gemini-3.1-pro-preview    ⧉  ✕ │  ← click this clock
├─────────────────────────────────────┤
   ┌───────────────────────────────┐
   │  ＋ New chat (re-read clipboard) │
   │ ───────────────────────────── │
   │  Today                         │
   │  ✓ SSE reconnect logic…  15:04 │
   │    Transformer attention… 11:22│
   │  Yesterday                     │
   │    What is this email…   22:10 │
   │ ───────────────────────────── │
   │  37 in total · Show in Finder  │
   │  Clear history…                │
   └───────────────────────────────┘
```

Click any entry to switch to it: the window is restored to how it looked, the model's context is restored too, and you can keep asking right there.
The checked entry is the conversation you are currently in.

A few details:

- Titles are taken automatically from the first few words of the clipboard, no naming needed
- **Hold Option** and an entry turns into "Delete this one"
- The menu lists only the latest 30 entries by default (more would run off the screen). All of them are in that folder, and the bottom of the menu has a shortcut to open it in Finder. To list more, change `historyMenuCount` in the config
- Images are saved too, so when you switch back to a conversation about an image, the model can still see it

Pressing the shortcut **always starts a new conversation**. That never changes, so the everyday "copy → press" feel stays the same.

## Install

```bash
make install
```

Builds, packages, installs to `~/Applications/Nutshell.app`, and launches it.

It **has no UI of its own**: no Dock icon, no menu bar item by default, just a background process listening on a port. To check whether it is running:

```bash
pgrep -x Nutshell
```

**No system permissions needed**: it only reads the clipboard, and reading the clipboard is free.

Launch at login (run once after installing):

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"'$HOME'/Applications/Nutshell.app", hidden:true}'
```

## Setting up BetterTouchTool (double right-click)

The app stays in the background and listens on local port `8823`. Anything that can send an HTTP request can wake it up. BTT is just one option.

1. Open BTT and pick **Normal Mouse** (or whichever mouse device you use) in the top-left
2. Click **+** to add a new trigger and choose **double right-click**
3. On the right, add an action: **Execute Terminal Command (Async, non-blocking)**
4. Use this command:

```bash
curl -s http://127.0.0.1:8823/explain
```

**Recommended: add one more step and skip Cmd+C entirely.** Before step 3 above, add two actions so BTT presses copy for you:

1. Action one: **Send Keyboard Shortcut** → `⌘C`
2. Action two: **Delay Next Action** → `0.08` seconds (gives the frontmost app time to put the content on the clipboard)
3. Action three: the `curl` command above

With this setup you just **select → double right-click**, in one step.

**The same gesture can also open history.** In two cases it opens the history list instead of explaining:
when you trigger it while holding ⌥ (Option), or when you trigger it without copying anything new (the clipboard is the same as last time).
To explain the same text again, use "＋ New chat (re-read clipboard)" at the top of the list. Nothing extra needs to be set up in BTT.

## Four commands to control it

```bash
curl -s http://127.0.0.1:8823/explain   # trigger (this is what BTT is bound to)
curl -s http://127.0.0.1:8823/history   # open the history list directly (if you want another gesture for it)
curl -s http://127.0.0.1:8823/reload    # reload after editing the config
pkill -x Nutshell                       # quit
```

## Changing the prompt or the model

The config file is `~/.config/nutshell/config.json`.
After editing it, run `curl -s http://127.0.0.1:8823/reload`. **No rebuild and no restart needed.**

The fields you will change most often:

```jsonc
{
  // What gets sent to the model. {content} is replaced with what you copied.
  "promptTemplate": "用通俗易懂的大白话讲一下下面讲的是什么东西：\n\n{content}\n\n用通俗易懂的大白话讲一下上面讲的是什么东西。",

  // Used when you copied an image (no {content})
  "imagePromptTemplate": "用通俗易懂的大白话讲一下这张图里讲的是什么东西。",

  // Any OpenAI-compatible /chat/completions works: the official API, a self-hosted gateway,
  // a company proxy, or a local Ollama (http://localhost:11434/v1)
  "baseURL": "https://api.openai.com/v1",
  "model": "gpt-5.4",

  // Which shell environment variable to read the key from (or put it directly in the apiKey field)
  "apiKeyEnvVar": "OPENAI_API_KEY"
}
```

The default prompts are in Chinese ("explain what the following is about in plain, easy words"). Rewrite them in any language you like.

Explaining images requires a multimodal model. For text only, any model works.

**A quick way to tune the prompt** (without restarting the app again and again):

```bash
./scripts/try-prompt.sh "text to explain"
```

It calls the gateway once with the prompt and model from the config file and prints the result in the terminal, without going through the app.
Once you are happy, run `curl -s http://127.0.0.1:8823/reload` to apply it in the app.

Other settings:

| Field | What it does |
|---|---|
| `window.width` / `height` | Popup size |
| `window.fontSize` | Body font size |
| `window.gap` | Distance between the popup and the cursor |
| `port` | Trigger port. Change it if something else is using it |
| `contextWindow` | How large the model's context window is (in tokens), 1 million by default. Only used to show "used / total" in the title bar. Nothing is truncated: whatever you paste is sent in full |
| `maxImages` | Maximum number of images per request |
| `maxScannedPDFPages` | How many pages of a scanned PDF to look at |
| `showMenuBarIcon` | `false` by default. Set to `true` to show a bubble icon in the menu bar with open config / reload / quit |
| `systemPrompt` | System prompt, empty by default. Whether or not you fill it in, the app always appends the current time after it (in Gemini's official format: "Current time is Wednesday, November 11, 2026 at 11:40 PM GMT+8."), so the model doesn't treat the current year as "the future". You don't need to write that line yourself. If you want Gemini's official system prompt, you can copy the identity and knowledge-cutoff parts from [asgeirtj/system_prompts_leaks](https://github.com/asgeirtj/system_prompts_leaks/tree/main/Google). Skip the tool definitions and jailbreak-detection parts |
| `historyMenuCount` | How many entries the history menu lists, 30 by default (no conversation on disk is ever deleted) |
| `rateLimitRetries` | How many times to retry on a 429, 6 by default. 0 means report the error right away |
| `rateLimitRetryDelay` | Seconds to wait between retries, 2 by default |

You don't have to put the API key in the config file: the app runs `source ~/.zshrc` to read `$OPENAI_API_KEY` (change the variable name with `apiKeyEnvVar`), and it picks up a changed key automatically (a 401 triggers one re-read). If you prefer to hard-code it, fill in the `apiKey` field.

## Using the window

- **Press the shortcut again** → another new window explains the current clipboard, and the old one stays. You can have several windows at once. Pressing repeatedly at the same spot staggers them so they don't stack exactly on top of each other
- **⌘W** → closes one. With several open, it closes the one you last clicked, or the newest one if you haven't clicked any, so pressing it repeatedly closes them from the top down. While a popup is visible, ⌘W belongs to it: a system-wide hotkey takes it first, so Chrome / VS Code behind it never receive it and no tab gets closed by mistake. As soon as the last popup closes, ⌘W goes back to normal
- Click the **×** in the top-right, or press **Esc** after clicking the popup → closes that window
- Click anywhere in the window → the cursor jumps to the input box at the bottom, and **you can ask follow-ups** (multi-turn, it remembers what was said)
- In the input box, **Return sends, Shift+Return adds a new line**. It normally takes one line. When you type more or paste a big chunk, it grows on its own up to 8 lines, then scrolls inside. You can type your next message while it is still answering, and press Return once it is done
- The line above the input box **can be dragged up and down** to any height you like. Double-click the line to go back to automatic, which also happens after you send a message
- Network dropped, timed out, or the answer broke off halfway → a **↻ Retry** button appears below the error. Click it to resend the last question without typing it again. The partial answer and the error are cleared and don't stay in the conversation. The button is still there if you close the window and reopen it from history
- Math formulas in answers are typeset properly (`$…$`, `$$…$$`, `\(…\)` and `\[…\]` are all recognized), instead of showing raw `\frac` and `^`
- Click the **copy icon** in the top-right → copies the whole answer
- Select part of the body text → **Cmd+C** copies just that part (Cmd+V paste, Cmd+A select all and Cmd+Z undo also work in the input box)
- Drag the top bar → move the window. Drag the edges → resize it
- The window floats on top but **doesn't steal focus**: when it pops up, your original app stays in front

## Terminal version: plain chat with Gemini in the terminal

The popup is good for "I don't get this, quick question". If you want to sit down and go back and forth (discussing a plan, polishing an article), use the terminal version:

```bash
uv tool install --editable ./cli    # install once, then use it from any directory
nutshell                            # start chatting, or use the short form: nut
```

It's just question and answer, no tools and no agent, so it's fast. It shares the same `config.json` with the popup (gateway, model, `systemPrompt`), so there is nothing extra to configure.

**The whole conversation stays in the terminal as is**: no full-screen UI, no screen clearing, output is only appended, never rewritten. When you are done, **Cmd+A to select all and copy**, and you have the complete chat log, ready to paste to Claude to save as a file. If the terminal's scrollback is too short and the beginning has been pushed out, type `/copyall` to get the complete log anyway (the VS Code terminal keeps only 1000 lines by default; raise `terminal.integrated.scrollback`).

Markdown in answers is rendered before it is shown: headings, bold, lists, tables and code highlighting are laid out properly, so you don't see a pile of `**` and `#`. Rendering happens while the answer streams in, paragraph by paragraph: the paragraph being received is shown temporarily at the bottom, and each paragraph is finalized once it is complete. That way Cmd+A copies the formatted text. For the raw Markdown, use `/copy` or `/copyall`. To turn rendering off, start with `--raw`, or type `/raw` during a chat to toggle it.

**Dragging things in**: drag files, images, PDFs or folders from Finder or your editor's sidebar into the terminal. The terminal shows the path, and when the message is sent, the path is replaced in place with the content:

| What you drag in | What the model gets |
|---|---|
| Text files (`.md`, code, `.json`…) | The full text |
| Images (PNG / JPG / HEIC / WebP…) | The image itself, with the longest side scaled down to 2048 pixels |
| PDF | The whole original file. Gemini looks at every page as an image and reads the text at the same time. All pages are sent |
| Word / RTF | Converted to plain text |
| Folders | Every file inside, each handled by the rules above. Inside a git repository, files ignored by `.gitignore` are skipped |

One message can include several attachments, and you can type and drag at the same time. If the attachments are very large (over 200,000 tokens or 60 images), it asks before sending. Because the terminal keeps the paths, after you paste the chat log to Claude, it can read those files itself by following the paths.

**Switching backends**: by default it uses the gateway in `config.json`. When that key is saturated by batch jobs, switch to your own Google AI Studio key:

```bash
nutshell --own      # use your own key from the start
```

You can also switch mid-chat: type `/own` to switch over and `/work` to switch back, without losing the conversation. Create your key in [AI Studio](https://aistudio.google.com/api-keys), then put it in `.env` at the repository root (this file is not committed):

```
GEMINI_AI_STUDIO_KEY_NUTSHELL='your key'
```

| Command | What it does |
|---|---|
| `/own`, `/work` | Switch to your own key / back to the gateway |
| `/model name` | Change model |
| `/models` | List the Gemini models the current key can use |
| `/copy` | Copy the last answer (raw Markdown) |
| `/copyall` | Copy the whole chat log (raw Markdown) |
| `/raw` | Toggle Markdown rendering. When off, answers are printed as plain text |
| `/new` | Start a new conversation |
| `/resume` | List earlier conversations and pick one with the arrow keys to continue |
| `/exit`, Ctrl+D or Ctrl+C twice | Quit |

Return sends, **Option+Return** (or Esc then Return) adds a new line, and pasting multiple lines doesn't split them into separate messages. Press Ctrl+C while waiting for an answer to interrupt it. `nutshell -p "one question"` asks a single question, prints the answer and exits.

**Continuing earlier conversations**: every answer is saved as soon as it is received (under `~/.config/nutshell/chats/`), so you can quit at any time, or even just close the terminal, without losing anything. On exit it prints a line like `接着聊：nutshell -r <id>` ("continue: …"); type it to return to that conversation. If you don't remember the id, type `nutshell -r` (or `/resume` during a chat) to list recent conversations, pick one with the arrow keys and press Return. `nutshell -c` continues the most recent one directly. After resuming, the earlier questions and answers are printed again, so the terminal still holds the complete log.

Each conversation in the list gets a title written by the model: it is generated quietly in the background after the first few rounds, without holding up your chat. Older conversations without a title get one all at once the first time they are listed. The prompt used for titles is `TITLE_PROMPT` at the top of `cli/nutshell_cli/main.py`. Change the wording there.

## Why it stays in the background

Because it needs to be fast. If the app had to start and build its window only after you pressed the shortcut, it would take at least half a second to a second before you saw anything, and that is before the model even starts. Staying resident means it appears the moment you press.

## Troubleshooting

**Nothing happens when I press it**: first check that the process is running, then that it is the one listening on the port:

```bash
pgrep -x Nutshell && lsof -nP -iTCP:8823 -sTCP:LISTEN
```

If the port is taken by another program, Nutshell shows a dialog telling you so (it doesn't fail silently). Just change `port`.

**It says it can't find the API key**:

```bash
source ~/.zshrc && echo ${OPENAI_API_KEY: -4}
```

If something is printed, you are fine. If not, the key isn't set up, or it isn't reachable through `~/.zshrc`.

**Rate-limited with a 429**: nothing to do, it retries on its own, once every 2 seconds, up to 6 times, and the window shows which attempt it is on.

The common 429 message `Limit type: max_parallel_requests. Current limit: 2` doesn't mean "you pressed too fast".
It means **the number of requests this key can run at the same time** is used up, most likely because you are running batch jobs elsewhere,
or the key is shared with other people. That kind of limit frees up within seconds, so just wait.
If you really can't wait, change `rateLimitRetries` and `rateLimitRetryDelay`.

## Layout

```
Sources/Nutshell/       Popup version (Swift)
  main.swift            Startup, registers as a background app without a Dock icon
  AppDelegate.swift     Coordinator: triggers, chat history, optional menu bar icon
  TriggerServer.swift   Listens on 127.0.0.1:8823, BTT wakes it up with curl
  CloseHotKey.swift     Takes over ⌘W while a window is open
  InputCapture.swift    Figures out whether the clipboard holds text/PDF/images/files and handles each
  ExplainWindowController.swift  One conversation in one window: ask, follow up, retry, save
  LLMClient.swift       Calls the gateway, receives text over SSE streaming
  PopoverPanel.swift    The popup itself + adaptive positioning + layout of the input area at the bottom
  ComposerViews.swift   Two parts of the input area: the self-growing input box and the draggable divider
  MarkdownView.swift    WKWebView wrapper, handles rendering
  SessionStore.swift    Saves chat history to disk (one JSON per conversation, append only)
  Config.swift          Reads and writes the config (prompt constants at the top of the file)
  Resources/
    viewer.html         The rendering page (styles, thinking animation, auto-scroll, retry button)
    marked.min.js       Markdown parser, bundled into the app, works offline
    katex.min.js        KaTeX math typesetting library, bundled into the app, works offline
    katex.inline.min.css  KaTeX styles, with the fonts embedded as base64
Tests/NutshellTests/    Automated tests for the popup version, run with `make test`, no windows shown, no network
scripts/                Development helper scripts
  explain_repo.py       Generates a plain-language explanation for every file (in docs/explain/, not committed)
  try-prompt.sh         Tries a prompt in the terminal without opening the app
  make_icon.py          Cuts the solid background out of icon/AppIcon-source.png and builds the app icon
  vendor_katex.py       For upgrading KaTeX: fetches a new version and embeds the fonts into the CSS
icon/                   Source image and finished app icon
cli/nutshell_cli/       Terminal version (Python, installed with uv)
  main.py               Chat loop, commands, the two backends, streaming output
  attach.py             Recognizes dragged-in paths and replaces them with file contents / images / original PDFs
  render.py             Renders Markdown in answers to the terminal paragraph by paragraph
```

## License

MIT. Use it however you like.
