#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
WAZUH_MANAGER="${WAZUH_MANAGER:-siem}"

# 사용자
if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,www-data "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# Self-signed cert
if [ ! -f /etc/apache2/ssl/server.crt ]; then
    echo "[web] generating self-signed cert"
    mkdir -p /etc/apache2/ssl
    openssl req -x509 -nodes -days 730 \
        -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/server.key \
        -out    /etc/apache2/ssl/server.crt \
        -subj "/CN=*.6v6.lab/O=6v6/C=KR" 2>/dev/null
    chmod 600 /etc/apache2/ssl/server.key
fi

echo "ServerName web" >> /etc/apache2/apache2.conf

# ─── Wazuh agent 설정 + 등록 ─────────────────────────────
if [ -d /var/ossec ]; then
    echo "[web] configuring Wazuh agent (manager=$WAZUH_MANAGER)"
    # ossec.conf 의 manager IP 치환
    sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" /var/ossec/etc/ossec.conf

    # localfile 추가 (Apache + ModSec)
    if ! grep -q '/var/log/apache2/modsec_audit.log' /var/ossec/etc/ossec.conf; then
        # </ossec_config> 직전에 append
        sed -i '/<\/ossec_config>/i\
  <localfile>\n    <log_format>apache</log_format>\n    <location>/var/log/apache2/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>apache</log_format>\n    <location>/var/log/apache2/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>json</log_format>\n    <location>/var/log/apache2/modsec_audit.log</location>\n  </localfile>' /var/ossec/etc/ossec.conf
    fi

    # manager 가 ready 될 때까지 대기 (1515 = registration port)
    echo "[web] waiting for Wazuh manager $WAZUH_MANAGER:1515..."
    for i in $(seq 1 30); do
        if (echo > /dev/tcp/$WAZUH_MANAGER/1515) 2>/dev/null; then
            echo "[web]   manager ready"
            break
        fi
        sleep 2
    done

    # agent-auth 로 등록 (auth-disabled 시 자동)
    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -A "$(hostname)" 2>&1 | tail -3 || \
        echo "[web] WARN: agent-auth 실패 — manager 의 authd 설정 확인"

    # agent 기동
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || \
        echo "[web] WARN: wazuh-control 기동 실패"
fi

# Apache foreground (백그라운드)
echo "[web] starting apache2"
apache2ctl configtest 2>&1 | sed 's/^/  /' || true
apache2ctl -D FOREGROUND &

# sshd foreground
echo "[web] starting sshd"
exec /usr/sbin/sshd -D -e
