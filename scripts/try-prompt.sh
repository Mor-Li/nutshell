#!/usr/bin/env bash
# 调 prompt 用的：直接拿配置文件里的 prompt 和模型打一次网关，结果打在终端里。
# 不经过 app，也不用重启——改完 config.json 立刻就能试。
#
#   ./scripts/try-prompt.sh "要解读的内容"
#   ./scripts/try-prompt.sh -f 某个文件.txt
#   ./scripts/try-prompt.sh -m gemini-3.6-flash "换个模型试试"

set -euo pipefail

CONFIG="$HOME/.config/nutshell/config.json"
[ -f "$CONFIG" ] || { echo "找不到配置文件 $CONFIG，先跑一次 Nutshell 让它生成"; exit 1; }

MODEL=""
CONTENT=""

while [ $# -gt 0 ]; do
  case "$1" in
    -m) MODEL="$2"; shift 2 ;;
    -f) CONTENT="$(cat "$2")"; shift 2 ;;
    *)  CONTENT="$1"; shift ;;
  esac
done

[ -n "$CONTENT" ] || { echo "用法: $0 [-m 模型] [-f 文件] \"要解读的内容\""; exit 1; }

read -r BASE_URL CONFIG_MODEL MAX_TOKENS TEMPERATURE KEY_VAR CONFIG_KEY <<EOF
$(python3 -c "
import json
c = json.load(open('$CONFIG'))
print(c['baseURL'], c['model'], c['maxTokens'], c['temperature'],
      c.get('apiKeyEnvVar','OPENAI_API_KEY'), c.get('apiKey','') or '-')
")
EOF

[ -n "$MODEL" ] || MODEL="$CONFIG_MODEL"

if [ "$CONFIG_KEY" != "-" ]; then
  API_KEY="$CONFIG_KEY"
else
  # 开个 zsh 子进程去 source zshrc 取 key：zshrc 是 zsh 语法，
  # 在当前这个 bash 里 source 会直接炸掉；顺便 key 换了也能自动跟上
  API_KEY="$(zsh -c "source ~/.zshrc >/dev/null 2>&1; printf %s \"\$$KEY_VAR\"" 2>/dev/null || true)"
fi
[ -n "$API_KEY" ] || { echo "没读到 API key（\$$KEY_VAR 是空的）"; exit 1; }

# 把 promptTemplate 里的 {content} 换成实际内容，交给 python 拼 JSON 免得引号打架
PAYLOAD=$(CONTENT="$CONTENT" MODEL="$MODEL" MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" python3 -c "
import json, os
c = json.load(open('$CONFIG'))
prompt = c['promptTemplate'].replace('{content}', os.environ['CONTENT'])
print(json.dumps({
    'model': os.environ['MODEL'],
    'messages': [{'role': 'user', 'content': prompt}],
    'max_tokens': int(os.environ['MAX_TOKENS']),
    'temperature': float(os.environ['TEMPERATURE']),
    'stream': True,
}, ensure_ascii=False))
")

echo "── 模型: $MODEL ──────────────────────────────"
echo

curl -sS -N "${BASE_URL%/}/chat/completions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
| python3 -u -c "
import sys, json
for line in sys.stdin:
    if not line.startswith('data:'):
        continue
    payload = line[5:].strip()
    if payload == '[DONE]':
        break
    try:
        chunk = json.loads(payload)
    except json.JSONDecodeError:
        continue
    if 'error' in chunk:
        print('\n[错误]', chunk['error'].get('message', chunk['error']))
        break
    for choice in chunk.get('choices', []):
        piece = choice.get('delta', {}).get('content')
        if piece:
            sys.stdout.write(piece)
"

echo
echo
echo "──────────────────────────────────────────────"
echo "prompt 在 $CONFIG 的 promptTemplate 字段，改完这里再跑一次即可。"
echo "满意后到菜单栏点「重新加载配置」让 app 生效。"
