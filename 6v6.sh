#!/usr/bin/env bash
# 6v6 — CCC infra docker single-VM operations script
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

ensure_env() {
    [ -f .env ] || { echo "[6v6] .env not found -> 'cp .env.example .env' (auto)"; cp .env.example .env; }
}

ensure_ssh_keys() {
    # 학생 신규 배포 — keys/ 디렉토리 + bastion SSH key 자동 생성. bind mount 로 6
    # 컨테이너 (bastion / attacker / fw / ips / web / siem) 가 /keys read-only 마운트.
    # bastion 의 ccc 가 id_rsa 보유, 나머지가 id_rsa.pub 을 authorized_keys 로 받아
    # password 없이 ssh 6v6-fw 등 ProxyJump 가능. 학생 환경마다 다른 키 생성 (gitignore).
    mkdir -p keys
    if [ ! -f keys/id_rsa ]; then
        if ! command -v ssh-keygen >/dev/null 2>&1; then
            echo "[6v6] ssh-keygen not found. Install with 'sudo apt install -y openssh-client' and re-run."
            exit 1
        fi
        ssh-keygen -t ed25519 -f keys/id_rsa -N "" -C "6v6-bastion@auto" >/dev/null 2>&1
        echo "[6v6] generated SSH key pair (keys/id_rsa) - for password-less SSH between containers"
    fi
    chmod 600 keys/id_rsa  2>/dev/null || true
    chmod 644 keys/id_rsa.pub 2>/dev/null || true
}

ensure_misp_env() {
    # secuops/W14 (MISP) 의 학생 신규 배포. .env.misp 가 없으면 template + 학생 환경 값 자동.
    [ -f .env.misp ] && return 0
    [ -f .env.misp.example ] || return 0
    cp .env.misp.example .env.misp
    VM_IP=$(vm_ip 2>/dev/null || echo "127.0.0.1")
    # MISP port 8880/8443 (6v6 의 fw HAProxy 가 80/443 점유 → 충돌 회피)
    sed -i "s|^BASE_URL=.*|BASE_URL=https://${VM_IP}:8443|" .env.misp
    sed -i "s|^MYSQL_PASSWORD=.*|MYSQL_PASSWORD=$(openssl rand -hex 16)|" .env.misp
    sed -i "s|^MYSQL_ROOT_PASSWORD=.*|MYSQL_ROOT_PASSWORD=$(openssl rand -hex 16)|" .env.misp
    sed -i "s|^DISABLE_IPV6=.*|DISABLE_IPV6=true|" .env.misp
    sed -i "s|^# CORE_HTTP_PORT=.*|CORE_HTTP_PORT=8880|; s|^CORE_HTTP_PORT=$|CORE_HTTP_PORT=8880|" .env.misp
    sed -i "s|^# CORE_HTTPS_PORT=.*|CORE_HTTPS_PORT=8443|; s|^CORE_HTTPS_PORT=$|CORE_HTTPS_PORT=8443|" .env.misp
    # default 값으로 추가 (sed가 못 잡으면)
    grep -q "^CORE_HTTP_PORT=" .env.misp || echo "CORE_HTTP_PORT=8880" >> .env.misp
    grep -q "^CORE_HTTPS_PORT=" .env.misp || echo "CORE_HTTPS_PORT=8443" >> .env.misp
    chmod 600 .env.misp
    echo "[6v6] generated .env.misp - MISP 5 container stack (core/db/redis/modules/mail)"
}

