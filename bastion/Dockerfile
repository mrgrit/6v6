# 6v6 bastion — SSH 점프 호스트 + Bastion API + rsyslog forward (syslog 패러다임)
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 dnsutils \
        rsyslog \
        curl wget jq python3 python3-pip ca-certificates \
        vim less tmux htop \
        gnupg lsb-release && \
    rm -rf /var/lib/apt/lists/*

# Docker CLI (read-only docker.sock + docker ps 학생 가시화용)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu jammy stable" \
        > /etc/apt/sources.list.d/docker.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# osquery (W07 호스트 가시화)
RUN curl -L https://pkg.osquery.io/deb/pubkey.gpg | \
        gpg --dearmor -o /etc/apt/keyrings/osquery.gpg && \
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/osquery.gpg] https://pkg.osquery.io/deb deb main" \
        > /etc/apt/sources.list.d/osquery.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends osquery && \
    rm -rf /var/lib/apt/lists/*

RUN pip3 install --no-cache-dir fastapi uvicorn[standard] httpx pydantic

RUN mkdir -p /run/sshd /var/lib/bastion && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY bastion/api.py /opt/bastion-api/api.py
COPY bastion/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 9100
ENTRYPOINT ["/entrypoint.sh"]
