"""6v6 Bastion API — 학습용 경량 placeholder.

CCC 본 프로젝트의 Bastion (apps/bastion) 은 풀 LLM ReAct 에이전트지만, 6v6 은 학습/배포
경량화를 위해 health + skills + targets 같은 정보 endpoint 만 제공한다.
LLM 통합은 LLM_BASE_URL 환경변수가 설정되면 옵션으로 동작.
"""
from __future__ import annotations

import os
import socket
import subprocess
from datetime import datetime, timezone

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

API_KEY = os.getenv("API_KEY", "ccc-api-key-2026")

app = FastAPI(title="6v6 Bastion API", version="0.1.0")


def _check_api_key(x_api_key: str | None) -> None:
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid X-API-Key")


@app.get("/health")
def health() -> dict:
    return {
        "status": "ok",
        "hostname": socket.gethostname(),
        "time": datetime.now(timezone.utc).isoformat(),
        "service": "6v6-bastion",
        "llm_configured": bool(os.getenv("LLM_BASE_URL")),
    }


@app.get("/targets")
def targets(x_api_key: str | None = Header(default=None)) -> dict:
    """6v6 환경의 컨테이너 alias 목록."""
    _check_api_key(x_api_key)
    return {
        "targets": [
            {"name": "secu",     "ip": "10.20.30.1",   "role": "nftables + Suricata"},
            {"name": "web",      "ip": "10.20.30.80",  "role": "Apache + ModSec + JuiceShop reverse proxy"},
            {"name": "siem",     "ip": "10.20.30.100", "role": "Wazuh manager + alert viewer"},
            {"name": "attacker", "ip": "10.20.30.202", "role": "pentest 도구"},
            {"name": "portal",   "ip": "10.20.30.50",  "role": "관리 대시보드"},
        ]
    }


class CommandRequest(BaseModel):
    target: str
    command: str


@app.post("/exec")
def exec_command(req: CommandRequest, x_api_key: str | None = Header(default=None)) -> dict:
    """학습용 — bastion 자체에서 명령 실행 (target 무관, 단순 echo + 안전 화이트리스트)."""
    _check_api_key(x_api_key)
    safe_prefixes = ("ping ", "uptime", "hostname", "date", "whoami", "ip a", "ip route",
                     "nslookup ", "dig ", "curl http")
    if not any(req.command.startswith(p) for p in safe_prefixes):
        raise HTTPException(status_code=403, detail=f"command must start with one of: {safe_prefixes}")
    try:
        out = subprocess.run(
            req.command, shell=True, check=False, capture_output=True, text=True, timeout=10
        )
        return {"target": req.target, "command": req.command,
                "rc": out.returncode, "stdout": out.stdout, "stderr": out.stderr}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="command timeout")


@app.get("/skills")
def skills(x_api_key: str | None = Header(default=None)) -> dict:
    """정적 skill 카탈로그 (placeholder — full bastion 에서 동적 catalog)."""
    _check_api_key(x_api_key)
    return {
        "skills": [
            {"id": "nft.list_ruleset",  "target": "secu", "desc": "nftables ruleset 조회"},
            {"id": "suricata.tail_eve", "target": "secu", "desc": "최근 IDS alert 출력"},
            {"id": "apache.error_log",  "target": "web",  "desc": "ModSecurity error.log tail"},
            {"id": "wazuh.alerts",      "target": "siem", "desc": "Wazuh alerts.json tail"},
            {"id": "attacker.nmap",     "target": "attacker", "desc": "nmap 포트 스캔"},
        ]
    }
