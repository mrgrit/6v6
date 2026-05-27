# secuops-easy 특강 배포 (방화벽·IPS·WAF 교육용 GUI)

보안시스템 입문 특강(secuops-easy, 6주)에서 쓰는 세 개의 장비형 교육용 GUI 를 6v6 인프라에
배포·검증하는 번들이다. 학생은 모든 조작을 웹 콘솔로 하고, GUI 가 만들어내는 실제 명령
(`nft` / Suricata rule / SecRule)을 함께 배운다.

## 구성 요소

| 장비 | GUI 레포 | 배포 대상 | 학생 접속 |
|------|----------|-----------|-----------|
| 방화벽(nftables) | `mrgrit/nft_edu_gui` | 6v6-fw :8080 | http://fw-gui.6v6.lab |
| IPS(Suricata) | `mrgrit/suricata_edu_gui` | 6v6-ips :8080 | http://ips-gui.6v6.lab |
| WAF(ModSecurity) | `mrgrit/modsec_edu_gui` | 6v6-web :8080 | http://waf-gui.6v6.lab |

각 GUI 는 **Python 표준 라이브러리만** 사용(pip 불필요), 단일 `server.py` + 정적 파일로
컨테이너 안에서 root 로 동작한다.

## 이 번들이 적용하는 인프라 보정

배포 과정에서 다음 보정을 함께 적용한다(2026-05-27 6v6 실측 기준 필요했던 수정).

| 파일 | 무엇을 고치나 | 왜 |
|------|--------------|----|
| `fix_modsec.py` | `/etc/modsecurity/modsecurity.conf` 의 중복·잘린 예외 블록(`SecRule REMOTE_ADDR @ipMatch` 등) 정규화 | 문법 오류로 Apache 가 기동 실패(AH00526)하던 것 복구 |
| `suricata_local.rules.baseline` | `/etc/suricata/rules/local.rules` 를 올바른 문법으로 교체 | 기존 `!src_ip` 잘못된 옵션으로 전 룰 로딩 실패(rules_loaded 0)하던 것 복구 → 5/0 |
| `patch_haproxy.py` | fw HAProxy 에 `fw-gui`/`ips-gui`/`waf-gui` vhost(both frontend) + backend 추가(idempotent) | 학생이 브라우저로 세 콘솔에 접속하도록 |

> HAProxy reload 주의: reload 후 **구 프로세스(이전 config)를 반드시 종료**해야 한다.
> SO_REUSEPORT 로 두 프로세스가 80포트를 나눠 받으면, 일부 요청이 옛 config 로 가 404(Apache)
> 가 난다. `deploy_all.sh` 의 [4/5] 단계가 이를 처리한다.

## 사용법

6v6 호스트(docker 가 있는 머신)에서:

```bash
# GUI 레포를 자동 clone 하려면 GH_PAT 제공
GH_PAT=<github_token> bash secuops-easy-deploy/deploy_all.sh

# 또는 GUI 레포를 미리 /opt/secuops-easy-src/{nft,suricata,modsec}_edu_gui 에 두고:
bash secuops-easy-deploy/deploy_all.sh
```

개별 재배포(각 GUI 레포에서):
```bash
./deploy.sh 6v6-fw  8080   # nft_edu_gui
./deploy.sh 6v6-ips 8080   # suricata_edu_gui
./deploy.sh 6v6-web 8080   # modsec_edu_gui
```

## 검증(스모크)

```bash
for g in fw ips waf; do
  docker exec 6v6-fw curl -s -o /dev/null -w "$g-gui %{http_code}\n" -H "Host: $g-gui.6v6.lab" http://127.0.0.1/
done
# 기대: 모두 200
docker exec 6v6-ips suricatasc -c ruleset-stats   # rules_loaded>=5, failed 0
docker exec 6v6-web apache2ctl configtest          # Syntax OK
```

## SIEM(Wazuh) 연동
- 방화벽: GUI "SIEM 연동 켜기" → `/var/log/nft_edu/events.log` 를 Wazuh 에이전트가 tail.
- IPS: `/var/log/suricata/eve.json` (대개 기연동).
- WAF: `/var/log/apache2/modsec_audit.log` (대개 기연동).
- 매니저: 10.20.32.100.

## 강의 콘텐츠
교안/실습(6주)은 CCC 레포 `contents/standalone/{lecture,lab}/secuops-easy/` 에 있으며 6v6 Training
UI(`/api/standalone/secuops-easy/...`)로 서빙된다.

> 교육용 도구. 운영 보안장비에 그대로 쓰지 말 것.
