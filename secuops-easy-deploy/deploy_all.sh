#!/usr/bin/env bash
# secuops-easy 특강 배포 — 6v6 호스트에서 실행한다.
# 세 교육용 GUI(방화벽/IPS/WAF)를 각 tier 컨테이너에 배포하고, 필요한 인프라 보정을 적용한다.
#
#   대상 컨테이너: 6v6-fw / 6v6-ips / 6v6-web  (port 8080)
#   접속(학생): http://fw-gui.6v6.lab  /  http://ips-gui.6v6.lab  /  http://waf-gui.6v6.lab
#
# 사용:
#   GH_PAT=<token> bash secuops-easy-deploy/deploy_all.sh
# (GH_PAT 없으면 GUI 레포가 이미 /opt/src 에 있다고 가정하거나 git clone 을 건너뜀)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-/tmp/secuops-easy-src}"
PAT="${GH_PAT:-}"

clone() { # repo
  local r="$1"
  rm -rf "$WORK/$r"
  if [ -n "$PAT" ]; then
    git clone -q "https://${PAT}@github.com/mrgrit/${r}.git" "$WORK/$r"
  else
    # public clone (PAT unnecessary — 3 GUI repos are public)
    git clone -q --depth 1 "https://github.com/mrgrit/${r}.git" "$WORK/$r" || \
      echo "  ! clone failed for $r — check network or repo visibility"
  fi
}

echo "== [1/5] WAF(ModSecurity) 설정 보정 + Apache 기동 =="
docker cp "$HERE/fix_modsec.py" 6v6-web:/tmp/fix_modsec.py
docker exec 6v6-web python3 /tmp/fix_modsec.py || true
docker exec 6v6-web apache2ctl configtest && docker exec 6v6-web service apache2 start || docker exec 6v6-web apache2ctl graceful

echo "== [2/5] Suricata 기본 룰 보정(local.rules) + reload =="
docker cp "$HERE/suricata_local.rules.baseline" 6v6-ips:/etc/suricata/rules/local.rules
docker exec 6v6-ips suricatasc -c reload-rules
docker exec 6v6-ips suricatasc -c ruleset-stats

echo "== [3/5] 세 GUI 배포 (각 레포의 deploy.sh) =="
mkdir -p "$WORK"
for r in nft_edu_gui:6v6-fw suricata_edu_gui:6v6-ips modsec_edu_gui:6v6-web; do
  repo="${r%%:*}"; cont="${r##*:}"
  clone "$repo"
  if [ -d "$WORK/$repo" ]; then
    ( cd "$WORK/$repo" && bash deploy.sh "$cont" 8080 )
  else
    echo "  ! $WORK/$repo 없음 — GH_PAT 로 clone 하거나 수동 배치 후 deploy.sh 실행"
  fi
done

echo "== [4/5] HAProxy 에 GUI vhost 추가(idempotent) + reload(stale 제거) =="
docker exec 6v6-fw cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date +%Y%m%d%H%M%S)
docker cp "$HERE/patch_haproxy.py" 6v6-fw:/tmp/patch_haproxy.py
docker exec 6v6-fw python3 /tmp/patch_haproxy.py
docker exec 6v6-fw haproxy -c -f /etc/haproxy/haproxy.cfg
# reload 후 구(舊) 프로세스(이전 config)를 정리해야 SO_REUSEPORT split 로 404 가 안 난다.
OLD=$(docker exec 6v6-fw pgrep -o haproxy)
docker exec 6v6-fw bash -c "service haproxy reload 2>/dev/null || haproxy -f /etc/haproxy/haproxy.cfg -sf \$(pgrep -o haproxy) -D"
sleep 2
docker exec 6v6-fw bash -c "kill $OLD 2>/dev/null || true"

echo "== [5/5] 검증 =="
for g in fw ips waf; do
  echo -n "  $g-gui.6v6.lab => HTTP "
  docker exec 6v6-fw curl -s -o /dev/null -w "%{http_code}\n" -H "Host: $g-gui.6v6.lab" http://127.0.0.1/ 2>/dev/null || echo "?"
done
echo "done. 학생 접속: http://{fw,ips,waf}-gui.6v6.lab"
