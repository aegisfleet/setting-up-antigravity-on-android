#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Termux entrypoint installer
# ==============================================================================
set -euo pipefail

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}    Antigravity & T3 Code on Android (Termux + proot-distro)   ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo ""

# 1. Environment check
if [ -z "${TERMUX_VERSION:-}" ] && [ ! -d "/data/data/com.termux" ]; then
    echo -e "${RED}[エラー] このスクリプトは Termux 環境上で実行してください。${NC}"
    exit 1
fi

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ "$ARCH" != "arm64" ]; then
    echo -e "${YELLOW}[警告] アーキテクチャが $ARCH です。本環境は aarch64 (ARM64) を推奨しています。${NC}"
fi

# 2. Options: Optional component flags (Android SDK, Codex)
INSTALL_ANDROID_SDK="${INSTALL_ANDROID_SDK:-0}"
if [ "$INSTALL_ANDROID_SDK" -eq 0 ] && [ -t 0 ]; then
    echo -e "${YELLOW}Android SDK (APKビルド環境) もセットアップしますか？ [y/N]: ${NC}"
    read -r ans || ans="n"
    case "$ans" in
        [yY][eE][sS]|[yY])
            INSTALL_ANDROID_SDK=1
            ;;
        *)
            INSTALL_ANDROID_SDK=0
            ;;
    esac
fi

INSTALL_CODEX="${INSTALL_CODEX:-0}"
if [ "$INSTALL_CODEX" -eq 0 ] && [ -t 0 ]; then
    echo -e "${YELLOW}OpenAI Codex CLI (Codex プロバイダ連携) もセットアップしますか？ [y/N]: ${NC}"
    read -r ans || ans="n"
    case "$ans" in
        [yY][eE][sS]|[yY])
            INSTALL_CODEX=1
            ;;
        *)
            INSTALL_CODEX=0
            ;;
    esac
fi

INSTALL_GH="${INSTALL_GH:-0}"
if [ "$INSTALL_GH" -eq 0 ] && [ -t 0 ]; then
    echo -e "${YELLOW}GitHub CLI (gh / リポジトリ・PR連携) もセットアップしますか？ [y/N]: ${NC}"
    read -r ans || ans="n"
    case "$ans" in
        [yY][eE][sS]|[yY])
            INSTALL_GH=1
            ;;
        *)
            INSTALL_GH=0
            ;;
    esac
fi

INSTALL_EMBEDDINGGEMMA="${INSTALL_EMBEDDINGGEMMA:-0}"
if [ "$INSTALL_EMBEDDINGGEMMA" -eq 0 ] && [ -t 0 ]; then
    echo -e "${YELLOW}Google EmbeddingGemma 2 (ローカルAI意味検索 & MCP連携 / 約1.5GB) もセットアップしますか？ [y/N]: ${NC}"
    read -r ans || ans="n"
    case "$ans" in
        [yY][eE][sS]|[yY])
            INSTALL_EMBEDDINGGEMMA=1
            ;;
        *)
            INSTALL_EMBEDDINGGEMMA=0
            ;;
    esac
fi

# 3. Termux host dependencies
echo -e "${BLUE}[1/4] Termux ホストのパッケージを更新・インストール中...${NC}"
pkg update -y
pkg install -y proot-distro curl git tar jq

# 4. Setup Ubuntu via proot-distro
echo -e "${BLUE}[2/4] proot-distro で Ubuntu を準備中...${NC}"

# インストール済みチェック
UBUNTU_INSTALLED=0
if proot-distro list 2>&1 | grep -qE "(Installed containers:.*ubuntu|\* ubuntu|ubuntu.*\[installed\])"; then
    UBUNTU_INSTALLED=1
elif proot-distro login ubuntu -- true < /dev/null 2>/dev/null; then
    UBUNTU_INSTALLED=1
fi

if [ "$UBUNTU_INSTALLED" -eq 1 ]; then
    echo -e "Ubuntu は既にインストール済みです。"
else
    echo -e "Ubuntu が未インストールのため、新規インストールします..."
    # 既にコンテナが存在する場合はエラーにせず続行
    INSTALL_OUT=$(proot-distro install ubuntu 2>&1) || {
        if echo "$INSTALL_OUT" | grep -qi "already exists"; then
            echo -e "Ubuntu は既に存在します（続行します）。"
        else
            echo -e "${RED}[エラー] Ubuntu のインストールに失敗しました:${NC}"
            echo "$INSTALL_OUT"
            exit 1
        fi
    }
fi

