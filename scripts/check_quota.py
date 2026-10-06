#!/usr/bin/env python3
"""
Antigravity Quota Checker
Fetches user quota and rate limits from Google Antigravity backend.
"""
import sys
import json
import urllib.request
import urllib.error
from datetime import datetime, timezone

TOKEN_FILE = "/root/.gemini/antigravity-cli/antigravity-oauth-token"
QUOTA_URL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"

def get_quota_summary():
    try:
        with open(TOKEN_FILE, "r", encoding="utf-8") as f:
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
    req = urllib.request.Request(QUOTA_URL, data=b"{}", headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"error": f"HTTP {e.code}: {e.reason}"}
    except Exception as e:
        return {"error": str(e)}

def make_bar(fraction, width=15):
    filled = int(round(fraction * width))
    filled = max(0, min(width, filled))
    return "█" * filled + "░" * (width - filled)

def parse_relative_time(iso_str):
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

def format_quota_markdown(data):
    if "error" in data:
        err = data["error"]
        return f"⚠️ **クォータ情報の取得に失敗しました**: {err}\n\nTermux で `agy` を起動して Google 認証が完了しているか確認してください。"

    groups = data.get("groups", [])
    if not groups:
        return "利用状況データが見つかりませんでした。"

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
            rel_time = parse_relative_time(b.get("resetTime", ""))
            reset_info = f" (🔄 全回復: 約 {rel_time})" if rel_time else ""
            
            if pct > 50:
                icon = "🟢"
            elif pct > 20:
                icon = "🟡"
            else:
                icon = "🔴"

            lines.append(f"- {icon} **{dname}**: `[{bar}]` **{pct:.1f}% 残り**{reset_info}")
        lines.append("")

    lines.append("---")
    lines.append("> 💡 **ヒント**: モデルグループごとに「5時間枠（短期集中用）」と「週間枠（全体契約用）」が共有されています。残り枠が少なくなった場合は別グループのモデル（Gemini ⇔ Claude）に切り替えることで作業を継続できます。")
    return "\n".join(lines)

def get_quota_map_short(data):
    """
    Returns a dictionary of group prefix to short remaining string.
    e.g. {'gemini': '5h:73% 週:22%', '3p': '5h:99% 週:99%'}
    """
    res = {}
    if "error" in data:
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
    q = get_quota_summary()
    if len(sys.argv) > 1 and sys.argv[1] == "--json":
        print(json.dumps(q, indent=2, ensure_ascii=False))
    elif len(sys.argv) > 1 and sys.argv[1] == "--short":
        print(json.dumps(get_quota_map_short(q), ensure_ascii=False))
    else:
        print(format_quota_markdown(q))
