#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# ─── Wazuh manager 설정 — 첫 부팅 시 한 번만 patch (idempotent) ────────────
PATCH_FLAG=/var/ossec/.6v6-patched
if [ -d /var/ossec ] && [ ! -f "$PATCH_FLAG" ]; then
    echo "[siem] patching wazuh ossec.conf (first boot only)"

    # 1) authd 강제 enable (auth 블록 안의 disabled 만 yes→no)
    python3 <<'PY'
import re
p = '/var/ossec/etc/ossec.conf'
src = open(p).read()
# auth 블록 안의 disabled 토글
src = re.sub(
    r'(<auth>.*?<disabled>)yes(</disabled>.*?</auth>)',
    r'\1no\2', src, flags=re.S
)
# syslog remote 블록이 없으면 </ossec_config> 직전에 한 번만 삽입
if '<connection>syslog</connection>' not in src:
    block = (
        '\n  <!-- 6v6: rsyslog forward 수신 (syslog 패러다임 학습) -->\n'
        '  <remote>\n'
        '    <connection>syslog</connection>\n'
        '    <port>514</port>\n'
        '    <protocol>udp</protocol>\n'
        '    <allowed-ips>10.20.30.0/24</allowed-ips>\n'
        '  </remote>\n'
    )
    src = src.replace('</ossec_config>', block + '</ossec_config>', 1)
open(p, 'w').write(src)
print('[siem]   ossec.conf patched OK')
PY

    # 2) authd 인증서 (없으면 생성)
    if [ ! -f /var/ossec/etc/sslmanager.cert ]; then
        echo "[siem]   generating authd cert"
        cd /var/ossec/etc && \
            openssl req -x509 -batch -nodes -days 730 -newkey rsa:2048 \
                -subj "/CN=6v6-siem" \
                -keyout sslmanager.key -out sslmanager.cert 2>/dev/null
        chmod 600 sslmanager.key
        cd - > /dev/null
    fi

    touch "$PATCH_FLAG"
fi

# Wazuh manager 기동
if [ -d /var/ossec ]; then
    echo "[siem] starting wazuh-manager"
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || \
        echo "[siem] WARN: wazuh-control 기동 실패"
fi

# rsyslog (학습 alt 입력 — Wazuh manager 가 514 listen 이므로 별도 미사용)
echo "[siem] starting rsyslog"
service rsyslog start 2>/dev/null || true

# alert viewer (Flask) — 5601
echo "[siem] starting alert viewer on :5601"
python3 /opt/alert_viewer.py > /var/log/alert_viewer.log 2>&1 &

# cti-collector
echo "[siem] starting cti-collector"
python3 /opt/cti_collector.py > /var/log/cti_collector.log 2>&1 &

# sshd foreground
echo "[siem] starting sshd"
exec /usr/sbin/sshd -D -e
