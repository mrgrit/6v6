"""6v6 SIEM lite Alert Viewer.

Wazuh manager 의 /var/ossec/logs/alerts/alerts.json (NDJSON) 을 tail 방식으로 읽어서
브라우저에 보여준다. 풀 Wazuh dashboard 대신 학습/시연 용도.
"""
from __future__ import annotations

import json
import os
import socket
from collections import Counter
from datetime import datetime
from pathlib import Path

from flask import Flask, render_template_string

ALERTS_FILE = Path("/var/ossec/logs/alerts/alerts.json")
OSSEC_LOG = Path("/var/ossec/logs/ossec.log")
MAX_TAIL = 500

app = Flask(__name__)

PAGE = """<!doctype html><meta charset=utf-8>
<title>6v6 SIEM — Wazuh Alerts (lite)</title>
<style>
body { font-family: system-ui, sans-serif; background: #0f172a; color: #e2e8f0; margin: 0; padding: 24px; }
h1 { color: #60a5fa; margin: 0 0 18px; }
.kv { display: inline-block; background: #1e293b; border-radius: 6px; padding: 6px 12px; margin: 4px; }
.kv b { color: #fcd34d; }
.col { display: grid; grid-template-columns: 1fr 1fr; gap: 18px; margin-top: 18px; }
.box { background: #1e293b; border-radius: 8px; padding: 16px; }
.box h2 { margin: 0 0 10px; color: #93c5fd; font-size: 1em; }
table { width: 100%; border-collapse: collapse; font-size: 0.86em; }
th, td { border-bottom: 1px solid #334155; padding: 6px 8px; text-align: left; }
th { color: #cbd5e1; font-weight: 600; }
.lvl-1, .lvl-2, .lvl-3, .lvl-4 { color: #94a3b8; }
.lvl-5, .lvl-6, .lvl-7 { color: #fbbf24; }
.lvl-8, .lvl-9, .lvl-10 { color: #fb923c; }
.lvl-11, .lvl-12, .lvl-13, .lvl-14, .lvl-15 { color: #f87171; font-weight: 600; }
.muted { color: #64748b; font-size: 0.85em; }
.refresh { float: right; color: #94a3b8; }
pre { white-space: pre-wrap; word-break: break-all; font-size: 0.78em; color: #cbd5e1; max-height: 280px; overflow: auto; background: #0f172a; padding: 10px; border-radius: 6px; }
</style>
<h1>6v6 SIEM — Wazuh Alerts <span class=refresh>(자동 새로고침 10초)</span></h1>
<meta http-equiv=refresh content=10>

<div>
<span class=kv><b>HOST:</b> {{host}}</span>
<span class=kv><b>최근 alert:</b> {{count}}</span>
<span class=kv><b>최고 레벨:</b> {{max_level}}</span>
<span class=kv><b>가장 최근:</b> {{latest_time or '—'}}</span>
<span class=kv><b>Manager:</b> <a style="color:#60a5fa" href="/health">/health</a></span>
</div>

<div class=col>

<div class=box>
<h2>최근 알림 (최신 30개)</h2>
{% if alerts %}
<table>
<tr><th>Time</th><th>Lvl</th><th>Rule</th><th>Description</th><th>Src</th></tr>
{% for a in alerts %}
<tr>
  <td class=muted>{{a.time[-12:-3] if a.time else '-'}}</td>
  <td class="lvl-{{a.level}}">{{a.level}}</td>
  <td class=muted>{{a.rule_id}}</td>
  <td>{{a.description[:80]}}</td>
  <td class=muted>{{a.src or '-'}}</td>
</tr>
{% endfor %}
</table>
{% else %}
<p class=muted>아직 alert 가 없습니다. attacker 로 web 에 SQLi/XSS/nmap 등 시도 후 새로고침하세요.</p>
{% endif %}
</div>

<div class=box>
<h2>Top 10 Rule (최근 {{count}}건)</h2>
<table>
<tr><th>#</th><th>Rule ID</th><th>Description</th></tr>
{% for r in top_rules %}
<tr><td>{{r.cnt}}</td><td>{{r.id}}</td><td>{{r.desc[:60]}}</td></tr>
{% endfor %}
</table>
</div>

<div class=box>
<h2>Level 분포</h2>
<table>
<tr><th>Level</th><th>Count</th></tr>
{% for l, c in level_counts %}
<tr><td class="lvl-{{l}}">{{l}}</td><td>{{c}}</td></tr>
{% endfor %}
</table>
</div>

<div class=box>
<h2>Manager 로그 tail</h2>
<pre>{{ossec_tail}}</pre>
</div>

</div>

<p class=muted style="margin-top:24px">
6v6 SIEM lite — 풀 Wazuh dashboard 가 아닌 학습용 viewer. 실제 운영은 wazuh-dashboard 권장.
</p>
"""


def parse_alerts():
    if not ALERTS_FILE.exists():
        return []
    try:
        with ALERTS_FILE.open() as f:
            lines = f.readlines()[-MAX_TAIL:]
    except Exception:
        return []
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        out.append({
            "time": d.get("timestamp", ""),
            "level": int(d.get("rule", {}).get("level", 0)),
            "rule_id": d.get("rule", {}).get("id", "-"),
            "description": d.get("rule", {}).get("description", ""),
            "src": d.get("data", {}).get("srcip") or d.get("agent", {}).get("ip"),
        })
    return out


@app.route("/")
def index():
    alerts = parse_alerts()
    alerts_sorted = sorted(alerts, key=lambda a: a["time"], reverse=True)
    top = Counter((a["rule_id"], a["description"]) for a in alerts).most_common(10)
    levels = Counter(a["level"] for a in alerts).most_common()

    ossec_tail = ""
    if OSSEC_LOG.exists():
        try:
            with OSSEC_LOG.open() as f:
                lines = f.readlines()[-15:]
            ossec_tail = "".join(lines)
        except Exception:
            ossec_tail = "(read error)"

    return render_template_string(
        PAGE,
        host=socket.gethostname(),
        count=len(alerts),
        max_level=max((a["level"] for a in alerts), default=0),
        latest_time=alerts_sorted[0]["time"] if alerts_sorted else None,
        alerts=alerts_sorted[:30],
        top_rules=[{"cnt": c, "id": k[0], "desc": k[1]} for k, c in top],
        level_counts=levels,
        ossec_tail=ossec_tail,
    )


@app.route("/health")
def health():
    return {
        "status": "ok",
        "host": socket.gethostname(),
        "time": datetime.utcnow().isoformat() + "Z",
        "alerts_file_exists": ALERTS_FILE.exists(),
        "alerts_file_size": ALERTS_FILE.stat().st_size if ALERTS_FILE.exists() else 0,
    }


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5601")), debug=False)
