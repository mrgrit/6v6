#!/bin/sh
# cont-init: HAProxy de-NAT decoder + rules 적용 (wazuh etc volume mask 대응, 매 시작 copy)
# 6v6 결함수정(2026-05-25): fw HAProxy 가 원본 client IP 를 SIEM:514 전송 → NAT 뒤 진짜 출처 복원
set -e
IMG_DEC=/opt/haproxy-denat-decoder.xml; IMG_RULES=/opt/haproxy-denat-rules.xml
DST_DEC=/var/ossec/etc/decoders/haproxy-denat-decoder.xml; DST_RULES=/var/ossec/etc/rules/haproxy-denat-rules.xml
if [ -f "$IMG_DEC" ] && [ -f "$IMG_RULES" ]; then
  cp -f "$IMG_DEC" "$DST_DEC"; cp -f "$IMG_RULES" "$DST_RULES"
  chown root:wazuh "$DST_DEC" "$DST_RULES" 2>/dev/null || true
  chmod 660 "$DST_DEC" "$DST_RULES" 2>/dev/null || true
  echo "[siem] HAProxy de-NAT decoder + rules applied"
fi
