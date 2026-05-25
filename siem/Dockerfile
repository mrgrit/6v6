FROM wazuh/wazuh-manager:4.10.0

# openssh-server + sudo + iproute (ss 명령) + procps (ps/top/네트워크 진단)
RUN yum install -y openssh-server openssh-clients sudo passwd hostname iproute procps-ng jq && yum clean all && \
    ssh-keygen -A && \
    mkdir -p /run/sshd /var/empty/sshd && \
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config

# ccc 사용자 (wazuh group 가입 안 함 — sudo NOPASSWD 로 ossec 명령 권한)
RUN useradd -m -s /bin/bash ccc && \
    echo 'ccc:ccc' | chpasswd && \
    echo 'ccc ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ccc && \
    chmod 0440 /etc/sudoers.d/ccc

# SubAgent — A2A worker on :8002 (다른 컨테이너와 동일한 패턴)
COPY agent/subagent.py /opt/subagent.py

# cont-init.d scripts — wazuh init 후 ssh key 배포 (97) + subagent (98) + sshd (99)
COPY siem/97-deploy-ssh-key.sh /etc/cont-init.d/97-deploy-ssh-key
COPY siem/98-start-subagent.sh /etc/cont-init.d/98-start-subagent
COPY siem/99-start-sshd.sh /etc/cont-init.d/99-start-sshd
RUN chmod +x /etc/cont-init.d/97-deploy-ssh-key /etc/cont-init.d/98-start-subagent /etc/cont-init.d/99-start-sshd

# Bastion audit decoder + rules (image /opt 보존, cont-init 가 volume 의 /var/ossec/etc 로 copy)
COPY siem/bastion-audit-decoder.xml /opt/bastion-audit-decoder.xml
COPY siem/bastion-audit-rules.xml /opt/bastion-audit-rules.xml

# cont-init: bastion audit decoder/rule 강제 적용 + syslog 514/udp remote 활성
COPY siem/96-bastion-audit-rules.sh /etc/cont-init.d/96-bastion-audit-rules
COPY siem/haproxy-denat-decoder.xml /opt/haproxy-denat-decoder.xml
COPY siem/haproxy-denat-rules.xml /opt/haproxy-denat-rules.xml
COPY siem/95-haproxy-denat.sh /etc/cont-init.d/95-haproxy-denat
RUN chmod +x /etc/cont-init.d/95-haproxy-denat
# cont-init: Wazuh API rate limit 5000/min (default 300 부족 → No API available)
COPY siem/95-api-rate-limit.sh /etc/cont-init.d/95-api-rate-limit
RUN chmod +x /etc/cont-init.d/96-bastion-audit-rules /etc/cont-init.d/95-api-rate-limit

EXPOSE 22 514/udp 8002
