# 6v6 — CCC 인프라 단일 VM Docker 버전 (+ 7 취약 웹 + 통합 SIEM)

학생 PC 의 **VMware Bridge VM 1대 안에** docker 컨테이너로 CCC 의 4-노드 보안 인프라
(`bastion / secu / web / siem`) 를 그대로 올리고 **취약 웹 7개 + 관리 포털** 을 추가한
교육용 경량 배포. 강의 자료의 IP 스킴 (`10.20.30.0/24`) 그대로 사용.

```
                       단일 bridge 10.20.30.0/24
   ┌──────────┐    ┌────────┐    ┌────────┐    ┌────────┐
   │ attacker │───▶│  secu  │───▶│  web   │───▶│ siem   │
   │  10.202  │    │  10.1  │    │ 10.80  │    │ 10.100 │
   └──────────┘    └────────┘    └────────┘    └────────┘
                       │            │
                       │            ├─ juice (10.81)   ┐
                       │            ├─ dvwa  (10.82)   │
                       │            ├─ neobank (10.83) │
                       │            ├─ govportal(10.84)│ 외부 노출 X
                       │            ├─ mediforum(10.85)│ web 만 reverse proxy
                       │            ├─ admin (10.86)   │
                       │            └─ ai (10.87)      ┘
                       │
                       └─ Suricata sniff + Wazuh agent
```

## 통합 로그 (Wazuh — agent + syslog 두 패러다임)

| Source | 방식 | 로그 | 경로 |
|--------|------|------|------|
| **secu** (Suricata) | Wazuh **agent** | eve.json + syslog | siem:1514/tcp |
| **web** (Apache+ModSec) | Wazuh **agent** | access/error/modsec_audit | siem:1514/tcp |
| **bastion** (sshd) | **rsyslog** forward | auth.log + system | siem:514/udp |
| **attacker** (shell) | **rsyslog** forward | shell + system | siem:514/udp |

학습 포인트: Suricata 와 ModSecurity 는 **agent 패러다임** (자체 binary 가 디코딩까지),
bastion + attacker 는 **syslog 패러다임** (rsyslog 가 raw forward, manager 가 디코딩).

## VM 권장 사양

| 등급 | CPU | RAM | Disk | 비고 |
|------|-----|-----|------|------|
| 최소 | 4 vCPU | 6 GB | 30 GB | 취약 웹 7 + Wazuh manager |
| 권장 | 4 vCPU | 8 GB | 40 GB | + attacker 풀 도구 |

## 빠른 시작

```bash
git clone https://github.com/mrgrit/6v6
cd 6v6
cp .env.example .env       # LLM_BASE_URL 만 옵션 (aicompanion mock 으로 동작 가능)
bash 6v6.sh up             # 첫 빌드 8~12분 (이미지 다수 + Wazuh)
bash 6v6.sh smoke          # 헬스 + Wazuh agent 등록 검증
bash 6v6.sh status         # 외부 접속 안내
```

## 외부 노출 포트

| 포트 | 용도 |
|------|------|
| 80 | HTTP — 7 vhost (랜딩 + 7 취약 웹) |
| 443 | HTTPS (self-signed) |
| 2204 | bastion SSH (점프 호스트) |
| 2202 | attacker SSH (직접 진입) |
| 8000 | 관리 포털 |
| 5601 | SIEM lite UI (Wazuh 알림 viewer) |
| 9100 | Bastion API |

## 컨테이너 구성 (총 13개)

