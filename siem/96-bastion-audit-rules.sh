#!/bin/sh
# cont-init: bastion audit decoder + rules 를 wazuh manager 에 강제 적용
# (wazuh-manager-etc volume 이 image 의 /var/ossec/etc 를 가릴 수 있어 매 시작 시 copy)

set -e

# /tmp 에 image build 시 보존한 원본 가져오기
IMG_DECODER=/opt/bastion-audit-decoder.xml
IMG_RULES=/opt/bastion-audit-rules.xml

# wazuh etc volume 의 실제 경로
DST_DECODER=/var/ossec/etc/decoders/bastion-audit-decoder.xml
DST_RULES=/var/ossec/etc/rules/bastion-audit-rules.xml

if [ -f "$IMG_DECODER" ] && [ -f "$IMG_RULES" ]; then
    cp -f "$IMG_DECODER" "$DST_DECODER"
    cp -f "$IMG_RULES" "$DST_RULES"
    chown root:wazuh "$DST_DECODER" "$DST_RULES" 2>/dev/null || true
    chmod 660 "$DST_DECODER" "$DST_RULES" 2>/dev/null || true
    echo "[siem] ★ bastion audit decoder + rules applied"
fi

# syslog remote (514/udp from 10.20.0.0/16) 강제 설정
OSSEC_CONF=/var/ossec/etc/ossec.conf
if [ -f "$OSSEC_CONF" ] && ! grep -q "bastion-audit-syslog" "$OSSEC_CONF"; then
    # </global> 뒤에 syslog remote block 삽입
    sed -i '/<\/global>/a\
  <!-- bastion-audit-syslog: bastion 의 rsyslog 514/udp 수신 -->\
  <remote>\
    <connection>syslog</connection>\
    <port>514</port>\
    <protocol>udp</protocol>\
    <allowed-ips>10.20.0.0/16</allowed-ips>\
  </remote>' "$OSSEC_CONF" 2>/dev/null || true
    echo "[siem] ★ ossec.conf updated — syslog remote :514/udp from 10.20.0.0/16"
fi

# Wazuh API rate limit 상향 — default 300/min 은 bastion lifecycle alert + dashboard
# health check 합산 시 429 (No API available to connect) 발생. 5000/min 으로 영구 상향.
API_CONF=/var/ossec/api/configuration/api.yaml
if [ -f "$API_CONF" ] && ! grep -q "max_request_per_minute: 5000" "$API_CONF"; then
    cat >> "$API_CONF" <<'API_RATE_EOF'

# bastion lifecycle + dashboard health 다수 호출 → default 300 부족 (6v6 deploy default)
access:
  max_request_per_minute: 5000
  max_login_attempts: 50
  block_time: 30
API_RATE_EOF
    echo "[siem] ★ api.yaml updated — access.max_request_per_minute=5000"
fi
