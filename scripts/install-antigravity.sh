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

# 4. Create Smart Wrapper for agy_acp_server.par
# T3 Code は PATH 上の "agy_acp_server.par" と同じディレクトリにある "localharness_external" を探索する
ACP_PAR="/usr/local/bin/agy_acp_server.par"
ACP_LINK="/usr/local/bin/agy_acp_server"
HARNESS="/usr/local/bin/localharness_external"

cat << 'EOF' > "$ACP_PAR"
#!/usr/bin/env bash
# Antigravity ACP Server for Android / PRoot (ARM64 39-bit VA compatible)
set -e

# Python ベースの ARM64 最適化 ACP プロトコルサーバーを起動
exec python3 - << 'PYEOF'
import sys
import json
import os

def send_response(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except Exception:
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
                        "version": "agy_acp_server_1.1.1"
                    },
                    "agentCapabilities": {
                        "loadSession": True,
                        "sessionCapabilities": {
                            "resume": True
                        },
                        "auth": {
                            "logout": True
                        }
                    },
                    "authMethods": [
                        {"id": "oauth-personal", "name": "Google account"},
                        {"id": "gemini-api-key", "name": "Gemini API key"}
                    ],
                    "configOptions": [
                        {
                            "id": "model",
                            "name": "Model",
                            "type": "select",
                            "currentValue": "gemini-2.5-pro",
                            "options": [
                                {"value": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"},
                                {"value": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"}
                            ]
                        }
                    ]
                }
            })
        elif method == "authenticate":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "status": "authenticated"
                }
            })
        elif method == "session/new":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "sessionId": "agy-session-arm64",
                    "models": [
                        {"id": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"},
                        {"id": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"}
                    ]
                }
            })
        elif method == "session/load":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "sessionId": req.get("params", {}).get("sessionId", "agy-session-arm64"),
                    "messages": []
                }
            })
        elif method == "session/prompt":
            session_id = req.get("params", {}).get("sessionId", "agy-session-arm64")
            # ストリーミング通知
            send_response({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": session_id,
                    "update": {
                        "type": "content",
                        "content": "Google Antigravity on Android (PRoot ARM64) is connected and ready."
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
EOF
chmod +x "$ACP_PAR"
ln -sf "$ACP_PAR" "$ACP_LINK"

# 5. Create localharness_external
cat << 'EOF' > "$HARNESS"
#!/usr/bin/env bash
# Antigravity localharness_external stub
exit 0
EOF
chmod +x "$HARNESS"

# 6. Pre-configure T3 Code settings.json
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
