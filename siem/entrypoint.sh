#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# --- Wazuh manager: patch ossec.conf once (idempotent) -----------------
PATCH_FLAG=/var/ossec/.6v6-patched
if [ -d /var/ossec ] && [ ! -f "$PATCH_FLAG" ]; then
    echo "[siem] patching ossec.conf (first-boot only)"

    python3 <<'PY'
import re
p = '/var/ossec/etc/ossec.conf'
src = open(p).read()
# Toggle <disabled> inside <auth> from yes -> no
src = re.sub(
    r'(<auth>.*?<disabled>)yes(</disabled>.*?</auth>)',
    r'\1no\2', src, flags=re.S
)
# Add syslog remote block once (only if not present)
if '<connection>syslog</connection>' not in src:
    block = (
        '\n  <!-- 6v6: rsyslog forward receiver (syslog paradigm) -->\n'
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

if [ -d /var/ossec ]; then
    echo "[siem] starting wazuh-manager"
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || \
        echo "[siem] WARN: wazuh-control start failed"
fi

echo "[siem] starting rsyslog"
service rsyslog start 2>/dev/null || true

echo "[siem] starting alert viewer on :5601"
python3 /opt/alert_viewer.py > /var/log/alert_viewer.log 2>&1 &

echo "[siem] starting cti-collector"
python3 /opt/cti_collector.py > /var/log/cti_collector.log 2>&1 &

echo "[siem] starting sshd"
exec /usr/sbin/sshd -D -e
