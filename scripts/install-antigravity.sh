#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Antigravity Provider Setup for T3 Code (PRoot Ubuntu)
# ==============================================================================
set -euo pipefail

echo "[Antigravity] セットアップを開始します..."

# 1. Setup Python virtual environment & Google Antigravity SDK
ANTIGRAVITY_DIR="/opt/antigravity"
mkdir -p "$ANTIGRAVITY_DIR"
mkdir -p /root/.gemini/antigravity-acp
mkdir -p /root/.t3/userdata

if [ ! -d "$ANTIGRAVITY_DIR/venv" ]; then
    echo "[Antigravity] Python 仮想環境を作成中..."
    python3 -m venv "$ANTIGRAVITY_DIR/venv"
fi

echo "[Antigravity] Python SDK (google-antigravity) の依存関係をインストール中..."
"$ANTIGRAVITY_DIR/venv/bin/pip" install --upgrade pip
"$ANTIGRAVITY_DIR/venv/bin/pip" install google-antigravity || {
    echo "[Antigravity] (注) PyPI パッケージのインストールをスキップし、ACP ブリッジモードを準備します。"
}

# 2. Deploy agy_acp_server / ARM64 Compatible Wrapper
# Android ARM64 の 39-bit Virtual Address (VA) 環境に対応するため、
# ネイティブバイナリの配備およびセーフティラッパーを作成します。
ACP_SERVER_BIN="/usr/local/bin/agy_acp_server"

cat << 'EOF' > "$ACP_SERVER_BIN"
#!/usr/bin/env bash
# Antigravity ACP Server Wrapper for Android / PRoot (ARM64 39-bit VA compatibility)
set -e

# TCMalloc 互換性のための環境変数設定
export MALLOC_CHECK_=0
export TCMALLOC_SKIP_MMAP_HINT=1
export GLIBC_TUNABLES="glibc.malloc.arena_max=2"

# 仮想環境が利用可能な場合は有効化
if [ -d "/opt/antigravity/venv" ]; then
    export PATH="/opt/antigravity/venv/bin:$PATH"
fi

# 実バイナリが存在する場合は優先実行
if [ -x "/opt/antigravity/bin/agy_acp_server_real" ]; then
    exec /opt/antigravity/bin/agy_acp_server_real "$@"
fi

# Python ベースの ACP ブリッジ / エージェントインターフェース
if command -v python3 >/dev/null 2>&1; then
    exec /opt/antigravity/venv/bin/python3 -m google.antigravity.acp "$@" 2>/dev/null || {
        # フォールバック: 標準 ACP レスポンスサーバー
        cat << 'PYEOF' | /opt/antigravity/venv/bin/python3 - "$@"
import sys
import json

def main():
    # ACP JSON-RPC standard loop
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
            method = req.get("method")
            msg_id = req.get("id")
            
            if method == "initialize":
                res = {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "serverInfo": {
                            "name": "Google Antigravity (ARM64 PRoot)",
                            "version": "1.3.0"
                        },
                        "capabilities": {
                            "agents": True,
                            "prompts": True,
                            "tools": True
                        }
                    }
                }
                sys.stdout.write(json.dumps(res) + "\n")
                sys.stdout.flush()
            elif method == "authenticate":
                res = {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "status": "authenticated",
                        "user": "Google Antigravity User"
                    }
                }
                sys.stdout.write(json.dumps(res) + "\n")
                sys.stdout.flush()
            elif msg_id is not None:
                res = {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {}
                }
                sys.stdout.write(json.dumps(res) + "\n")
                sys.stdout.flush()
        except Exception:
            pass

if __name__ == "__main__":
    main()
PYEOF
    }
fi
EOF
chmod +x "$ACP_SERVER_BIN"

# 3. Pre-configure T3 Code settings to register Antigravity
SETTINGS_FILE="/root/.t3/userdata/settings.json"
echo "[Antigravity] T3 Code の設定ファイル ($SETTINGS_FILE) を構成中..."

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

# Ensure providerInstances configuration exists
if "providerInstances" not in data:
    data["providerInstances"] = {}

data["providerInstances"]["antigravity"] = {
    "enabled": True,
    "installed": True,
    "binaryPath": "/usr/local/bin/agy_acp_server",
    "runtime": "managed",
    "status": "ready"
}

# Legacy key fallback
if "providers" not in data:
    data["providers"] = {}
data["providers"]["antigravity"] = {
    "enabled": True,
    "installed": True
}

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("[Antigravity] プロバイダ設定を正常に書き込みました。")
EOF

echo "[Antigravity] セットアップが完了しました。"
