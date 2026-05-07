#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
# Default to siem's static IP (avoids DNS-resolution issues if docker DNS is broken)
WAZUH_MANAGER="${WAZUH_MANAGER:-10.20.30.100}"
if [[ ! "$WAZUH_MANAGER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    RES_IP=$(getent hosts "$WAZUH_MANAGER" 2>/dev/null | awk '{print $1}' | head -1)
    [ -n "$RES_IP" ] && WAZUH_MANAGER="$RES_IP" || WAZUH_MANAGER="10.20.30.100"
fi

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# nftables ruleset (NET_ADMIN cap required)
echo "[secu] applying nftables ruleset (6v6_filter table)"
nft -f /etc/nftables.conf 2>&1 | sed 's/^/  /' || echo "[secu] WARN: nft apply failed (NET_ADMIN cap?)"

echo "[secu] updating Suricata rules (5-10s)"
suricata-update --no-test 2>&1 | tail -3 || true

if ! grep -q 'local.rules' /etc/suricata/suricata.yaml; then
    sed -i 's|^rule-files:|rule-files:\n  - local.rules|' /etc/suricata/suricata.yaml || true
fi

# auto-detect sniff iface (the one with 10.20.30.x IP)
IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.20\.30\./ {print $2; exit}')
[ -z "$IFACE" ] && IFACE="eth0"

mkdir -p /var/log/suricata
echo "[secu] starting Suricata on iface=$IFACE"
suricata -i "$IFACE" -c /etc/suricata/suricata.yaml \
    --runmode autofp -l /var/log/suricata \
    > /var/log/suricata/stdout.log 2>&1 &

# --- Wazuh agent: configure + register + start --------------------------
if [ -d /var/ossec ]; then
    echo "[secu] configuring Wazuh agent (manager=$WAZUH_MANAGER)"
    sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" /var/ossec/etc/ossec.conf

    if ! grep -q '/var/log/suricata/eve.json' /var/ossec/etc/ossec.conf; then
        sed -i '/<\/ossec_config>/i\
  <localfile>\n    <log_format>json</log_format>\n    <location>/var/log/suricata/eve.json</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/syslog</location>\n  </localfile>' /var/ossec/etc/ossec.conf
    fi

    echo "[secu] waiting for Wazuh manager $WAZUH_MANAGER:1515..."
    for i in $(seq 1 30); do
        if (echo > /dev/tcp/$WAZUH_MANAGER/1515) 2>/dev/null; then
            echo "[secu]   manager ready"
            break
        fi
        sleep 2
    done

    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -A "$(hostname)" 2>&1 | tail -3 || \
        echo "[secu] WARN: agent-auth failed"

    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || \
        echo "[secu] WARN: wazuh-control start failed"
fi

echo "[secu] starting sshd"
exec /usr/sbin/sshd -D -e
