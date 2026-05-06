# 6v6 — CCC 인프라 단일 VM Docker 버전 (+ 랜딩 + 포털)

학생 PC 의 **VMware Bridge VM 1대 안에** docker 컨테이너로 CCC 의 4-노드 보안 인프라
(`bastion / secu / web / siem`) 를 그대로 올린 **교육용 경량 배포**. 300B 의 4-tier (AWS-style)
구성이 너무 복잡하다고 판단되어, 강의 자료의 IP 스킴 (`10.20.30.0/24`) 을 그대로 유지하면서
docker 한 번에 띄울 수 있게 만든 버전이다.

```
                       단일 bridge network 10.20.30.0/24
   ┌──────────┐    ┌────────┐    ┌────────┐    ┌────────┐
   │ attacker │───▶│  secu  │───▶│  web   │───▶│ siem   │
   │  10.202  │    │  10.1  │    │ 10.80  │    │ 10.100 │
   └──────────┘    └────────┘    └────────┘    └────────┘
                       (nftables   (Apache+    (Wazuh
                        +Suricata)  ModSec+    + cti)
                                    JuiceShop
                                    backend)

   ┌──────────┐                   ┌────────┐
   │ bastion  │  (점프 호스트)     │ portal │  (관리 대시보드)
   │ 10.201   │  + Bastion API    │ 10.50  │
   └──────────┘                   └────────┘
```

## VM 권장 사양

| 등급 | CPU | RAM | Disk | 비고 |
|------|-----|-----|------|------|
| 최소 | 2 vCPU | 4 GB | 20 GB | Wazuh 단일 컨테이너 모드 |
| 권장 | 4 vCPU | 8 GB | 40 GB | + JuiceShop + 풀 attacker 도구 |

## 빠른 시작

```bash
git clone https://github.com/mrgrit/6v6
cd 6v6
cp .env.example .env       # 필요시 외부 노출 포트만 수정
bash 6v6.sh up             # 첫 빌드 5~8분 (juiceshop/wazuh image pull 포함)
bash 6v6.sh smoke          # 헬스 체크
bash 6v6.sh status         # 외부 접속 정보
```

## 외부 노출 포트

| 포트 | 용도 | 접근 |
|------|------|------|
| 80 | HTTP | `http://<VM_IP>/` (web 의 landing + reverse proxy → JuiceShop) |
| 443 | HTTPS | `https://<VM_IP>/` (self-signed) |
| 2204 | bastion SSH | `ssh -p 2204 ccc@<VM_IP>` (점프 호스트) |
| 2202 | attacker SSH | `ssh -p 2202 ccc@<VM_IP>` (직접 attacker 진입) |
| 8000 | 관리 포털 | `http://<VM_IP>:8000/` (FastAPI + HTMX) |
| 5601 | SIEM 대시보드 | `http://<VM_IP>:5601/` (lite Wazuh 알림 뷰) |
| 9100 | Bastion API | `http://<VM_IP>:9100/health` |

## 컨테이너 구성 (총 7 개)

| 컨테이너 | IP | 역할 | 외부 포트 |
|----------|-----|------|----------|
| `6v6-bastion` | 10.20.30.201 | SSH 점프 + Bastion API + 컨테이너 alias | 2204, 9100 |
| `6v6-secu` | 10.20.30.1 | nftables + Suricata IDS | — |
| `6v6-web` | 10.20.30.80 | Apache + ModSecurity + 랜딩 페이지 + JuiceShop reverse proxy | 80, 443 |
| `6v6-juiceshop` | 10.20.30.81 | OWASP Juice Shop (web 만 reverse proxy 로 접근) | — |
| `6v6-siem` | 10.20.30.100 | Wazuh manager + cti-collector + simple alert viewer | 5601 |
| `6v6-attacker` | 10.20.30.202 | nmap + hydra + sqlmap + nikto + msfconsole 등 | 2202 |
| `6v6-portal` | 10.20.30.50 | 관리 포털 (FastAPI + HTMX) | 8000 |

## 학생 접속

### 브라우저
```
http://<VM_IP>/                  랜딩 페이지 (모든 서비스 링크 포함)
http://<VM_IP>/juice/             JuiceShop (Apache + ModSecurity 통과)
http://<VM_IP>:8000/              관리 포털 (Resources / Logs / WAF / IDS / Audit)
http://<VM_IP>:5601/              SIEM (Wazuh 알림 lite UI)
http://<VM_IP>:9100/health        Bastion API
```

### SSH (Bastion ProxyJump)
학생 PC `~/.ssh/config` 에 한 번 추가:
```ssh-config
Host 6v6-bastion
  HostName <VM_IP>
  Port 2204
  User ccc

Host 6v6-attacker
  HostName <VM_IP>
  Port 2202
  User ccc

Host 6v6-secu 6v6-web 6v6-siem
  ProxyJump 6v6-bastion
  User ccc
```

그 후 `ssh 6v6-attacker`, `ssh 6v6-secu`, `ssh 6v6-web`, `ssh 6v6-siem`. 비밀번호 = `ccc`.

## 명령어

```bash
bash 6v6.sh up        # 빌드 + 기동
bash 6v6.sh smoke     # 외부 노출 포트 + 컨테이너 헬스 체크
bash 6v6.sh status    # 컨테이너 상태 + 외부 접속 안내
bash 6v6.sh logs <svc>
bash 6v6.sh down
bash 6v6.sh destroy   # 컨테이너 + 볼륨 + 이미지 모두 삭제
```

## 300B 와의 차이점

| 항목 | 300B | 6v6 |
|------|------|-----|
| 토폴로지 | 4-tier (edge/dmz/private/mgmt) | 단일 bridge (10.20.30.0/24) |
| 컨테이너 수 | 18 | 7 |
| 외부 노출 포트 | 4 (80/443/53/2204) | 7 (80/443/2204/2202/8000/5601/9100) |
| WAF 분리 | 별도 컨테이너 (300b-waf) | web 컨테이너 안에 통합 |
| IDS 분리 | 별도 sidecar (300b-ids) | secu 컨테이너 안에 통합 |
| Wazuh | 3 컨테이너 (manager/indexer/dashboard) | 1 컨테이너 (manager 위주) |
| TLS | self-signed CA + 11 vhost | self-signed (web 자체) |
| 학습 난이도 | 고 | 저 |

## 운영 메모

- 이 환경은 **교육용** — production 보안 표준이 아님.
- `juiceshop` 은 docker hub `bkimminich/juice-shop` 사용 — 학생이 코드 수정 시 web 의
  apache 만 reload 하면 즉시 적용 (juiceshop 자체는 pristine).
- `bastion-data` / `siem-data` 볼륨에 학습 산출물 영속.
- attacker 의 metasploit omnibus 다운로드 (~800 MB) — 첫 빌드 시 시간 소요.

## 라이선스

MIT — 자유롭게 학습/수업에서 활용.
