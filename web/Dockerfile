# 6v6 web — Apache 2.4 + ModSecurity v2 + OWASP CRS + 랜딩 페이지 + JuiceShop reverse proxy
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        apache2 libapache2-mod-security2 modsecurity-crs \
        ssl-cert openssl ca-certificates \
        curl jq vim less && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd /var/www/landing /etc/apache2/ssl && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# Apache 모듈 활성화
RUN a2enmod proxy proxy_http proxy_wstunnel headers ssl rewrite security2 && \
    a2dissite 000-default || true

# ModSecurity SecRuleEngine On
RUN sed -i 's|^SecRuleEngine .*|SecRuleEngine On|' /etc/modsecurity/modsecurity.conf 2>/dev/null || \
    cp /etc/modsecurity/modsecurity.conf-recommended /etc/modsecurity/modsecurity.conf 2>/dev/null && \
    sed -i 's|^SecRuleEngine .*|SecRuleEngine On|' /etc/modsecurity/modsecurity.conf

# CRS include — Debian 패키지가 mods-enabled/security2.conf 로 자동 추가하지만
# 명시적으로 IncludeOptional 다시 한 번 등록.
RUN echo 'IncludeOptional /usr/share/modsecurity-crs/owasp-crs.load' >> /etc/apache2/mods-enabled/security2.conf 2>/dev/null || true

# 랜딩 페이지 + vhost 정적 파일
COPY web/landing/ /var/www/landing/
COPY web/vhosts/ /etc/apache2/sites-available/

# 모든 vhost 활성화
RUN a2ensite 000-landing 010-juice 020-tls

COPY web/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 80 443
ENTRYPOINT ["/entrypoint.sh"]
