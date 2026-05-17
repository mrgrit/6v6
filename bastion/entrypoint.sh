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

# secuops/W08-S1 의 'docker ps' 학생 명령 위해 ccc 를 docker group 에 추가.
# /var/run/docker.sock 의 GID 와 일치하는 group 생성 + ccc 추가.
if [ -S /var/run/docker.sock ]; then
    DOCKER_GID=$(stat -c %g /var/run/docker.sock)
    if ! getent group docker >/dev/null 2>&1; then
        groupadd -g "$DOCKER_GID" docker 2>/dev/null || true
    else
        groupmod -g "$DOCKER_GID" docker 2>/dev/null || true
    fi
    usermod -aG docker "$SSH_USER" 2>/dev/null || true
    echo "[bastion] ccc → docker group (GID=$DOCKER_GID) — secuops W08 의 docker ps 가능"
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

Host 6v6-siem siem
    HostName 10.20.32.100
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ProxyJump 6v6-fw

# W11 학습용 — sysmon-host (ext network, systemd 컨테이너)
Host 6v6-sysmon-host sysmon-host
    HostName 10.20.30.210
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

# Wazuh Dashboard (https UI, no SSH): https://siem.6v6.lab/
#   admin / SecretPassword
SSHCFG
chmod 600 /home/$SSH_USER/.ssh/config
chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh

# /keys (호스트 ./keys bind mount, RO) → ccc 의 id_rsa + authorized_keys 배포. bastion
# 은 양쪽 모두 보유 (id_rsa = ProxyJump client key, authorized_keys = bastion 자체 로그인).
# 학생 신규 배포 시 6v6.sh 가 ssh-keygen 자동 생성하여 /keys 채움.
if [ -f /keys/id_rsa ] && [ -f /keys/id_rsa.pub ]; then
    cp /keys/id_rsa     /home/$SSH_USER/.ssh/id_rsa
    cp /keys/id_rsa.pub /home/$SSH_USER/.ssh/id_rsa.pub
    cat /keys/id_rsa.pub > /home/$SSH_USER/.ssh/authorized_keys
    chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh
    chmod 600 /home/$SSH_USER/.ssh/id_rsa /home/$SSH_USER/.ssh/authorized_keys
    chmod 644 /home/$SSH_USER/.ssh/id_rsa.pub
    echo "[bastion] SSH key deployed (id_rsa + authorized_keys) — password-less ssh 6v6-fw 가능"
else
    echo "[bastion] WARN: /keys/id_rsa 없음 — 6v6.sh up 의 ensure_ssh_keys 실행 안 됨? password ssh 로 fallback."
fi

cat > /etc/motd <<MOTD
========================================================
  6v6 Bastion - single entry point for the lab
========================================================
ProxyJump aliases: ssh secu | ssh web | ssh attacker
SIEM via ssh 6v6-siem (ProxyJump fw) or Wazuh dashboard https://siem.6v6.lab/
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
