#!/usr/bin/env python3
"""
Codex T3 Code Bridge
Transparent JSON-RPC stdio proxy between T3 Code and `codex app-server`.
Injects quota percentages into model display names (e.g. "GPT-6-Luna [残99%]").
"""
import sys
import os
import re
import json
import time
import shutil
import subprocess
import threading

LOG_FILE = "/tmp/codex_t3_bridge.log"
CACHE_FILE = "/root/.codex/quota_cache.json"

def log_debug(msg):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}\n")
    except Exception:
        pass

def get_real_codex_bin():
    candidates = [
        "/usr/local/bin/codex",
        "/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-arm64/vendor/aarch64-unknown-linux-musl/bin/codex",
        "/usr/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex",
    ]
    for c in candidates:
        if os.path.islink(c):
            real = os.path.realpath(c)
            if os.path.exists(real) and os.access(real, os.X_OK) and not real.endswith("codex-t3-bridge") and not real.endswith("codex_t3_bridge.py"):
                return real
        elif os.path.exists(c) and os.access(c, os.X_OK) and not c.endswith("codex-t3-bridge") and not c.endswith("codex_t3_bridge.py"):
            return c

    which = shutil.which("codex")
    if which:
        real = os.path.realpath(which)
        if os.path.exists(real) and os.access(real, os.X_OK) and not real.endswith("codex-t3-bridge") and not real.endswith("codex_t3_bridge.py"):
            return real

    return "/usr/local/bin/codex"

cached_quota_tag = None
cached_quota_time = 0

def extract_quota_from_rate_limits(rate_limits_payload):
    """
    Extracts usedPercent from rateLimits object and returns short tag e.g. '残99%'
    """
    if not isinstance(rate_limits_payload, dict):
        return None
    rl = rate_limits_payload.get("rateLimits", rate_limits_payload)
    if not isinstance(rl, dict):
        return None
    primary = rl.get("primary")
    if isinstance(primary, dict):
        used = primary.get("usedPercent")
        if used is not None:
            rem = max(0, min(100, int(round(100 - float(used)))))
            return f"残{rem}%"
    return None