# 5. Execute setup inside Ubuntu PRoot
echo -e "${BLUE}[3/4] Ubuntu 環境内でスクリプトを取得し、セットアップを実行中...${NC}"

# PRoot 内で直接 git clone して実行することで、ホスト側パスの不整合を完全に防止
proot-distro login ubuntu -- /bin/bash -c "
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends ca-certificates git curl

    rm -rf /root/setting-up-antigravity-on-android
    echo '[Ubuntu] リポジトリをクローン中...'
    git clone https://github.com/aegisfleet/setting-up-antigravity-on-android.git /root/setting-up-antigravity-on-android

    export INSTALL_ANDROID_SDK=\"$INSTALL_ANDROID_SDK\"
    export INSTALL_CODEX=\"$INSTALL_CODEX\"
    export INSTALL_GH=\"$INSTALL_GH\"
    export INSTALL_EMBEDDINGGEMMA=\"$INSTALL_EMBEDDINGGEMMA\"
    bash /root/setting-up-antigravity-on-android/scripts/setup-ubuntu.sh
" < /dev/null

# 6. Create launcher commands in Termux
echo -e "${BLUE}[4/4] Termux コマンドを作成中...${NC}"
PREFIX_BIN="/data/data/com.termux/files/usr/bin"

# t3-start
cat << 'EOF' > "${PREFIX_BIN}/t3-start"
#!/data/data/com.termux/files/usr/bin/bash
PID_FILE="$HOME/.t3-server.pid"
LOG_FILE="$HOME/.t3-server.log"

get_ip() {
    ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true
}

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "[*] T3 Code サーバーは既に起動しています (PID: $PID)"
        DEVICE_IP=$(get_ip)
        echo "    端末内ブラウザ: http://127.0.0.1:3773"
        [ -n "$DEVICE_IP" ] && echo "    外部ブラウザ:   http://${DEVICE_IP}:3773"
        exit 0
    fi
fi

# 既存のプロセスやポートのクリーンアップ
pkill -f "proot-distro.*t3 serve" 2>/dev/null || true
pkill -f "t3 serve" 2>/dev/null || true
sleep 1

echo "[*] T3 Code サーバーを起動中..."
nohup proot-distro login ubuntu -- bash -c "exec /usr/local/bin/t3 serve --host 0.0.0.0" < /dev/null > "$LOG_FILE" 2>&1 &
NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"
sleep 3

if kill -0 "$NEW_PID" 2>/dev/null; then
    echo "[✓] T3 Code サーバーが正常に起動しました (PID: $NEW_PID)"
    DEVICE_IP=$(get_ip)
    echo "    端末内ブラウザ: http://127.0.0.1:3773"
    [ -n "$DEVICE_IP" ] && echo "    外部ブラウザ:   http://${DEVICE_IP}:3773"
    echo "    停止するには 't3-stop' を実行してください。"
else
    echo "[!] サーバーの起動に失敗しました。直近のログ:"
    tail -n 20 "$LOG_FILE" 2>/dev/null || true
fi
EOF
chmod +x "${PREFIX_BIN}/t3-start"

# t3-stop
cat << 'EOF' > "${PREFIX_BIN}/t3-stop"
#!/data/data/com.termux/files/usr/bin/bash
PID_FILE="$HOME/.t3-server.pid"
if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "[*] T3 Code サーバー (PID: $PID) を停止中..."
        kill "$PID" 2>/dev/null || true
        pkill -P "$PID" 2>/dev/null || true
    fi
    rm -f "$PID_FILE"
fi
pkill -f "proot-distro.*t3 serve" 2>/dev/null || true
pkill -f "t3 serve" 2>/dev/null || true
echo "[✓] T3 Code サーバーを停止しました。"
EOF
chmod +x "${PREFIX_BIN}/t3-stop"

# t3-status
cat << 'EOF' > "${PREFIX_BIN}/t3-status"
#!/data/data/com.termux/files/usr/bin/bash
PID_FILE="$HOME/.t3-server.pid"
LOG_FILE="$HOME/.t3-server.log"

get_ip() {
    ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || true
}

if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null; then
    PID=$(cat "$PID_FILE")
    DEVICE_IP=$(get_ip)
    echo "[✓] T3 Code サーバーは稼働中です (PID: $PID)"
    echo "    端末内ブラウザ: http://127.0.0.1:3773"
    [ -n "$DEVICE_IP" ] && echo "    外部ブラウザ:   http://${DEVICE_IP}:3773"
    echo ""
    echo "--- 直近のログ (末尾 10 行) ---"
    tail -n 10 "$LOG_FILE" 2>/dev/null || true
