# 6v6 Windows 엔드포인트 (사용자 PC, EDR 계측)

베어메탈 KVM 위 `dockurr/windows`(tiny11)로 Windows 11 사용자 PC를 6v6 에 추가한다.
보안장비(방화벽/IPS/WAF)가 지키는 **엔드포인트(victim)** 이자 SOC 감시 대상.

- 컨테이너 `6v6-win`, 네트워크 **6v6-dmz `10.20.32.60`** (int 는 매니저 도달 불가라 dmz 배치).
- 접속: 웹뷰어 `http://<host>:8006`, RDP `10.20.32.60:3389` (ccc/ccc).
- 첫 부팅 시 `win-oem/install.bat` 가 **Sysmon(SwiftOnSecurity) + Wazuh agent 4.10.0** 자동 설치,
  `agent-auth` 로 매니저(10.20.32.100) 등록, Sysmon eventchannel 수집 추가.
- 웹 브라우징: Windows hosts 에 `*.6v6.lab → 10.20.32.80`(web/WAF) 지정 시 juice/dvwa 등 접속(WAF 통과).

## 배포
```bash
docker compose -f docker-compose.windows.yml up -d   # 첫 부팅 ISO 다운로드+무인설치+oem (~20분)
```
## 검증 (2026-05-28 실측)
- `docker exec 6v6-siem /var/ossec/bin/agent_control -l` → `6v6-win ... Active`
- SIEM 도달 채널: Microsoft-Windows-Sysmon/Operational, Security, System, Application, SCA.

## 전제 (둘 다 충족돼야 등록됨)
- 매니저 authd 가동 + 1515 listen (Wazuh 자동등록).
- Windows 가 매니저(dmz 10.20.32.100)에 도달 가능한 세그먼트(=dmz). int 는 존 격리로 불가.

> ⚠️ 매니저 재시작 전 `/var/ossec/bin/wazuh-analysisd -t` 로 룰 검증 필수
> (local_rules.xml 의 잘못된 root `<ruleset>` 가 매니저 다운 유발한 사례 있음 → `<group>` 으로 수정).
