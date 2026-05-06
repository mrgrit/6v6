#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# bash 로그인 시 motd 출력
sed -i 's|^#PrintMotd.*|PrintMotd yes|' /etc/ssh/sshd_config
echo "cat /etc/motd 2>/dev/null" >> /home/$SSH_USER/.bashrc

echo "[attacker] starting sshd"
exec /usr/sbin/sshd -D -e
