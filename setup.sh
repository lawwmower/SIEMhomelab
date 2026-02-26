#!/usr/bin/env bash
# ============================================================================
# SIEM Homelab — Bootstrap Script
# ============================================================================
# Usage:  chmod +x setup.sh && sudo ./setup.sh
# ============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}/nginx/certs"
WAZUH_CERTS_DIR="${SCRIPT_DIR}/wazuh/certs"

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }
info()  { echo -e "${CYAN}[i]${NC} $*"; }
header() { echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${NC}\n"; }

# ============================================================================
# Pre-flight Checks
# ============================================================================
preflight() {
    header "Pre-flight Checks"

    # Must be root or sudo
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (use sudo)"
        exit 1
    fi
    log "Running as root"

    # Docker
    if ! command -v docker &>/dev/null; then
        err "Docker is not installed. Install it first:"
        echo "    curl -fsSL https://get.docker.com | sh"
        exit 1
    fi
    local docker_ver
    docker_ver=$(docker --version | grep -oP '\d+\.\d+\.\d+')
    log "Docker installed: v${docker_ver}"

    # Docker Compose (v2)
    if ! docker compose version &>/dev/null; then
        err "Docker Compose v2 is not installed. Install docker-compose-plugin:"
        echo "    apt install docker-compose-plugin"
        exit 1
    fi
    local compose_ver
    compose_ver=$(docker compose version --short 2>/dev/null || docker compose version | grep -oP '\d+\.\d+\.\d+')
    log "Docker Compose installed: v${compose_ver}"

    # RAM check
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    if [[ $total_ram_mb -lt 7000 ]]; then
        err "Insufficient RAM: ${total_ram_mb} MB (minimum 8 GB required)"
        exit 1
    elif [[ $total_ram_mb -lt 14000 ]]; then
        warn "RAM is ${total_ram_mb} MB — 16 GB recommended for full stack"
    else
        log "RAM: ${total_ram_mb} MB"
    fi

    # Disk check
    local avail_gb
    avail_gb=$(df -BG "${SCRIPT_DIR}" | awk 'NR==2{gsub("G","",$4); print $4}')
    if [[ $avail_gb -lt 30 ]]; then
        err "Insufficient disk space: ${avail_gb} GB available (30 GB minimum)"
        exit 1
    fi
    log "Disk space: ${avail_gb} GB available"

    # Network interface
    local iface
    iface=$(grep -oP 'HOST_INTERFACE=\K.*' "${SCRIPT_DIR}/.env" 2>/dev/null || echo "enp2s0")
    if ip link show "$iface" &>/dev/null; then
        log "Network interface '${iface}' exists"
    else
        warn "Network interface '${iface}' not found. Available interfaces:"
        ip -br link show | grep -v lo
        echo ""
        warn "Update HOST_INTERFACE in .env before starting Suricata"
    fi
}

# ============================================================================
# Kernel Tuning
# ============================================================================
tune_kernel() {
    header "Kernel Tuning"

    # vm.max_map_count for OpenSearch / Elasticsearch
    local current_mmc
    current_mmc=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
    if [[ $current_mmc -lt 262144 ]]; then
        sysctl -w vm.max_map_count=262144 >/dev/null
        if ! grep -q "vm.max_map_count" /etc/sysctl.conf 2>/dev/null; then
            echo "vm.max_map_count=262144" >> /etc/sysctl.conf
        fi
        log "Set vm.max_map_count=262144 (was ${current_mmc})"
    else
        log "vm.max_map_count already set to ${current_mmc}"
    fi

    # Increase file descriptors
    local current_nofile
    current_nofile=$(ulimit -n 2>/dev/null || echo 0)
    if [[ $current_nofile -lt 65536 ]]; then
        ulimit -n 65536 2>/dev/null || true
        warn "Increased nofile limit to 65536 for this session"
    fi
    log "File descriptor limit: $(ulimit -n)"
}

# ============================================================================
# Generate Self-Signed TLS Certificates (Nginx)
# ============================================================================
generate_nginx_certs() {
    header "Generating Nginx TLS Certificates"

    mkdir -p "${CERTS_DIR}"

    if [[ -f "${CERTS_DIR}/server.crt" && -f "${CERTS_DIR}/server.key" ]]; then
        log "Nginx TLS certs already exist — skipping"
        return
    fi

    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${CERTS_DIR}/server.key" \
        -out "${CERTS_DIR}/server.crt" \
        -subj "/C=US/ST=Texas/L=HomeCity/O=SIEM-Homelab/CN=siem.local" \
        -addext "subjectAltName=DNS:siem.local,DNS:localhost,IP:127.0.0.1" \
        2>/dev/null

    chmod 644 "${CERTS_DIR}/server.crt"
    chmod 600 "${CERTS_DIR}/server.key"
    log "Generated self-signed TLS certificate (valid 10 years)"
}

# ============================================================================
# Generate Wazuh Certificates
# ============================================================================
generate_wazuh_certs() {
    header "Generating Wazuh Certificates"

    # Use the official Wazuh cert generator container
    if docker volume inspect wazuh-indexer-certs &>/dev/null 2>&1; then
        # Check if certs already exist in the volume
        local has_certs
        has_certs=$(docker run --rm -v wazuh-indexer-certs:/certs alpine ls /certs/ 2>/dev/null | wc -l)
        if [[ $has_certs -gt 2 ]]; then
            log "Wazuh certificates already exist in volume — skipping"
            return
        fi
    fi

    info "Generating Wazuh certificates using official tool..."

    # Create a config file for the cert tool
    local cert_config_dir
    cert_config_dir=$(mktemp -d)
    cat > "${cert_config_dir}/config.yml" <<'EOF'
nodes:
  indexer:
    - name: wazuh-indexer
      ip:
        - 127.0.0.1
        - wazuh-indexer
  server:
    - name: wazuh-manager
      ip:
        - 127.0.0.1
        - wazuh-manager
      node_type: master
  dashboard:
    - name: wazuh-dashboard
      ip:
        - 127.0.0.1
        - wazuh-dashboard
EOF

    docker run --rm \
        -v "${cert_config_dir}/config.yml:/config/certs.yml:ro" \
        -v wazuh-indexer-certs:/certificates \
        -v wazuh-dashboard-certs:/dashboard-certs \
        wazuh/wazuh-certs-generator:0.0.2 2>/dev/null || {
            warn "Official cert generator failed, generating certificates manually..."
            generate_wazuh_certs_manual
            rm -rf "${cert_config_dir}"
            return
        }

    rm -rf "${cert_config_dir}"
    log "Wazuh certificates generated successfully"
}

generate_wazuh_certs_manual() {
    info "Generating Wazuh certificates manually with OpenSSL..."

    local tmpdir
    tmpdir=$(mktemp -d)

    # Root CA
    openssl genrsa -out "${tmpdir}/root-ca-key.pem" 2048 2>/dev/null
    openssl req -new -x509 -sha256 -key "${tmpdir}/root-ca-key.pem" \
        -out "${tmpdir}/root-ca.pem" -days 3650 \
        -subj "/C=US/O=Wazuh/CN=Wazuh Root CA" 2>/dev/null

    # Generate cert for each component
    for name in wazuh-indexer wazuh-manager wazuh-dashboard admin filebeat; do
        openssl genrsa -out "${tmpdir}/${name}-key.pem" 2048 2>/dev/null

        local san_ext="subjectAltName=DNS:${name},DNS:localhost,IP:127.0.0.1"
        local subj="/C=US/O=Wazuh/OU=Wazuh/CN=${name}"
        if [[ "$name" == "admin" ]]; then
            subj="/C=US/O=Wazuh/OU=Wazuh/CN=admin"
        fi

        openssl req -new -key "${tmpdir}/${name}-key.pem" \
            -out "${tmpdir}/${name}.csr" \
            -subj "$subj" 2>/dev/null

        openssl x509 -req -in "${tmpdir}/${name}.csr" \
            -CA "${tmpdir}/root-ca.pem" -CAkey "${tmpdir}/root-ca-key.pem" \
            -CAcreateserial -out "${tmpdir}/${name}.pem" \
            -days 3650 -sha256 \
            -extfile <(echo "$san_ext") 2>/dev/null
    done

    # Copy to Docker volumes
    docker volume create wazuh-indexer-certs >/dev/null 2>&1 || true
    docker volume create wazuh-dashboard-certs >/dev/null 2>&1 || true

    docker run --rm \
        -v "${tmpdir}:/source:ro" \
        -v wazuh-indexer-certs:/certs \
        alpine sh -c "cp /source/*.pem /certs/ && chmod 644 /certs/*.pem && chmod 600 /certs/*-key.pem" 2>/dev/null

    docker run --rm \
        -v "${tmpdir}:/source:ro" \
        -v wazuh-dashboard-certs:/certs \
        alpine sh -c "cp /source/wazuh-dashboard*.pem /source/root-ca.pem /certs/ && chmod 644 /certs/*.pem && chmod 600 /certs/*-key.pem" 2>/dev/null

    rm -rf "${tmpdir}"
    log "Wazuh certificates generated manually"
}

# ============================================================================
# Create Docker Network & Volumes
# ============================================================================
create_infrastructure() {
    header "Creating Docker Infrastructure"

    # Network
    if docker network inspect siem-net &>/dev/null 2>&1; then
        log "Network 'siem-net' already exists"
    else
        docker network create --driver bridge --subnet 172.25.0.0/16 siem-net >/dev/null
        log "Created Docker network 'siem-net'"
    fi

    # Shared volumes
    for vol in suricata-logs wazuh-alerts; do
        if docker volume inspect "$vol" &>/dev/null 2>&1; then
            log "Volume '${vol}' already exists"
        else
            docker volume create "$vol" >/dev/null
            log "Created Docker volume '${vol}'"
        fi
    done
}

# ============================================================================
# Pull Images
# ============================================================================
pull_images() {
    header "Pulling Docker Images"

    local images=(
        "wazuh/wazuh-indexer:4.9.2"
        "wazuh/wazuh-manager:4.9.2"
        "wazuh/wazuh-dashboard:4.9.2"
        "splunk/splunk:latest"
        "jasonish/suricata:latest"
        "strangebee/thehive:5"
        "cassandra:4"
        "docker.elastic.co/elasticsearch/elasticsearch:7.17.24"
        "ghcr.io/misp/misp-docker/misp-core:latest"
        "mysql:8.0"
        "redis:7-alpine"
        "nginx:alpine"
    )

    for img in "${images[@]}"; do
        info "Pulling ${img}..."
        docker pull "$img" 2>/dev/null || warn "Failed to pull ${img} — will retry on compose up"
    done
    log "All images pulled"
}

# ============================================================================
# Start Services
# ============================================================================
start_services() {
    header "Starting SIEM Stack"

    cd "${SCRIPT_DIR}"
    docker compose up -d --remove-orphans 2>&1 | tail -20

    log "All services starting..."
    echo ""
}

# ============================================================================
# Wait for Health Checks
# ============================================================================
wait_for_health() {
    header "Waiting for Services"

    local services=("wazuh-indexer" "wazuh-manager" "wazuh-dashboard" "splunk" "thehive" "nginx-proxy")
    local max_wait=300
    local elapsed=0

    for svc in "${services[@]}"; do
        info "Waiting for ${svc}..."
        while [[ $elapsed -lt $max_wait ]]; do
            local status
            status=$(docker inspect --format='{{.State.Health.Status}}' "$svc" 2>/dev/null || echo "not_found")
            if [[ "$status" == "healthy" ]]; then
                log "${svc} is healthy ✓"
                break
            elif [[ "$status" == "not_found" ]]; then
                warn "${svc} container not found — may not have started yet"
                break
            fi
            sleep 10
            elapsed=$((elapsed + 10))
        done
        if [[ $elapsed -ge $max_wait ]]; then
            warn "${svc} did not become healthy within ${max_wait}s — check logs with: docker logs ${svc}"
        fi
    done
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    local host_ip
    host_ip=$(hostname -I | awk '{print $1}')

    header "SIEM Homelab — Ready!"

    echo -e "${BOLD}Dashboard URLs:${NC}"
    echo -e "  ${CYAN}🛡  Wazuh Dashboard${NC}   https://${host_ip}:5601"
    echo -e "  ${CYAN}🔍 Splunk Web${NC}         http://${host_ip}:8000"
    echo -e "  ${CYAN}🐝 TheHive${NC}            http://${host_ip}:9000"
    echo -e "  ${CYAN}🌐 MISP${NC}               https://${host_ip}:8443"
    echo -e "  ${CYAN}🏠 Landing Page${NC}       https://${host_ip}/"
    echo ""
    echo -e "${BOLD}Default Credentials:${NC}"
    echo -e "  Wazuh:    admin / SecretPassword!2025"
    echo -e "  Splunk:   admin / SplunkAdmin!2025"
    echo -e "  TheHive:  admin@thehive.local / secret  (set on first login)"
    echo -e "  MISP:     admin@siem.local / MISPAdmin!2025"
    echo ""
    echo -e "${YELLOW}⚠  Change all default passwords immediately!${NC}"
    echo -e "${YELLOW}⚠  Update credentials in .env and restart: docker compose down && docker compose up -d${NC}"
    echo ""
    echo -e "${BOLD}Useful Commands:${NC}"
    echo -e "  docker compose ps                # Check service status"
    echo -e "  docker compose logs -f <service> # Follow logs"
    echo -e "  docker compose down              # Stop all services"
    echo -e "  docker compose up -d             # Start all services"
    echo ""
    echo -e "${BOLD}Enroll a Wazuh Agent:${NC}"
    echo -e "  curl -so wazuh-agent.deb https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.9.2-1_amd64.deb"
    echo -e "  WAZUH_MANAGER='${host_ip}' dpkg -i wazuh-agent.deb"
    echo -e "  systemctl enable --now wazuh-agent"
    echo ""
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo -e "\n${BOLD}${CYAN}"
    echo "  ███████╗██╗███████╗███╗   ███╗"
    echo "  ██╔════╝██║██╔════╝████╗ ████║"
    echo "  ███████╗██║█████╗  ██╔████╔██║"
    echo "  ╚════██║██║██╔══╝  ██║╚██╔╝██║"
    echo "  ███████║██║███████╗██║ ╚═╝ ██║"
    echo "  ╚══════╝╚═╝╚══════╝╚═╝     ╚═╝"
    echo -e "  Homelab Security Stack${NC}\n"

    preflight
    tune_kernel
    generate_nginx_certs
    generate_wazuh_certs
    create_infrastructure
    pull_images
    start_services
    wait_for_health
    print_summary
}

main "$@"
