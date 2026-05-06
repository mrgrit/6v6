# 6v6 attacker — pentest 도구 모음
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        nmap hydra sqlmap nikto \
        curl wget jq dnsutils whois \
        netcat-openbsd ncat socat \
        python3 python3-pip git \
        vim less tmux htop \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Python pentest 도구
RUN pip3 install --no-cache-dir requests beautifulsoup4 pwntools

# Metasploit framework (선택 — image size +800MB)
# 학습 환경 기본은 omit. 필요 시 BUILD_WITH_MSF=1 빌드 args 로 활성:
ARG BUILD_WITH_MSF=0
RUN if [ "$BUILD_WITH_MSF" = "1" ]; then \
        curl -sSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb -o /tmp/msfinstall && \
        chmod +x /tmp/msfinstall && /tmp/msfinstall || echo "msf install skipped"; \
    fi

RUN mkdir -p /run/sshd && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY attacker/entrypoint.sh /entrypoint.sh
COPY attacker/motd /etc/motd
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
