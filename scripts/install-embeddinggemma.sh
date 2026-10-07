#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Google EmbeddingGemma 2 Setup Script for T3 Code (PRoot Ubuntu ARM64)
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "=========================================================="
echo "  Google EmbeddingGemma 2 (ローカルAI意味検索 & MCP) セットアップ"
echo "=========================================================="

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64)
        TORCH_URL="https://download.pytorch.org/whl/cpu"
        ;;
    x86_64)
        TORCH_URL="https://download.pytorch.org/whl/cpu"
        ;;
    *)
        echo "[EmbeddingGemma] (エラー) 未対応のアーキテクチャです: $ARCH"
        exit 1
        ;;
esac

# 1. 依存システムの確認
echo "[EmbeddingGemma] 1/5 必要なシステムパッケージを確認中..."
apt-get update -y
apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    git \
    procps \
    ca-certificates

# 2. Python 仮想環境の構築 (/opt/embedding-env)
VENV_DIR="/opt/embedding-env"
echo "[EmbeddingGemma] 2/5 Python 仮想環境 (${VENV_DIR}) を準備中..."
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/pip" install --upgrade --quiet pip

# 3. PyTorch (CPU) & Transformers & SentenceTransformers のインストール
echo "[EmbeddingGemma] 3/5 PyTorch (CPU) と Hugging Face ライブラリをインストール中..."
echo "  ※ aarch64 最適化ホイールを取得します（しばらくお待ちください）..."

"$VENV_DIR/bin/pip" install --quiet --no-cache-dir \
    --extra-index-url "$TORCH_URL" \
    torch \
    torchvision \
    transformers \
    sentence-transformers \
    sentencepiece \
    protobuf \
    huggingface-hub \
    safetensors

# 4. サービススクリプトの配置 (/opt/embeddinggemma/embedding_service.py)
echo "[EmbeddingGemma] 4/5 サービススクリプトおよびラッパーコマンドを配置中..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="/opt/embeddinggemma"
mkdir -p "$TARGET_DIR"

if [ -f "${SCRIPT_DIR}/embedding_service.py" ]; then
    cp "${SCRIPT_DIR}/embedding_service.py" "${TARGET_DIR}/embedding_service.py"
fi
chmod +x "${TARGET_DIR}/embedding_service.py"

# ラッパーコマンド作成
cat << 'EOF' > /usr/local/bin/t3-search
#!/bin/bash
exec /opt/embeddinggemma/embedding_service.py "$@"
EOF
chmod +x /usr/local/bin/t3-search

cat << 'EOF' > /usr/local/bin/t3-embed-mcp
#!/bin/bash
exec /opt/embeddinggemma/embedding_service.py --mcp "$@"
EOF
chmod +x /usr/local/bin/t3-embed-mcp

cat << 'EOF' > /usr/local/bin/t3-embed-server
#!/bin/bash
exec /opt/embeddinggemma/embedding_service.py --serve "$@"
EOF
chmod +x /usr/local/bin/t3-embed-server

# 5. MCP (Model Context Protocol) サーバーの自動登録
echo "[EmbeddingGemma] 5/5 MCP サーバーのセットアップ..."
if command -v agy >/dev/null 2>&1; then
    agy mcp remove embedding 2>/dev/null || true
    if agy mcp add embedding /usr/local/bin/t3-embed-mcp; then
        echo "[✓] Antigravity CLI (agy) に 'embedding' MCP サーバーを自動登録しました。"
    else
        echo "[!] agy への MCP 登録に失敗しました。後で 'agy mcp add embedding /usr/local/bin/t3-embed-mcp' を実行してください。"
    fi
fi

if command -v codex >/dev/null 2>&1; then
    codex mcp remove embedding 2>/dev/null || true
    if codex mcp add embedding -- /usr/local/bin/t3-embed-mcp; then
        echo "[✓] Codex CLI に 'embedding' MCP サーバーを自動登録しました。"
    else
        echo "[!] Codex への MCP 登録に失敗しました。後で 'codex mcp add embedding -- /usr/local/bin/t3-embed-mcp' を実行してください。"
    fi
fi

# T3 Code model-manifest.json へのモデル登録
MANIFEST_FILE="/root/.t3/userdata/model-manifest.json"
if [ -f "$MANIFEST_FILE" ]; then
    python3 -c "
import json
try:
    with open('$MANIFEST_FILE') as f:
        d = json.load(f)
    ag_models = d.get('manifest', {}).get('currentModels', {}).get('antigravity', [])
    if 'embeddinggemma-2' not in ag_models:
        ag_models.append('embeddinggemma-2')
        models_list = d.get('manifest', {}).get('providers', {}).get('antigravity', {}).get('models', [])
        if not any(m.get('slug') == 'embeddinggemma-2' for m in models_list):
            models_list.append({
                'slug': 'embeddinggemma-2',
                'name': 'EmbeddingGemma 2 [ローカル / 意味検索]',
                'status': 'current',
                'badge': 'local'
            })
    d['fetchedAtMs'] = 2524608000000  # 遠い未来に設定してリモート上書きを防止
    with open('$MANIFEST_FILE', 'w', encoding='utf-8') as f:
        json.dump(d, f, ensure_ascii=False)
    print('[✓] T3 Code モデルメニューに EmbeddingGemma 2 を登録しました。')
except Exception as e:
    pass
" 2>/dev/null || true
fi

# モデル重みの事前キャッシュ（1.49GB）
DOWNLOAD_WEIGHTS="${DOWNLOAD_WEIGHTS:-1}"
if [ "$DOWNLOAD_WEIGHTS" -eq 1 ]; then
    echo ""
    echo "[EmbeddingGemma] モデル重み (google/embeddinggemma-2: 約 1.49 GB) をダウンロード中..."
    "$VENV_DIR/bin/python3" -c "
from huggingface_hub import snapshot_download
print('Downloading EmbeddingGemma 2 files...')
snapshot_download('google/embeddinggemma-2', resume_download=True)
print('EmbeddingGemma 2 download complete!')
" || {
        echo "[!] ダウンロード中にエラーが発生しました。初回推論時に自動ダウンロードされます。"
    }
fi

echo ""
echo "=========================================================="
echo "  Google EmbeddingGemma 2 のセットアップが完了しました！"
echo "=========================================================="
echo ""
echo "利用可能なコマンド:"
echo "  1. ターミナルから自然言語コード検索:"
echo "     t3-search \"検索クエリ\" [-p /path/to/project] [-k 件数]"
echo ""
echo "  2. AI エージェント連携 (MCP サーバー):"
echo "     t3-embed-mcp (Antigravity CLI / T3 Code に 'embedding' として登録済み)"
echo "     チャット内で「プロジェクト内の〇〇の実装を探して」と指示すると自動で活用されます。"
echo ""
echo "  3. OpenAI 互換 API サーバー:"
echo "     t3-embed-server --port 8000 (http://127.0.0.1:8000/v1/embeddings)"
echo "=========================================================="