ensure_opencti_env() {
    # secuops/W12-W13 (OpenCTI) 의 학생 신규 배포 자동화. .env.opencti 가 없으면 자동 생성.
    # docker-compose.opencti.yml 의 모든 ${OPENCTI_*} / ${MINIO_*} / ${RABBITMQ_*} env 채움.
    [ -f .env.opencti ] && return 0
    if ! command -v openssl >/dev/null 2>&1 || ! command -v uuidgen >/dev/null 2>&1; then
        echo "[6v6] WARN: openssl/uuidgen not installed - OpenCTI overlay auto-gen unavailable."
        echo "      Install with 'sudo apt install -y openssl uuid-runtime' and re-run 'bash 6v6.sh up'."
        return 1
    fi
    VM_IP=$(vm_ip 2>/dev/null || echo "127.0.0.1")
    cat > .env.opencti <<ENV
# OpenCTI 7.x — 학생 신규 배포 자동 생성. 환경마다 다른 UUID/key (재현 금지).
OPENCTI_ADMIN_EMAIL=admin@opencti.io
OPENCTI_ADMIN_PASSWORD=ChangeMe123!
OPENCTI_ADMIN_TOKEN=$(uuidgen)
OPENCTI_HEALTHCHECK_ACCESS_KEY=$(uuidgen)
OPENCTI_ENCRYPTION_KEY=$(openssl rand -base64 32)
OPENCTI_BASE_URL=http://${VM_IP}:8080
OPENCTI_EXTERNAL_SCHEME=http
OPENCTI_HOST=${VM_IP}
OPENCTI_PORT=8080
MINIO_ROOT_USER=$(uuidgen)
MINIO_ROOT_PASSWORD=$(uuidgen)
RABBITMQ_DEFAULT_USER=opencti
RABBITMQ_DEFAULT_PASS=$(uuidgen)
ELASTIC_MEMORY_SIZE=1G
CONNECTOR_HISTORY_ID=$(uuidgen)
CONNECTOR_EXPORT_FILE_STIX_ID=$(uuidgen)
CONNECTOR_EXPORT_FILE_CSV_ID=$(uuidgen)
CONNECTOR_EXPORT_FILE_TXT_ID=$(uuidgen)
CONNECTOR_EXPORT_FILE_XLSX_ID=$(uuidgen)
CONNECTOR_IMPORT_FILE_STIX_ID=$(uuidgen)
CONNECTOR_IMPORT_FILE_YARA_ID=$(uuidgen)
CONNECTOR_IMPORT_FILE_PDF_OBSERVABLES_ID=$(uuidgen)
CONNECTOR_ANALYSIS_ID=$(uuidgen)
CONNECTOR_IMPORT_DOCUMENT_ID=$(uuidgen)
CONNECTOR_IMPORT_EXTERNAL_REFERENCE_ID=$(uuidgen)
CONNECTOR_MITRE_ID=$(uuidgen)
CONNECTOR_OPENCTI_ID=$(uuidgen)
SMTP_HOSTNAME=localhost
ENV
    chmod 600 .env.opencti
    echo "[6v6] generated .env.opencti - OpenCTI 7.x ENCRYPTION_KEY + TOKEN + MINIO + RABBITMQ"
}

vm_ip() {
    # VM external IP (for student-facing instructions)
    ip -4 -o addr show 2>/dev/null \
        | awk '{print $4}' \
        | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
        | grep -v '^10\.20\.30\.' \
        | head -1 \
        | cut -d/ -f1
}

cmd_install() {
    # Auto-install docker + compose + helpers on a fresh Debian/Ubuntu VM.
    if ! command -v sudo >/dev/null 2>&1; then
        echo "[6v6] sudo is required. Install with 'apt install sudo' first."
        exit 1
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "[6v6] Auto-install supports Debian/Ubuntu only."
        echo "      For RHEL/Arch/etc, install docker-ce + docker-compose-plugin manually,"
        echo "      then run 'bash 6v6.sh up'."
        exit 1
    fi

    echo "[6v6] (1/4) apt-get update"
    sudo apt-get update -qq

    echo "[6v6] (2/4) install helpers (git, curl, jq, sshpass, net-tools, iproute2, dnsutils, python3-venv)"
    sudo apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        git jq sshpass net-tools iproute2 dnsutils \
        python3-venv python3-pip >/dev/null

    if ! command -v docker >/dev/null 2>&1; then
        echo "[6v6] (3/4) install Docker Engine"
        local OS_ID OS_CODE
        OS_ID=$(. /etc/os-release && echo "$ID")
        OS_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
        case "$OS_ID" in
            ubuntu|debian) ;;
            *) echo "[6v6] unsupported distro: $OS_ID — Ubuntu 22.04 or Debian 12 recommended"; exit 1 ;;
        esac

        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $OS_CODE stable" | \
            sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

        sudo apt-get update -qq
        sudo apt-get install -y --no-install-recommends \
            docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin

        sudo systemctl enable --now docker
        sudo usermod -aG docker "$USER"
        echo "[6v6]   Docker Engine installed: $(docker --version)"
    else
        echo "[6v6] (3/4) Docker already installed: $(docker --version)"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "[6v6]   docker compose plugin missing — installing"
        sudo apt-get install -y --no-install-recommends docker-compose-plugin
    fi

    # Configure Docker daemon DNS - prevents "network is unreachable" pull errors
    # on VMs where /etc/resolv.conf points to a DNS that doesn't resolve docker.io.
    if [ ! -f /etc/docker/daemon.json ] || ! grep -q '"dns"' /etc/docker/daemon.json 2>/dev/null; then
        echo "[6v6] (3.5/4) configure Docker daemon DNS (8.8.8.8, 1.1.1.1)"
        sudo mkdir -p /etc/docker
        if [ -f /etc/docker/daemon.json ]; then
            sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s)
            # Merge dns into existing JSON (best-effort with jq, fallback to overwrite)
            if command -v jq >/dev/null 2>&1; then
                sudo jq '. + {"dns":["8.8.8.8","1.1.1.1"]}' /etc/docker/daemon.json | \
                    sudo tee /etc/docker/daemon.json.new >/dev/null && \
                    sudo mv /etc/docker/daemon.json.new /etc/docker/daemon.json
            else
                echo '{"dns":["8.8.8.8","1.1.1.1"]}' | sudo tee /etc/docker/daemon.json >/dev/null
            fi
        else
            echo '{"dns":["8.8.8.8","1.1.1.1"]}' | sudo tee /etc/docker/daemon.json >/dev/null
        fi
        sudo systemctl restart docker 2>/dev/null || true
    fi

    echo "[6v6] (4/4) verify"
    echo "  - docker:         $(docker --version 2>/dev/null || echo MISSING)"
    echo "  - docker compose: $(docker compose version 2>/dev/null | head -1 || echo MISSING)"
    echo "  - git:            $(git --version 2>/dev/null || echo MISSING)"
    echo "  - jq:             $(jq --version 2>/dev/null || echo MISSING)"

    if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
        echo
        echo "[6v6] * 'docker' group membership is not active in this shell."
        echo "      -> Open a NEW terminal, OR run 'newgrp docker' in this shell,"
        echo "      -> then 'bash 6v6.sh up' to start."
        exit 0
    fi

    echo
    echo "[6v6] install complete — run 'bash 6v6.sh up' to start the 6v6 environment."
}

