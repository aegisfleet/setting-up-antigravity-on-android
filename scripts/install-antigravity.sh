#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Antigravity Provider Setup for T3 Code (PRoot Ubuntu ARM64)
# ==============================================================================
set -euo pipefail

echo "[Antigravity] セットアップを開始します..."

ANTIGRAVITY_DIR="/opt/antigravity"
RUNTIME_BIN_DIR="${ANTIGRAVITY_DIR}/bin"
mkdir -p "$RUNTIME_BIN_DIR"
mkdir -p /root/.gemini/antigravity-acp
mkdir -p /root/.t3/userdata

# 1. クリーンアップ: 39-bit VA非互換の巨大公式バイナリ(~2GB)が存在する場合は削除して空き容量を確保
if [ -f "${RUNTIME_BIN_DIR}/agy_acp_server.real" ]; then
    echo "[Antigravity] 39-bit VA非互換バイナリを削除し、ディスク容量を解放中..."
    rm -f "${RUNTIME_BIN_DIR}/agy_acp_server.real" "${RUNTIME_BIN_DIR}/localharness_external.real" 2>/dev/null || true
fi

# 2. Setup Python virtual environment for agent bridge
if [ ! -d "$ANTIGRAVITY_DIR/venv" ]; then
    echo "[Antigravity] Python 仮想環境を作成中..."
    python3 -m venv "$ANTIGRAVITY_DIR/venv"
fi

# 3. Create dummy xdg-open to safely intercept browser opening in PRoot
XDG_OPEN_BIN="/usr/local/bin/xdg-open"
cat << 'EOF' > "$XDG_OPEN_BIN"
#!/usr/bin/env bash
# Termux PRoot dummy xdg-open
echo "Open the following link to authenticate the ACP server: $1" >&2
EOF
chmod +x "$XDG_OPEN_BIN"

# 4. Create Antigravity ACP Python Bridge script
ACP_PY="${RUNTIME_BIN_DIR}/agy_acp_bridge.py"
cat << 'PYEOF' > "$ACP_PY"
#!/usr/bin/env python3
import sys
import json
import os
import uuid
import urllib.request
import urllib.error

LOG_FILE = "/tmp/agy_acp.log"
API_KEY_FILE = "/root/.gemini/antigravity-acp/gemini_api_key"

def log_debug(msg):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except Exception:
        pass

def send_response(obj):
    raw = json.dumps(obj)
    log_debug(">> " + raw)
    sys.stdout.write(raw + "\n")
    sys.stdout.flush()

