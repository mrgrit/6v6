# Windows 엔드포인트 — 6v6 의 사용자 PC (user 구역 10.20.33.60)

6v6 인프라에 **Windows 11 (tiny11) 사용자 PC** 1대를 별도 **user 구역** (10.20.33.0/24) 의
10.20.33.60 에 추가한다. **dockurr/windows** 컨테이너로 KVM 위에서 동작하며, 첫 부팅 시
`win-oem/install.bat` 가 자동 실행되어 **Sysmon + Wazuh agent + OpenSSH** 가 모두 설치·구성되고,
**정적 라우팅** 으로 다른 4 zone(ext/pipe/dmz/int) 은 모두 ips(10.20.33.1) 경유로 도달하게 된다
(사용자가 마우스로 만질 게 거의 없음).

## 목적

- secuops / soc / attack / secuops-easy 4 과목의 **endpoint 측 가시화** (EDR 학습) 무대.
- victim 직원 PC (피싱·다운로드·우발 행위 시뮬) + analyst 보안담당 PC 두 페르소나.
- 보안 모범사례에 맞춘 zone 분리 — 외부 노출 서버(dmz)와 사용자 PC(user)는 다른 영역.
- Wazuh manager (dmz 10.20.32.100) 에 `6v6-win` agent 로 자동 enroll → user→ips→dmz 경유로
  Sysmon EID 1/3/22/11 + Security 4624/4625 가 같은 SIEM dashboard 로 흐른다.

## 요구 사항

| 항목 | 기준 |
|------|------|
| 호스트 | Linux (KVM 가능, `/dev/kvm` 접근권한) |
| RAM | 6v6 본 스택 + Windows 4G 여유 — 최소 16G, 권장 24G 이상 |
| 디스크 | 추가 50G+ (Windows 디스크 이미지 + ISO 다운로드) |
| 첫 부팅 시간 | Windows 11 ISO 다운로드 + 자동설치 — **20-60분** |

## 배포 — 두 가지 방법

### 방법 A — 본 스택 가동 시 같이 (추천)

```bash
# 한 줄로 13 + Windows 까지 — up 시작 전 /dev/kvm·권한·RAM 사전검사
bash 6v6.sh up --with-windows
```

### 방법 B — 본 스택 가동 후 따로 (학습 중간 추가)

```bash
# ① 본체 6v6 스택이 먼저 가동되어 있어야 함 (6v6-dmz 네트워크 생성)
bash 6v6.sh up

# ② Windows 컨테이너 기동 — KVM 사전검사 + ISO 다운로드/무인설치/OEM 자동
bash 6v6.sh windows up

# ③ 첫 부팅 진행 모니터링 (웹뷰어로 OOBE 진행 확인)
#    브라우저: http://<호스트IP>:8006
#    OOBE 끝나면 자동으로 install.bat 가 실행되어 Sysmon/Wazuh/OpenSSH 설치
#    또는: bash 6v6.sh windows status  /  bash 6v6.sh windows logs

# ④ 후속 관리
bash 6v6.sh windows down       # Windows 만 중단 (본 스택 유지)
bash 6v6.sh windows destroy    # compose down -v (win-storage/ 는 별도 삭제)
```

> 직접 호출도 가능 (fallback): `docker compose -f docker-compose.windows.yml up -d`.
> `bash 6v6.sh windows up` 는 그 위에 KVM 사전검사 + 진행 안내를 얹은 래퍼.

## 검증 (2026-05-31 실측 — user zone)

```bash
# 1) SIEM 에서 6v6-win agent 가 Active 인지
docker exec 6v6-siem /var/ossec/bin/agent_control -l | grep 6v6-win
# → ID: 005, Name: 6v6-win, IP: any, Active

# 2) Sysmon 채널이 매니저로 흘러오는지 (Wazuh archives)
docker exec 6v6-siem grep -c "6v6-win" /var/ossec/logs/archives/archives.json | head -1

# 3) SSH 로 Windows 접속 (관리/실습용)
sshpass -p ccc ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ccc@10.20.33.60 'Get-Service Sysmon64 | Select-Object Status'
# → Running 출력
```

SIEM 도달 채널: `Microsoft-Windows-Sysmon/Operational`, `Security`, `System`, `Application`, `SCA`.

## enroll 패킷 흐름 — user → dmz manager (자동화 매커니즘)

