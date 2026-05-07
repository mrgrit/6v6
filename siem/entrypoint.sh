#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# ─── Wazuh manager 설정 — agent + syslog 두 입력 ────────────
if [ -d /var/ossec ]; then
    echo "[siem] configuring Wazuh manager (agent + syslog inputs)"

    # 1) authd 활성화 — agent 자동 등록 허용 (인증서 자동 생성)
    sed -i 's|<auth>|<auth>\n    <use_password>no</use_password>|' /var/ossec/etc/ossec.conf 2>/dev/null || true
    sed -i 's|<disabled>yes</disabled>|<disabled>no</disabled>|' /var/ossec/etc/ossec.conf 2>/dev/null || true

    # 2) syslog 입력 추가 — bastion / attacker 의 rsyslog forward 수신
    if ! grep -q '<connection>syslog</connection>' /var/ossec/etc/ossec.conf; then
        sed -i '/<\/ossec_config>/i\
  <!-- 6v6: rsyslog forward 수신 (syslog 패러다임 학습) -->\n  <remote>\n    <connection>syslog</connection>\n    <port>514</port>\n    <protocol>udp</protocol>\n    <allowed-ips>10.20.30.0/24</allowed-ips>\n  </remote>' /var/ossec/etc/ossec.conf
    fi

    # 3) agent 입력 — 기본 1514/udp+tcp 활성화 (Wazuh 기본값)

    # 4) authd 데몬용 ossec-authd 인증서 생성 (없으면)
    if [ ! -f /var/ossec/etc/sslmanager.cert ]; then
        echo "[siem]   generating authd cert"
        cd /var/ossec/etc && \
            openssl req -x509 -batch -nodes -days 730 -newkey rsa:2048 \
                -subj "/CN=6v6-siem" \
                -keyout sslmanager.key -out sslmanager.cert 2>/dev/null
        chmod 600 sslmanager.key
        cd - > /dev/null
    fi

    echo "[siem] starting wazuh-manager"
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || \
        echo "[siem] WARN: wazuh-control 기동 실패"
fi

# rsyslog (학습 alt 입력)
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
