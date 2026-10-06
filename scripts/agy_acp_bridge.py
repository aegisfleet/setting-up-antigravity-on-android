#!/usr/bin/env python3
"""
Antigravity ACP Python Bridge for T3 Code
Connects T3 Code's Agent Client Protocol (ACP) stdio interface to the official Google Antigravity CLI (agy).
Supports multi-turn conversation persistence, real-time stream-json parsing, and automated model execution.
"""
import sys
import json
import os
import re
import time
import uuid
import shutil
import subprocess
import threading

LOG_FILE = "/tmp/agy_acp.log"
SESSION_MAP_FILE = "/root/.gemini/antigravity-acp/session_map.json"
MODELS_CACHE_FILE = "/root/.gemini/antigravity-acp/models_cache.json"
MODELS_CACHE_TTL = 3600 * 12  # 12時間

FALLBACK_MODELS = [
    {"modelId": "gemini-3.8-flash-medium", "name": "Gemini 3.8 Flash (Medium)"},
    {"modelId": "gemini-3.8-flash-high", "name": "Gemini 3.8 Flash (High)"},
    {"modelId": "gemini-3.8-flash-low", "name": "Gemini 3.8 Flash (Low)"},
    {"modelId": "gemini-3.7-flash-medium", "name": "Gemini 3.7 Flash (Medium)"},
    {"modelId": "gemini-3.6-flash-medium", "name": "Gemini 3.6 Flash (Medium)"},
    {"modelId": "gemini-3.1-pro-high", "name": "Gemini 3.1 Pro (High)"},
    {"modelId": "claude-sonnet-4-6", "name": "Claude Sonnet 4.6 (Thinking)"},
    {"modelId": "claude-opus-4-6-thinking", "name": "Claude Opus 4.6 (Thinking)"},
    {"modelId": "gpt-oss-120b-medium", "name": "GPT-OSS 120B (Medium)"},
]

MODEL_ALIASES = {
    "gemini-3.8-flash": "gemini-3.8-flash-medium",
    "gemini-3.7-flash": "gemini-3.7-flash-medium",
    "gemini-3.6-flash": "gemini-3.6-flash-medium",
    "gemini-3.1-pro": "gemini-3.1-pro-high",
    "claude-sonnet-4.6": "claude-sonnet-4-6",
    "claude-opus-4.6": "claude-opus-4-6-thinking",
    "gemini-2.5-pro": "gemini-3.1-pro-high",
    "gemini-2.5-flash": "gemini-3.8-flash-medium",
}

current_model = "gemini-3.8-flash-medium"
cached_models = []

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

