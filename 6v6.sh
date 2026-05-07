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

cmd_up() {
    ensure_env
    echo "[6v6] docker compose build + up 시작 — 첫 빌드는 5~8 분."
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

  up        빌드 + 기동
  down      컨테이너 정지 (볼륨 보존)
  destroy   컨테이너 + 볼륨 + 이미지 삭제
  status    컨테이너 상태 + 외부 접속 안내
  smoke     외부 노출 포트 + 컨테이너 헬스 체크
  logs <svc>  컨테이너 로그 follow

서비스: bastion / secu / web / juiceshop / siem / attacker / portal
HELP
}

case "${1:-help}" in
    up)       cmd_up ;;
    down)     cmd_down ;;
    destroy)  cmd_destroy ;;
    status)   cmd_status ;;
    smoke)    cmd_smoke ;;
    logs)     shift; cmd_logs "$@" ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
esac