cmd_check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "[6v6] X Docker is not installed."
        echo "      -> Run 'bash 6v6.sh install' for auto-setup, or install manually."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "[6v6] X Cannot reach Docker daemon."
        echo "      -> Run with sudo, or:"
        echo "         sudo usermod -aG docker \$USER && newgrp docker"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "[6v6] X 'docker compose' plugin missing."
        echo "      -> Run 'bash 6v6.sh install' to add it."
        exit 1
    fi
}

cmd_check_network() {
    # Verify outbound connectivity + DNS works for Docker Hub / GitHub.
    # Without this, `docker compose up` fails mid-pull with confusing errors like
    # "failed to copy: failed to do request: ... network is unreachable".
    local fail=0
    if ! getent hosts registry-1.docker.io >/dev/null 2>&1; then
        echo "[6v6] X DNS cannot resolve 'registry-1.docker.io'."
        echo "      Fix:  echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
        echo "      or check /etc/systemd/resolved.conf and 'systemctl restart systemd-resolved'."
        fail=1
    fi
    if ! curl -s -o /dev/null -w "%{http_code}" --max-time 8 https://registry-1.docker.io/v2/ 2>/dev/null | grep -qE '^(200|401)$'; then
        echo "[6v6] X Cannot reach https://registry-1.docker.io (Docker Hub)."
        echo "      Check VM network: VMware NAT mode + host has internet,"
        echo "      or corporate proxy: configure /etc/systemd/system/docker.service.d/http-proxy.conf"
        fail=1
    fi
    if ! getent hosts github.com >/dev/null 2>&1; then
        echo "[6v6] X DNS cannot resolve 'github.com' (secuops-easy GUI repos)."
        fail=1
    fi
    if [ "$fail" = "1" ]; then
        echo "[6v6] Network preflight failed - fix above and re-run 'bash 6v6.sh up'."
        exit 1
    fi
}

cmd_check_kernel() {
    # wazuh-indexer (OpenSearch) requires vm.max_map_count >= 262144
    local cur
    cur=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
    if [ "$cur" -lt 262144 ]; then
        echo "[6v6] tuning vm.max_map_count for wazuh-indexer (OpenSearch)"
        if sudo -n true 2>/dev/null; then
            sudo sysctl -w vm.max_map_count=262144 >/dev/null
            grep -q '^vm.max_map_count' /etc/sysctl.conf 2>/dev/null || \
                echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf >/dev/null
        else
            echo "[6v6]   sudo unavailable; please run manually:"
            echo "         sudo sysctl -w vm.max_map_count=262144"
            echo "         echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf"
        fi
    fi

    # bridge-nf-call=0 — required for inter-bridge forwarding (fw->ips->web).
    # When br_netfilter is loaded with bridge-nf-call=1, host iptables FORWARD
    # processes packets traversing docker bridges, and docker's per-IP DROP
    # rules block our 4-tier chain.
    if sudo -n true 2>/dev/null; then
        sudo modprobe br_netfilter 2>/dev/null || true
        if [ -f /proc/sys/net/bridge/bridge-nf-call-iptables ]; then
            sudo sysctl -w net.bridge.bridge-nf-call-iptables=0 >/dev/null 2>&1
            grep -q 'bridge-nf-call-iptables' /etc/sysctl.conf 2>/dev/null || \
                echo 'net.bridge.bridge-nf-call-iptables=0' | sudo tee -a /etc/sysctl.conf >/dev/null
        fi
    fi
}