def send_android_notification(title, content, notif_id="codex_task"):
    """
    Termux:API (termux-notification) を利用して Android ネイティブ通知を非同期送信する。
    環境変数 TERMUX_NOTIFICATION / TERMUX_NOTIFY が 0/false/off/no の場合は無効化される。
    """
    env_val = os.environ.get("TERMUX_NOTIFICATION", os.environ.get("TERMUX_NOTIFY", "")).strip().lower()
    if env_val in ("0", "false", "no", "off"):
        return

    def _worker():
        try:
            candidates = [
                shutil.which("termux-notification"),
                "/data/data/com.termux/files/usr/bin/termux-notification",
                "/usr/bin/termux-notification"
            ]
            termux_notif = next((c for c in candidates if c and os.path.isfile(c) and os.access(c, os.X_OK)), None)
            if not termux_notif:
                return

            clean = re.sub(r'<[^>]+>', '', content)
            clean = re.sub(r'```.*?```', '', clean, flags=re.DOTALL)
            clean = re.sub(r'[*_#`~>\[\]]', '', clean)
            lines = [l.strip() for l in clean.splitlines() if l.strip()]
            summary = lines[0] if lines else "処理が完了しました。"
            if len(summary) > 80:
                summary = summary[:77] + "..."

            t3_port = os.environ.get("T3_PORT", "3773")
            action_url = f"termux-open-url http://127.0.0.1:{t3_port}"

            cmd = [
                termux_notif,
                "-i", notif_id,
                "-t", title,
                "-c", summary,
                "--priority", "high",
                "--sound",
                "--action", action_url
            ]
            subprocess.run(cmd, timeout=5, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            log_debug(f"Sent Android notification: id={notif_id}, title={title}, summary={summary[:30]}")
        except Exception as e:
            log_debug(f"Failed to send Android notification: {e}")

    threading.Thread(target=_worker, daemon=True).start()

def save_quota_tag(tag):
    global cached_quota_tag, cached_quota_time
    if not tag:
        return
    cached_quota_tag = tag
    cached_quota_time = time.time()
    try:
        os.makedirs(os.path.dirname(CACHE_FILE), exist_ok=True)
        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            json.dump({"timestamp": cached_quota_time, "tag": tag}, f)
    except Exception:
        pass

def get_current_quota_tag():
    global cached_quota_tag, cached_quota_time
    now = time.time()
    # Cache in-memory for 60 seconds
    if cached_quota_tag and (now - cached_quota_time) < 60:
        return cached_quota_tag

    # Try cache file (valid for 90 seconds)
    if os.path.exists(CACHE_FILE):
        try:
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                c = json.load(f)
                if (now - c.get("timestamp", 0)) < 90:
                    tag = c.get("tag")
                    if tag:
                        cached_quota_tag = tag
                        cached_quota_time = c.get("timestamp", 0)
                        return cached_quota_tag
        except Exception:
            pass

    # If not in cache, query check_quota.get_codex_quota_summary()
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import check_quota
        summary = check_quota.get_codex_quota_summary(timeout=4)
        if summary:
            tag = extract_quota_from_rate_limits(summary)
            if tag:
                save_quota_tag(tag)
                return tag
    except Exception as e:
        log_debug(f"Failed to fetch quota from check_quota: {e}")

    return cached_quota_tag or ""

def main():
    real_bin = get_real_codex_bin()

    # If not app-server, transparently exec the real CLI
    if len(sys.argv) < 2 or sys.argv[1] != "app-server":
        os.execv(real_bin, [real_bin] + sys.argv[1:])

    log_debug(f"Starting codex app-server proxy to {real_bin} with args {sys.argv[1:]}")

    proc = subprocess.Popen(
        [real_bin] + sys.argv[1:],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
        text=True,
        bufsize=1
    )

    pending_model_list_ids = set()
    lock = threading.Lock()

    def stdin_thread():
        try:
            for line in sys.stdin:
                line_str = line.strip()
                if line_str:
                    try:
                        msg = json.loads(line_str)
                        method = msg.get("method")
                        req_id = msg.get("id")
                        if method == "model/list" and req_id is not None:
                            with lock:
                                pending_model_list_ids.add(req_id)
                    except Exception:
                        pass
                proc.stdin.write(line)
                proc.stdin.flush()
        except Exception as e:
            log_debug(f"stdin exception: {e}")
        finally:
            try:
                proc.stdin.close()
            except Exception:
                pass

    def stdout_thread():
        try:
            for line in proc.stdout:
                line_str = line.strip()
                if not line_str:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    continue

                try:
                    msg = json.loads(line_str)
                except Exception:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                    continue

                # Watch for turn completion to send Android notification
                method = msg.get("method")
                if method == "turn/completed":
                    try:
                        params = msg.get("params", {})
                        turn = params.get("turn", {}) if isinstance(params, dict) else {}
                        status = turn.get("status") if isinstance(turn, dict) else None
                        if status in ("completed", "done", None):
                            agent_text = ""
                            items = turn.get("items", []) if isinstance(turn, dict) else []
                            if isinstance(items, list):
                                for item in reversed(items):
                                    if isinstance(item, dict):
                                        content = item.get("content")
                                        if isinstance(content, list):
                                            for part in reversed(content):
                                                if isinstance(part, dict):
                                                    t = part.get("text") or part.get("output")
                                                    if t and isinstance(t, str):
                                                        agent_text = t
                                                        break
                                                elif isinstance(part, str):
                                                    agent_text = part
                                                    break
                                        elif isinstance(content, str):
                                            agent_text = content
                                        elif isinstance(item.get("output"), str):
                                            agent_text = item.get("output")
                                        if agent_text:
                                            break
                            send_android_notification(
                                title="🧠 Codex 完了",
                                content=agent_text or "タスクの処理が完了しました。",
                                notif_id="codex_task"
                            )
                    except Exception as e:
                        log_debug(f"Error handling turn/completed notification: {e}")

                # Watch for rate-limit updates to update cache
                if method == "account/rateLimits/updated":
                    tag = extract_quota_from_rate_limits(msg.get("params", {}))
                    if tag:
                        save_quota_tag(tag)

                msg_id = msg.get("id")
                result = msg.get("result")

                # Watch for account/rateLimits/read response
                if isinstance(result, dict) and "rateLimits" in result:
                    tag = extract_quota_from_rate_limits(result)
                    if tag:
                        save_quota_tag(tag)

                # Intercept model/list response
                is_model_list = False
                with lock:
                    if msg_id in pending_model_list_ids:
                        pending_model_list_ids.remove(msg_id)
                        is_model_list = True

                if is_model_list and isinstance(result, dict) and "data" in result:
                    data = result.get("data", [])
                    if isinstance(data, list):
                        tag = get_current_quota_tag()
                        if tag:
                            for item in data:
                                dn = item.get("displayName")
                                if dn:
                                    clean_dn = re.sub(r'\s*\[残\d+%\]', '', dn)
                                    item["displayName"] = f"{clean_dn} [{tag}]"
                            modified_line = json.dumps(msg, ensure_ascii=False) + "\n"
                            sys.stdout.write(modified_line)
                            sys.stdout.flush()
                            continue

                sys.stdout.write(line)
                sys.stdout.flush()

        except Exception as e:
            log_debug(f"stdout exception: {e}")
        finally:
            try:
                sys.stdout.flush()
            except Exception:
                pass

    t_in = threading.Thread(target=stdin_thread, daemon=True)
    t_out = threading.Thread(target=stdout_thread, daemon=True)
    t_in.start()
    t_out.start()

    ret = proc.wait()
    t_out.join(timeout=1.0)
    sys.exit(ret)

if __name__ == "__main__":
    main()
