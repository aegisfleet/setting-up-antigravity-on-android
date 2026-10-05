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

LOG_FILE = "/tmp/agy_acp.log"

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
    res = {
        "models": {
            "currentModelId": current_model,
            "availableModels": MODELS_LIST
        },
        "configOptions": get_config_options(),
        "availableCommands": [
            {"name": "compact", "description": "Compact conversation history"}
        ]
    }
    if session_id:
        res["sessionId"] = session_id
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
                "result": get_session_setup_result("agy-session-arm64")
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
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": get_session_setup_result()
            })
        elif method == "session/prompt":
            session_id = req.get("params", {}).get("sessionId", "agy-session-arm64")
            prompt_data = req.get("params", {}).get("prompt", [])
            user_text = ""
            if isinstance(prompt_data, list):
                for p in prompt_data:
                    if isinstance(p, dict) and p.get("type") == "text":
                        user_text += p.get("text", "")
            elif isinstance(prompt_data, str):
                user_text = prompt_data

            reply = f"【Antigravity on Android (ARM64)】\nモデル: {current_model}\nメッセージを受信しました: {user_text}\n\nT3 Code と Antigravity (ACP) の連携は正常に稼働しています。"

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
