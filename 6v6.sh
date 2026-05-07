#!/usr/bin/env bash
# 6v6 — CCC 인프라 docker 단일 VM 버전 운영 스크립트
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

ensure_env() {
    [ -f .env ] || { echo "[6v6] .env 가 없습니다 → cp .env.example .env"; cp .env.example .env; }
}

vm_ip() {
    # VM 의 외부 IP — 학생 안내용
    ip -4 -o addr show 2>/dev/null \
        | awk '{print $4}' \
        | grep -E '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
        | grep -v '^10\.20\.30\.' \
        | head -1 \
        | cut -d/ -f1
}

cmd_install() {
    # 리눅스만 설치된 환경에 docker + docker compose + 보조 도구 일괄 설치 (Debian/Ubuntu).
    if ! command -v sudo >/dev/null 2>&1; then
        echo "[6v6] sudo 가 필요합니다 — 'apt install sudo' 후 다시 실행"
        exit 1
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        echo "[6v6] 이 스크립트의 자동 설치는 Debian/Ubuntu 계열만 지원합니다."
        echo "      RHEL/CentOS/Arch 환경은 docker engine + docker compose plugin 을"
        echo "      각 배포판 패키지 매니저로 직접 설치 후 'bash 6v6.sh up' 사용하세요."
        exit 1
    fi

    echo "[6v6] (1/4) 시스템 패키지 업데이트"
    sudo apt-get update -qq

    echo "[6v6] (2/4) 보조 도구 설치 (git, curl, jq, sshpass, net-tools, iproute2 ...)"
    sudo apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg lsb-release \
        git jq sshpass net-tools iproute2 dnsutils >/dev/null

    if ! command -v docker >/dev/null 2>&1; then
        echo "[6v6] (3/4) Docker Engine 설치"
        local OS_ID OS_CODE
        OS_ID=$(. /etc/os-release && echo "$ID")
        OS_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
        # ubuntu/debian 둘 다 지원
        case "$OS_ID" in
            ubuntu|debian) ;;
            *) echo "[6v6] 알 수 없는 배포판: $OS_ID — Ubuntu 22.04 또는 Debian 12 권장"; exit 1 ;;
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
        echo "[6v6]   Docker Engine 설치 완료: $(docker --version)"
    else
        echo "[6v6] (3/4) Docker 이미 설치됨: $(docker --version)"
    fi

    if ! docker compose version >/dev/null 2>&1; then
        echo "[6v6]   docker compose plugin 누락 — 추가 설치"
        sudo apt-get install -y --no-install-recommends docker-compose-plugin
    fi

    echo "[6v6] (4/4) 설치 검증"
    echo "  - docker:         $(docker --version 2>/dev/null || echo MISSING)"
    echo "  - docker compose: $(docker compose version 2>/dev/null | head -1 || echo MISSING)"
    echo "  - git:            $(git --version 2>/dev/null || echo MISSING)"
    echo "  - jq:             $(jq --version 2>/dev/null || echo MISSING)"

    if ! id -nG "$USER" 2>/dev/null | grep -qw docker; then
        echo
        echo "[6v6] ★ 'docker' 그룹 가입이 현재 셸에 반영되지 않았습니다."
        echo "      → 새 터미널을 열거나, 같은 셸에서 'newgrp docker' 실행 후"
        echo "      → 'bash 6v6.sh up' 으로 시작하세요."
        exit 0
    fi

    echo
    echo "[6v6] 설치 완료 — 이제 'bash 6v6.sh up' 으로 6v6 환경 기동 가능."
}

cmd_check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "[6v6] ✗ Docker 가 설치되지 않았습니다."
        echo "      → 'bash 6v6.sh install' 로 자동 설치하거나, 수동 설치 후 다시 실행."
        exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "[6v6] ✗ Docker daemon 에 접근할 수 없습니다."
        echo "      → sudo 로 실행하거나 다음 후 새 터미널 열기:"
        echo "         sudo usermod -aG docker \$USER && newgrp docker"
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "[6v6] ✗ 'docker compose' plugin 이 없습니다."
        echo "      → 'bash 6v6.sh install' 로 추가 설치"
        exit 1
    fi
}