cmd_setup_forward() {
    # Docker's DOCKER-INTERNAL chain drops packets between containers on
    # different bridges by default. For our 4-tier chain (fw->ips->web->vuln)
    # to work, we must allow forwarding between our bridges in DOCKER-USER.
    if ! command -v sudo >/dev/null 2>&1; then
        echo "[6v6] WARN: sudo unavailable — cannot configure inter-bridge forwarding"
        return
    fi

    local ext_br pipe_br dmz_br int_br
    ext_br=$(docker network inspect 6v6-ext  -f '{{range $k,$v := .Options}}{{if eq $k "com.docker.network.bridge.name"}}{{$v}}{{end}}{{end}}' 2>/dev/null)
    [ -z "$ext_br" ]  && ext_br=$(docker network inspect 6v6-ext  -f '{{.Id}}' 2>/dev/null | cut -c1-12 | sed 's/^/br-/')
    pipe_br=$(docker network inspect 6v6-pipe -f '{{.Id}}' 2>/dev/null | cut -c1-12 | sed 's/^/br-/')
    dmz_br=$(docker network inspect 6v6-dmz  -f '{{.Id}}' 2>/dev/null | cut -c1-12 | sed 's/^/br-/')
    int_br=$(docker network inspect 6v6-int  -f '{{.Id}}' 2>/dev/null | cut -c1-12 | sed 's/^/br-/')

    if [ -z "$pipe_br" ] || [ -z "$dmz_br" ]; then
        echo "[6v6] WARN: cannot detect 6v6 bridge interfaces — networks created?"
        return
    fi

    echo "[6v6] inserting DOCKER-USER forward rules (ext<->pipe<->dmz<->int)"
    echo "      ext=$ext_br  pipe=$pipe_br  dmz=$dmz_br  int=$int_br"
    sudo iptables -F DOCKER-USER 2>/dev/null || true
    for pair in \
        "$ext_br $pipe_br" "$pipe_br $ext_br" \
        "$pipe_br $dmz_br" "$dmz_br $pipe_br" \
        "$dmz_br $int_br"  "$int_br $dmz_br"  ; do
        local in=${pair% *} out=${pair#* }
        sudo iptables -I DOCKER-USER -i "$in" -o "$out" -j ACCEPT 2>/dev/null || true
    done
    # Always end with the default RETURN
    sudo iptables -A DOCKER-USER -j RETURN 2>/dev/null || true
}

cmd_up() {
    # 플래그 파싱 — --with-windows (환경변수 WITH_WINDOWS=1).
    # secuops-easy GUI 3종은 default 로 자동 배포 (SKIP_SECUOPS_EASY=1 으로 비활성).
    local with_windows=0
    for arg in "$@"; do
        case "$arg" in
            --with-windows|--windows) with_windows=1 ;;
        esac
    done
    [ "${WITH_WINDOWS:-0}" = "1" ] && with_windows=1

    cmd_check_docker
    cmd_check_network
    cmd_check_kernel
    ensure_env
    ensure_ssh_keys
    ensure_opencti_env || true   # OpenCTI overlay 활성화 시점에 필요
    ensure_misp_env || true       # MISP overlay 활성화 시점에 필요
    [ "$with_windows" = "1" ] && cmd_check_kvm
    echo "[6v6] docker compose build + up — first run downloads ~15 GB of images,"
    echo "      build + start takes 20-30 min (Wazuh + 7 vuln + OpenCTI 20 + MISP 5)."
    # overlay 는 SKIP_OPENCTI=1 / SKIP_MISP=1 로 비활성. 자원 적은 학생 환경.
    COMPOSE_FILES="-f docker-compose.yaml"
    ENV_FILES="--env-file .env"
    if [ "${SKIP_OPENCTI:-0}" = "0" ] && [ -f docker-compose.opencti.yml ]; then
        COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.opencti.yml"
        ENV_FILES="$ENV_FILES --env-file .env.opencti"
        echo "[6v6] OpenCTI overlay enabled (set SKIP_OPENCTI=1 to disable)"
    fi
    if [ "${SKIP_MISP:-0}" = "0" ] && [ -f docker-compose.misp.yml ]; then
        COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.misp.yml"
        ENV_FILES="$ENV_FILES --env-file .env.misp"
        echo "[6v6] MISP overlay enabled (set SKIP_MISP=1 to disable)"
    fi
    if [ "${SKIP_SYSMON:-0}" = "0" ] && [ -f docker-compose.sysmon.yml ]; then
        COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.sysmon.yml"
        echo "[6v6] sysmon-host overlay enabled (W11 lecture; set SKIP_SYSMON=1 to disable)"
    fi
    if [ "${SKIP_OLLAMA:-0}" = "0" ] && [ -f docker-compose.ollama.yml ]; then
        COMPOSE_FILES="$COMPOSE_FILES -f docker-compose.ollama.yml"
        echo "[6v6] Ollama overlay enabled (aisec lecture; CPU inference slow. SKIP_OLLAMA=1 to disable)"
    fi
    COMPOSE_FILES="$COMPOSE_FILES $ENV_FILES"
    docker compose $COMPOSE_FILES build
    docker compose $COMPOSE_FILES up -d
    sleep 3   # let docker create networks + bridges before we tweak iptables
    cmd_setup_forward
    echo
    echo "[6v6] up done. Wazuh stack takes 1-2 min after 'up' to fully initialize."
    echo "      Run 'bash 6v6.sh smoke' after ~2 min for full health check."
    cmd_status

    # Manager-SubAgent layer 자동 구성 (skip 시 SKIP_AGENTS=1)
    if [ "${SKIP_AGENTS:-0}" = "0" ] && [ -x agent/setup-agents.sh ]; then
        echo
        echo "[6v6] starting Manager + SubAgent layer (set SKIP_AGENTS=1 to skip)..."
        # non-fatal: agent 레이어 실패가 set -e 로 up 전체(특히 뒤의 GUI 자동배포)를 중단시키지 않도록.
        bash agent/setup-agents.sh || \
            echo "[6v6] WARN: Manager/SubAgent 레이어 구성 실패 — 위 로그 확인. 'bash 6v6.sh agents' 로 재시도 가능. (계속 진행)"
    fi

    # Windows 엔드포인트 (옵션 — --with-windows 또는 WITH_WINDOWS=1)
    if [ "$with_windows" = "1" ]; then
        echo
        echo "[6v6] starting Windows endpoint (6v6-win, user zone 10.20.33.60)..."
        echo "      first boot 30-60 min - Windows ISO download + unattended install + Sysmon/Wazuh/OpenSSH"
        echo "      watch progress: http://<VM_IP>:8006  /  completion marker: win-shared/OEM_DONE.txt"
        docker compose -f docker-compose.windows.yml up -d
        cmd_win_route_fix
    fi

    # secuops-easy 특강 GUI 3종 자동 배포 (방화벽/IPS/WAF 콘솔).
    # SKIP_SECUOPS_EASY=1 로 비활성.
    if [ "${SKIP_SECUOPS_EASY:-0}" = "0" ] && [ -x secuops-easy-deploy/deploy_all.sh ]; then
        cmd_secuops_easy_deploy
    fi
}

