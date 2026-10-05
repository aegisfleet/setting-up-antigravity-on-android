#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Android SDK Setup Script for Linux ARM64 (PRoot Ubuntu)
# ==============================================================================
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "[Android SDK] セットアップを開始します..."

# 1. Install OpenJDK 17 & native build tools
echo "[Android SDK] OpenJDK 17 およびビルドツールをインストール中..."
apt-get update -y
apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    aapt \
    zipalign \
    unzip \
    wget

# 2. Configure aapt2 for ARM64
# Google Maven の公式 aapt2 は x86_64 専用のため、ARM64 ネイティブ版を配置します。
echo "[Android SDK] ARM64 用 aapt2 の設定中..."
if ! command -v aapt2 >/dev/null 2>&1; then
    if [ -x /usr/bin/aapt ]; then
        # aapt を aapt2 としてリンクまたはエイリアス
        ln -sf /usr/bin/aapt /usr/local/bin/aapt2
    fi
fi

# 3. Setup Android Command-Line Tools
ANDROID_ROOT="/opt/android-sdk"
mkdir -p "${ANDROID_ROOT}/cmdline-tools"

CMDLINE_TOOLS_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
TMP_ZIP="/tmp/cmdline-tools.zip"

if [ ! -d "${ANDROID_ROOT}/cmdline-tools/latest" ]; then
    echo "[Android SDK] Android Command-line Tools をダウンロード中..."
    curl -fsSL "$CMDLINE_TOOLS_URL" -o "$TMP_ZIP"
    
    echo "[Android SDK] ツールを展開中..."
    unzip -q "$TMP_ZIP" -d "/tmp/cmdline-tools-extracted"
    rm -f "$TMP_ZIP"
    
    mv "/tmp/cmdline-tools-extracted/cmdline-tools" "${ANDROID_ROOT}/cmdline-tools/latest"
    rm -rf "/tmp/cmdline-tools-extracted"
else
    echo "[Android SDK] cmdline-tools は既に存在します。"
fi

# 4. Environment Variables
export ANDROID_HOME="$ANDROID_ROOT"
export ANDROID_SDK_ROOT="$ANDROID_ROOT"
export JAVA_HOME="/usr/lib/jvm/java-17-openjdk-arm64"
export PATH="$PATH:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools"

# 5. Accept licenses & install essential platforms/build-tools
echo "[Android SDK] SDK パッケージ (API 34, build-tools) をインストール中..."
yes | "${ANDROID_ROOT}/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
"${ANDROID_ROOT}/cmdline-tools/latest/bin/sdkmanager" \
    "platforms;android-34" \
    "build-tools;34.0.0" \
    "platform-tools" || {
    echo "[Android SDK] (警告) 一部パッケージのダウンロードに失敗した可能性があります。必要に応じて後から手動実行可能です。"
}

# 6. Global Gradle Configuration for ARM64 aapt2 override
GRADLE_USER_HOME="/root/.gradle"
mkdir -p "$GRADLE_USER_HOME"
GRADLE_PROP="$GRADLE_USER_HOME/gradle.properties"

echo "[Android SDK] Gradle 設定 ($GRADLE_PROP) を構成中..."
if [ -f "$GRADLE_PROP" ]; then
    sed -i '/android.aapt2FromMavenOverride/d' "$GRADLE_PROP"
fi
echo "android.aapt2FromMavenOverride=/usr/local/bin/aapt2" >> "$GRADLE_PROP"
echo "org.gradle.jvmargs=-Xmx2048m -XX:MaxMetaspaceSize=512m" >> "$GRADLE_PROP"

# 7. Persist environment variables in /etc/profile.d/android.sh and /root/.bashrc
cat << 'EOF' > /etc/profile.d/android.sh
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
EOF

if ! grep -q "ANDROID_HOME" /root/.bashrc 2>/dev/null; then
    cat << 'EOF' >> /root/.bashrc

# Android SDK Environment
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
EOF
fi

echo "[Android SDK] セットアップが完了しました。"
