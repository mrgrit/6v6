#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
WAZUH_MANAGER="${WAZUH_MANAGER:-10.20.32.100}"
FW_PIPE_IP="${FW_PIPE_IP:-10.20.31.1}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# bastion pubkey → ccc authorized_keys (ProxyJump 의 2-hop)
if [ -f /keys/id_rsa.pub ]; then
    mkdir -p /home/$SSH_USER/.ssh
    cat /keys/id_rsa.pub > /home/$SSH_USER/.ssh/authorized_keys
    chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh
    chmod 700 /home/$SSH_USER/.ssh
    chmod 600 /home/$SSH_USER/.ssh/authorized_keys
    echo "[ips] authorized_keys deployed — bastion 의 password-less ssh 가능"
fi

# ─── Routing: ext (10.20.30/24) -> back via fw on pipe ────
echo "[ips] adding return route to ext via fw $FW_PIPE_IP"
ip route add 10.20.30.0/24 via "$FW_PIPE_IP" 2>/dev/null || true

# ─── NAT: masquerade so dmz services reply to ips (not their default GW) ──
echo "[ips] enabling NAT masquerade on dmz NIC"
DMZ_IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.20\.32\./ {print $2; exit}')
nft "add table ip nat6v6" 2>/dev/null || true
nft "add chain ip nat6v6 postrouting { type nat hook postrouting priority 100 ; }" 2>/dev/null || true
nft "add rule ip nat6v6 postrouting oifname \"$DMZ_IFACE\" ip saddr 10.20.30.0/24 masquerade" 2>/dev/null || true
nft "add rule ip nat6v6 postrouting oifname \"$DMZ_IFACE\" ip saddr 10.20.31.0/24 masquerade" 2>/dev/null || true
# int (10.20.40/24) is reached via web (dmz NIC = 10.20.32.80) — but web does L7
# proxy, not L3 forward. ips doesn't need a route to int — incoming TCP to dmz
# 10.20.32.80 (web) terminates there.

# ─── Suricata 룰 update + sniff both pipe + dmz ────────────
echo "[ips] updating Suricata rules (5-10s)"
suricata-update --no-test 2>&1 | tail -3 || true

if ! grep -q 'local.rules' /etc/suricata/suricata.yaml; then
    sed -i 's|^rule-files:|rule-files:\n  - local.rules|' /etc/suricata/suricata.yaml || true
fi

# Detect interfaces
PIPE_IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.20\.31\./ {print $2; exit}')
DMZ_IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.20\.32\./ {print $2; exit}')
echo "[ips] sniff interfaces: pipe=$PIPE_IFACE dmz=$DMZ_IFACE"

mkdir -p /var/log/suricata
# af-packet on both interfaces (forward path is in pipe→dmz, return is dmz→pipe)
suricata -i "$PIPE_IFACE" -i "$DMZ_IFACE" -c /etc/suricata/suricata.yaml \
    --runmode autofp -l /var/log/suricata \
    > /var/log/suricata/stdout.log 2>&1 &

# ─── Wazuh agent ───────────────────────────────────────
if [ -d /var/ossec ]; then
    echo "[ips] configuring Wazuh agent (manager=$WAZUH_MANAGER)"
    sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" /var/ossec/etc/ossec.conf

    if ! grep -q '/var/log/suricata/eve.json' /var/ossec/etc/ossec.conf; then
        sed -i '/<\/ossec_config>/i\
  <localfile>\n    <log_format>json</log_format>\n    <location>/var/log/suricata/eve.json</location>\n  </localfile>\n  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/syslog</location>\n  </localfile>' /var/ossec/etc/ossec.conf
    fi

    echo "[ips] waiting for Wazuh manager $WAZUH_MANAGER:1515..."
    for i in $(seq 1 30); do
        if (echo > /dev/tcp/$WAZUH_MANAGER/1515) 2>/dev/null; then
            echo "[ips]   manager ready"
            break
        fi
        sleep 2
    done

    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -A "$(hostname)" 2>&1 | tail -3 || true
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || true
fi

echo "[ips] starting sshd"
exec /usr/sbin/sshd -D -e
