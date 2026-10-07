#!/usr/bin/env python3
"""
Antigravity & Codex Quota Checker
Fetches user quota and rate limits from Google Antigravity backend
and OpenAI Codex CLI backend (if installed).
"""
import sys
import os
import json
import time
import shutil
import subprocess
import urllib.request
import urllib.error
from datetime import datetime, timezone

# Antigravity settings
AGY_TOKEN_FILE = "/root/.gemini/antigravity-cli/antigravity-oauth-token"
AGY_QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"

# Codex settings
CODEX_HOME = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
CODEX_AUTH_FILE = os.path.join(CODEX_HOME, "auth.json")

def get_antigravity_quota_summary():
    """Fetches quota summary from Google Antigravity backend."""
    try:
        with open(AGY_TOKEN_FILE, "r", encoding="utf-8") as f:
            token_data = json.load(f)
        access_token = token_data.get("token", {}).get("access_token")
        if not access_token:
            return {"error": "OAuth access token is empty or missing"}
    except Exception as e:
        return {"error": f"Failed to read oauth token: {e}"}

    headers = {
        "Authorization": f"Bearer {access_token}",
        "Content-Type": "application/json",
        "User-Agent": "Antigravity-CLI"
    }
    req = urllib.request.Request(AGY_QUOTA_URL, data=b"{}", headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"error": str(e)}

