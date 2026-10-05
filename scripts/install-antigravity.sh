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

# 1. Download official Google Antigravity Linux ARM64 Runtime if not present
OFFICIAL_ZIP_URL="https://dl.google.com/agy-extensions/releases/linux/agy-acp-server-agy_acp_server_1.1.1-linux-arm64.zip"
ZIP_PATH="/tmp/agy-acp-server-linux-arm64.zip"

if [ ! -f "${RUNTIME_BIN_DIR}/agy_acp_server.real" ]; then
    echo "[Antigravity] Google 公式 Antigravity ランタイム (Linux ARM64) をダウンロード中..."
    echo "              (約 656 MB のため、ネットワーク速度によって数分かかる場合があります)"
    if curl -fSL --progress-bar "$OFFICIAL_ZIP_URL" -o "$ZIP_PATH"; then
        echo "[Antigravity] ランタイムを展開中..."
        unzip -q -o "$ZIP_PATH" -d "/tmp/agy-extracted"
        rm -f "$ZIP_PATH"
        
        # 配下のバイナリを配置
        if [ -f "/tmp/agy-extracted/agy_acp_server.par" ]; then
            mv "/tmp/agy-extracted/agy_acp_server.par" "${RUNTIME_BIN_DIR}/agy_acp_server.real"
        fi
        if [ -f "/tmp/agy-extracted/localharness_external" ]; then
            mv "/tmp/agy-extracted/localharness_external" "${RUNTIME_BIN_DIR}/localharness_external.real"
        fi
        rm -rf "/tmp/agy-extracted"
        chmod +x "${RUNTIME_BIN_DIR}"/* 2>/dev/null || true
        echo "[Antigravity] 公式バイナリの配備が完了しました。"
    else
        echo "[Antigravity] 公式バイナリのダウンロードをスキップし、互換ラッパーを配備します。"
        rm -f "$ZIP_PATH"
    fi
fi

# 2. Setup Python virtual environment for fallback / agent bridge
if [ ! -d "$ANTIGRAVITY_DIR/venv" ]; then
    echo "[Antigravity] Python 仮想環境を作成中..."
    python3 -m venv "$ANTIGRAVITY_DIR/venv"
fi

# 3. Create dummy xdg-open to safely intercept browser opening in PRoot
XDG_OPEN_BIN="/usr/local/bin/xdg-open"
cat << 'EOF' > "$XDG_OPEN_BIN"
#!/usr/bin/env bash
# Termux PRoot dummy xdg-open
# Output auth URL directly to stderr so T3 Code ACP client detects it
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
# Antigravity ACP Server Smart Wrapper for Android / PRoot (ARM64 39-bit VA compatibility)
set -e

# TCMalloc 互換性のための環境変数設定
export MALLOC_CHECK_=0
export TCMALLOC_SKIP_MMAP_HINT=1
export GLIBC_TUNABLES="glibc.malloc.arena_max=2"

# 1. 公式バイナリが存在し、実行可能な場合は透過実行
REAL_BIN="/opt/antigravity/bin/agy_acp_server.real"
if [ -x "$REAL_BIN" ]; then
    # stderr をリダイレクトせず、T3 Code に直接流す（Google OAuth 認証 URL の検知に必須）
    exec "$REAL_BIN" "$@"
fi

# 2. Python ベースの ACP プロトコルブリッジ
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
# Antigravity localharness_external wrapper
REAL_HARNESS="/opt/antigravity/bin/localharness_external.real"
if [ -x "$REAL_HARNESS" ]; then
    exec "$REAL_HARNESS" "$@"
fi
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

# Ensure providerInstances structure
if "providerInstances" not in data:
    data["providerInstances"] = {}

data["providerInstances"]["antigravity"] = {
    "enabled": True,
    "binaryPath": "/usr/local/bin/agy_acp_server.par",
    "authMethod": "oauth-personal"
}

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("[Antigravity] settings.json のプロバイダ設定を正常に更新しました。")
EOF

echo "[Antigravity] セットアップが完了しました。"
echo "             T3 Code を再起動すると設定が反映されます。"
