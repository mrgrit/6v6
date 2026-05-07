"""6v6 cti-collector — 학습용 간이 IOC 수집기.

공개 IOC 피드 (예시 — 학교 환경에서는 실제 호출 대신 placeholder JSON 사용) 를 주기적으로
수집하여 /var/lib/siem/iocs.json 에 저장. wazuh-manager 의 lists 디렉토리로 export 하면
local_rules.xml 에서 매칭 가능.
"""
from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from pathlib import Path

OUT_FILE = Path("/var/lib/siem/iocs.json")
OUT_FILE.parent.mkdir(parents=True, exist_ok=True)

# 학교 환경의 외부망 정책에 따라 실제 fetch 대신 정적 샘플 IOC 사용 (학습 목적).
SAMPLE_IOCS = {
    "abuse_ip": [
        {"ip": "185.220.101.4",  "category": "tor-exit",   "first_seen": "2025-12-01"},
        {"ip": "45.227.255.4",   "category": "scanner",    "first_seen": "2026-01-12"},
        {"ip": "192.42.116.16",  "category": "tor-exit",   "first_seen": "2025-11-08"},
        {"ip": "62.102.148.69",  "category": "malware-c2", "first_seen": "2026-02-22"},
    ],
    "malware_hash": [
        {"sha256": "9d4b8e2a8f...", "family": "Emotet"},
        {"sha256": "b7c5e9f1a4...", "family": "Cobalt Strike"},
    ],
    "domains": [
        {"domain": "evil-c2.example",       "category": "malware-c2"},
        {"domain": "phish-bank.example",    "category": "phishing"},
    ],
}


def write_iocs() -> dict:
    payload = {
        "collected_at": datetime.now(timezone.utc).isoformat(),
        "source": "6v6-static-sample (educational)",
        "iocs": SAMPLE_IOCS,
        "counts": {
            "abuse_ip": len(SAMPLE_IOCS["abuse_ip"]),
            "malware_hash": len(SAMPLE_IOCS["malware_hash"]),
            "domains": len(SAMPLE_IOCS["domains"]),
        },
    }
    with OUT_FILE.open("w") as f:
        json.dump(payload, f, indent=2)
    return payload


def main() -> None:
    print(f"[cti] starting — writing to {OUT_FILE}")
    while True:
        p = write_iocs()
        print(f"[cti] {p['collected_at']} updated — {p['counts']}")
        time.sleep(300)


if __name__ == "__main__":
    main()
