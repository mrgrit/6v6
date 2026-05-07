#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
WAZUH_MANAGER="${WAZUH_MANAGER:-10.20.30.100}"
if [[ ! "$WAZUH_MANAGER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RES_IP=$(getent hosts "$WAZUH_MANAGER" 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$RES_IP" ] && WAZUH_MANAGER="$RES_IP" || WAZUH_MANAGER="10.20.30.100"
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,www-data "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# Self-signed cert (generate once)
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

# --- Wazuh agent: configure + register + start --------------------------
if [ -d /var/ossec ]; then
    echo "[web] configuring Wazuh agent (manager=$WAZUH_MANAGER)"
    sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" /var/ossec/etc/ossec.conf

    if ! grep -q '/var/log/apache2/modsec_audit.log' /var/ossec/etc/ossec.conf; then
        sed -i '/<\/ossec_config>/i\
  <localfile>\n    <log_format>apache</log_format>\n    <location>/var/log/apache2/access.log</location>\n  </localfile>\n  <localfile>\n    <log_format>apache</log_format>\n    <location>/var/log/apache2/error.log</location>\n  </localfile>\n  <localfile>\n    <log_format>json</log_format>\n    <location>/var/log/apache2/modsec_audit.log</location>\n  </localfile>' /var/ossec/etc/ossec.conf
    fi

    echo "[web] waiting for Wazuh manager $WAZUH_MANAGER:1515..."
    for i in $(seq 1 30); do
        if (echo > /dev/tcp/$WAZUH_MANAGER/1515) 2>/dev/null; then
            echo "[web]   manager ready"
            break
        fi
        sleep 2
    done

    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -A "$(hostname)" 2>&1 | tail -3 || \
        echo "[web] WARN: agent-auth failed"

    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || \
        echo "[web] WARN: wazuh-control start failed"
fi

echo "[web] starting apache2"
apache2ctl configtest 2>&1 | sed 's/^/  /' || true
apache2ctl -D FOREGROUND &

echo "[web] starting sshd"
exec /usr/sbin/sshd -D -e
