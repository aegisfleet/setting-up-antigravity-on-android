# Antigravity & T3 Code on Android (Termux)

Android 上の **Termux**（Google Play 版）および **proot-distro (Ubuntu)** を利用し、[T3 Code](https://github.com/pingdotgg/t3code) と **Google Antigravity** をワンライナーで手軽にセットアップ・運用するためのスクリプト群です。
オプションで、ARM64 環境に最適化された **Android SDK (APK/AAB ビルド環境)** の自動構築もサポートします。

---

## 主な特徴

- 🚀 **ワンライナー導入**: Termux 上で 1 行のコマンドを実行するだけで Ubuntu 環境から T3 Code まで完全自動構築。
- 🤖 **Antigravity セットアップ済み**: 
  - Android (ARM64) 特有の 39-bit VA (Virtual Address) / TCMalloc 起因によるクラッシュや、T3 UI 上の「Install Antigravity」失敗問題を解消するラッパーとプロバイダ設定を事前配備。
- 📦 **完全な依存関係解決**:
  - Ubuntu PRoot 環境に必要な `libatomic1`、Node.js LTS (v22.x)、Python 環境を事前インストール。
- 🛠 **Android SDK ビルド環境（オプション）**:
  - Google 公式 Maven に存在しない ARM64 版 `aapt2` の問題に対応し、端末内での Gradle による APK ビルドを可能にする環境を自動構成。
- 📱 **直感的な操作コマンド**:
  - `t3-start`、`t3-stop`、`t3-status`、`t3-shell` などの Termux コマンドを自動生成。

---

## 前提条件

1. **Android 端末** (ARM64 / aarch64 推奨)
2. **Termux (Google Play 版)**
3. **空きストレージ容量**:
   - 基本構成 (Ubuntu + T3 Code + Antigravity): 約 2.5 GB 以上
   - Android SDK オプション追加時: 約 5 GB 以上

---

## インストール手順

### 1. Termux を起動してワンライナーを実行

Termux を開き、以下のコマンドを貼り付けて実行します。

```bash
pkg update -y && pkg install -y curl
curl -fsSL "https://raw.githubusercontent.com/aegisfleet/setting-up-antigravity-on-android/main/install.sh?v=$(date +%s)" | bash
```

> **対話プロンプトについて**:
> スクリプト実行中に「`Android SDK (APKビルド環境) もセットアップしますか？ [y/N]:`」と尋ねられます。
> Android アプリのビルドも行いたい場合は `y`、T3 Code とエージェントのみで十分な場合は `n`（Enter）を押してください。
> （環境変数 `INSTALL_ANDROID_SDK=1` を指定して非対話で実行することも可能です）

---

## 使い方

### 1. T3 Code サーバーの起動

Termux のプロンプトで以下を実行します。

```bash
t3-start
```

バックグラウンドでサーバーが起動します。

### 2. ブラウザまたは T3 Code アプリからアクセス

端末の Web ブラウザ（Chrome 等）を開き、以下のアドレスにアクセスします。

👉 **`http://127.0.0.1:3773`**

（Google Play で配信されている Android 版「T3 Code」アプリからローカルサーバーに接続して利用することも可能です）

### 3. Antigravity の認証

1. T3 Code の画面左下の **Settings**（歯車アイコン）を開きます。
2. **Providers** メニューを選択します。
3. **Antigravity** がすでにセットアップ済みの状態で表示されます。
4. **Sign in with Google** をクリックし、Google アカウントで認証を完了します。
5. 認証が完了すると、Antigravity エージェントとチャットやコード生成を開始できます。

---

## 便利な管理コマンド

セットアップ完了後、Termux ホスト側で以下のショートカットコマンドが利用可能です。

| コマンド | 説明 |
| :--- | :--- |
| `t3-start` | T3 Code サーバーをバックグラウンド起動 (`http://127.0.0.1:3773`) |
| `t3-stop` | T3 Code サーバーを停止 |
| `t3-status` | サーバーの稼働状態と直近のログを確認 |
| `t3-shell` | Ubuntu PRoot 環境の bash シェルに対話的にログイン |

---

## オプション: Android アプリのビルド（Android SDK）

オプションを有効化した場合、Ubuntu 内に以下の環境が整います。

- **OpenJDK 17**: `/usr/lib/jvm/java-17-openjdk-arm64`
- **Android SDK**: `/opt/android-sdk` (`platforms;android-34`, `build-tools;34.0.0`)
- **ARM64 aapt2 対策**:
  - `~/.gradle/gradle.properties` に以下が自動設定されます。
    ```properties
    android.aapt2FromMavenOverride=/usr/local/bin/aapt2
    ```

### ビルドの実行例

```bash
# Ubuntu 環境に入る
t3-shell

# プロジェクトディレクトリに移動
cd /path/to/your-android-project

# Gradle でデバッグ APK をビルド
./gradlew assembleDebug
```

---

## トラブルシューティング

### 1. バックグラウンドでサーバーが勝手に落ちる (Phantom Process Killer)
Android 12 以降では、バックグラウンドのプロセス数が制限（最大 32 プロセス）されています。
- **対策 1**: Termux の通知欄を開き、「**Acquire Wakelock**」をタップしてスリープ抑止を有効にしてください。
- **対策 2**: PC と ADB 接続できる場合、以下のコマンドで制限を解除できます。
  ```bash
  adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
  ```

### 2. ポート 3773 が既に使われている
```bash
t3-stop
```
を実行して一度プロセスをクリーンアップしてから、再度 `t3-start` を実行してください。

---

## ライセンス

[MIT License](LICENSE)
