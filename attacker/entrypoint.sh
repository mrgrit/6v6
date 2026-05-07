#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
SIEM_HOST="${SIEM_HOST:-10.20.32.100}"
DEFAULT_GW="${DEFAULT_GW:-10.20.30.1}"

# Default route via fw (so packets to dmz/int go through chain)
echo "[attacker] setting default route via $DEFAULT_GW (fw)"
ip route del default 2>/dev/null || true
ip route add default via "$DEFAULT_GW" 2>/dev/null || true

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

sed -i 's|^#PrintMotd.*|PrintMotd yes|' /etc/ssh/sshd_config
echo "cat /etc/motd 2>/dev/null" >> /home/$SSH_USER/.bashrc

echo "[attacker] configuring rsyslog forward -> $SIEM_HOST:514/udp"
cat > /etc/rsyslog.d/50-forward-siem.conf <<RSYSLOG
# 6v6: attacker -> siem syslog forward (syslog paradigm vs Wazuh agent)
*.*  @${SIEM_HOST}:514
RSYSLOG
service rsyslog restart 2>/dev/null || service rsyslog start 2>/dev/null || true

sed -i 's|^#SyslogFacility.*|SyslogFacility AUTH|' /etc/ssh/sshd_config
sed -i 's|^#LogLevel.*|LogLevel INFO|' /etc/ssh/sshd_config

echo "[attacker] starting sshd"
exec /usr/sbin/sshd -D -e