| 컨테이너 | IP | 역할 |
|----------|-----|------|
| 6v6-bastion | 10.20.30.201 | SSH 점프 + Bastion API + rsyslog forward |
| 6v6-secu | 10.20.30.1 | nftables + Suricata + **Wazuh agent** |
| 6v6-web | 10.20.30.80 | Apache + ModSecurity + 7 vhost + **Wazuh agent** |
| 6v6-juiceshop | 10.20.30.81 | OWASP Juice Shop (웹 → web 만) |
| 6v6-dvwa | 10.20.30.82 | DVWA |
| 6v6-neobank | 10.20.30.83 | NeoBank (Flask, 30 취약점) |
| 6v6-govportal | 10.20.30.84 | GovPortal (Flask, 25 취약점) |
| 6v6-mediforum | 10.20.30.85 | MediForum (Flask) |
| 6v6-adminconsole | 10.20.30.86 | AdminConsole (Flask, RCE/XXE) |
| 6v6-aicompanion | 10.20.30.87 | AICompanion (LLM 취약점, mock 가능) |
| 6v6-siem | 10.20.30.100 | **Wazuh manager** (agent + syslog 입력) + alert viewer |
| 6v6-attacker | 10.20.30.202 | nmap, hydra, sqlmap, nikto + rsyslog forward |
| 6v6-portal | 10.20.30.50 | 관리 대시보드 (FastAPI + HTMX) |

## 학생 PC 접속

### 브라우저 — `/etc/hosts` 에 7개 도메인 추가
```
<VM_IP> 6v6.lab juice.6v6.lab dvwa.6v6.lab neobank.6v6.lab govportal.6v6.lab mediforum.6v6.lab admin.6v6.lab ai.6v6.lab
```

그 후:
- `http://<VM_IP>/` — 랜딩 (모든 사이트 링크)
- `http://juice.6v6.lab/`, `http://dvwa.6v6.lab/`, `http://neobank.6v6.lab/` … (모두 ModSec 통과)
- `http://<VM_IP>:8000/` — 관리 포털
- `http://<VM_IP>:5601/` — Wazuh 알림 viewer

### SSH (bastion ProxyJump)
```ssh-config
Host 6v6-bastion
  HostName <VM_IP>
  Port 2204
  User ccc

Host 6v6-attacker
  HostName <VM_IP>
  Port 2202
  User ccc

Host 6v6-secu 6v6-web 6v6-siem 6v6-portal
  ProxyJump 6v6-bastion
  User ccc
```

비밀번호: `ccc`. Bastion API key: `ccc-api-key-2026`.

## Wazuh 동작 검증

```bash
# 1) manager 의 8 daemon 확인
docker exec 6v6-siem /var/ossec/bin/wazuh-control status

# 2) 등록된 agent 목록 (secu, web 보여야)
docker exec 6v6-siem /var/ossec/bin/agent_control -l

# 3) 최근 alert (Suricata + ModSec 통합)
docker exec 6v6-siem tail -20 /var/ossec/logs/alerts/alerts.json | jq

# 4) 학생이 attacker 에서 SQLi 발사 → 즉시 alert
docker exec 6v6-attacker bash -c "curl -s -A 'sqlmap/1.7' \
    \"http://web/?q=' UNION SELECT 1,2,3--\""
sleep 3
docker exec 6v6-siem grep -i sqli /var/ossec/logs/alerts/alerts.json | tail
```

## 명령어

```bash
bash 6v6.sh up        # 빌드 + 기동
bash 6v6.sh smoke     # 외부 노출 포트 + Wazuh agent 등록 + 컨테이너 헬스
bash 6v6.sh status    # 컨테이너 상태 + 접속 안내
bash 6v6.sh logs <svc>
bash 6v6.sh down
bash 6v6.sh destroy   # 컨테이너 + 볼륨 + 이미지 모두 삭제
```

## 300B 와의 차이점

| 항목 | 300B | 6v6 |
|------|------|-----|
| 토폴로지 | 4-tier (edge/dmz/private/mgmt) | 단일 bridge |
| 컨테이너 수 | 18 | 13 |
| 외부 노출 포트 | 4 (80/443/53/2204) | 7 |
| WAF / IDS 분리 | 별도 컨테이너 | secu / web 통합 |
| Wazuh | 3 컨테이너 (manager+indexer+dashboard) | 1 컨테이너 (manager + lite viewer) |
| 취약 웹 | 7 (juice/dvwa/neobank/govportal/mediforum/admin/ai) | 7 (동일) |
| Wazuh agent | 미포함 (300B 는 raw 로그 마운트) | secu+web 에 설치 |
| syslog forward | 미포함 | bastion+attacker → siem |

## 라이선스

MIT — 자유롭게 학습/수업에서 활용.
