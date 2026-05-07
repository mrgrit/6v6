#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
SIEM_HOST="${SIEM_HOST:-10.20.32.100}"
DEFAULT_GW="${DEFAULT_GW:-10.20.30.1}"

# Default route via fw (so packets to dmz/int go through chain)
echo "[bastion] setting default route via $DEFAULT_GW (fw)"
ip route del default 2>/dev/null || true
ip route add default via "$DEFAULT_GW" 2>/dev/null || true

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# ~/.ssh/config — ProxyJump aliases
mkdir -p /home/$SSH_USER/.ssh
cat > /home/$SSH_USER/.ssh/config <<SSHCFG
# 4-tier chained topology — direct/jump aliases
Host 6v6-fw fw
    HostName 10.20.30.1
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host 6v6-attacker attacker
    HostName 10.20.30.202
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

# pipe/dmz/int reachable via fw (route forwarding is in place)
Host 6v6-ips ips
    HostName 10.20.31.2
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyJump 6v6-fw

Host 6v6-web web
    HostName 10.20.32.80
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyJump 6v6-fw

Host 6v6-portal portal
    HostName 10.20.32.50
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyJump 6v6-fw

# Note: 6v6-siem (wazuh-manager official image) has no sshd. Access via:
#   docker exec -it 6v6-siem bash    (from VM host)
#   https://siem.6v6.lab/             (real Wazuh dashboard, admin/SecretPassword)
SSHCFG
chmod 600 /home/$SSH_USER/.ssh/config
chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh

cat > /etc/motd <<MOTD
========================================================
  6v6 Bastion - single entry point for the lab
========================================================
ProxyJump aliases: ssh secu | ssh web | ssh attacker
SIEM (Wazuh manager) has no SSH (official image) -
  Use: docker exec -it 6v6-siem bash  (from VM host)
  Or:  https://siem.6v6.lab/         (real Wazuh dashboard)
API: http://localhost:9100/health
========================================================
MOTD

# rsyslog forward (syslog paradigm) - bastion auth/system -> siem:514/udp
echo "[bastion] configuring rsyslog forward -> $SIEM_HOST:514/udp"
cat > /etc/rsyslog.d/50-forward-siem.conf <<RSYSLOG
# 6v6: bastion -> siem syslog forward (syslog paradigm vs Wazuh agent)
*.*  @${SIEM_HOST}:514
RSYSLOG

service rsyslog restart 2>/dev/null || service rsyslog start 2>/dev/null || true

echo "[bastion] starting Bastion API on :9100"
cd /opt/bastion-api && \
    python3 -m uvicorn api:app --host 0.0.0.0 --port 9100 \
        > /var/log/bastion-api.log 2>&1 &

# sshd auth events -> syslog
sed -i 's|^#SyslogFacility.*|SyslogFacility AUTH|' /etc/ssh/sshd_config
sed -i 's|^#LogLevel.*|LogLevel INFO|' /etc/ssh/sshd_config

echo "[bastion] starting sshd"
exec /usr/sbin/sshd -D -e
