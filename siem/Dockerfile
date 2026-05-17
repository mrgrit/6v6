FROM wazuh/wazuh-manager:4.10.0

# openssh-server + sudo (Amazon Linux 2023)
RUN yum install -y openssh-server openssh-clients sudo passwd hostname && yum clean all && \
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

EXPOSE 22 8002
