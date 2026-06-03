#!/bin/bash
set -e

SSH_USER="${SSH_USER:-ccc}"
SSH_PASS="${SSH_PASS:-ccc}"
WAZUH_MANAGER="${WAZUH_MANAGER:-10.20.32.100}"
IPS_PIPE_IP="${IPS_PIPE_IP:-10.20.31.2}"

if ! id "$SSH_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo "$SSH_USER"
    echo "${SSH_USER}:${SSH_PASS}" | chpasswd
    echo "$SSH_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/$SSH_USER
fi

# bastion pubkey → ccc authorized_keys (ProxyJump 의 첫 hop). 학생 환경마다 다른 키.
if [ -f /keys/id_rsa.pub ]; then
    mkdir -p /home/$SSH_USER/.ssh
    cat /keys/id_rsa.pub > /home/$SSH_USER/.ssh/authorized_keys
    chown -R $SSH_USER:$SSH_USER /home/$SSH_USER/.ssh
    chmod 700 /home/$SSH_USER/.ssh
    chmod 600 /home/$SSH_USER/.ssh/authorized_keys
    echo "[fw] authorized_keys deployed — bastion 의 password-less ssh 가능"
fi

# ─── Routing: dmz/int 은 ips 경유 ───────────────────────
echo "[fw] adding routes (dmz/int via ips $IPS_PIPE_IP)"
ip route add 10.20.32.0/24 via "$IPS_PIPE_IP" 2>/dev/null || true
ip route add 10.20.40.0/24 via "$IPS_PIPE_IP" 2>/dev/null || true

# ─── nftables ─────────────────────────────────────────
echo "[fw] applying nftables (six_filter / six_nat tables)"
nft -f /etc/nftables.conf 2>&1 | sed 's/^/  /' || echo "[fw] WARN: nft apply failed"

# ─── HAProxy self-signed cert (for 443 termination) ────
if [ ! -f /etc/haproxy/certs/server.pem ]; then
    echo "[fw] generating HAProxy self-signed cert"
    mkdir -p /etc/haproxy/certs
    openssl req -x509 -nodes -days 730 -newkey rsa:2048 \
        -keyout /tmp/server.key -out /tmp/server.crt \
        -subj "/CN=*.6v6.lab/O=6v6/C=KR" 2>/dev/null
    cat /tmp/server.crt /tmp/server.key > /etc/haproxy/certs/server.pem
    chmod 600 /etc/haproxy/certs/server.pem
    rm -f /tmp/server.key /tmp/server.crt
fi

# ─── HAProxy 기동 ──────────────────────────────────────
echo "[fw] starting HAProxy (L7 host-header routing)"
haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | sed 's/^/  /' || true
haproxy -f /etc/haproxy/haproxy.cfg -D &

# ─── Wazuh agent ────────────────────────────────────────
if [ -d /var/ossec ]; then
    echo "[fw] configuring Wazuh agent (manager=$WAZUH_MANAGER)"
    sed -i "s|<address>.*</address>|<address>$WAZUH_MANAGER</address>|" /var/ossec/etc/ossec.conf

    if ! grep -q '/var/log/syslog' /var/ossec/etc/ossec.conf; then
        sed -i '/<\/ossec_config>/i\
  <localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/syslog</location>\n  </localfile>' /var/ossec/etc/ossec.conf
    fi

    # 6v6-assessor: FIM(nftables/haproxy/실습 디렉터리) + 명령 로깅 localfile (정적·cohort-free, 멱등)
    if ! grep -q '6v6-assessor-collection' /var/ossec/etc/ossec.conf; then
        __fimblk=$(mktemp)
        cat > "$__fimblk" <<'FIMBLK'
  <!-- 6v6-assessor-collection: FIM + cmdlog localfile (정적·cohort-free) -->
  <syscheck>
    <disabled>no</disabled>
    <frequency>300</frequency>
    <scan_on_start>yes</scan_on_start>
    <directories realtime="yes" report_changes="yes" whodata="yes">/etc/nftables.conf</directories>
    <directories realtime="yes" report_changes="yes" whodata="yes">/etc/haproxy</directories>
    <directories realtime="yes" report_changes="yes">/home/ccc</directories>
  </syscheck>
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/6v6-cmd.log</location>
  </localfile>
FIMBLK
        __awktmp=$(mktemp)
        awk 'NR==FNR{ins=ins $0 ORS; next} /<\/ossec_config>/ && !d{printf "%s",ins; d=1} {print}' \
            "$__fimblk" /var/ossec/etc/ossec.conf > "$__awktmp" && \
            cat "$__awktmp" > /var/ossec/etc/ossec.conf
        rm -f "$__fimblk" "$__awktmp"
        echo "[fw] ★ Assessor 수집(FIM + cmdlog localfile) 주입"
    fi

    echo "[fw] waiting for Wazuh manager $WAZUH_MANAGER:1515..."
    for i in $(seq 1 30); do
        if (echo > /dev/tcp/$WAZUH_MANAGER/1515) 2>/dev/null; then
            echo "[fw]   manager ready"
            break
        fi
        sleep 2
    done

    /var/ossec/bin/agent-auth -m "$WAZUH_MANAGER" -A "$(hostname)" 2>&1 | tail -3 || true
    /var/ossec/bin/wazuh-control start 2>&1 | sed 's/^/  /' || true
fi

# ── 6v6 명령 로깅(채점/감사용, cohort-free 정적) ──────────────────────────
: > /var/log/6v6-cmd.log 2>/dev/null || true
chmod 0666 /var/log/6v6-cmd.log 2>/dev/null || true
cat > /etc/profile.d/6v6-cmdlog.sh <<'CMDLOG'
# 6v6: 대화형 셸 명령 로깅(채점/감사). CC/tubewar 가 Assessor command_ran 으로 질의.
case "$-" in *i*) ;; *) return 2>/dev/null ;; esac
__6v6_cmdlog() {
  local rc=$? last
  last=$(history 1 2>/dev/null | sed 's/^ *[0-9]* *//')
  [ -z "$last" ] && return
  local msg="CMD6V6 host=$(hostname) user=${USER:-?} pwd=$PWD rc=$rc cmd=$last"
  logger -p local6.info -t 6v6audit "$msg" 2>/dev/null
  printf '%s %s 6v6audit: %s\n' "$(date '+%b %e %H:%M:%S')" "$(hostname)" "$msg" >> /var/log/6v6-cmd.log 2>/dev/null
}
case ";${PROMPT_COMMAND};" in
  *__6v6_cmdlog*) ;;
  *) PROMPT_COMMAND="__6v6_cmdlog;${PROMPT_COMMAND}" ;;
esac
CMDLOG

echo "[fw] starting sshd"
exec /usr/sbin/sshd -D -e
