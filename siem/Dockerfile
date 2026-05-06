# 6v6 siem — Wazuh manager + 학습용 simple alert viewer (5601) + cti-collector
# 풀 Wazuh 3-stack (manager+indexer+dashboard) 대신 manager 단독 + 자체 viewer 로 경량화.
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        curl wget gnupg ca-certificates lsb-release \
        python3 python3-pip jq vim less rsyslog && \
    rm -rf /var/lib/apt/lists/*

# Wazuh manager 4.7.x 설치 (단독 — 별도 indexer/dashboard 없이)
RUN curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --no-default-keyring --keyring gnupg-ring:/usr/share/keyrings/wazuh.gpg --import && \
    chmod 644 /usr/share/keyrings/wazuh.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends wazuh-manager && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir flask

RUN mkdir -p /run/sshd /var/lib/siem && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY siem/alert_viewer.py /opt/alert_viewer.py
COPY siem/cti_collector.py /opt/cti_collector.py
COPY siem/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 5601 1514 1515
ENTRYPOINT ["/entrypoint.sh"]