```
[Windows 게스트 OS, 172.30.33.60]            (dockurr 의 internal NAT subnet)
        │
        ▼ outbound packet → dockurr NAT
[6v6-win 컨테이너, 10.20.33.60]              (6v6-user docker bridge)
        │
        ▼ container default GW = 10.20.33.1   ← 6v6.sh cmd_win_route_fix 가 자동 설정
[6v6-ips eth1 (user), 10.20.33.1]
        │
        ▼ ip_forward + nat6v6 masquerade      ← ips/entrypoint.sh 가 자동 설정
[6v6-ips eth2 (dmz), 10.20.32.1]
        │
        ▼ source IP = 10.20.32.1 (SNAT 후)
[6v6-siem (Wazuh manager), 10.20.32.100:1515/1514]
```

**2 자리 자동화** — fresh clone + `bash 6v6.sh up --with-windows` 한 줄로 동작:
- `ips/entrypoint.sh` : `nat6v6` chain 에 `user(10.20.33/24) → dmz NIC masquerade` 룰 추가
- `6v6.sh cmd_win_route_fix` : 컨테이너 default GW 를 docker bridge `.254` → `ips 10.20.33.1` 로 변경 (windows up 마다)

manager 의 응답은 source IP `10.20.32.1` (ips) 로 옴 → ips conntrack 가 user 측 IP 로 복원 → 컨테이너 → 게스트 OS.

## install.bat 가 자동으로 하는 일

| 단계 | 내용 |
|------|------|
| ① Sysmon 64-bit | live.sysinternals.com 에서 다운로드 + SwiftOnSecurity config 적용 |
| ② Wazuh agent 4.10.0 | MSI 설치 + agent-auth 로 매니저(10.20.32.100) 자동 enroll |
| ③ ossec.conf 패치 | `<localfile>` 에 `Microsoft-Windows-Sysmon/Operational` eventchannel 추가 |
| ④ OpenSSH (Win32 v9.8.1.0p1) | 설치 + DefaultShell=PowerShell 로 설정 |
| ⑤ hosts 파일 | `*.6v6.lab` → 10.20.32.80 등록 (victim 브라우징용) |
| ⑥ ICMP allow | 방화벽 inbound 룰 |
| ⑦ Wazuh 재기동 | 채널 통합 적용 |
| 종료 | `\\host.lan\Data\OEM_DONE.txt` 생성 (호스트에서 완료 확인 가능) |

## 전제 (넷 다 충족돼야 등록됨 — `bash 6v6.sh up --with-windows` 가 모두 자동 보장)

- 매니저 `authd` 가동 + 1515 listen (Wazuh 자동등록).
- `6v6-user` 네트워크 존재 + `6v6-ips` 가 user(10.20.33.1) 인터페이스 보유 (`docker-compose.yaml`).
- `6v6-ips` 의 nat6v6 chain 에 `user(10.20.33/24) → dmz NIC masquerade` 룰 — ips entrypoint 가 추가.
- `6v6-win` 컨테이너의 default GW = `10.20.33.1` (ips) — `6v6.sh cmd_win_route_fix` 가 windows up
  마다 자동 변경. 기본 docker bridge GW(.254) 로 두면 cross-bridge routing 안 됨 → enroll 실패.

> install.bat 의 게스트 OS 정적 라우팅(10.20.32.0/24 → 10.20.33.1) 은 dockurr 의 NETWORK mode
> bridge 호환용 보조. 기본 NAT mode 에선 게스트가 default GW(172.30.33.1=dockurr NAT) 만 사용,
> 위 4 자리 자동화로 manager 도달.

> ⚠️ **매니저 재시작 전 `/var/ossec/bin/wazuh-analysisd -t` 로 룰 검증 필수.**
> `local_rules.xml` 의 root 가 `<ruleset>` 로 잘못되어 있을 경우 매니저 다운 유발 사례 있음
> → 반드시 `<group>` 로 수정. (2026-05-28 사고 사례)

## 트러블슈팅

### KVM 관련 — `bash 6v6.sh up --with-windows` 시 `X /dev/kvm missing` 에러

원인 진단 한 줄:
```bash
ls -l /dev/kvm; egrep -c '(vmx|svm)' /proc/cpuinfo; lsmod | grep kvm; systemd-detect-virt
```

진단 결과 별 처치:

| 진단 | 의미 | 처치 |
|------|------|------|
| `/dev/kvm` 있지만 권한 X (`Permission denied`) | 모듈/CPU OK, user 권한만 부족 | `sudo usermod -aG kvm $USER && newgrp kvm` |
| `vmx/svm` count > 0, `lsmod` 에 kvm 없음 | CPU 지원 OK, 모듈 미로드 (패키지 미설치) | `sudo apt install -y qemu-kvm && sudo modprobe kvm_intel` (Intel) 또는 `kvm_amd` (AMD) |
| `vmx/svm` count = 0, `systemd-detect-virt` ≠ none | 호스트가 VM 안 (VMware/VirtualBox 등), nested virtualization 꺼짐 | **호스트 hypervisor** 설정. VMware: VM 종료 → 설정 → CPU → "Virtualize Intel VT-x/EPT or AMD-V/RVI" 체크 → 재시작 |
| `vmx/svm` count = 0, baremetal | BIOS 가상화 비활성 | 재부팅 → BIOS/UEFI → "Intel Virtualization Technology" 또는 "SVM Mode" 활성 → 저장 후 재부팅 |

> KVM 못 켜는 환경이면 **Windows 만 빼고 본 스택 15컨테이너는 정상 동작**:
> `bash 6v6.sh up` (--with-windows 빼고). Windows 관련 lab/lecture step 만 건너뛰면 됨.

### 그 외

| 증상 | 처치 |
|------|------|
| OEM 안 돌아간 채로 Windows 가 뜸 | `docker compose -f docker-compose.windows.yml down -v` → `win-storage/` 삭제 → 재시작 (디스크 새로 만들어야 OEM 재실행) |
| agent 가 `Duplicate agent name` 으로 enroll 실패 | 매니저에서 `docker exec 6v6-siem /var/ossec/bin/manage_agents -r <id>` 로 stale 레코드 제거 후 재시도 (`agent_control -l` 로 stale ID 확인) |
| 6v6-win 이 `Never connected` 또는 `Disconnected` (enroll 됐지만 keepalive X) | 1) `docker exec 6v6-win ip route` 로 default GW 가 `10.20.33.1` 인지 확인 (아니면 `bash 6v6.sh windows down && bash 6v6.sh windows up`). 2) `docker exec 6v6-ips nft list table ip nat6v6` 에 `saddr 10.20.33.0/24 masquerade` 룰 있는지 확인 |
| ips/web/siem 등 base agent 가 `Disconnected` (force-recreate 후) | client.keys 가 image 안에만 있어 force-recreate 시 사라짐. `manage_agents -r <stale_id>` 후 컨테이너 안에서 `/var/ossec/bin/agent-auth -m 10.20.32.100 -A <name>` + `wazuh-control restart` |
| Sysmon 이벤트가 SIEM 에 안 도달 | ossec.conf 에 Sysmon eventchannel `<localfile>` 가 있는지 확인. 없으면 install.bat ③ 단계 수동 재실행 |
| SSH 가 일시 거부 (`kex_exchange_identification`) | Win32-OpenSSH MaxStartups 일시 lockout. 30초 대기 후 재시도. 4625 생성용 brute 는 victim 안의 `net use bad creds` 패턴 사용 권장 |
| Win → 10.20.32.100:1515/1514 TCP timeout | 위 "Never connected" 처치와 동일. 추가로 host 의 `docker network inspect 6v6-user` 에서 ips 가 `10.20.33.1/24` 보유 확인 |

## 4 과목에서의 활용 (요약)

- **secuops-easy W1/W2/W5/W6**: 방화벽 가시성 한계 + 4 층 다층 방어에 endpoint 자리.
- **secuops W3 (신설)**: Windows 엔드포인트 정식 주차 — Sysmon EID + Security 4625 + R/B/P 5건.
- **soc W2/W5/W11/W12/W15**: 분석가 시각 (UEBA baseline / 4 패턴 / 악성코드 본진 / 사용자 인터뷰).
- **attack W1/W2/W6/W11/W12/W15**: Red 의 자기 인식 (포트 표면 / 인증 / 권한상승 / 지속성 / PTES Stage 5).

자세한 학습 콘텐츠는 mrgrit/ccc 의 `contents/standalone/{lecture,lab}/{secuops-easy,secuops,soc,attack}/`
참조.
