# 6v6 Assessor — 읽기 전용 평가 수집 레이어

중앙 플랫폼(CC/tubewar)이 학생별 6v6 VM에서 **채점·모니터링에 필요한 상황정보를
읽기 전용으로 당겨갈 수 있도록** 추가된 별도 서비스다. Bastion·토폴로지·취약웹·Wazuh
코어는 일절 손대지 않는다.

> **클라이언트는 문맥 없이(dumb) 수집만 한다.** 과목/학년/반/팀(Cohort)·index 분리
> 로직은 6v6 안에 없다 — 그건 전적으로 서버(tubewar)의 책임이다. 같은 6v6 이미지가
> 여러 과목·학년에 재사용되므로, 어떤 수업인지 클라이언트는 알지 못한다.

---

## 1. 구성

| 항목 | 값 |
|------|----|
| 컨테이너 | `6v6-assessor` (dmz, `10.20.32.55`) |
| 스택 | `python:3.12-slim` + FastAPI + docker SDK + httpx |
| 외부 노출 | `http://assessor.6v6.lab/` (fw HAProxy, WAF 우회 — portal 과 동일) |
| 인증 | `X-API-Key` (env `API_KEY`, 기본 `ccc-api-key-2026`) |
| 마운트(전부 read-only) | `/var/run/docker.sock`, `wazuh-manager-logs`, `ips-suricata-logs`, `web-apache-logs` |
| 토글 | `SKIP_ASSESSOR=1 bash 6v6.sh up` → 생성 안 함(base 무영향) |

Assessor 는 compose profile `assessor` 로 묶여 있어 `bash 6v6.sh up` 이 기본 활성화하고,
`SKIP_ASSESSOR=1` 이면 profile 미활성 → 컨테이너 자체가 생성되지 않는다.

---

## 2. 동작 원리 — 게이트키퍼

CC 는 **절대 raw 명령을 보내지 않는다.** 선언적 *check-spec* 만 보내고, Assessor 가
이를 **고정 명령 템플릿 + 파라미터 화이트리스트**로만 안전 명령으로 변환해 실행한다.

```
CC ──(check-spec, X-API-Key)──▶ Assessor ──┬─ 호스트 상태: docker.sock 로 read-only exec
                                            │   (stat/grep/sha256sum/pgrep/ss/tail — argv 직접)
                                            └─ 보안 알림: 로컬 Wazuh alerts.json 질의(+옵션 indexer)
        ◀──(pass/fail + evidence)──────────┘
```

- **모든 검사 부작용 0.** 쓰기·변경·네트워크 공격 명령은 존재하지 않는다.
- **명령 주입 불가.** docker exec 는 셸 없이 argv 리스트를 직접 실행하며, path/pattern/port 는
  엄격한 화이트리스트(절대경로 + `[A-Za-z0-9._-/]`, `..` 금지, 제어문자 금지, 포트 1–65535)를
  통과해야 한다. 미지원 type·위험 파라미터는 `passed:false` 가 아니라 **명시적 `error` 로 거부**.

---

## 3. API

### `GET /health` (인증 불필요)
```json
{ "status": "ok", "service": "6v6-assessor",
  "supported_types": ["command_ran", "..."], "targets": ["attacker","bastion","..."],
  "alerts_source": "/data/wazuh/alerts/alerts.json", "indexer_enabled": false }
```

### `POST /assess` (헤더 `X-API-Key`)
요청:
```json
{
  "battle_id": "optional",
  "checks": [
    { "id": "c1", "type": "file_contains", "target": "web",
      "params": { "path": "/etc/modsecurity/modsecurity.conf", "pattern": "SecRuleEngine On" } }
  ]
}
```
응답:
```json
{
  "collected_at": "2026-06-03T12:00:00+00:00",
  "battle_id": "optional",
  "results": [
    { "id": "c1", "passed": true, "evidence": "12:SecRuleEngine On", "raw": { "exit_code": 0, "container": "6v6-web" } }
  ]
}
```
- `passed`: `true`/`false` = 검사 수행 결과. `null` + `error` = 수행 불가(미지원/위험/잘못된 파라미터).
- `evidence`: 근거 문자열(≤2KB).
- `raw`: 부가 메타(exit_code, container, matches 등).

---

## 4. target/container 별칭

`target` 또는 `container` 에 아래 표준 별칭(또는 `6v6-` 컨테이너명)을 쓴다. 어느 컨테이너에
exec 할지는 Assessor 내부 맵이 결정한다 — **클라이언트는 토폴로지를 몰라도 된다.**

| 별칭 | 컨테이너 | 비고 |
|------|----------|------|
| `fw` (=`firewall`,`secu`) | 6v6-fw | nftables + HAProxy |
| `ips` (=`ids`,`suricata`) | 6v6-ips | Suricata |
| `web` (=`waf`,`apache`) | 6v6-web | Apache + ModSecurity |
| `siem` (=`wazuh`,`manager`) | 6v6-siem | Wazuh manager |
| `attacker` | 6v6-attacker | |
| `bastion` | 6v6-bastion | |
| `juiceshop`(=`juice`) `dvwa` `neobank` `govportal` `mediforum` `adminconsole`(=`admin`) `aicompanion`(=`ai`) | 취약웹 7종 | |

---

## 5. check type 레퍼런스 (전부 읽기 전용)