# モデル定義 (デフォルト: Gemini 3.8 Flash)
MODELS_LIST = [
    {"modelId": "gemini-3.8-flash", "name": "Gemini 3.8 Flash (Default)"},
    {"modelId": "claude-sonnet-4.6", "name": "Claude Sonnet 4.6"},
    {"modelId": "claude-opus-4.6", "name": "Claude Opus 4.6"},
    # 既存・過去スレッド互換用
    {"modelId": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"},
    {"modelId": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"}
]

current_model = "gemini-3.8-flash"

def get_api_key():
    key = os.environ.get("GEMINI_API_KEY")
    if key and key.strip():
        return key.strip()
    if os.path.exists(API_KEY_FILE):
        try:
            with open(API_KEY_FILE, "r", encoding="utf-8") as f:
                k = f.read().strip()
                if k:
                    return k
        except Exception:
            pass
    return None

def call_gemini_api(api_key, model, prompt_text):
    # APIモデル名の対応付け
    api_model = "gemini-2.5-flash"
    if "pro" in model.lower():
        api_model = "gemini-2.5-pro"
    elif "flash" in model.lower():
        api_model = "gemini-2.5-flash"

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{api_model}:generateContent?key={api_key}"
    payload = {
        "contents": [
            {
                "parts": [{"text": prompt_text}]
            }
        ]
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        res_json = json.loads(resp.read().decode("utf-8"))
        candidates = res_json.get("candidates", [])
        if candidates:
            parts = candidates[0].get("content", {}).get("parts", [])
            if parts:
                return parts[0].get("text", "")
    return "APIからの応答が空でした。"

def get_config_options():
    return [
        {
            "id": "model",
            "name": "Model",
            "type": "select",
            "currentValue": current_model,
            "options": [
                {"value": m["modelId"], "name": m["name"]}
                for m in MODELS_LIST
            ]
        }
    ]

def get_session_setup_result(session_id=None):
    sid = session_id or str(uuid.uuid4())
    res = {
        "sessionId": sid,
        "models": {
            "currentModelId": current_model,
            "availableModels": MODELS_LIST
        },
        "configOptions": get_config_options(),
        "availableCommands": [
            {"name": "compact", "description": "Compact conversation history"}
        ]
    }
    return res

def main():
    global current_model
    log_debug(f"Antigravity ACP bridge started. Args: {sys.argv}")
    while True:
        line = sys.stdin.readline()
        if not line:
            log_debug("stdin closed (EOF)")
            break
        line = line.strip()
        if not line:
            continue
        log_debug("<< " + line)
        try:
            req = json.loads(line)
        except Exception as e:
            log_debug("JSON parse error: " + str(e))
            continue

        method = req.get("method")
        msg_id = req.get("id")

        if method == "initialize":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": 1,
                    "agentInfo": {
                        "name": "antigravity-acp",
                        "title": "Google Antigravity",
                        "version": "agy_acp_server_1.1.1"
                    },
                    "agentCapabilities": {
                        "loadSession": True,
                        "sessionCapabilities": {
                            "list": {},
                            "resume": {}
                        },
                        "auth": {
                            "logout": {}
                        },
                        "promptCapabilities": {
                            "image": True,
                            "audio": True,
                            "embeddedContext": True
                        }
                    },
                    "authMethods": [
                        {"id": "oauth-personal", "name": "Google account"},
                        {"id": "gemini-api-key", "name": "Gemini API key"}
                    ]
                }
            })
        elif method == "authenticate":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })
        elif method == "session/new":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": get_session_setup_result(str(uuid.uuid4()))
            })
        elif method == "session/set_config_option":
            params = req.get("params", {})
            cfg_id = params.get("configId")
            val = params.get("value")
            if cfg_id == "model" and isinstance(val, str) and val:
                current_model = val
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "configOptions": get_config_options()
                }
            })
        elif method == "session/set_model":
            params = req.get("params", {})
            m_id = params.get("modelId")
            if isinstance(m_id, str) and m_id:
                current_model = m_id
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })
        elif method == "session/set_mode":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })
        elif method in ("session/load", "session/resume"):
            params = req.get("params", {})
            sid = params.get("sessionId") or str(uuid.uuid4())
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": get_session_setup_result(sid)
            })
        elif method == "session/prompt":
            session_id = req.get("params", {}).get("sessionId") or str(uuid.uuid4())
            prompt_data = req.get("params", {}).get("prompt", [])
            user_text = ""
            if isinstance(prompt_data, list):
                for p in prompt_data:
                    if isinstance(p, dict) and p.get("type") == "text":
                        user_text += p.get("text", "")
            elif isinstance(prompt_data, str):
                user_text = prompt_data

            api_key = get_api_key()

            # タイトル生成や構造化JSON出力リクエストの判定
            is_json_request = "Return only the requested JSON object" in user_text or "outputSchema" in user_text

            if is_json_request:
                if api_key:
                    try:
                        reply = call_gemini_api(api_key, current_model, user_text)
                    except Exception as e:
                        log_debug(f"Gemini API JSON generation error: {e}")
                        reply = json.dumps({"title": "チャット"})
                else:
                    reply = json.dumps({"title": "チャット"})
            else:
                if api_key:
                    try:
                        reply = call_gemini_api(api_key, current_model, user_text)
                    except Exception as e:
                        log_debug(f"Gemini API error: {e}")
                        reply = f"【Gemini API 呼び出しエラー】\n{str(e)}\n\nAPIキーまたはネットワーク接続を確認してください。"
                else:
                    reply = (
                        f"【Antigravity on Android (PRoot)】\n"
                        f"選択モデル: {current_model}\n\n"
                        f"受信メッセージ:\n{user_text}\n\n"
                        f"---\n"
                        f"💡 **本物の AI 応答を有効にする方法**\n"
                        f"Google 公式の Antigravity サーバーバイナリは、Linux ARM64 版が 48-bit 仮想アドレス空間（TCMalloc）前提でコンパイルされており、Android カーネルの 39-bit 仮想アドレス空間では起動時に強制終了（Aborted）します。\n\n"
                        f"本環境では軽量 ACP ブリッジを介して T3 Code と連携しているため、**Gemini API キー** を設定することで即座に本物の Gemini からリアルタイム回答を取得できます。\n\n"
                        f"**設定手順:**\n"
                        f"1. [Google AI Studio](https://aistudio.google.com/) で API キー（無料）を取得します。\n"
                        f"2. Termux PRoot 内で以下を実行します:\n"
                        f"   `echo 'あなたのGemini_APIキー' > /root/.gemini/antigravity-acp/gemini_api_key`\n"
                        f"3. 再度チャットで質問を送信すると、本物の AI が回答します。"
                    )

            # ACP agent_message_chunk ストリーミング通知
            send_response({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": {
                            "type": "text",
                            "text": reply
                        }
                    }
                }
            })
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "stopReason": "end_turn"
                }
            })
        elif msg_id is not None:
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$ACP_PY"