cmd_secuops_easy_deploy() {
    # base 컨테이너 (fw/ips/web) ready 까지 대기 후 deploy_all.sh 호출.
    # 학생이 fw-gui/ips-gui/waf-gui.6v6.lab 으로 접속 가능하게 됨.
    echo
    echo "[6v6] secuops-easy GUI auto-deploy (set SKIP_SECUOPS_EASY=1 to disable)"
    echo "[6v6]   waiting for fw/ips/web to be ready (max 60s)..."
    local i
    for i in $(seq 1 30); do
        if docker exec 6v6-fw test -d /etc/haproxy 2>/dev/null && \
           docker exec 6v6-ips test -f /etc/suricata/suricata.yaml 2>/dev/null && \
           docker exec 6v6-web test -d /etc/modsecurity 2>/dev/null; then
            break
        fi
        sleep 2
    done
    bash secuops-easy-deploy/deploy_all.sh 2>&1 | sed 's/^/  /'
    echo "[6v6] secuops-easy GUI deployed — http://fw-gui.6v6.lab / ips-gui / waf-gui"
}

cmd_win_route_fix() {
    # dockurr/windows 컨테이너의 default GW 변경: docker bridge .254 → ips (10.20.33.1).
    # 게스트 OS 가 dockurr NAT 모드로 outbound 패킷을 컨테이너로 보내면, 컨테이너가
    # 자신의 default GW 로 SNAT 송신한다. 기본 docker bridge GW(.254=docker host) 로
    # 보내면 다른 zone(dmz/int) 으로 routing 불가 → Wazuh manager(10.20.32.100) 도달 X.
    # ips 의 user IP(10.20.33.1) 로 변경하면 ips 가 dmz/int 로 forward + SNAT.
    # (컨테이너 재시작 시 docker 가 default GW 복구 → cmd_windows up 마다 재적용 필요.)
    echo "[6v6] waiting 10s for 6v6-win container to be ready..."
    sleep 10
    if docker ps --format '{{.Names}}' | grep -q '^6v6-win$'; then
        docker exec 6v6-win sh -c \
            "ip route del default 2>/dev/null; ip route add default via 10.20.33.1" \
            2>/dev/null && echo "[6v6] 6v6-win default route -> 10.20.33.1 (ips)" \
                        || echo "[6v6] WARN: failed to change 6v6-win default route (check manually)"
    fi
}

