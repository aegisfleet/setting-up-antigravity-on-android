#!/usr/bin/env bash
# ==============================================================================
# setting-up-antigravity-on-android
# Antigravity Provider Setup for T3 Code (PRoot Ubuntu ARM64)
# ==============================================================================
set -euo pipefail

echo "[Antigravity] セットアップを開始します..."

ANTIGRAVITY_DIR="/opt/antigravity"
RUNTIME_BIN_DIR="${ANTIGRAVITY_DIR}/bin"
mkdir -p "$RUNTIME_BIN_DIR"
mkdir -p /root/.gemini/antigravity-acp
mkdir -p /root/.t3/userdata

# 1. クリーンアップ: 39-bit VA非互換の巨大公式バイナリ(~2GB)が存在する場合は削除して空き容量を確保
if [ -f "${RUNTIME_BIN_DIR}/agy_acp_server.real" ]; then
    echo "[Antigravity] 39-bit VA非互換バイナリを削除し、ディスク容量を解放中..."
    rm -f "${RUNTIME_BIN_DIR}/agy_acp_server.real" "${RUNTIME_BIN_DIR}/localharness_external.real" 2>/dev/null || true
fi

# 2. Setup Python virtual environment for agent bridge
if [ ! -d "$ANTIGRAVITY_DIR/venv" ]; then
    echo "[Antigravity] Python 仮想環境を作成中..."
    python3 -m venv "$ANTIGRAVITY_DIR/venv"
fi

# 2.5 Ensure Antigravity CLI (agy) is linked in PATH
if ! command -v agy >/dev/null 2>&1; then
    if [ -f "/root/.local/bin/agy" ]; then
        ln -sf /root/.local/bin/agy /usr/local/bin/agy
    else
        echo "[Antigravity] Antigravity CLI (agy) をインストール中..."
        curl -fsSL https://antigravity.google/cli/install.sh | bash || true
        if [ -f "/root/.local/bin/agy" ]; then
            ln -sf /root/.local/bin/agy /usr/local/bin/agy
        fi
    fi
fi

# 3. Create dummy xdg-open to safely intercept browser opening in PRoot
XDG_OPEN_BIN="/usr/local/bin/xdg-open"
cat << 'EOF' > "$XDG_OPEN_BIN"
#!/usr/bin/env bash
# Termux PRoot dummy xdg-open
echo "Open the following link to authenticate the ACP server: $1" >&2
EOF
chmod +x "$XDG_OPEN_BIN"

# 4. Create Antigravity ACP Python Bridge script
ACP_PY="${RUNTIME_BIN_DIR}/agy_acp_bridge.py"
cat << 'PYEOF' > "$ACP_PY"
#!/usr/bin/env python3
import sys
import json
import os
import uuid
import shutil
import subprocess
import urllib.request
import urllib.error

LOG_FILE = "/tmp/agy_acp.log"
API_KEY_FILE = "/root/.gemini/antigravity-acp/gemini_api_key"

def log_debug(msg):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except Exception:
        pass

def send_response(obj):
    raw = json.dumps(obj)
    log_debug(">> " + raw)
    sys.stdout.write(raw + "\n")
    sys.stdout.flush()

# モデル定義 (デフォルト: Gemini 3.8 Flash)
MODELS_LIST = [
    {"modelId": "gemini-3.8-flash", "name": "Gemini 3.8 Flash (Default)"},
    {"modelId": "claude-sonnet-4.6", "name": "Claude Sonnet 4.6"},
    {"modelId": "claude-opus-4.6", "name": "Claude Opus 4.6"},
    # 既存・過去スレッド互換用
    {"modelId": "gemini-2.5-pro", "name": "Gemini 2.5 Pro"},
    {"modelId": "gemini-2.5-flash", "name": "Gemini 2.5 Flash"}
]

current_model = "gemini-3.8-flash"

def find_agy_binary():
    candidates = [
        shutil.which("agy"),
        "/usr/local/bin/agy",
        "/root/.local/bin/agy",
        "/data/data/com.termux/files/home/.local/bin/agy"
    ]
    for c in candidates:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return None

def get_api_key():
    key = os.environ.get("GEMINI_API_KEY")
    if key and key.strip():
        return key.strip()
    if os.path.exists(API_KEY_FILE):
        try:
            with open(API_KEY_FILE, "r", encoding="utf-8") as f:
                k = f.read().strip()
                if k:
                    return k
        except Exception:
            pass
    return None

