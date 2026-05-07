# 6v6 web — Apache 2.4 + ModSecurity v2 + OWASP CRS + 랜딩 + 7 vuln reverse proxy + Wazuh agent
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        apache2 libapache2-mod-security2 modsecurity-crs \
        ssl-cert openssl ca-certificates gnupg lsb-release \
        curl wget jq vim less && \
    rm -rf /var/lib/apt/lists/*

# Wazuh agent (web → Wazuh manager 로 Apache + ModSec 로그 전송)
RUN curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && \
    chmod 644 /usr/share/keyrings/wazuh.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list && \
    apt-get update && \
    WAZUH_MANAGER="siem" apt-get install -y --no-install-recommends wazuh-agent && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd /var/www/landing /etc/apache2/ssl && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Apache 모듈
RUN a2enmod proxy proxy_http proxy_wstunnel headers ssl rewrite security2 && \
    a2dissite 000-default || true

# ModSecurity 활성화 + audit log JSON 형식 (Wazuh 에서 decoder 처리 친화)
RUN if [ ! -f /etc/modsecurity/modsecurity.conf ]; then \
        cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf || true; \
    fi && \
    sed -i 's|^SecRuleEngine .*|SecRuleEngine On|' /etc/modsecurity/modsecurity.conf && \
    sed -i 's|^SecAuditLogFormat .*|SecAuditLogFormat JSON|' /etc/modsecurity/modsecurity.conf && \
    sed -i 's|^SecAuditEngine .*|SecAuditEngine RelevantOnly|' /etc/modsecurity/modsecurity.conf && \
    sed -i 's|^SecAuditLog .*|SecAuditLog /var/log/apache2/modsec_audit.log|' /etc/modsecurity/modsecurity.conf

# 랜딩 페이지 + vhost
COPY web/landing/ /var/www/landing/
COPY web/vhosts/ /etc/apache2/sites-available/

# 모든 vhost 활성화
RUN cd /etc/apache2/sites-available && \
    for f in *.conf; do a2ensite "$f"; done

# Wazuh agent ossec.conf — Apache + ModSec localfile 추가
COPY web/wazuh-agent.conf.append /tmp/wazuh-agent.conf.append

COPY web/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 80 443
ENTRYPOINT ["/entrypoint.sh"]
