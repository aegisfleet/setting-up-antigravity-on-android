#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# T3 Code Server Process Manager for PRoot
# ==============================================================================
set -euo pipefail

T3_DIR="/root/.t3"
PID_FILE="${T3_DIR}/t3.pid"
LOG_FILE="${T3_DIR}/server.log"

mkdir -p "$T3_DIR"

start_server() {
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "[*] T3 Code サーバーは既に起動しています (PID: $PID)"
            return 0
        fi
        rm -f "$PID_FILE"
    fi

    echo "[*] T3 Code サーバーを起動中..."
    export PATH="/usr/local/bin:$PATH"
    
    # Run in background with nohup
    nohup t3 serve --host 0.0.0.0 < /dev/null > "$LOG_FILE" 2>&1 &
    NEW_PID=$!
    echo "$NEW_PID" > "$PID_FILE"

    # Wait briefly and verify
    sleep 2
    if kill -0 "$NEW_PID" 2>/dev/null; then
        echo "[✓] T3 Code サーバーが正常に起動しました (PID: $NEW_PID)"
        echo "    Web UI: http://127.0.0.1:3773"
        echo "    ログファイル: $LOG_FILE"
    else
        echo "[!] サーバーの起動に失敗しました。直近のログ:"
        tail -n 20 "$LOG_FILE"
        exit 1
    fi
}

stop_server() {
    if [ ! -f "$PID_FILE" ]; then
        echo "[*] T3 Code サーバーは起動していません。"
        # Backup check with pkill
        pkill -f "t3 serve" 2>/dev/null || true
        return 0
    fi

    PID="$(cat "$PID_FILE")"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        echo "[*] T3 Code サーバー (PID: $PID) を停止中..."
        kill "$PID" || true
        sleep 1
        if kill -0 "$PID" 2>/dev/null; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi

    rm -f "$PID_FILE"
    echo "[✓] T3 Code サーバーを停止しました。"
}

status_server() {
    if [ -f "$PID_FILE" ]; then
        PID="$(cat "$PID_FILE" 2>/dev/null || true)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "[✓] T3 Code サーバーは稼働中です (PID: $PID)"
            echo "    アドレス: http://127.0.0.1:3773"
            echo ""
            echo "--- 直近のログ (末尾 10 行) ---"
            tail -n 10 "$LOG_FILE" 2>/dev/null || true
            return 0
        fi
    fi
    echo "[*] T3 Code サーバーは停止しています。"
}

case "${1:-start}" in
    start)
        start_server
        ;;
    stop)
        stop_server
        ;;
    status)
        status_server
        ;;
    restart)
        stop_server
        sleep 1
        start_server
        ;;
    *)
        echo "使用方法: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
