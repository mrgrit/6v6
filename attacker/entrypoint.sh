#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
SIEM_HOST="${SIEM_HOST:-siem}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

sed -i 's|^#PrintMotd.*|PrintMotd yes|' /etc/ssh/sshd_config
echo "cat /etc/motd 2>/dev/null" >> /home/$SSH_USER/.bashrc

# rsyslog forward — attacker 활동 로그도 SIEM 에 (syslog 패러다임 학습)
echo "[attacker] configuring rsyslog forward → $SIEM_HOST:514/udp"
cat > /etc/rsyslog.d/50-forward-siem.conf <<RSYSLOG
# 6v6: attacker → siem syslog forward
*.*  @${SIEM_HOST}:514
RSYSLOG
service rsyslog restart 2>/dev/null || service rsyslog start 2>/dev/null || true

# sshd 의 auth event 도 syslog 로
sed -i 's|^#SyslogFacility.*|SyslogFacility AUTH|' /etc/ssh/sshd_config
sed -i 's|^#LogLevel.*|LogLevel INFO|' /etc/ssh/sshd_config

echo "[attacker] starting sshd"
exec /usr/sbin/sshd -D -e