cmd_check_kvm() {
    if [ ! -e /dev/kvm ]; then
        echo "[6v6] X /dev/kvm missing - Windows endpoint requires KVM acceleration."
        echo "      1) Enable virtualization (VT-x / AMD-V) in BIOS/UEFI"
        echo "      2) sudo apt install -y qemu-kvm"
        echo "      3) sudo modprobe kvm_intel  (or kvm_amd)"
        echo "      To skip Windows entirely, run 'bash 6v6.sh up' without --with-windows."
        exit 1
    fi
    if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
        echo "[6v6] WARN: no rw permission on /dev/kvm for current user."
        echo "      Windows container may fail to start. Fix:"
        echo "      sudo usermod -aG kvm \$USER && newgrp kvm"
    fi
    local ram_avail
    ram_avail=$(awk '/^MemAvailable:/ {print int($2/1024/1024)}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${ram_avail:-0}" -lt 5 ]; then
        echo "[6v6] WARN: only ${ram_avail}G RAM available - tight for Windows 4G + 6v6 stack."
        echo "      Consider adding swap or stopping some containers."
    fi
}

cmd_windows() {
    # Windows 엔드포인트 후속 관리 — up/down/status/logs
    [ -f docker-compose.windows.yml ] || { echo "[6v6] docker-compose.windows.yml not found"; exit 1; }
    local sub="${1:-status}"
    case "$sub" in
        up)
            cmd_check_docker
            cmd_check_kvm
            docker compose -f docker-compose.windows.yml up -d
            cmd_win_route_fix
            echo "[6v6] watch progress: http://$(vm_ip):8006  /  completion marker: win-shared/OEM_DONE.txt"
            ;;
        down)    docker compose -f docker-compose.windows.yml down ;;
        destroy) docker compose -f docker-compose.windows.yml down -v
                 echo "[6v6] win-storage/ and win-shared/ dirs not deleted (disk image preserved)" ;;
        status)
            if docker ps --format '{{.Names}}' | grep -q '^6v6-win$'; then
                docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter name=^6v6-win$
                [ -f win-shared/OEM_DONE.txt ] && echo "[6v6] OEM complete (Sysmon + Wazuh agent + OpenSSH installed)" \
                                              || echo "[6v6] OEM in progress - watch boot at http://$(vm_ip):8006"
            else
                echo "[6v6] 6v6-win not running - start with 'bash 6v6.sh windows up'"
            fi
            ;;
        logs)    docker compose -f docker-compose.windows.yml logs -f --tail=100 ;;
        *) echo "Usage: bash 6v6.sh windows {up|down|destroy|status|logs}"; exit 1 ;;
    esac
}

cmd_agents() {
    # 수동 호출 — 컨테이너 재가동 없이 agent layer 만 갱신
    [ -x agent/setup-agents.sh ] || { echo "[6v6] agent/setup-agents.sh not found"; exit 1; }
    bash agent/setup-agents.sh "$@"
}

cmd_down() {
    [ -f docker-compose.windows.yml ] && \
        docker compose -f docker-compose.windows.yml down 2>/dev/null || true
    docker compose down
}

cmd_destroy() {
    [ -f docker-compose.windows.yml ] && \
        docker compose -f docker-compose.windows.yml down -v 2>/dev/null || true
    docker compose down -v --rmi local
    echo "[6v6] containers + volumes + built images all removed."
    echo "      (Windows: win-storage/ and win-shared/ dirs preserved - delete manually if needed)"
}

cmd_logs() {
    local svc="${1:-}"
    if [ -z "$svc" ]; then
        echo "Usage: bash 6v6.sh logs <bastion|secu|web|juiceshop|dvwa|neobank|govportal|mediforum|adminconsole|aicompanion|siem|attacker|portal>"
        exit 1
    fi
    docker compose logs -f --tail=100 "$svc"
}