def load_session_map():
    if os.path.exists(SESSION_MAP_FILE):
        try:
            with open(SESSION_MAP_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            log_debug(f"Error loading session map: {e}")
    return {}

def save_session_map(mapping):
    try:
        os.makedirs(os.path.dirname(SESSION_MAP_FILE), exist_ok=True)
        with open(SESSION_MAP_FILE, "w", encoding="utf-8") as f:
            json.dump(mapping, f, indent=2, ensure_ascii=False)
    except Exception as e:
        log_debug(f"Error saving session map: {e}")

session_map = load_session_map()

def get_agy_conversation(session_id):
    global session_map
    if not session_id:
        return None
    return session_map.get(session_id)

def set_agy_conversation(session_id, agy_conv_id):
    global session_map
    if not session_id or not agy_conv_id:
        return
    if session_map.get(session_id) != agy_conv_id:
        session_map[session_id] = agy_conv_id
        save_session_map(session_map)
        log_debug(f"Mapped T3 sessionId {session_id} -> agy conversation {agy_conv_id}")

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

def load_cached_models():
    if os.path.exists(MODELS_CACHE_FILE):
        try:
            with open(MODELS_CACHE_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict) and "models" in data:
                    models = data.get("models", [])
                    ts = data.get("timestamp", 0)
                    if isinstance(models, list) and models:
                        return models, ts
        except Exception as e:
            log_debug(f"Error loading models cache: {e}")
    return [], 0

def save_cached_models(models):
    try:
        os.makedirs(os.path.dirname(MODELS_CACHE_FILE), exist_ok=True)
        with open(MODELS_CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({
                "timestamp": time.time(),
                "models": models
            }, f, indent=2, ensure_ascii=False)
        log_debug(f"Saved {len(models)} models to {MODELS_CACHE_FILE}")
    except Exception as e:
        log_debug(f"Error saving models cache: {e}")

def fetch_models_from_agy(agy_bin=None):
    b = agy_bin or find_agy_binary()
    if not b:
        return []
    try:
        proc = subprocess.run(
            [b, "models"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15
        )
        if proc.returncode == 0:
            parsed = []
            for line in proc.stdout.splitlines():
                line = line.strip()
                if not line:
                    continue
                parts = line.split(None, 1)
                if parts:
                    m_id = parts[0]
                    m_name = parts[1] if len(parts) > 1 else m_id
                    parsed.append({"modelId": m_id, "name": m_name})
            if parsed:
                log_debug(f"Successfully fetched {len(parsed)} models from agy")
                return parsed
        else:
            log_debug(f"agy models returned code {proc.returncode}: {proc.stderr}")
    except Exception as e:
        log_debug(f"Exception fetching agy models: {e}")
    return []

def refresh_models_async(agy_bin=None):
    global cached_models
    log_debug("Starting async refresh of models list...")
    live_models = fetch_models_from_agy(agy_bin)
    if live_models:
        cached_models = live_models
        save_cached_models(live_models)
        log_debug(f"Async refresh complete. Updated {len(live_models)} models.")

def get_available_models(agy_bin=None):
    global cached_models
    if cached_models:
        return cached_models

    models, ts = load_cached_models()
    if models:
        cached_models = models
        if (time.time() - ts) > MODELS_CACHE_TTL:
            threading.Thread(target=refresh_models_async, args=(agy_bin,), daemon=True).start()
        return cached_models

    cached_models = list(FALLBACK_MODELS)
    threading.Thread(target=refresh_models_async, args=(agy_bin,), daemon=True).start()
    return cached_models

def normalize_model_id(model_id, available_models=None):
    if not model_id:
        return "gemini-3.8-flash-medium"

    aliased = MODEL_ALIASES.get(model_id, model_id)
    if available_models:
        avail_ids = [m["modelId"] for m in available_models]
        if aliased in avail_ids:
            return aliased
        for mid in avail_ids:
            if aliased.startswith(mid) or mid.startswith(aliased):
                return mid
        if "gemini-3.8-flash-medium" in avail_ids:
            return "gemini-3.8-flash-medium"
        return avail_ids[0]
    return aliased

def build_agy_cmd(agy_bin, prompt_text, model=None, effort=None, conv_id=None):
    avail = get_available_models(agy_bin)
    normalized = normalize_model_id(model, avail) if model else None
    cmd = [
        agy_bin,
        "-p", prompt_text,
        "--output-format", "stream-json",
        "--dangerously-skip-permissions"
    ]
    if conv_id:
        cmd.extend(["--conversation", conv_id])
    if normalized:
        cmd.extend(["--model", normalized])
    if effort:
        cmd.extend(["--effort", effort])
    elif normalized and ("gemini-3" in normalized and not any(normalized.endswith(x) for x in ["-high", "-medium", "-low"])):
        # 正規化後も effort 接尾辞がない旧形式の場合のみ --effort を付与
        cmd.extend(["--effort", "medium"])
    return cmd


def execute_agy(cmd, session_id, agy_env):
    log_debug(f"Spawning agy: {cmd}")
    err_log_path = "/tmp/agy_cmd_err.log"
    full_output = ""
    err_msg = ""
    retcode = 0
    captured_conv_id = None
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
                line_str = line.strip()
                if not line_str:
                    continue

                # Stream-JSON (NDJSON) のパース
                try:
                    event_data = json.loads(line_str)
                    ev_type = event_data.get("event")

                    if ev_type == "init":
                        cid = event_data.get("conversation_id")
                        if cid:
                            captured_conv_id = cid
                            set_agy_conversation(session_id, cid)

                    elif ev_type == "step_update":
                        su = event_data.get("step_update", {})
                        cid = su.get("conversation_id")
                        if cid and not captured_conv_id:
                            captured_conv_id = cid
                            set_agy_conversation(session_id, cid)

                        step_type = su.get("step_type")
                        if step_type == "agent_response":
                            td = su.get("text_delta")
                            if td:
                                full_output += td
                                send_response({
                                    "jsonrpc": "2.0",
                                    "method": "session/update",
                                    "params": {
                                        "sessionId": session_id,
                                        "update": {
                                            "sessionUpdate": "agent_message_chunk",
                                            "content": {
                                                "type": "text",
                                                "text": td
                                            }
                                        }
                                    }
                                })
                        elif step_type == "tool" and su.get("state") == "ACTIVE":
                            tool_name = su.get("tool_name", "tool")
                            tool_notice = f"\n> ⚙️ *Tool: `{tool_name}`*\n\n"
                            send_response({
                                "jsonrpc": "2.0",
                                "method": "session/update",
                                "params": {
                                    "sessionId": session_id,
                                    "update": {
                                        "sessionUpdate": "agent_message_chunk",
                                        "content": {
                                            "type": "text",
                                            "text": tool_notice
                                        }
                                    }
                                }
                            })

                    elif ev_type == "result":
                        res = event_data.get("result", {})
                        cid = res.get("conversation_id")
                        if cid and not captured_conv_id:
                            captured_conv_id = cid
                            set_agy_conversation(session_id, cid)

                        # text_delta が送られていなかった場合のフォールバック
                        if not full_output and res.get("response"):
                            resp_text = res.get("response")
                            full_output += resp_text
                            send_response({
                                "jsonrpc": "2.0",
                                "method": "session/update",
                                "params": {
                                    "sessionId": session_id,
                                    "update": {
                                        "sessionUpdate": "agent_message_chunk",
                                        "content": {
                                            "type": "text",
                                            "text": resp_text
                                        }
                                    }
                                }
                            })
                except Exception:
                    # JSON形式でないプレーンテキスト行のフォールバック出力
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

def extract_thread_title(user_text):
    if not user_text:
        return "新しいチャット"

    # User message: 以降が存在する場合は実際のユーザー入力を抽出
    if "User message:" in user_text:
        content = user_text.split("User message:", 1)[1].strip()
    else:
        content = user_text.strip()

    # XMLタグやシステムプロンプトタグ (<runtime_info> 等) を除去
    content = re.sub(r'<[^>]+>.*?</[^>]+>', '', content, flags=re.DOTALL)
    content = re.sub(r'<[^>]+>', '', content)

    # 先頭の空行やマークダウン記号を除去
    lines = [l.strip() for l in content.splitlines() if l.strip()]
    if not lines:
        return "新しいチャット"

    first_line = re.sub(r'^[#*\-`\s]+', '', lines[0]).strip()
    if len(first_line) < 6 and len(lines) > 1:
        second_line = re.sub(r'^[#*\-`\s]+', '', lines[1]).strip()
        first_line = f"{first_line} {second_line}".strip()

    # 最初の文を取り出す（。や！？）
    parts = re.split(r'([。？！?!])', first_line)
    if len(parts) >= 2 and len(parts[0].strip()) >= 4:
        cand = parts[0].strip()
        if parts[1] in '？?':
            cand += parts[1]
    else:
        cand = first_line.strip()

    cand = cand.rstrip('。、,. ')

    if len(cand) > 30:
        cand = cand[:30].rstrip('、 ,') + '…'

    return cand or "新しいチャット"

def get_config_options():
    models = get_available_models()
    cur = normalize_model_id(current_model, models)
    return [
        {
            "id": "model",
            "name": "Model",
            "type": "select",
            "currentValue": cur,
            "options": [
                {"value": m["modelId"], "name": m["name"]}
                for m in models
            ]
        }
    ]

def get_session_setup_result(session_id=None):
    sid = session_id or str(uuid.uuid4())
    models = get_available_models()
    cur = normalize_model_id(current_model, models)
    res = {
        "sessionId": sid,
        "models": {
            "currentModelId": cur,
            "availableModels": models
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
    # 起動時に非同期でモデルキャッシュを確認・最新化
    threading.Thread(target=refresh_models_async, daemon=True).start()

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
                current_model = normalize_model_id(val, get_available_models())
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
                current_model = normalize_model_id(m_id, get_available_models())
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

            agy_env = dict(os.environ)
            agy_env["HOME"] = "/root"
            agy_env["PATH"] = "/usr/local/bin:/root/.local/bin:" + agy_env.get("PATH", "/usr/bin:/bin")

            is_json_request = "Return only the requested JSON object" in user_text or "outputSchema" in user_text

            if is_json_request:
                # タイトル生成要求には即座に軽量JSONを返して並行競合を防止
                title = extract_thread_title(user_text)
                log_debug(f"Generated thread title: {title}")
                title_json = json.dumps({"title": title, "needsRefinement": False}, ensure_ascii=False)
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
                    agy_conv_id = get_agy_conversation(session_id)
                    # 1回目: 選択モデル・セッションID引き継ぎで実行
                    cmd = build_agy_cmd(agy_bin, user_text, current_model, conv_id=agy_conv_id)
                    retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    # 失敗時 (1): conversation が見つからない / 無効な場合は conv_id なしで新規作成リトライ
                    if retcode != 0 and not full_output and agy_conv_id and any(k in err_msg for k in ["not found", "Conversation", "conversation"]):
                        log_debug(f"Retrying without conversation ID due to: {err_msg}")
                        session_map.pop(session_id, None)
                        save_session_map(session_map)
                        cmd = build_agy_cmd(agy_bin, user_text, current_model, conv_id=None)
                        retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    # 失敗時 (2): --effort が明示的に要求された場合のリトライ
                    if retcode != 0 and not full_output and "requires --effort" in err_msg:
                        cmd = build_agy_cmd(agy_bin, user_text, current_model, effort="medium", conv_id=get_agy_conversation(session_id))
                        log_debug(f"Retrying with effort: {cmd}")
                        retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    # 失敗時 (2.5): --effort がサポートされていないモデルでエラーになった場合のリトライ
                    if retcode != 0 and not full_output and "--effort is not supported" in err_msg:
                        log_debug(f"Retrying without effort due to: {err_msg}")
                        cmd = [
                            agy_bin,
                            "-p", user_text,
                            "--output-format", "stream-json",
                            "--dangerously-skip-permissions",
                            "--model", normalize_model_id(current_model, get_available_models(agy_bin))
                        ]
                        conv_retry = get_agy_conversation(session_id)
                        if conv_retry:
                            cmd.extend(["--conversation", conv_retry])
                        retcode, full_output, err_msg = execute_agy(cmd, session_id, agy_env)

                    # 失敗時 (3): モデルエラーの場合はデフォルトモデルでリトライ
                    if retcode != 0 and not full_output and any(k in err_msg for k in ["invalid model selection", "not supported", "unknown model", "no model configuration"]):
                        log_debug(f"Retrying with default model due to model error: {err_msg}")
                        cmd = [
                            agy_bin,
                            "-p", user_text,
                            "--output-format", "stream-json",
                            "--dangerously-skip-permissions"
                        ]
                        conv_retry = get_agy_conversation(session_id)
                        if conv_retry:
                            cmd.extend(["--conversation", conv_retry])
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
