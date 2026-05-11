#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
WAZUH_MANAGER="${WAZUH_MANAGER:-10.20.32.100}"
IPS_PIPE_IP="${IPS_PIPE_IP:-10.20.31.2}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# ─── Routing: dmz/int 은 ips 경유 ───────────────────────
echo "[fw] adding routes (dmz/int via ips $IPS_PIPE_IP)"
ip route add 10.20.32.0/24 via "$IPS_PIPE_IP" 2>/dev/null || true
ip route add 10.20.40.0/24 via "$IPS_PIPE_IP" 2>/dev/null || true

# ─── nftables ─────────────────────────────────────────
echo "[fw] applying nftables (six_filter / six_nat tables)"
nft -f /etc/nftables.conf 2>&1 | sed 's/^/  /' || echo "[fw] WARN: nft apply failed"

# ─── HAProxy self-signed cert (for 443 termination) ────
if [ ! -f /etc/haproxy/certs/server.pem ]; then
    echo "[fw] generating HAProxy self-signed cert"
    mkdir -p /etc/haproxy/certs
    openssl req -x509 -nodes -days 730 -newkey rsa:2048 \
        -keyout /tmp/server.key -out /tmp/server.crt \
        -subj "/CN=*.6v6.lab/O=6v6/C=KR" 2>/dev/null
    cat /tmp/server.crt /tmp/server.key > /etc/haproxy/certs/server.pem
    chmod 600 /etc/haproxy/certs/server.pem
    rm -f /tmp/server.key /tmp/server.crt
fi

# ─── HAProxy 기동 ──────────────────────────────────────
echo "[fw] starting HAProxy (L7 host-header routing)"
haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | sed 's/^/  /' || true
haproxy -f /etc/haproxy/haproxy.cfg -D &

# ─── Wazuh agent ────────────────────────────────────────
if [ -d /var/ossec ]; then
    echo "[fw] configuring Wazuh agent (manager=$WAZUH_MANAGER)"
    sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" /var/ossec/etc/ossec.conf

    if ! grep -q '/var/log/syslog' /var/ossec/etc/ossec.conf; then
        sed -i '/<\/ossec_config>/i\
  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/syslog</location>\n  </localfile>' /var/ossec/etc/ossec.conf
    fi

    echo "[fw] waiting for Wazuh manager $WAZUH_MANAGER:1515..."
    for i in $(seq 1 30); do
        if (echo > /dev/tcp/$WAZUH_MANAGER/1515) 2>/dev/null; then
            echo "[fw]   manager ready"
            break
        fi
        sleep 2
    done

    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -A "$(hostname)" 2>&1 | tail -3 || true
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || true
fi

echo "[fw] starting sshd"
exec /usr/sbin/sshd -D -e
