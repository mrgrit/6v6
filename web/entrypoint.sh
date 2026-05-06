#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,www-data "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# Self-signed cert (없으면 생성)
if [ ! -f /etc/apache2/ssl/server.crt ]; then
    echo "[web] generating self-signed cert"
    mkdir -p /etc/apache2/ssl
    openssl req -x509 -nodes -days 730 \
        -newkey rsa:2048 \
        -keyout /etc/apache2/ssl/server.key \
        -out    /etc/apache2/ssl/server.crt \
        -subj "/CN=6v6-web/O=6v6/C=KR" 2>/dev/null
    chmod 600 /etc/apache2/ssl/server.key
fi

# Apache 의 ServerName warning 회피
echo "ServerName web" >> /etc/apache2/apache2.conf

# Apache foreground
echo "[web] starting apache2"
apache2ctl configtest 2>&1 | sed 's/^/  /'
apache2ctl -D FOREGROUND &

# sshd foreground
echo "[web] starting sshd"
exec /usr/sbin/sshd -D -e
