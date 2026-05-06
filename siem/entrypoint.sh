#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# Wazuh manager 기동 (analysisd / remoted / monitord ... 8 daemon)
echo "[siem] starting wazuh-manager"
/var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || echo "[siem] WARN: wazuh-control 실패"

# alert viewer (Flask) 기동 — 5601
echo "[siem] starting alert viewer on :5601"
python3 /opt/alert_viewer.py > /var/log/alert_viewer.log 2>&1 &

# cti-collector 기동 (백그라운드)
echo "[siem] starting cti-collector"
python3 /opt/cti_collector.py > /var/log/cti_collector.log 2>&1 &

# rsyslog (학습용 — 외부 syslog 수신)
echo "[siem] starting rsyslog"
service rsyslog start 2>/dev/null || true

# sshd foreground
echo "[siem] starting sshd"
exec /usr/sbin/sshd -D -e