cmd_up() {
    cmd_check_docker
    ensure_env
    echo "[6v6] docker compose build + up 시작 — 첫 빌드는 8~12 분 (Wazuh + 7 vuln 사이트 포함)."
    docker compose build
    docker compose up -d
    echo
    echo "[6v6] 부팅 완료. 'bash 6v6.sh smoke' 로 헬스 확인."
    cmd_status
}

cmd_down() {
    docker compose down
}

cmd_destroy() {
    docker compose down -v --rmi local
    echo "[6v6] 컨테이너 + 볼륨 + 빌드 이미지 모두 삭제."
}

cmd_logs() {
    local svc="${1:-}"
    if [ -z "$svc" ]; then
        echo "사용법: bash 6v6.sh logs <bastion|secu|web|juiceshop|siem|attacker|portal>"
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
    echo " 6v6 실습 환경 — VM IP: $IP"
    echo "================================================================"
    echo
    docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
    echo
    echo "─── 학생 PC 접속 ───────────────────────────────────────────"
    echo "  http://$IP/                  랜딩 페이지 + JuiceShop"
    echo "  http://$IP:8000/             관리 포털"
    echo "  http://$IP:5601/             SIEM lite UI"
    echo "  http://$IP:9100/health       Bastion API"
    echo
    echo "─── SSH (ProxyJump) ────────────────────────────────────────"
    echo "  ssh -p 2204 ccc@$IP          # bastion (점프 호스트)"
    echo "  ssh -p 2202 ccc@$IP          # attacker 직접"
    echo "  ssh -J ccc@$IP:2204 ccc@10.20.30.1    # secu (jump)"
    echo "  ssh -J ccc@$IP:2204 ccc@10.20.30.80   # web"
    echo "  ssh -J ccc@$IP:2204 ccc@10.20.30.100  # siem"
    echo "  비밀번호: ccc"
    echo
}

check_url() {
    local label="$1" url="$2" expect="${3:-200}"
    local code
    code=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' "$url" 2>/dev/null || echo "000")
    if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
        printf "  [OK]  %-22s %s (HTTP %s)\n" "$label" "$url" "$code"
    else
        printf "  [FAIL] %-22s %s (HTTP %s)\n" "$label" "$url" "$code"
    fi
}