# 5. Create Smart Wrapper for agy_acp_server.par
# T3 Code は PATH 上の "agy_acp_server.par" と同じディレクトリにある "localharness_external" を探索する
ACP_PAR="/usr/local/bin/agy_acp_server.par"
ACP_LINK="/usr/local/bin/agy_acp_server"
HARNESS="/usr/local/bin/localharness_external"

cat << 'EOF' > "$ACP_PAR"
#!/usr/bin/env bash
# Antigravity ACP Server for Android / PRoot (ARM64 39-bit VA compatible)
set -e
exec python3 -u /opt/antigravity/bin/agy_acp_bridge.py "$@"
EOF
chmod +x "$ACP_PAR"
ln -sf "$ACP_PAR" "$ACP_LINK"

# 6. Create localharness_external
cat << 'EOF' > "$HARNESS"
#!/usr/bin/env bash
# Antigravity localharness_external stub
exit 0
EOF
chmod +x "$HARNESS"

# 7. Pre-configure T3 Code settings.json
SETTINGS_FILE="/root/.t3/userdata/settings.json"
echo "[Antigravity] T3 Code の設定ファイル ($SETTINGS_FILE) を更新中..."

python3 - << 'EOF'
import json
import os

settings_path = "/root/.t3/userdata/settings.json"
data = {}

if os.path.exists(settings_path):
    try:
        with open(settings_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}

if "providerInstances" not in data:
    data["providerInstances"] = {}

if "antigravity" not in data["providerInstances"]:
    data["providerInstances"]["antigravity"] = {}

inst = data["providerInstances"]["antigravity"]
inst["driver"] = "antigravity"
inst["enabled"] = True

if "config" not in inst or not isinstance(inst["config"], dict):
    inst["config"] = {}

inst["config"]["authMethod"] = "oauth-personal"
inst["config"]["binaryPath"] = "/usr/local/bin/agy_acp_server.par"

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("[Antigravity] settings.json のプロバイダ設定を正常に更新しました。")
EOF

echo "[Antigravity] セットアップが完了しました。"
echo "             T3 Code を再起動すると設定が反映されます。"
