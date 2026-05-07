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

## 빠른 시작 (리눅스만 설치된 새 VM 기준)

```bash
git clone https://github.com/mrgrit/6v6
cd 6v6

# 1) Docker + 도구 자동 설치 (Ubuntu 22.04 / Debian 12)
bash 6v6.sh install         # docker, docker compose plugin, git, jq, sshpass, dnsutils
                             # 'docker' 그룹에 사용자 추가 후 종료

# 2) 새 터미널 열거나
newgrp docker

# 3) 환경 설정
cp .env.example .env        # LLM_BASE_URL 만 옵션 (aicompanion 은 mock 으로 동작 가능)

# 4) 기동
bash 6v6.sh up              # 첫 빌드 8~12분 (Wazuh manager + 7 vuln 사이트 포함)
bash 6v6.sh smoke           # 헬스 + Wazuh agent 등록 검증
bash 6v6.sh status          # 외부 접속 안내 (VM_IP / 포트 / SSH 명령)
```

`6v6.sh install` 이 자동 설치하는 항목:
- Docker Engine + CLI + containerd
- docker-buildx-plugin + docker-compose-plugin
- git, curl, jq, sshpass, net-tools, iproute2, dnsutils, gnupg, lsb-release
- `docker` group 에 현재 사용자 추가 (재로그인 또는 `newgrp docker` 필요)

> 자동 설치는 **Debian/Ubuntu 계열만 지원**. RHEL/CentOS/Arch 등은 `docker-ce` +
> `docker-compose-plugin` 을 각 배포판 패키지 매니저로 직접 설치 후 `bash 6v6.sh up` 사용.

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

## 학생 PC 접속 — 시스템별 가이드

전제: VM IP 는 `bash 6v6.sh status` 로 확인. 아래 `<VM_IP>` 자리에 실제 IP 대체.

### 1. 브라우저 (학생 PC)

먼저 학생 PC 의 hosts 파일에 1줄 추가:
- 윈도우: `C:\Windows\System32\drivers\etc\hosts` (관리자 권한 메모장)
- 리눅스/맥: `/etc/hosts` (sudo)

```
<VM_IP>  6v6.lab juice.6v6.lab dvwa.6v6.lab neobank.6v6.lab govportal.6v6.lab mediforum.6v6.lab admin.6v6.lab ai.6v6.lab portal.6v6.lab siem.6v6.lab bastion.6v6.lab
```

그 후 브라우저 — **모두 동일 패턴 `<service>.6v6.lab` 으로 접근** (web 의 Apache vhost 가 reverse proxy):

| URL | 대상 | 비고 |
|-----|------|------|
| `http://6v6.lab/` 또는 `http://<VM_IP>/` | **랜딩 페이지** | 모든 사이트 링크 |
| `http://juice.6v6.lab/` | OWASP Juice Shop | 가입 자유 / `admin@juice-sh.op` 비밀번호 추측 |
| `http://dvwa.6v6.lab/` | DVWA | `admin / password` |
| `http://neobank.6v6.lab/` | NeoBank (가상 은행) | 30 취약점 |
| `http://govportal.6v6.lab/` | GovPortal (가상 정부) | 25 취약점 |
| `http://mediforum.6v6.lab/` | MediForum (가상 의료) | 게시판 + 업로드 |
| `http://admin.6v6.lab/` | AdminConsole | RCE/XXE/SSRF/pickle |
| `http://ai.6v6.lab/` | AICompanion | OWASP LLM Top 10 (mock LLM) |
| `http://portal.6v6.lab/` | **관리 포털** | 컨테이너 / 네트워크 / 로그 / WAF / IDS / Audit / Agent |
| `http://siem.6v6.lab/` | **SIEM (Wazuh lite)** | 알림 + Top rule + level 분포 |
| `http://bastion.6v6.lab/health` | Bastion API | 헬스 체크 |

> **직접 포트 접근도 살아있음** (관리/디버그용): `http://<VM_IP>:8000/` (portal),
> `http://<VM_IP>:5601/` (siem), `http://<VM_IP>:9100/health` (bastion).
> 이 경로는 ModSecurity 검사를 거치지 않음 — 학습 비교용.

### 2. SSH (Bastion ProxyJump 모델)

학생 PC `~/.ssh/config` 에 1회 등록:

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