cmd_smoke() {
    ensure_env
    local IP="$(vm_ip)"
    [ -z "$IP" ] && { echo "VM IP 미감지"; exit 1; }
    echo
    echo "[6v6] smoke test (VM_IP=$IP)"
    echo "─── 외부 노출 포트 ─────────────────────────────────────────"
    check_url "landing"          "http://$IP/"
    check_url "portal"           "http://$IP:8000/"
    check_url "portal /health"   "http://$IP:8000/health"
    check_url "siem"             "http://$IP:5601/"
    check_url "bastion API"      "http://$IP:9100/health"
    echo
    echo "─── vhost reverse proxy (Host 헤더로 검증) ────────────────"
    for h in juice dvwa neobank govportal mediforum admin ai; do
        local code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' \
            -H "Host: $h.6v6.lab" "http://$IP/" 2>/dev/null || echo 000)
        if [[ "$code" =~ ^(200|301|302|307|308|401|403)$ ]]; then
            printf "  [OK]  %-22s HTTP %s\n" "$h.6v6.lab" "$code"
        else
            printf "  [FAIL] %-22s HTTP %s\n" "$h.6v6.lab" "$code"
        fi
    done
    echo
    echo "─── 컨테이너 헬스 ─────────────────────────────────────────"
    for c in 6v6-bastion 6v6-secu 6v6-web 6v6-juiceshop 6v6-dvwa 6v6-neobank 6v6-govportal 6v6-mediforum 6v6-adminconsole 6v6-aicompanion 6v6-siem 6v6-attacker 6v6-portal; do
        if docker ps --format '{{.Names}}' | grep -q "^$c$"; then
            printf "  [OK]  %-15s %s\n" "$c" "$(docker ps --format '{{.Status}}' --filter name=^$c$)"
        else
            printf "  [FAIL] %-15s 컨테이너 미동작\n" "$c"
        fi
    done
    echo
    echo "─── Wazuh 동작 검증 ───────────────────────────────────────"
    if docker ps --format '{{.Names}}' | grep -q '^6v6-siem$'; then
        # manager 8 daemon
        local running=$(docker exec 6v6-siem /var/ossec/bin/wazuh-control status 2>/dev/null \
                        | grep -c 'is running' || echo 0)
        local total=$(docker exec 6v6-siem /var/ossec/bin/wazuh-control status 2>/dev/null \
                      | grep -cE 'is running|not running' || echo 0)
        if [ "$running" -ge 6 ]; then
            printf "  [OK]  wazuh-manager daemon  %s/%s running\n" "$running" "$total"
        else
            printf "  [WARN] wazuh-manager daemon %s/%s running\n" "$running" "$total"
        fi
        # 등록된 agent
        local agents=$(docker exec 6v6-siem /var/ossec/bin/agent_control -l 2>/dev/null \
                       | grep -cE '^\s+ID:' || echo 0)
        if [ "$agents" -ge 2 ]; then
            printf "  [OK]  Wazuh agent 등록      %s 개 (secu/web 등)\n" "$agents"
        else
            printf "  [WARN] Wazuh agent 등록     %s 개 (목표 2+) — agent-auth 결과 확인\n" "$agents"
        fi
        # alerts.json 갱신
        if docker exec 6v6-siem test -s /var/ossec/logs/alerts/alerts.json 2>/dev/null; then
            local alines=$(docker exec 6v6-siem wc -l /var/ossec/logs/alerts/alerts.json 2>/dev/null | awk '{print $1}')
            printf "  [OK]  alerts.json           %s 라인\n" "$alines"
        else
            printf "  [INFO] alerts.json 비었음   — attacker 에서 SQLi 등 발사 후 재확인\n"
        fi
    else
        echo "  [FAIL] siem 컨테이너 미동작"
    fi
    echo
    echo "─── SSH 점프 검증 ──────────────────────────────────────────"
    local ssh_opt='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=3 -o BatchMode=yes'
    # 비밀번호 없이는 BatchMode 에서 fail. sshpass 가 있으면 검증.
    if command -v sshpass >/dev/null 2>&1; then
        if sshpass -p "${SSH_PASS:-ccc}" ssh -p 2204 $ssh_opt -o PreferredAuthentications=password \
              "${SSH_USER:-ccc}@$IP" 'true' 2>/dev/null; then
            echo "  [OK]  bastion SSH (port 2204)"
        else
            echo "  [WARN] bastion SSH 검증 실패 (비밀번호 인증)"
        fi
    else
        echo "  [SKIP] sshpass 없음 — 수동으로 'ssh -p 2204 ccc@$IP' 검증"
    fi
    echo
}

cmd_help() {
    cat <<'HELP'
사용법: bash 6v6.sh <command>

  install   docker + docker compose + 보조 도구 자동 설치 (Debian/Ubuntu)
            → 처음 환경에서 한 번만. 'docker' 그룹 가입 후 새 터미널 열기.
  up        빌드 + 기동 (docker 사전 검증 포함)
  down      컨테이너 정지 (볼륨 보존)
  destroy   컨테이너 + 볼륨 + 이미지 삭제
  status    컨테이너 상태 + 외부 접속 안내
  smoke     외부 노출 포트 + 컨테이너 + Wazuh agent + SSH 헬스 체크
  logs <svc>  컨테이너 로그 follow

처음 사용 흐름 (리눅스만 설치된 새 VM):
  bash 6v6.sh install     # docker + 도구 자동 설치
  newgrp docker           # 또는 새 터미널 열기
  bash 6v6.sh up          # 6v6 환경 기동
  bash 6v6.sh status      # 외부 접속 안내 표시
  bash 6v6.sh smoke       # 헬스 체크

서비스: bastion / secu / web / juiceshop / dvwa / neobank / govportal /
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