else
    echo "[*] T3 Code サーバーは停止しています。"
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "--- 直近のログ (末尾 10 行) ---"
        tail -n 10 "$LOG_FILE" 2>/dev/null || true
    fi
fi
EOF
chmod +x "${PREFIX_BIN}/t3-status"

# t3-shell
cat << 'EOF' > "${PREFIX_BIN}/t3-shell"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu
EOF
chmod +x "${PREFIX_BIN}/t3-shell"

# t3-quota (日本語コマンド「使用量」「使用状況」も作成)
cat << 'EOF' > "${PREFIX_BIN}/t3-quota"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash -c "python3 /root/setting-up-antigravity-on-android/scripts/check_quota.py"
EOF
chmod +x "${PREFIX_BIN}/t3-quota"
ln -sf "${PREFIX_BIN}/t3-quota" "${PREFIX_BIN}/使用量"
ln -sf "${PREFIX_BIN}/t3-quota" "${PREFIX_BIN}/使用状況"

# t3-install-codex
cat << 'EOF' > "${PREFIX_BIN}/t3-install-codex"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/install-codex.sh
EOF
chmod +x "${PREFIX_BIN}/t3-install-codex"

# codex (Termux から直接 codex コマンドを実行)
cat << 'EOF' > "${PREFIX_BIN}/codex"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- codex "$@"
EOF
chmod +x "${PREFIX_BIN}/codex"

# t3-install-gh
cat << 'EOF' > "${PREFIX_BIN}/t3-install-gh"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/install-gh.sh
EOF
chmod +x "${PREFIX_BIN}/t3-install-gh"

# gh (Termux から直接 gh コマンドを実行)
cat << 'EOF' > "${PREFIX_BIN}/gh"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- gh "$@"
EOF
chmod +x "${PREFIX_BIN}/gh"

# t3-install-sdk
cat << 'EOF' > "${PREFIX_BIN}/t3-install-sdk"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/install-android-sdk.sh
EOF
chmod +x "${PREFIX_BIN}/t3-install-sdk"

# t3-install-embedding
cat << 'EOF' > "${PREFIX_BIN}/t3-install-embedding"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/install-embeddinggemma.sh
EOF
chmod +x "${PREFIX_BIN}/t3-install-embedding"

# t3-search (Termux から直接意味検索を実行)
cat << 'EOF' > "${PREFIX_BIN}/t3-search"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- t3-search "$@"
EOF
chmod +x "${PREFIX_BIN}/t3-search"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  セットアップが完了しました！${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "利用可能なコマンド:"
echo -e "  ${CYAN}t3-start${NC}             : T3 Code サーバーを起動 (http://127.0.0.1:3773)"
echo -e "  ${CYAN}t3-stop${NC}              : T3 Code サーバーを停止"
echo -e "  ${CYAN}t3-status${NC}            : サーバーの稼働状態とログを確認"
echo -e "  ${CYAN}t3-quota${NC}             : Antigravity の利用状況・残りクォータを確認"
echo -e "  ${CYAN}t3-shell${NC}             : Ubuntu PRoot 環境のシェルにログイン"
echo -e "  ${CYAN}codex${NC}                : OpenAI Codex CLI（'codex login' などを Termux から直接実行可能）"
echo -e "  ${CYAN}gh${NC}                   : GitHub CLI（'gh auth login' などを Termux から直接実行可能）"
echo -e "  ${CYAN}t3-search${NC}            : EmbeddingGemma 2 による自然言語コード意味検索"
echo -e "  ${CYAN}t3-install-codex${NC}     : OpenAI Codex CLI のセットアップ（後からいつでも実行可能）"
echo -e "  ${CYAN}t3-install-gh${NC}        : GitHub CLI のセットアップ（後からいつでも実行可能）"
echo -e "  ${CYAN}t3-install-embedding${NC} : EmbeddingGemma 2 (MCP連携) のセットアップ（後からいつでも実行可能）"
echo -e "  ${CYAN}t3-install-sdk${NC}       : Android SDK (APKビルド環境) のセットアップ（後からいつでも実行可能）"
echo ""
echo -e "${YELLOW}💡 【初回のみ】Antigravity の Google アカウント認証を行ってください:${NC}"
echo -e "   1. ${CYAN}t3-shell${NC} を実行して Ubuntu シェルに入ります。"
echo -e "   2. ${CYAN}agy${NC} を実行し、画面の指示に従ってブラウザで Google ログインします。"
echo -e "   3. 認証完了後、${CYAN}exit${NC} で抜け、${CYAN}t3-start${NC} でサーバーを起動してください。"
echo ""
