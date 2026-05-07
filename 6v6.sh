#!/usr/bin/env bash
# 6v6 — CCC infra docker single-VM operations script
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

ensure_env() {
    [ -f .env ] || { echo "[6v6] .env not found -> 'cp .env.example .env' (auto)"; cp .env.example .env; }
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

    echo "[6v6] (2/4) install helpers (git, curl, jq, sshpass, net-tools, iproute2, dnsutils)"
    sudo apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        git jq sshpass net-tools iproute2 dnsutils >/dev/null

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

cmd_up() {
    cmd_check_docker
    ensure_env
    echo "[6v6] docker compose build + up — first build takes 8-12 min (Wazuh + 7 vuln sites)."
    docker compose build
    docker compose up -d
    echo
    echo "[6v6] up done. Run 'bash 6v6.sh smoke' for health check."
    cmd_status
}

cmd_down() {
    docker compose down
}

cmd_destroy() {
    docker compose down -v --rmi local
    echo "[6v6] containers + volumes + built images all removed."
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
    echo "  $IP  6v6.lab juice.6v6.lab dvwa.6v6.lab neobank.6v6.lab govportal.6v6.lab mediforum.6v6.lab admin.6v6.lab ai.6v6.lab portal.6v6.lab siem.6v6.lab bastion.6v6.lab"
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
    echo "--- external ports ---------------------------------------------"
    check_url "landing"          "http://$IP/"
    check_url "portal"           "http://$IP:8000/"
    check_url "portal /health"   "http://$IP:8000/health"
    check_url "siem"             "http://$IP:5601/"
    check_url "bastion API"      "http://$IP:9100/health"
    echo
    echo "--- vhost reverse proxy (Host header) --------------------------"
    for h in juice dvwa neobank govportal mediforum admin ai portal siem bastion; do
        local code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
            -H "Host: $h.6v6.lab" "http://$IP/" 2>/dev/null || echo 000)
        if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
            printf "  [OK]   %-22s HTTP %s\n" "$h.6v6.lab" "$code"
        else
            printf "  [FAIL] %-22s HTTP %s\n" "$h.6v6.lab" "$code"
        fi
    done
    echo
    echo "--- container health -------------------------------------------"
    for c in 6v6-bastion 6v6-secu 6v6-web 6v6-juiceshop 6v6-dvwa 6v6-neobank 6v6-govportal 6v6-mediforum 6v6-adminconsole 6v6-aicompanion 6v6-siem 6v6-attacker 6v6-portal; do
        if docker ps --format '{{.Names}}' | grep -q "^$c$"; then
            printf "  [OK]   %-19s %s\n" "$c" "$(docker ps --format '{{.Status}}' --filter name=^$c$)"
        else
            printf "  [FAIL] %-19s container not running\n" "$c"
        fi
    done
    echo
    echo "--- Wazuh integration ------------------------------------------"
    if docker ps --format '{{.Names}}' | grep -q '^6v6-siem$'; then
        local running=$(docker exec 6v6-siem /var/ossec/bin/wazuh-control status 2>/dev/null \
                        | grep -c 'is running' || echo 0)
        local total=$(docker exec 6v6-siem /var/ossec/bin/wazuh-control status 2>/dev/null \
                      | grep -cE 'is running|not running' || echo 0)
        if [ "$running" -ge 6 ]; then
            printf "  [OK]   wazuh-manager daemons %s/%s running\n" "$running" "$total"
        else
            printf "  [WARN] wazuh-manager daemons %s/%s running\n" "$running" "$total"
        fi
        local agents=$(docker exec 6v6-siem /var/ossec/bin/agent_control -l 2>/dev/null \
                       | grep -cE '^\s+ID:' || echo 0)
        if [ "$agents" -ge 2 ]; then
            printf "  [OK]   Wazuh agents enrolled  %s (secu/web)\n" "$agents"
        else
            printf "  [WARN] Wazuh agents enrolled %s (target 2+) — agent-auth result\n" "$agents"
        fi
        if docker exec 6v6-siem test -s /var/ossec/logs/alerts/alerts.json 2>/dev/null; then
            local alines=$(docker exec 6v6-siem wc -l /var/ossec/logs/alerts/alerts.json 2>/dev/null | awk '{print $1}')
            printf "  [OK]   alerts.json lines      %s\n" "$alines"
        else
            printf "  [INFO] alerts.json empty      — fire SQLi from attacker, recheck\n"
        fi
    else
        echo "  [FAIL] siem container not running"
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
  up        build + start (with docker pre-flight check)
  down      stop containers (volumes preserved)
  destroy   remove containers + volumes + images
  status    container status + access info
  smoke     external ports + container + Wazuh + SSH health checks
  logs <svc>  follow container logs

Quick start (fresh Linux VM):
  bash 6v6.sh install     # auto-install docker + helpers
  newgrp docker           # or open new terminal
  bash 6v6.sh up          # start 6v6 environment
  bash 6v6.sh status      # show access info
  bash 6v6.sh smoke       # health check

Services: bastion / secu / web / juiceshop / dvwa / neobank / govportal /
          mediforum / adminconsole / aicompanion / siem / attacker / portal
HELP
}

case "${1:-help}" in
    install)  cmd_install ;;
    up)       cmd_up ;;
    down)     cmd_down ;;
    destroy)  cmd_destroy ;;
    status)   cmd_status ;;
    smoke)    cmd_smoke ;;
    logs)     shift; cmd_logs "$@" ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
esac