cmd_status() {
    ensure_env
    local IP="$(vm_ip)"
    [ -z "$IP" ] && IP="<VM_IP>"
    echo
    echo "================================================================"
    echo " 6v6 Lab Environment — VM IP: $IP"
    echo "================================================================"
    echo
    docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    # Windows 엔드포인트 (옵션) — base compose 와 분리돼 있어 별도로 보여줌
    if docker ps --format '{{.Names}}' | grep -q '^6v6-win$'; then
        docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' --filter name=^6v6-win$ | tail -n +2
    fi
    echo
    echo "--- Browser access (all via Apache vhosts) --------------------"
    echo "  http://6v6.lab/              Landing page (or http://$IP/)"
    echo "  http://juice.6v6.lab/        OWASP Juice Shop"
    echo "  http://dvwa.6v6.lab/         DVWA"
    echo "  http://neobank.6v6.lab/      NeoBank"
    echo "  http://govportal.6v6.lab/    GovPortal"
    echo "  http://mediforum.6v6.lab/    MediForum"
    echo "  http://admin.6v6.lab/        AdminConsole"
    echo "  http://ai.6v6.lab/           AICompanion"
    echo "  http://portal.6v6.lab/       Admin Portal"
    echo "  http://siem.6v6.lab/         SIEM (Wazuh lite UI)"
    echo "  http://bastion.6v6.lab/health  Bastion API"
    echo
    echo "  Direct port access (debug, bypasses Apache):"
    echo "    http://$IP:8000/  http://$IP:5601/  http://$IP:9100/health"
    echo
    echo "  Add to student PC hosts file (/etc/hosts on linux/mac,"
    echo "  C:\\Windows\\System32\\drivers\\etc\\hosts on Windows):"
    echo "  $IP  6v6.lab juice.6v6.lab dvwa.6v6.lab neobank.6v6.lab govportal.6v6.lab mediforum.6v6.lab admin.6v6.lab ai.6v6.lab portal.6v6.lab siem.6v6.lab bastion.6v6.lab fw-gui.6v6.lab ips-gui.6v6.lab waf-gui.6v6.lab"
    echo
    echo "--- SSH (ProxyJump) --------------------------------------------"
    echo "  ssh -p 2204 ccc@$IP            # bastion (jump host)"
    echo "  ssh -p 2202 ccc@$IP            # attacker (direct)"
    echo "  ssh -J ccc@$IP:2204 ccc@10.20.30.1     # secu"
    echo "  ssh -J ccc@$IP:2204 ccc@10.20.30.80    # web"
    echo "  ssh -J ccc@$IP:2204 ccc@10.20.30.100   # siem"
    echo "  password: ccc"
    echo
}

check_url() {
    local label="$1" url="$2"
    local code
    code=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
        printf "  [OK]   %-22s %s (HTTP %s)\n" "$label" "$url" "$code"
    else
        printf "  [FAIL] %-22s %s (HTTP %s)\n" "$label" "$url" "$code"
    fi
}