### 호스트 상태 — docker.sock exec
| type | params | passed 조건 | 합성 명령(argv) |
|------|--------|-------------|------------------|
| `file_exists` | `path`, `target/container` | 파일 존재 | `stat -c … -- <path>` |
| `file_contains` | `path`, `pattern`\|`regex`, `target` | 매치 1건+ | `grep -F\|-E -n -m1 -e <pat> -- <path>` |
| `file_hash` | `path`, `target`, `sha256?` | 해시 산출(또는 expected 일치) | `sha256sum -- <path>` |
| `process_running` | `name`\|`pattern`, `target` | 프로세스 존재 | `pgrep -a -f <pat>` |
| `port_listening` | `port`, `target` | LISTEN 소켓 존재 | `ss -ltn` (파이썬 파싱) |
| `log_contains` | `log`, `pattern`, `since_sec?`, `container?` | 매치 라인 존재 | `tail -n 4000 <path>` (파이썬 필터) |

`log` 별칭: `suricata`(ips:/var/log/suricata/eve.json), `modsec`(web:/var/log/apache2/modsec_audit.log),
`apache_error`(web:/var/log/apache2/error.log), `auth`(container 의 /var/log/auth.log).

### 보안 알림/로그 — Wazuh 질의 (로컬 alerts.json, 옵션 indexer)
| type | params | passed 조건 |
|------|--------|-------------|
| `wazuh_alert` | `rule_id`\|`sid`\|`groups`\|`agent`, `since_sec?` | 조건 매칭 알림 존재 |
| `fim_change` | `path`\|`dir`, `since_sec?` | 해당 경로의 syscheck(FIM) 변경 알림 존재 |
| `command_ran` | `pattern`, `user?`, `since_sec?` | 패턴에 맞는 셸 명령 로그 존재 |

> 풍부 경로: `ASSESSOR_USE_INDEXER=1`(compose env) 로 Wazuh indexer(`https://10.20.32.110:9200`,
> admin/SecretPassword, self-signed→verify off) 병행 질의. 기본은 alerts.json(견고·무의존).

---

## 6. 예시

```bash
KEY=ccc-api-key-2026
ASSESS="curl -s -H Host:assessor.6v6.lab -H X-API-Key:$KEY -H Content-Type:application/json -X POST http://<VM_IP>/assess -d"

# 1) WAF 차단 모드 확인
$ASSESS '{"checks":[{"id":"waf-on","type":"file_contains","target":"web",
  "params":{"path":"/etc/modsecurity/modsecurity.conf","pattern":"SecRuleEngine On"}}]}'

# 2) Suricata 동작 + 80 리슨
$ASSESS '{"checks":[
  {"id":"suri","type":"process_running","target":"ips","params":{"pattern":"suricata"}},
  {"id":"p80","type":"port_listening","target":"web","params":{"port":80}}]}'

# 3) SQLi 탐지 알림 + 방화벽 룰 변경(FIM) + 위험 명령 실행
$ASSESS '{"checks":[
  {"id":"sqli","type":"wazuh_alert","params":{"groups":["web_attack"],"since_sec":3600}},
  {"id":"fw-fim","type":"fim_change","params":{"path":"/etc/nftables.conf","since_sec":3600}},
  {"id":"ran","type":"command_ran","params":{"pattern":"sqlmap","since_sec":3600}}]}'
```

---

## 7. 정적 수집(cohort-free) — FIM + 명령 로깅

`fim_change`/`command_ran` 질의가 가능하도록 6v6 의 Wazuh 수집을 **모든 학생 동일하게
정적으로** 켠다(per-task/per-cohort 동적 config 없음).

- **FIM (syscheck, realtime + report_changes + whodata)** — `web`(apache/modsec 설정 + /home/ccc),
  `fw`(/etc/nftables.conf + /etc/haproxy + /home/ccc), `ips`(/etc/suricata + /home/ccc).
  각 컨테이너 `entrypoint.sh` 가 `<ossec_config>` 에 `6v6-assessor-collection` 블록을 1회 주입(멱등).
- **명령 로깅** — 모든 대화형 셸이 `/etc/profile.d/6v6-cmdlog.sh` 의 `PROMPT_COMMAND` 로
  `CMD6V6 host=… user=… pwd=… rc=… cmd=…` 라인을 남긴다.
  - `attacker`/`bastion`(Wazuh agent 없음): 기존 `rsyslog *.* @siem:514` 로 manager 전달.
  - `web`/`fw`/`ips`(Wazuh agent 보유): `/var/log/6v6-cmd.log` localfile 로 manager 전달.
  - manager 의 `cmdlog` decoder/rules(`siem/cmdlog-*.xml`, cont-init `94-cmdlog-rules`)가
    `data.command` 등으로 파싱 → `alerts.json` 기록 → `command_ran` 질의 가능.

> **bastion 무변경 보장:** 위 셸 profile.d 드롭인은 Bastion 의 두뇌(KG/Manager/SubAgent)·
> API(`/health`·`/exec`·`/chat`)·ProxyJump 와 완전히 무관하다. 명령 합성 surface(`/exec`
> 화이트리스트)는 확장하지 않았고, Assessor 는 Bastion 과 별개 서비스다.

---

## 8. 보안 노트

- `docker.sock` 은 root 등가다. 그래서 CC 문자열을 절대 그대로 실행하지 않고, **고정 템플릿 +
  화이트리스트**로만 명령을 합성한다(`assessor/checks/base.py`, `host.py`). 새 RCE 표면 없음.
- 기존 Bastion `/exec` 화이트리스트는 확장하지 않았다.
- 모든 외부 접근은 **읽기 전용 + API 키**. 쓰기/변경/공격 명령 type 은 존재하지 않는다.
- 보안 핵심 로직은 `assessor/tests/test_checks.py` 로 단위 검증(주입 차단·미지원 거부·필터):
  `python3 -m unittest assessor.tests.test_checks -v` (repo 루트).