def call_gemini_api(api_key, model, prompt_text):
    api_model = "gemini-2.5-flash"
    if "pro" in model.lower():
        api_model = "gemini-2.5-pro"
    elif "flash" in model.lower():
        api_model = "gemini-2.5-flash"

    url = f"https://generativelanguage.googleapis.com/v1beta/models/{api_model}:generateContent?key={api_key}"
    payload = {
        "contents": [
            {
                "parts": [{"text": prompt_text}]
            }
        ]
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        res_json = json.loads(resp.read().decode("utf-8"))
        candidates = res_json.get("candidates", [])
        if candidates:
            parts = candidates[0].get("content", {}).get("parts", [])
            if parts:
                return parts[0].get("text", "")
    return "APIからの応答が空でした。"

def build_agy_cmd(agy_bin, prompt_text, model=None, effort=None):
    cmd = [agy_bin, "-p", prompt_text, "--dangerously-skip-permissions"]
    if model:
        cmd.extend(["--model", model])
    if effort:
        cmd.extend(["--effort", effort])
    return cmd

def execute_agy(cmd, session_id, agy_env):
    log_debug(f"Spawning agy: {cmd}")
    err_log_path = "/tmp/agy_cmd_err.log"
    full_output = ""
    err_msg = ""
    retcode = 0
    try:
        with open(err_log_path, "w+", encoding="utf-8", errors="replace") as err_file:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=err_file,
                text=True,
                bufsize=1,
                env=agy_env
            )
            for line in iter(proc.stdout.readline, ''):
                if not line:
                    break
                full_output += line
                send_response({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {
                                "type": "text",
                                "text": line
                            }
                        }
                    }
                })
            proc.stdout.close()
            retcode = proc.wait()
        if retcode != 0:
            try:
                with open(err_log_path, "r", encoding="utf-8", errors="replace") as ef:
                    err_msg = ef.read().strip()
            except Exception:
                pass
            log_debug(f"agy exited with code {retcode}: {err_msg}")
    except Exception as e:
        log_debug(f"agy execution error: {e}")
        err_msg = str(e)
        retcode = -1
    return retcode, full_output, err_msg

def get_config_options():
    return [
        {
            "id": "model",
            "name": "Model",
            "type": "select",
            "currentValue": current_model,
            "options": [
                {"value": m["modelId"], "name": m["name"]}
                for m in MODELS_LIST
            ]
        }
    ]

def get_session_setup_result(session_id=None):
    sid = session_id or str(uuid.uuid4())
    res = {
        "sessionId": sid,
        "models": {
            "currentModelId": current_model,
            "availableModels": MODELS_LIST
        },
        "configOptions": get_config_options(),
        "availableCommands": [
            {"name": "compact", "description": "Compact conversation history"}
        ]
    }
    return res

