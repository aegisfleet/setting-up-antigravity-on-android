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

# 2. Options: Android SDK installation flag
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

# 3. Termux host dependencies
echo -e "${BLUE}[1/5] Termux ホストのパッケージを更新・インストール中...${NC}"
pkg update -y
pkg install -y proot-distro curl git tar jq

# 4. Setup Ubuntu via proot-distro
echo -e "${BLUE}[2/5] proot-distro で Ubuntu を準備中...${NC}"
if ! proot-distro list | grep -q "ubuntu.*\[installed\]"; then
    echo -e "Ubuntu が未インストールのため、新規インストールします..."
    proot-distro install ubuntu
else
    echo -e "Ubuntu は既にインストール済みです。"
fi

# 5. Clone or copy scripts to Ubuntu environment
echo -e "${BLUE}[3/5] セットアップスクリプトを配置中...${NC}"
DISTRO_ROOT="/data/data/com.termux/files/usr/var/lib/proot-distro/installed-rootfs/ubuntu"
REPO_TARGET_DIR="${DISTRO_ROOT}/root/setting-up-antigravity-on-android"

mkdir -p "${REPO_TARGET_DIR}"

# Check if script is executed from a git clone or via curl pipe
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/scripts" ]; then
    echo "ローカルのリポジトリスクリプトをコピーします..."
    cp -r "$SCRIPT_DIR"/* "${REPO_TARGET_DIR}/"
else
    echo "最新のスクリプトを GitHub からクローンします..."
    rm -rf "${REPO_TARGET_DIR}"
    git clone https://github.com/aegisfleet/setting-up-antigravity-on-android.git "${REPO_TARGET_DIR}"
fi

# 6. Execute setup inside Ubuntu PRoot
echo -e "${BLUE}[4/5] Ubuntu 内で T3 Code & Antigravity セットアップを実行中...${NC}"
proot-distro login ubuntu -- env INSTALL_ANDROID_SDK="$INSTALL_ANDROID_SDK" bash /root/setting-up-antigravity-on-android/scripts/setup-ubuntu.sh

# 7. Create launcher commands in Termux
echo -e "${BLUE}[5/5] Termux コマンドを作成中...${NC}"
PREFIX_BIN="/data/data/com.termux/files/usr/bin"

# t3-start
cat << 'EOF' > "${PREFIX_BIN}/t3-start"
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] T3 Code サーバーをバックグラウンドで起動します..."
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/t3-server-manager.sh start
echo ""
echo "[✓] サーバーが起動しました。"
echo "    Android のブラウザで http://127.0.0.1:3773 にアクセスしてください。"
echo "    停止するには 't3-stop' を実行してください。"
EOF
chmod +x "${PREFIX_BIN}/t3-start"

# t3-stop
cat << 'EOF' > "${PREFIX_BIN}/t3-stop"
#!/data/data/com.termux/files/usr/bin/bash
echo "[*] T3 Code サーバーを停止します..."
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/t3-server-manager.sh stop
EOF
chmod +x "${PREFIX_BIN}/t3-stop"

# t3-status
cat << 'EOF' > "${PREFIX_BIN}/t3-status"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/t3-server-manager.sh status
EOF
chmod +x "${PREFIX_BIN}/t3-status"

# t3-shell
cat << 'EOF' > "${PREFIX_BIN}/t3-shell"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu
EOF
chmod +x "${PREFIX_BIN}/t3-shell"

echo ""
echo -e "${GREEN}================================================================${NC}"
echo -e "${GREEN}  セットアップが完了しました！${NC}"
echo -e "${GREEN}================================================================${NC}"
echo ""
echo -e "利用可能なコマンド:"
echo -e "  ${CYAN}t3-start${NC}   : T3 Code サーバーを起動 (http://127.0.0.1:3773)"
echo -e "  ${CYAN}t3-stop${NC}    : T3 Code サーバーを停止"
echo -e "  ${CYAN}t3-status${NC}  : サーバーの稼働状態とログを確認"
echo -e "  ${CYAN}t3-shell${NC}   : Ubuntu PRoot 環境のシェルにログイン"
echo ""
echo -e "まずは ${CYAN}t3-start${NC} を実行し、ブラウザでアクセスしてください。"
