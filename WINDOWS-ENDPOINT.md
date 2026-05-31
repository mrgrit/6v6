# Windows 엔드포인트 — 6v6 의 사용자 PC (10.20.32.60)

6v6 인프라에 **Windows 11 (tiny11) 사용자 PC** 1대를 dmz zone (10.20.32.60) 에 추가한다.
**dockurr/windows** 컨테이너로 KVM 위에서 동작하며, 첫 부팅 시 `win-oem/install.bat` 가 자동
실행되어 **Sysmon + Wazuh agent + OpenSSH** 가 모두 설치·구성된다 (사용자가 마우스로 만질 게
거의 없음).

## 목적

- secuops / soc / attack / secuops-easy 4 과목의 **endpoint 측 가시화** (EDR 학습) 무대.
- victim 직원 PC (피싱·다운로드·우발 행위 시뮬) + analyst 보안담당 PC 두 페르소나.
- Wazuh manager (10.20.32.100) 에 `6v6-win` agent 로 자동 enroll → Sysmon EID 1/3/22/11 + Security
  4624/4625 가 같은 SIEM dashboard 로 흐른다.

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

## 검증 (2026-05-28 실측)

```bash
# 1) SIEM 에서 6v6-win agent 가 Active 인지
docker exec 6v6-siem /var/ossec/bin/agent_control -l | grep 6v6-win
# → ID: 006, Name: 6v6-win, IP: any, Active

# 2) Sysmon 채널이 매니저로 흘러오는지 (Wazuh archives)
docker exec 6v6-siem grep -c "6v6-win" /var/ossec/logs/archives/archives.json | head -1

# 3) SSH 로 Windows 접속 (관리/실습용)
sshpass -p ccc ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ccc@10.20.32.60 'Get-Service Sysmon64 | Select-Object Status'
# → Running 출력
```

SIEM 도달 채널: `Microsoft-Windows-Sysmon/Operational`, `Security`, `System`, `Application`, `SCA`.

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

## 전제 (둘 다 충족돼야 등록됨)

- 매니저 `authd` 가동 + 1515 listen (Wazuh 자동등록).
- Windows 가 매니저 (dmz 10.20.32.100) 에 도달 가능한 세그먼트 (=dmz). int 는 존 격리로 불가.

> ⚠️ **매니저 재시작 전 `/var/ossec/bin/wazuh-analysisd -t` 로 룰 검증 필수.**
> `local_rules.xml` 의 root 가 `<ruleset>` 로 잘못되어 있을 경우 매니저 다운 유발 사례 있음
> → 반드시 `<group>` 로 수정. (2026-05-28 사고 사례)

## 트러블슈팅

| 증상 | 처치 |
|------|------|
| OEM 안 돌아간 채로 Windows 가 뜸 | `docker compose -f docker-compose.windows.yml down -v` → `win-storage/` 삭제 → 재시작 (디스크 새로 만들어야 OEM 재실행) |
| agent 가 `Duplicate name` 으로 enroll 실패 | 매니저에서 `docker exec 6v6-siem /var/ossec/bin/manage_agents -r <id>` 로 stale 레코드 제거 후 재시도 |
| Sysmon 이벤트가 SIEM 에 안 도달 | ossec.conf 에 Sysmon eventchannel `<localfile>` 가 있는지 확인. 없으면 install.bat ③ 단계 수동 재실행 |
| SSH 가 일시 거부 (`kex_exchange_identification`) | Win32-OpenSSH MaxStartups 일시 lockout. 30초 대기 후 재시도. 4625 생성용 brute 는 victim 안의 `net use bad creds` 패턴 사용 권장 |

## 4 과목에서의 활용 (요약)

- **secuops-easy W1/W2/W5/W6**: 방화벽 가시성 한계 + 4 층 다층 방어에 endpoint 자리.
- **secuops W3 (신설)**: Windows 엔드포인트 정식 주차 — Sysmon EID + Security 4625 + R/B/P 5건.
- **soc W2/W5/W11/W12/W15**: 분석가 시각 (UEBA baseline / 4 패턴 / 악성코드 본진 / 사용자 인터뷰).
- **attack W1/W2/W6/W11/W12/W15**: Red 의 자기 인식 (포트 표면 / 인증 / 권한상승 / 지속성 / PTES Stage 5).

자세한 학습 콘텐츠는 mrgrit/ccc 의 `contents/standalone/{lecture,lab}/{secuops-easy,secuops,soc,attack}/`
참조.
