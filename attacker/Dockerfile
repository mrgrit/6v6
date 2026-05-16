# 6v6 attacker — pentest 도구 + rsyslog forward (syslog 패러다임)
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        openssh-server sudo iputils-ping iproute2 \
        rsyslog \
        nmap hydra sqlmap nikto \
        dirb gobuster john hashcat \
        tcpdump \
        curl wget jq dnsutils whois \
        netcat-openbsd ncat socat \
        python3 python3-pip git \
        vim less tmux htop \
        ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# scapy (Python pkg) + pwntools (이미) + requests / bs4
# ffuf — apt 패키지 없음 (Ubuntu 22.04). Go binary go install (단, builder 단계 분리)
RUN pip3 install --no-cache-dir requests beautifulsoup4 pwntools scapy

# ffuf — github release (ubuntu 22.04 apt 없음)
RUN curl -sSL https://github.com/ffuf/ffuf/releases/download/v2.1.0/ffuf_2.1.0_linux_amd64.tar.gz \
        -o /tmp/ffuf.tar.gz && \
    tar -xzf /tmp/ffuf.tar.gz -C /usr/local/bin ffuf && \
    chmod +x /usr/local/bin/ffuf && \
    rm /tmp/ffuf.tar.gz

# searchsploit (exploitdb) — github clone (ubuntu 22.04 apt 없음, kali 전용)
RUN git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb && \
    ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit

# msfconsole — default 설치 (학생 lab 의 13 도구 중 1). 빌드 시간 ~10 min 증가.
# SKIP_MSF=1 build arg 로 생략 가능.
ARG SKIP_MSF=0
RUN if [ "$SKIP_MSF" != "1" ]; then \
        curl -sSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb -o /tmp/msfinstall && \
        chmod +x /tmp/msfinstall && /tmp/msfinstall || echo "msf install skipped"; \
    fi

# LinPEAS + 추가 enum 도구 (CCC CURRICULUM 원칙 #8 — 폐쇄망 도구 사전 배포)
# attack/W11 의 fallback, secuops/W13 의 geoip 등 lab 의존 도구
RUN mkdir -p /opt/tools && \
    curl -sSL --retry 3 https://raw.githubusercontent.com/peass-ng/PEASS-ng/master/linPEAS/linpeas.sh \
        -o /opt/tools/linpeas.sh && \
    chmod +x /opt/tools/linpeas.sh && \
    echo "LinPEAS: $(wc -c < /opt/tools/linpeas.sh) byte" || \
    echo "LinPEAS download skipped (offline build)"

RUN apt-get update && apt-get install -y --no-install-recommends \
        geoip-bin geoip-database \
        net-tools traceroute mtr-tiny \
        && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /run/sshd && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY attacker/entrypoint.sh /entrypoint.sh
COPY attacker/motd /etc/motd
COPY agent/subagent.py /opt/subagent.py
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