| 명령 | 대상 컨테이너 | 진입 경로 |
|------|--------------|----------|
| `ssh 6v6-bastion` | bastion (점프 호스트) | 직접 (port 2204) |
| `ssh 6v6-attacker` | attacker (pentest 도구) | 직접 (port 2202, 빠른 공격 진입) |
| `ssh 6v6-secu` | secu (nftables + Suricata) | bastion 경유 자동 |
| `ssh 6v6-web` | web (Apache + ModSec) | bastion 경유 자동 |
| `ssh 6v6-siem` | siem (Wazuh manager) | bastion 경유 자동 |
| `ssh 6v6-portal` | portal (관리 대시보드) | bastion 경유 자동 |

**bastion 안에 들어가서**는 alias 자동 등록되어 다음도 가능:
```bash
ssh secu       # 10.20.30.1
ssh web        # 10.20.30.80
ssh siem       # 10.20.30.100
ssh attacker   # 10.20.30.202
```

### 3. 컨테이너 직접 (VM 호스트에서, 디버그/관리)

```bash
docker exec -it 6v6-bastion bash       # bastion API 디버그
docker exec -it 6v6-secu bash          # nftables / Suricata 점검
docker exec -it 6v6-web bash           # Apache / ModSec / Wazuh agent
docker exec -it 6v6-siem bash          # Wazuh manager
docker exec -it 6v6-attacker bash      # pentest 도구
docker exec -it 6v6-portal bash        # FastAPI portal
docker exec -it 6v6-juiceshop sh       # JuiceShop (Node.js, Alpine)
docker exec -it 6v6-dvwa bash          # DVWA (PHP + MySQL)
docker exec -it 6v6-neobank bash       # NeoBank Flask
# (govportal / mediforum / adminconsole / aicompanion 동일 패턴)
```

### 4. 핵심 운영 명령

| 명령 | 의미 |
|------|------|
| `bash 6v6.sh status` | 외부 접속 정보 + 컨테이너 상태 |
| `bash 6v6.sh smoke` | 외부 노출 포트 + Wazuh agent 등록 + SSH 헬스 |
| `bash 6v6.sh logs <svc>` | 컨테이너 로그 follow |
| `docker exec 6v6-siem /var/ossec/bin/wazuh-control status` | Wazuh manager 8 daemon 상태 |
| `docker exec 6v6-siem /var/ossec/bin/agent_control -l` | 등록된 agent (secu/web 보여야) |
| `docker exec 6v6-siem tail -20 /var/ossec/logs/alerts/alerts.json` | 최근 alert |
| `docker exec 6v6-secu sudo nft list ruleset` | secu nftables 룰 |
| `docker exec 6v6-secu tail /var/log/suricata/eve.json` | Suricata 알림 |
| `docker exec 6v6-web tail /var/log/apache2/modsec_audit.log` | ModSecurity 차단 로그 |

### 5. 빠른 e2e 테스트 — attacker 에서 SQLi 발사 → SIEM 알림 확인

```bash
# 학생 PC 에서 attacker 진입
ssh 6v6-attacker

# 안에서:
nmap -sT -p 22,80 web                              # 포트 스캔
curl -A 'sqlmap/1.7' http://web/                    # WAF 차단 확인 (HTTP 403)
curl "http://web/?q=' UNION SELECT 1,2,3--"         # SQLi (HTTP 403)
nikto -h http://web/                                # 종합 스캐너

# 발사 후 SIEM 의 alert 확인:
exit
ssh 6v6-siem
sudo tail -20 /var/ossec/logs/alerts/alerts.json | jq '.rule.description, .agent.name'
```

또는 portal 에서 시각적 확인:
- `http://<VM_IP>:8000/waf` — ModSec audit 이벤트
- `http://<VM_IP>:8000/ids` — Suricata alert
- `http://<VM_IP>:5601/` — Wazuh 통합 알림 (agent + syslog)

### 6. 비밀번호 / 인증 정보 정리

| 시스템 | 계정 |
|--------|------|
| 모든 컨테이너 SSH | `ccc / ccc` (`.env` 의 `SSH_USER` / `SSH_PASS`) |
| Bastion API | header `X-API-Key: ccc-api-key-2026` |
| Wazuh manager API (5601 lite UI 는 인증 없음) | `admin / SecretPassword` (실제 운영시 변경) |
| DVWA | `admin / password` |
| JuiceShop | 가입 자유, `admin@juice-sh.op` 의 비밀번호 추측 학습 |
| NeoBank / GovPortal / MediForum / AdminConsole | seed 폴더의 vulnerabilities.md 확인 |

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
