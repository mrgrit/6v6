# 6v6 ips — inline IPS: pipe <-> dmz forwarding + Suricata sniff.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        suricata suricata-update \
        nftables \
        curl wget gnupg lsb-release \
        jq vim less tcpdump \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Wazuh agent — Suricata eve.json shipped via agent
RUN curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | \
        gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && \
    chmod 644 /usr/share/keyrings/wazuh.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
        > /etc/apt/sources.list.d/wazuh.list && \
    apt-get update && \
    WAZUH_MANAGER="10.20.32.100" apt-get install -y --no-install-recommends wazuh-agent=4.10.1-1 && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd /var/log/suricata && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY ips/suricata-local.rules /etc/suricata/rules/local.rules
COPY ips/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
