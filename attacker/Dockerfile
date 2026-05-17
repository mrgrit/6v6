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

# dalfox — XSS 전용 자동 scanner (Go binary, github release)
RUN curl -sSL https://github.com/hahwul/dalfox/releases/download/v2.9.2/dalfox_2.9.2_linux_amd64.tar.gz \
        -o /tmp/dalfox.tar.gz && \
    tar -xzf /tmp/dalfox.tar.gz -C /usr/local/bin dalfox && \
    chmod +x /usr/local/bin/dalfox && \
    rm /tmp/dalfox.tar.gz || echo "(dalfox download skipped — offline build)"

# XSStrike — DOM XSS + WAF 우회 자동 (python clone + pip)
RUN git clone --depth 1 https://github.com/s0md3v/XSStrike.git /opt/xsstrike && \
    pip3 install --no-cache-dir -r /opt/xsstrike/requirements.txt && \
    printf '#!/bin/bash\npython3 /opt/xsstrike/xsstrike.py "$@"\n' > /usr/local/bin/xsstrike && \
    chmod +x /usr/local/bin/xsstrike || echo "(XSStrike install skipped)"

# searchsploit (exploitdb) — github clone (ubuntu 22.04 apt 없음, kali 전용)
RUN git clone --depth 1 https://gitlab.com/exploit-database/exploitdb.git /opt/exploitdb && \
    ln -sf /opt/exploitdb/searchsploit /usr/local/bin/searchsploit

# msfconsole — default 설치 (학생 lab 의 13 도구 중 1). 빌드 시간 ~10 min 증가.
# SKIP_MSF=1 build arg 로 생략 가능.
# msfinstall 이 추가하는 apt repo 의 GPG key 가 2026 갱신 후 deprecate — 신규 배포
# 시 apt-key 누락으로 후속 apt-get update 가 NO_PUBKEY 로 fail 함. 따라서 install
# 후 sources.list 의 signed-by= 형식으로 keyring 재바인딩 + 학생 신규 배포 안정성
# 위해 실패 시 repo 비활성화 (msf 자체는 이미 설치됨 = apt update 만 막지 않으면 됨).
ARG SKIP_MSF=0
RUN if [ "$SKIP_MSF" != "1" ]; then \
        curl -sSL https://raw.githubusercontent.com/rapid7/metasploit-omnibus/master/config/templates/metasploit-framework-wrappers/msfupdate.erb -o /tmp/msfinstall && \
        chmod +x /tmp/msfinstall && /tmp/msfinstall || echo "msf install skipped"; \
        if [ -f /etc/apt/sources.list.d/metasploit-framework.list ]; then \
            echo "[attacker] disabling metasploit apt repo (GPG key 갱신 회피 — msf binary 는 이미 설치됨)"; \
            mv /etc/apt/sources.list.d/metasploit-framework.list /etc/apt/sources.list.d/metasploit-framework.list.disabled; \
        fi; \
    fi

# LinPEAS + 추가 enum 도구 (CCC CURRICULUM 원칙 #8 — 폐쇄망 도구 사전 배포)
# attack/W11 의 fallback, secuops/W13 의 geoip 등 lab 의존 도구
RUN mkdir -p /opt/tools && \
    curl -sSL --retry 3 -L https://github.com/peass-ng/PEASS-ng/releases/latest/download/linpeas.sh \
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

# 6v6 vhost 매핑 — attacker 에서 host header 없이 curl http://juice.6v6.lab/...
# 직접 가능. web (10.20.32.80) 의 Apache + ModSec reverse proxy 가 host header
# 기반 backend (juiceshop:3000 등) 로 라우팅. siem (10.20.32.100) 는 dashboard 직접.
RUN printf '\n# 6v6 vhost mappings (lab content compatibility)\n\
10.20.32.80\tjuice.6v6.lab\n\
10.20.32.80\tdvwa.6v6.lab\n\
10.20.32.80\tneobank.6v6.lab\n\
10.20.32.80\tgovportal.6v6.lab\n\
10.20.32.80\tmediforum.6v6.lab\n\
10.20.32.80\tadminconsole.6v6.lab\n\
10.20.32.80\taicompanion.6v6.lab\n\
10.20.32.100\tsiem.6v6.lab\n' >> /etc/hosts

COPY attacker/entrypoint.sh /entrypoint.sh
COPY attacker/motd /etc/motd
COPY agent/subagent.py /opt/subagent.py
RUN chmod +x /entrypoint.sh

EXPOSE 22
ENTRYPOINT ["/entrypoint.sh"]
