#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# GitHub CLI (gh) Setup Script for Linux ARM64 (PRoot Ubuntu)
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[GitHub CLI] セットアップを開始します..."

# 1. 依存ツールの確認 (curl, ca-certificates, gpg)
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg

# 2. 公式 GitHub CLI リポジトリの登録 & インストール
echo "[GitHub CLI] 公式 APT リポジトリを設定中..."
mkdir -p -m 755 /etc/apt/keyrings

KEYRING="/etc/apt/keyrings/githubcli-archive-keyring.gpg"
if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o "$KEYRING" 2>/dev/null; then
    chmod go+r "$KEYRING"
    ARCH="$(dpkg --print-architecture)"
    echo "deb [arch=${ARCH} signed-by=${KEYRING}] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -y || true
fi

echo "[GitHub CLI] gh パッケージをインストール中..."
apt-get install -y --no-install-recommends gh || {
    echo "[GitHub CLI] (フォールバック) Ubuntu 標準リポジトリからインストールします..."
    apt-get install -y gh
}

# 3. 動作確認
if command -v gh >/dev/null 2>&1; then
    GH_VER="$(gh --version | head -n 1)"
    echo "[GitHub CLI] インストール済みバージョン: $GH_VER"
else
    echo "[GitHub CLI] (エラー) gh コマンドのインストールに失敗しました。"
    exit 1
fi

# 4. xdg-open の確認・更新 (Android ブラウザ連携)
XDG_OPEN_BIN="/usr/local/bin/xdg-open"
if [ ! -f "$XDG_OPEN_BIN" ] || grep -q "ACP server" "$XDG_OPEN_BIN" 2>/dev/null; then
    cat << 'EOF' > "$XDG_OPEN_BIN"
#!/usr/bin/env bash
# Termux PRoot xdg-open (Android 端末のブラウザ連携)
URL="$1"
if [ -x "/data/data/com.termux/files/usr/bin/termux-open-url" ]; then
    /data/data/com.termux/files/usr/bin/termux-open-url "$URL" 2>/dev/null || true
fi
echo "" >&2
echo "ブラウザで以下のURLを開いてください: $URL" >&2
echo "" >&2
EOF
    chmod +x "$XDG_OPEN_BIN"
fi

# 5. Ubuntu PRoot 内のショートカット作成
ln -sf /root/setting-up-antigravity-on-android/scripts/install-gh.sh /usr/local/bin/t3-install-gh

# 6. Termux コマンドの作成 (Termux 環境が存在する場合)
PREFIX_BIN="/data/data/com.termux/files/usr/bin"
if [ -d "$PREFIX_BIN" ] && [ -w "$PREFIX_BIN" ]; then
    # t3-install-gh
    cat << 'EOF' > "${PREFIX_BIN}/t3-install-gh"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- bash /root/setting-up-antigravity-on-android/scripts/install-gh.sh
EOF
    chmod +x "${PREFIX_BIN}/t3-install-gh"

    # gh (Termux から直接 gh コマンドを実行可能にする)
    cat << 'EOF' > "${PREFIX_BIN}/gh"
#!/data/data/com.termux/files/usr/bin/bash
proot-distro login ubuntu -- gh "$@"
EOF
    chmod +x "${PREFIX_BIN}/gh"
fi

echo ""
echo "================================================================"
echo "  GitHub CLI (gh) のセットアップが完了しました！"
echo "================================================================"
echo ""
echo "💡 【次のステップ: GitHub アカウント認証】"
echo "   以下のコマンドを実行して GitHub にログインしてください:"
echo ""
echo "   $ gh auth login"
echo ""
echo "   対話プロンプトでの選択例:"
echo "   - Account: GitHub.com"
echo "   - Preferred protocol: HTTPS (推奨)"
echo "   - Authenticate Git with GitHub credentials: Yes"
echo "   - How to authenticate: Login with a web browser"
echo "     → 表示された 8 桁コードをブラウザ (https://github.com/login/device) に入力して承認します。"
echo ""
echo "   ※ Personal Access Token をお持ちの場合は以下でも即座に認証可能です:"
echo "   $ echo \"ghp_...\" | gh auth login --with-token"
echo ""
