#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"

# 사용자
if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# nftables ruleset 적용 (NET_ADMIN cap 있어야 동작)
echo "[secu] applying nftables ruleset"
nft -f /etc/nftables.conf 2>&1 | sed 's/^/  /' || echo "[secu] WARN: nft 적용 실패 (NET_ADMIN cap 확인)"

# Suricata 룰 업데이트 — 첫 부팅 시 ET Open 등 다운로드.
# 학습 환경이라 시간 절약 위해 quiet, 실패해도 local.rules 로 동작.
echo "[secu] updating Suricata rules (first run downloads ~50MB)"
suricata-update --no-test 2>&1 | tail -3 || echo "[secu] suricata-update 실패 — local.rules 만 사용"

# Suricata config — local.rules 추가 보장
if ! grep -q 'local.rules' /etc/suricata/suricata.yaml; then
    sed -i 's|^rule-files:|rule-files:\n  - local.rules|' /etc/suricata/suricata.yaml || true
fi

# Suricata sniff iface — docker bridge 의 NIC 자동 감지
IFACE=$(ip -o -4 addr show | awk '$4 ~ /^10\.20\.30\./ {print $2; exit}')
[ -z "$IFACE" ] && IFACE="eth0"
echo "[secu] starting Suricata on iface=$IFACE"

# Suricata foreground 백그라운드 (sshd 가 메인)
mkdir -p /var/log/suricata
suricata -i "$IFACE" -c /etc/suricata/suricata.yaml \
    --runmode autofp -l /var/log/suricata \
    > /var/log/suricata/stdout.log 2>&1 &

# sshd foreground
echo "[secu] starting sshd"
exec /usr/sbin/sshd -D -e
