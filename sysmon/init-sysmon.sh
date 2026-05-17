#!/bin/bash
# sysmon-host 컨테이너 init — sysmon -i config.xml + ssh key 배포 + sshd 시작
set -e

# /keys (bastion pubkey) 가 마운트 되어 있으면 ccc 의 authorized_keys 배포 (bastion → sysmon-host 의 password-less ssh)
if [ -f /keys/id_rsa.pub ]; then
    mkdir -p /home/ccc/.ssh
    cat /keys/id_rsa.pub > /home/ccc/.ssh/authorized_keys
    chown -R ccc:ccc /home/ccc/.ssh
    chmod 700 /home/ccc/.ssh
    chmod 600 /home/ccc/.ssh/authorized_keys
    echo "[sysmon-host] authorized_keys deployed — bastion 의 password-less ssh 가능"
fi

# sysmon -i config.xml (service 등록 + 시작). 이미 등록되어 있으면 skip.
if ! systemctl is-enabled sysmon >/dev/null 2>&1; then
    sysmon -accepteula -i /opt/sysmon/config.xml 2>&1 | tail -5
fi

# sshd 시작
/usr/sbin/sshd -D -e &
SSHD_PID=$!
echo "[sysmon-host] sshd started pid=$SSHD_PID"

# systemd service 의 ExecStart 로는 fg blocking 필요 → wait
wait $SSHD_PID
