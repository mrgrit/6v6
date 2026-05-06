# 6v6 bastion — SSH 점프 호스트 + 간단 Bastion API placeholder
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 dnsutils \
        curl wget jq python3 python3-pip ca-certificates \
        vim less tmux htop && \
    rm -rf /var/lib/apt/lists/*

# Bastion API 의 의존성
RUN pip3 install --no-cache-dir fastapi uvicorn[standard] httpx pydantic

# sshd 가 PrivilegeSeparation 디렉토리 요구
RUN mkdir -p /run/sshd /var/lib/bastion && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY bastion/api.py /opt/bastion-api/api.py
COPY bastion/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 9100
ENTRYPOINT ["/entrypoint.sh"]