def main():
    global current_model
    log_debug(f"Antigravity ACP bridge started. Args: {sys.argv}")
    while True:
        line = sys.stdin.readline()
        if not line:
            log_debug("stdin closed (EOF)")
            break
        line = line.strip()
        if not line:
            continue
        log_debug("<< " + line)
        try:
            req = json.loads(line)
        except Exception as e:
            log_debug("JSON parse error: " + str(e))
            continue

        method = req.get("method")
        msg_id = req.get("id")

        if method == "initialize":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "protocolVersion": 1,
                    "agentInfo": {
                        "name": "antigravity-acp",
                        "title": "Google Antigravity",
                        "version": "agy_acp_server_1.1.1"
                    },
                    "agentCapabilities": {
                        "loadSession": True,
                        "sessionCapabilities": {
                            "list": {},
                            "resume": {}
                        },
                        "auth": {
                            "logout": {}
                        },
                        "promptCapabilities": {
                            "image": True,
                            "audio": True,
                            "embeddedContext": True
                        }
                    },
                    "authMethods": [
                        {"id": "oauth-personal", "name": "Google account"},
                        {"id": "gemini-api-key", "name": "Gemini API key"}
                    ]
                }
            })
        elif method == "authenticate":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })
        elif method == "session/new":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": get_session_setup_result(str(uuid.uuid4()))
            })
        elif method == "session/set_config_option":
            params = req.get("params", {})
            cfg_id = params.get("configId")
            val = params.get("value")
            if cfg_id == "model" and isinstance(val, str) and val:
                current_model = val
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "configOptions": get_config_options()
                }
            })
        elif method == "session/set_model":
            params = req.get("params", {})
            m_id = params.get("modelId")
            if isinstance(m_id, str) and m_id:
                current_model = m_id
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })
        elif method == "session/set_mode":
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })
        elif method in ("session/load", "session/resume"):
            params = req.get("params", {})
            sid = params.get("sessionId") or str(uuid.uuid4())
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": get_session_setup_result(sid)
            })
        elif method == "session/prompt":
            session_id = req.get("params", {}).get("sessionId") or str(uuid.uuid4())
            prompt_data = req.get("params", {}).get("prompt", [])
            user_text = ""
            if isinstance(prompt_data, list):
                for p in prompt_data:
                    if isinstance(p, dict) and p.get("type") == "text":
                        user_text += p.get("text", "")
            elif isinstance(prompt_data, str):
                user_text = prompt_data

            agy_bin = find_agy_binary()
            api_key = get_api_key()

            agy_env = dict(os.environ)
            agy_env["HOME"] = "/root"
            agy_env["PATH"] = "/usr/local/bin:/root/.local/bin:" + agy_env.get("PATH", "/usr/bin:/bin")

            is_json_request = "Return only the requested JSON object" in user_text or "outputSchema" in user_text

            if is_json_request:
                # タイトル生成要求には即座に軽量JSONを返して並行競合を防止
                title = "チャット"
                for line in user_text.splitlines():
                    clean_line = line.strip()
                    if clean_line and not clean_line.startswith("<") and not clean_line.startswith("Return only") and not clean_line.startswith("Use only"):
                        title = clean_line[:24]
                        break
                title_json = json.dumps({"title": title})
                send_response({
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": session_id,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {
                                "type": "text",
                                "text": title_json
                            }
                        }
                    }
                })
                send_response({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "stopReason": "end_turn"
                    }
                })
            else:
                if agy_bin:
                    # 1回目: 選択モデルで実行 (--effort は指定しない)
                    cmd = build_agy_cmd(agy_bin, user_text, current_model)
                    retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    # 失敗時: --effort が必須と要求された場合のみ effort を付与してリトライ
                    if retcode != 0 and not full_output and "requires --effort" in err_msg:
                        cmd = build_agy_cmd(agy_bin, user_text, current_model, effort="medium")
                        log_debug(f"Retrying with effort: {cmd}")
                        retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    # 失敗時: モデル選択・effort未対応・無効モデル等の場合、モデルフラグなし（CLI デフォルト）でリトライ
                    if retcode != 0 and not full_output and any(k in err_msg for k in ["invalid model selection", "not supported", "unknown model", "no model configuration"]):
                        log_debug(f"Retrying with default model (no flags) due to model error: {err_msg}")
                        cmd = [agy_bin, "-p", user_text, "--dangerously-skip-permissions"]
                        retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    if retcode != 0 and not full_output:
                        send_response({
                            "jsonrpc": "2.0",
                            "method": "session/update",
                            "params": {
                                "sessionId": session_id,
                                "update": {
                                    "sessionUpdate": "agent_message_chunk",
                                    "content": {
                                        "type": "text",
                                        "text": f"【Antigravity CLI エラー】\n{err_msg}"
                                    }
                                }
                            }
                        })
                elif api_key:
                    try:
                        reply = call_gemini_api(api_key, current_model, user_text)
                    except Exception as e:
                        log_debug(f"Gemini API error: {e}")
                        reply = f"【Gemini API 呼び出しエラー】\n{str(e)}"
                    send_response({
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": session_id,
                            "update": {
                                "sessionUpdate": "agent_message_chunk",
                                "content": {
                                    "type": "text",
                                    "text": reply
                                }
                            }
                        }
                    })
                else:
                    msg = (
                        f"【Antigravity CLI (agy) が未検出です】\n"
                        f"PRoot Ubuntu 内で以下を実行して agy をインストールおよびログインしてください:\n"
                        f"  curl -fsSL https://antigravity.google/cli/install.sh | bash\n"
                        f"  ln -sf /root/.local/bin/agy /usr/local/bin/agy\n"
                        f"  agy\n"
                    )
                    send_response({
                        "jsonrpc": "2.0",
                        "method": "session/update",
                        "params": {
                            "sessionId": session_id,
                            "update": {
                                "sessionUpdate": "agent_message_chunk",
                                "content": {
                                    "type": "text",
                                    "text": msg
                                }
                            }
                        }
                    })

                send_response({
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "result": {
                        "stopReason": "end_turn"
                    }
                })
        elif msg_id is not None:
            send_response({
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {}
            })

if __name__ == "__main__":
    main()
PYEOF
chmod +x "$ACP_PY"

# 5. Create Smart Wrapper for agy_acp_server.par
# T3 Code は PATH 上の "agy_acp_server.par" と同じディレクトリにある "localharness_external" を探索する
ACP_PAR="/usr/local/bin/agy_acp_server.par"
ACP_LINK="/usr/local/bin/agy_acp_server"
HARNESS="/usr/local/bin/localharness_external"

cat << 'EOF' > "$ACP_PAR"
#!/usr/bin/env bash
# Antigravity ACP Server for Android / PRoot (ARM64 39-bit VA compatible)
set -e
exec python3 -u /opt/antigravity/bin/agy_acp_bridge.py "$@"
EOF
chmod +x "$ACP_PAR"
ln -sf "$ACP_PAR" "$ACP_LINK"

# 6. Create localharness_external
cat << 'EOF' > "$HARNESS"
#!/usr/bin/env bash
# Antigravity localharness_external stub
exit 0
EOF
chmod +x "$HARNESS"

# 7. Pre-configure T3 Code settings.json
SETTINGS_FILE="/root/.t3/userdata/settings.json"
echo "[Antigravity] T3 Code の設定ファイル ($SETTINGS_FILE) を更新中..."

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

if "antigravity" not in data["providerInstances"]:
    data["providerInstances"]["antigravity"] = {}

inst = data["providerInstances"]["antigravity"]
inst["driver"] = "antigravity"
inst["enabled"] = True

if "config" not in inst or not isinstance(inst["config"], dict):
    inst["config"] = {}

inst["config"]["authMethod"] = "oauth-personal"
inst["config"]["binaryPath"] = "/usr/local/bin/agy_acp_server.par"

with open(settings_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)

print("[Antigravity] settings.json のプロバイダ設定を正常に更新しました。")
EOF

echo "[Antigravity] セットアップが完了しました。"
echo "             T3 Code を再起動すると設定が反映されます。"
