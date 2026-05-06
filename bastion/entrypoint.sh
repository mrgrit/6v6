#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

# 사용자 생성 (이미 있으면 skip)
if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# ~/.ssh/config 자동 생성 — ProxyJump alias
mkdir -p /home/$SSH_USER/.ssh
cat > /home/$SSH_USER/.ssh/config <<SSHCFG
Host 6v6-secu secu
    HostName 10.20.30.1
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host 6v6-web web
    HostName 10.20.30.80
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host 6v6-siem siem
    HostName 10.20.30.100
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host 6v6-attacker attacker
    HostName 10.20.30.202
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null

Host 6v6-portal portal
    HostName 10.20.30.50
    User $SSH_USER
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHCFG
chmod 600 /home/$SSH_USER/.ssh/config
chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh

# 로그인 배너
cat > /etc/motd <<MOTD
========================================================
  6v6 Bastion — CCC 인프라 단일 진입점
========================================================
사용 가능한 ProxyJump alias:
  ssh secu       (10.20.30.1)
  ssh web        (10.20.30.80)
  ssh siem       (10.20.30.100)
  ssh attacker   (10.20.30.202)
  ssh portal     (10.20.30.50)

API:  http://localhost:9100/health
========================================================
MOTD

# Bastion API 백그라운드 기동
echo "[bastion] starting API on :9100"
cd /opt/bastion-api && \
    python3 -m uvicorn api:app --host 0.0.0.0 --port 9100 \
        > /var/log/bastion-api.log 2>&1 &

# sshd foreground
echo "[bastion] starting sshd"
exec /usr/sbin/sshd -D -e
