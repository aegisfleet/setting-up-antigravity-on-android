#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Ubuntu Environment Setup Script (Runs inside PRoot)
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[Ubuntu] 1/4 基本パッケージの更新とインストール中..."
apt-get update -y
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    tar \
    gzip \
    unzip \
    xz-utils \
    procps \
    sudo \
    build-essential \
    libatomic1 \
    python3 \
    python3-pip \
    python3-venv \
    jq

# 2. Setup Node.js LTS (v22.x)
echo "[Ubuntu] 2/4 Node.js LTS のセットアップ中..."
if ! command -v node >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes
    NODE_MAJOR=22
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
    apt-get update -y
    apt-get install -y nodejs
else
    echo "Node.js は既にインストールされています ($(node -v))"
fi

# 3. Setup T3 Code CLI / Server
echo "[Ubuntu] 3/4 T3 Code のインストール中..."
export T3CODE_HOME="/root/.t3"
export T3CODE_INSTALL_BIN_DIR="/usr/local/bin"

if ! command -v t3 >/dev/null 2>&1; then
    curl -fsSL https://t3.codes/install.sh | sh
else
    echo "T3 Code は既にインストールされています ($(t3 --version 2>/dev/null || echo 'installed'))"
fi

# 4. Setup Antigravity
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "[Ubuntu] 4/4 Antigravity のセットアップ中..."
bash "${SCRIPT_DIR}/install-antigravity.sh"

# 5. Optional: Android SDK
INSTALL_ANDROID_SDK="${INSTALL_ANDROID_SDK:-0}"
if [ "$INSTALL_ANDROID_SDK" -eq 1 ]; then
    echo "[Ubuntu] オプション: Android SDK ビルド環境をセットアップ中..."
    bash "${SCRIPT_DIR}/install-android-sdk.sh"
fi

# Ensure paths in /root/.bashrc
if ! grep -q '/usr/local/bin' /root/.bashrc 2>/dev/null; then
    echo 'export PATH="/usr/local/bin:$PATH"' >> /root/.bashrc
fi

echo "[Ubuntu] セットアップが完了しました。"