def get_codex_quota_summary(timeout=7):
    """
    Fetches rate limits from OpenAI Codex via `codex app-server` JSON-RPC.
    Returns None if Codex is not installed.
    """
    codex_bin = shutil.which("codex") or ("/usr/local/bin/codex" if os.path.exists("/usr/local/bin/codex") else None)
    if not codex_bin:
        return None

    if not os.path.exists(CODEX_AUTH_FILE):
        return {"not_logged_in": True}

    try:
        proc = subprocess.Popen(
            [codex_bin, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
    except Exception as e:
        return {"error": f"Failed to spawn codex app-server: {e}"}

    def send(msg):
        proc.stdin.write(json.dumps(msg) + "\n")
        proc.stdin.flush()

    try:
        # Step 1: Initialize
        send({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "clientInfo": {
                    "name": "t3-quota",
                    "version": "1.0.0"
                }
            }
        })

        start_time = time.time()
        limits_resp = None

        while time.time() - start_time < timeout:
            line = proc.stdout.readline()
            if not line:
                break
            try:
                msg = json.loads(line.strip())
            except Exception:
                continue

            msg_id = msg.get("id")
            if msg_id == 1:
                send({"jsonrpc": "2.0", "method": "initialized"})
                send({
                    "jsonrpc": "2.0",
                    "id": 2,
                    "method": "account/rateLimits/read",
                    "params": {}
                })
            elif msg_id == 2:
                limits_resp = msg.get("result")
                break

        proc.terminate()
        try:
            proc.wait(timeout=1.5)
        except subprocess.TimeoutExpired:
            proc.kill()

        if limits_resp is None:
            return {"error": "Timeout waiting for rate limits from codex app-server"}
        return limits_resp

    except Exception as e:
        try:
            proc.kill()
        except Exception:
            pass
        return {"error": str(e)}

def make_bar(fraction, width=15):
    filled = int(round(fraction * width))
    filled = max(0, min(width, filled))
    return "█" * filled + "░" * (width - filled)

def format_duration_mins(minutes):
    if not minutes:
        return ""
    if minutes < 60:
        return f"{minutes}分"
    hours = minutes // 60
    rem_min = minutes % 60
    if hours < 24:
        return f"{hours}時間" + (f"{rem_min}分" if rem_min else "")
    days = hours // 24
    rem_hours = hours % 24
    return f"{days}日" + (f"{rem_hours}時間" if rem_hours else "")

def parse_relative_time_iso(iso_str):
    if not iso_str:
        return ""
    try:
        dt = datetime.fromisoformat(iso_str.replace("Z", "+00:00"))
        now = datetime.now(timezone.utc)
        diff = dt - now
        total_sec = max(0, int(diff.total_seconds()))
        hours = total_sec // 3600
        mins = (total_sec % 3600) // 60
        if hours >= 24:
            days = hours // 24
            rem_hours = hours % 24
            return f"{days}日{rem_hours}時間後"
        elif hours > 0:
            return f"{hours}時間{mins}分後"
        else:
            return f"{mins}分後"
    except Exception:
        return iso_str

def parse_relative_time_epoch(ts):
    if not ts:
        return ""
    try:
        now = time.time()
        diff = ts - now
        total_sec = max(0, int(diff))
        hours = total_sec // 3600
        mins = (total_sec % 3600) // 60
        if hours >= 24:
            days = hours // 24
            rem_hours = hours % 24
            return f"{days}日{rem_hours}時間後"
        elif hours > 0:
            return f"{hours}時間{mins}分後"
        else:
            return f"{mins}分後"
    except Exception:
        return str(ts)

def format_antigravity_markdown(data):
    if "error" in data:
        err = data["error"]
        return f"### 📊 Google Antigravity 利用状況 (Quota & Limits)\n\n⚠️ **クォータ情報の取得に失敗しました**: {err}\n\nTermux で `agy` を起動して Google 認証が完了しているか確認してください。"

    groups = data.get("groups", [])
    if not groups:
        return "### 📊 Google Antigravity 利用状況 (Quota & Limits)\n\n利用状況データが見つかりませんでした。"

    lines = ["### 📊 Google Antigravity 利用状況 (Quota & Limits)", ""]
    for g in groups:
        name = g.get("displayName", "Group")
        desc = g.get("description", "")
        lines.append(f"#### 🔹 **{name}**")
        if desc:
            lines.append(f"*{desc}*")
        lines.append("")
        for b in g.get("buckets", []):
            dname = b.get("displayName", "Limit")
            frac = b.get("remainingFraction", 1.0)
            pct = frac * 100.0
            bar = make_bar(frac)
            rel_time = parse_relative_time_iso(b.get("resetTime", ""))
            reset_info = f" (🔄 全回復: 約 {rel_time})" if rel_time else ""
            
            if pct > 50:
                icon = "🟢"
            elif pct > 20:
                icon = "🟡"
            else:
                icon = "🔴"

            lines.append(f"- {icon} **{dname}**: `[{bar}]` **{pct:.1f}% 残り**{reset_info}")
        lines.append("")

    return "\n".join(lines).strip()

def format_codex_markdown(data):
    if not data:
        return ""

    if data.get("not_logged_in"):
        return (
            "### 📊 OpenAI Codex 利用状況 (Quota & Limits)\n\n"
            "⚠️ **Codex アカウントが未認証です**\n\n"
            "`codex login` でログインすると利用状況が表示されます。"
        )

    if "error" in data:
        err = data["error"]
        return (
            "### 📊 OpenAI Codex 利用状況 (Quota & Limits)\n\n"
            f"⚠️ **Codex 利用状況の取得に失敗しました**: {err}\n\n"
            "`codex login` の認証状態を確認してください。"
        )

    plan_type = str(data.get("rateLimits", {}).get("planType", "unknown")).upper()
    allowed = data.get("ordinaryUsageAllowed", True)
    status_icon = "🟢 利用可能" if allowed else "🔴 利用制限中"

    lines = [
        "### 📊 OpenAI Codex 利用状況 (Quota & Limits)",
        "",
        f"#### 🔹 **ChatGPT アカウント** (プラン: `{plan_type}` / {status_icon})"
    ]

    credits = data.get("rateLimits", {}).get("credits", {})
    if credits.get("hasCredits") and credits.get("balance"):
        lines.append(f"- 💳 **クレジット残高**: `{credits.get('balance')}`")
    elif credits.get("unlimited"):
        lines.append("- 💳 **クレジット**: `無制限`")

    rate_limits = data.get("rateLimits", {})
    windows = []
    if rate_limits.get("primary"):
        windows.append(("プライマリ枠", rate_limits["primary"]))
    if rate_limits.get("secondary"):
        windows.append(("セカンダリ枠", rate_limits["secondary"]))

    by_id = data.get("rateLimitsByLimitId", {})
    for lid, linfo in by_id.items():
        if lid != "codex" and isinstance(linfo, dict):
            name = linfo.get("limitName") or lid
            if linfo.get("primary"):
                windows.append((f"{name} (プライマリ)", linfo["primary"]))
            if linfo.get("secondary"):
                windows.append((f"{name} (セカンダリ)", linfo["secondary"]))

    for title, win in windows:
        used_pct = win.get("usedPercent", 0)
        rem_pct = max(0.0, 100.0 - float(used_pct))
        frac = rem_pct / 100.0
        bar = make_bar(frac)
        dur = win.get("windowDurationMins")
        dur_str = f" ({format_duration_mins(dur)}枠)" if dur else ""
        reset_ts = win.get("resetsAt")
        rel_reset = parse_relative_time_epoch(reset_ts) if reset_ts else ""
        reset_info = f" (🔄 リセット: 約 {rel_reset})" if rel_reset else ""

        if rem_pct > 50:
            icon = "🟢"
        elif rem_pct > 20:
            icon = "🟡"
        else:
            icon = "🔴"

        lines.append(f"- {icon} **{title}**{dur_str}: `[{bar}]` **{rem_pct:.1f}% 残り**{reset_info}")

    return "\n".join(lines).strip()

def format_quota_markdown(agy_data, codex_data=None):
    sections = []
    agy_text = format_antigravity_markdown(agy_data)
    if agy_text:
        sections.append(agy_text)

    if codex_data is not None:
        codex_text = format_codex_markdown(codex_data)
        if codex_text:
            sections.append(codex_text)

    hint = (
        "---\n"
        "> 💡 **ヒント**: モデルグループごとに短期枠や週間・月間枠が設けられています。"
        "残り枠が少なくなった場合は、T3 Code 上で別グループ（Gemini ⇔ Claude ⇔ Codex）に切り替えることで作業を継続できます。"
    )
    sections.append(hint)
    return "\n\n---\n\n".join(sections[:len(sections)-1]) + "\n\n" + hint

def get_quota_map_short(data):
    """
    Returns a dictionary of group prefix to short remaining string.
    e.g. {'gemini': '5h:73% 週:22%', '3p': '5h:99% 週:99%'}
    """
    res = {}
    if not data or "error" in data:
        return res
    for g in data.get("groups", []):
        dname = g.get("displayName", "").lower()
        key = "gemini" if "gemini" in dname else ("claude" if "claude" in dname else "other")
        b_5h = None
        b_week = None
        for b in g.get("buckets", []):
            w = b.get("window", "")
            pct = int(round(b.get("remainingFraction", 1.0) * 100))
            if w == "5h":
                b_5h = pct
            elif w == "weekly":
                b_week = pct
        parts = []
        if b_5h is not None:
            parts.append(f"5h:{b_5h}%")
        if b_week is not None:
            parts.append(f"週:{b_week}%")
        if parts:
            res[key] = " ".join(parts)
    return res

if __name__ == "__main__":
    agy_data = get_antigravity_quota_summary()
    codex_data = get_codex_quota_summary()

    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        out = {
            "antigravity": agy_data,
            "codex": codex_data
        }
        if isinstance(agy_data, dict):
            for k, v in agy_data.items():
                if k not in out:
                    out[k] = v
        print(json.dumps(out, indent=2, ensure_ascii=False))
    elif len(sys.argv) > 1 and sys.argv[1] == "--short":
        print(json.dumps(get_quota_map_short(agy_data), ensure_ascii=False))
    else:
        print(format_quota_markdown(agy_data, codex_data))
