# 6v6 secu — nftables + Suricata IDS (단일 컨테이너)
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        nftables ipset \
        suricata suricata-update \
        curl jq vim less tcpdump \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd /var/log/suricata && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY secu/nftables.conf /etc/nftables.conf
COPY secu/suricata-local.rules /etc/suricata/rules/local.rules
COPY secu/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
