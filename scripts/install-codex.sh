#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# OpenAI Codex CLI Setup Script for T3 Code (PRoot Ubuntu ARM64)
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[Codex] セットアップを開始します..."

# 1. アーキテクチャ確認
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64)
        TRIPLE="aarch64-unknown-linux-musl"
        ;;
    x86_64)
        TRIPLE="x86_64-unknown-linux-musl"
        ;;
    *)
        echo "[Codex] (エラー) 未対応のアーキテクチャです: $ARCH"
        exit 1
        ;;
esac

# 2. 依存パッケージ (bubblewrap) の確認とインストール
echo "[Codex] 1/4 サンドボックスツール (bubblewrap) の確認..."
if ! command -v bwrap >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y --no-install-recommends bubblewrap libcap2
else
    echo "[Codex] bubblewrap は既にインストールされています。"
fi

# 3. Node.js & npm の確認
if ! command -v npm >/dev/null 2>&1; then
    echo "[Codex] (エラー) npm が見つかりません。先に Node.js をインストールしてください。"
    exit 1
fi

# 4. @openai/codex のインストール
echo "[Codex] 2/4 OpenAI Codex CLI (@openai/codex) のインストール中..."
npm install -g @openai/codex

# 5. 静的バイナリの探索と /usr/local/bin/codex への配置
echo "[Codex] 3/4 Codex 静的バイナリの設定中..."
NPM_ROOT="$(npm root -g 2>/dev/null || echo '/usr/lib/node_modules')"
CANDIDATE_PATHS=(
    "${NPM_ROOT}/@openai/codex/node_modules/@openai/codex-linux-arm64/vendor/${TRIPLE}/bin/codex"
    "${NPM_ROOT}/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/${TRIPLE}/bin/codex"
    "${NPM_ROOT}/@openai/codex/vendor/${TRIPLE}/bin/codex"
)

CODEX_BIN=""
for path in "${CANDIDATE_PATHS[@]}"; do
    if [ -f "$path" ] && [ -x "$path" ]; then
        CODEX_BIN="$path"
        break
    fi
done

if [ -z "$CODEX_BIN" ]; then
    # find による探索フォールバック
    FOUND=$(find "${NPM_ROOT}/@openai/codex" -type f -name "codex" -perm -111 2>/dev/null | grep -E "vendor/.*/bin/codex" | head -n 1 || true)
    if [ -n "$FOUND" ] && [ -x "$FOUND" ]; then
        CODEX_BIN="$FOUND"
    fi
fi

if [ -n "$CODEX_BIN" ]; then
    mkdir -p /usr/local/bin
    ln -sf "$CODEX_BIN" /usr/local/bin/codex
    chmod +x /usr/local/bin/codex
    echo "[Codex] バイナリをリンクしました: /usr/local/bin/codex -> $CODEX_BIN"
else
    echo "[Codex] (警告) ネイティブバイナリの直接リンクに失敗しました。npm のデフォルトラッパーを使用します。"
fi

# T3 Code 用の透過ブリッジ (/usr/local/bin/codex-t3-bridge) を設定
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_SRC="${SCRIPT_DIR}/codex_t3_bridge.py"
if [ -f "$BRIDGE_SRC" ]; then
    chmod +x "$BRIDGE_SRC"
    cat << 'EOF' > /usr/local/bin/codex-t3-bridge
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -u /root/setting-up-antigravity-on-android/scripts/codex_t3_bridge.py "$@"
EOF
    chmod +x /usr/local/bin/codex-t3-bridge
    echo "[Codex] T3 Code 連携ブリッジを配置しました: /usr/local/bin/codex-t3-bridge"
fi

# 動作確認
if command -v codex >/dev/null 2>&1; then
    CODEX_VER="$(codex --version 2>&1 || true)"
    echo "[Codex] インストール済みバージョン: $CODEX_VER"
else
    echo "[Codex] (警告) codex コマンドの実行パスを確認できませんでした。"
fi

# 6. T3 Code の settings.json 有効化
echo "[Codex] 4/4 T3 Code 設定ファイル (/root/.t3/userdata/settings.json) を更新中..."
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

if "codex" not in data["providerInstances"]:
    data["providerInstances"]["codex"] = {}

inst = data["providerInstances"]["codex"]
inst["driver"] = "codex"
inst["enabled"] = True

if "config" not in inst or not isinstance(inst["config"], dict):
    inst["config"] = {}

inst["config"]["binaryPath"] = "/usr/local/bin/codex-t3-bridge"
inst["config"].setdefault("homePath", "")
inst["config"].setdefault("shadowHomePath", "")
inst["config"].setdefault("launchArgs", "")
inst["config"].setdefault("customModels", [])

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("[Codex] T3 Code の settings.json (codex: enabled=True, binaryPath=/usr/local/bin/codex-t3-bridge) を更新しました。")
EOF

# 7. Termux コマンドの作成 (Termux 環境が存在する場合)
PREFIX_BIN="/data/data/com.termux/files/usr/bin"
if [ -d "$PREFIX_BIN" ] && [ -w "$PREFIX_BIN" ]; then
    # t3-install-codex
    cat << 'EOF' > "${PREFIX_BIN}/t3-install-codex"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/install-codex.sh
EOF
    chmod +x "${PREFIX_BIN}/t3-install-codex"

    # codex (Termux から直接 codex コマンドを実行可能にする)
    cat << 'EOF' > "${PREFIX_BIN}/codex"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- codex "$@"
EOF
    chmod +x "${PREFIX_BIN}/codex"
fi

echo ""
echo "================================================================"
echo "  Codex のセットアップが完了しました！"
echo "================================================================"
echo ""
echo "💡 【次のステップ: アカウント認証】"
echo "   以下のいずれかの方法で認証を行ってください:"
echo ""
echo "   1. ChatGPT アカウントで利用 (推奨・デバイスコード認証):"
echo "      Termux または Ubuntu シェルで以下を実行:"
echo "      $ codex login --device-auth"
echo "      表示された 8 桁のコードと URL をスマートフォンのブラウザで開いて認証します。"
echo ""
echo "   2. OpenAI API キーで利用:"
echo "      $ echo \"sk-...\" | codex login --with-api-key"
echo ""
echo "💡 認証完了後、T3 Code サーバーを再起動すると Codex が画面上で利用可能になります:"
echo "   $ t3-stop && t3-start"
echo ""