cmd_smoke() {
    ensure_env
    local IP="$(vm_ip)"
    [ -z "$IP" ] && { echo "[6v6] cannot detect VM IP"; exit 1; }
    echo
    echo "[6v6] smoke test (VM_IP=$IP)"
    echo "--- external ports (4-tier: fw HAProxy is the only ingress) ----"
    check_url "landing"          "http://$IP/"
    check_url "bastion API"      "http://$IP:9100/health"
    echo
    echo "--- vhost reverse proxy (Host header — fw HAProxy routing) -----"
    for h in juice dvwa neobank govportal mediforum admin ai portal siem bastion; do
        local code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
            -H "Host: $h.6v6.lab" "http://$IP/" 2>/dev/null || echo 000)
        # 200/302 = endpoint OK; 404 = backend alive (e.g. bastion API root); 503 still booting
        if [[ "$code" =~ ^(200|301|302|307|308|401|403|404)$ ]]; then
            printf "  [OK]   %-22s HTTP %s\n" "$h.6v6.lab" "$code"
        else
            printf "  [FAIL] %-22s HTTP %s (backend may still be booting)\n" "$h.6v6.lab" "$code"
        fi
    done
    echo
    echo "--- container health -------------------------------------------"
    for c in 6v6-bastion 6v6-attacker 6v6-fw 6v6-ips 6v6-web 6v6-juiceshop 6v6-dvwa 6v6-neobank 6v6-govportal 6v6-mediforum 6v6-adminconsole 6v6-aicompanion 6v6-wazuh-indexer 6v6-siem 6v6-wazuh-dashboard 6v6-portal; do
        if docker ps --format '{{.Names}}' | grep -q "^$c$"; then
            printf "  [OK]   %-19s %s\n" "$c" "$(docker ps --format '{{.Status}}' --filter name=^$c$)"
        else
            printf "  [FAIL] %-19s container not running\n" "$c"
        fi
    done
    echo
    echo "--- Wazuh full stack -------------------------------------------"
    if docker ps --format '{{.Names}}' | grep -q '^6v6-siem$'; then
        local running
        running=$(docker exec 6v6-siem /var/ossec/bin/wazuh-control status 2>/dev/null \
                  | grep -c 'is running' 2>/dev/null | head -1 | tr -dc 0-9)
        running=${running:-0}
        if [ "${running:-0}" -ge 6 ] 2>/dev/null; then
            printf "  [OK]   wazuh-manager daemons %s running\n" "$running"
        else
            printf "  [WARN] wazuh-manager daemons %s running (still booting?)\n" "$running"
        fi
        local agents
        agents=$(docker exec 6v6-siem /var/ossec/bin/agent_control -l 2>/dev/null \
                 | grep -cE '^\s+ID:' 2>/dev/null | head -1 | tr -dc 0-9)
        agents=${agents:-0}
        if [ "${agents:-0}" -ge 3 ] 2>/dev/null; then
            printf "  [OK]   Wazuh agents enrolled  %s (target 3+: fw/ips/web)\n" "$agents"
        else
            printf "  [WARN] Wazuh agents enrolled %s (target 3+: fw/ips/web)\n" "$agents"
        fi
        if docker exec 6v6-siem test -s /var/ossec/logs/alerts/alerts.json 2>/dev/null; then
            local alines=$(docker exec 6v6-siem wc -l /var/ossec/logs/alerts/alerts.json 2>/dev/null | awk '{print $1}')
            printf "  [OK]   alerts.json lines      %s\n" "$alines"
        else
            printf "  [INFO] alerts.json empty      — fire test traffic, recheck\n"
        fi
    else
        echo "  [FAIL] siem (wazuh-manager) not running"
    fi
    # indexer (OpenSearch) cluster health
    if docker ps --format '{{.Names}}' | grep -q '^6v6-wazuh-indexer$'; then
        local idx_status=$(docker exec 6v6-wazuh-indexer curl -sk -m 5 \
            -u admin:SecretPassword https://localhost:9200/_cluster/health 2>/dev/null \
            | grep -oE '"status":"[a-z]+"' | head -1)
        if echo "$idx_status" | grep -qE 'green|yellow'; then
            printf "  [OK]   wazuh-indexer cluster %s\n" "$idx_status"
        else
            printf "  [WARN] wazuh-indexer cluster %s (still booting?)\n" "${idx_status:-no-response}"
        fi
    fi
    # dashboard (Kibana fork)
    if docker ps --format '{{.Names}}' | grep -q '^6v6-wazuh-dashboard$'; then
        local d_code=$(docker exec 6v6-wazuh-dashboard curl -sk -m 5 \
            -o /dev/null -w '%{http_code}' https://localhost:5601/app/wazuh 2>/dev/null || echo 000)
        if [[ "$d_code" =~ ^(200|302)$ ]]; then
            printf "  [OK]   wazuh-dashboard listen (HTTP %s on :5601)\n" "$d_code"
        else
            printf "  [WARN] wazuh-dashboard responded HTTP %s\n" "$d_code"
        fi
    fi
    echo
    echo "--- SSH bastion ------------------------------------------------"
    local ssh_opt='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes'
    if command -v sshpass >/dev/null 2>&1; then
        if sshpass -p "${SSH_PASS:-ccc}" ssh -p 2204 $ssh_opt -o PreferredAuthentications=password \
              "${SSH_USER:-ccc}@$IP" 'true' 2>/dev/null; then
            echo "  [OK]   bastion SSH (port 2204)"
        else
            echo "  [WARN] bastion SSH check failed"
        fi
    else
        echo "  [SKIP] sshpass not installed — manually verify 'ssh -p 2204 ccc@$IP'"
    fi
    echo
}

cmd_help() {
    cat <<'HELP'
Usage: bash 6v6.sh <command>

  install   auto-install docker + compose + helpers (Debian/Ubuntu)
            -> first time only. Re-login or 'newgrp docker' after.
  up [--with-windows]  build + start. With --with-windows (or WITH_WINDOWS=1)
                       also starts 6v6-win (Windows 11 tiny11, user 10.20.33.60).
                       Requires KVM. First boot 30-60 min.
  down      stop containers (volumes preserved). Windows also taken down.
  destroy   remove containers + volumes + images
  status    container status + access info (Windows included)
  smoke     external ports + container + Wazuh + SSH health checks
  logs <svc>  follow container logs
  windows {up|down|destroy|status|logs}
            manage Windows endpoint separately (after base is up)

Quick start (fresh Linux VM):
  bash 6v6.sh install                # auto-install docker + helpers
  newgrp docker                      # or open new terminal
  bash 6v6.sh up                     # 15 containers (Windows excluded)
  bash 6v6.sh up --with-windows      # 16 containers (+ Windows tiny11, user zone)
  bash 6v6.sh status                 # show access info
  bash 6v6.sh smoke                  # health check

Services: bastion / attacker / fw / ips / web / siem / wazuh-indexer /
          wazuh-dashboard / portal / juiceshop / dvwa / neobank / govportal /
          mediforum / adminconsole / aicompanion
Optional: 6v6-win (Windows 11 tiny11 user PC, user 10.20.33.60) -- --with-windows
HELP
}

case "${1:-help}" in
    install)  cmd_install ;;
    up)       shift; cmd_up "$@" ;;
    down)     cmd_down ;;
    destroy)  cmd_destroy ;;
    status)   cmd_status ;;
    smoke)    cmd_smoke ;;
    logs)     shift; cmd_logs "$@" ;;
    agents)   shift; cmd_agents "$@" ;;
    windows)  shift; cmd_windows "$@" ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
esac
