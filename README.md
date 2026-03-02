# 🛡️ SIEM Homelab

A production-ready, Docker-based Security Information & Event Management stack for my Ubuntu homelab.
READme written with GenAI.

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│                    Ubuntu Homelab                         │
│                                                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │
│  │   Wazuh      │  │  Splunk     │  │   Suricata      │  │
│  │  Indexer     │  │  Enterprise │  │   IDS           │  │
│  │  Manager     │  │  (Free)     │  │  (host network) │  │
│  │  Dashboard   │  │             │  │                 │  │
│  └──────┬───────┘  └──────┬──────┘  └────────┬────────┘  │
│         │                 │                   │           │
│         └────── siem-net (172.25.0.0/16) ─────┘           │
│                       │                                   │
│  ┌─────────────┐  ┌───┴──────────┐  ┌─────────────────┐  │
│  │  TheHive 5  │  │    Nginx     │  │     MISP        │  │
│  │  Cassandra  │  │  TLS Proxy   │  │  MySQL + Redis  │  │
│  │  Elastic    │  │  :443 :80    │  │                 │  │
│  └─────────────┘  └──────────────┘  └─────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

## Components

| Component | Version | Purpose | Port(s) |
|-----------|---------|---------|---------|
| **Wazuh Indexer** | 4.9.2 | OpenSearch-based log storage | 9200 |
| **Wazuh Manager** | 4.9.2 | Agent management, rule engine, alerts | 1514, 1515, 55000 |
| **Wazuh Dashboard** | 4.9.2 | Security visualization | 5601 |
| **Splunk Enterprise** | latest | SIEM analytics & correlation | 8000, 8088, 9997 |
| **Suricata** | latest | Network IDS (packet capture) | host network |
| **TheHive** | 5 | Incident response & case management | 9000 |
| **MISP** | latest | Threat intelligence & IOC sharing | 8443, 8080 |
| **Cassandra** | 4 | TheHive database backend | — |
| **Elasticsearch** | 7.17 | TheHive index backend | — |
| **MySQL** | 8.0 | MISP database backend | — |
| **Redis** | 7 | MISP cache | — |
| **Nginx** | alpine | TLS reverse proxy & landing page | 443, 80 |

## Requirements

- **OS**: Ubuntu 20.04+ (or any Docker-capable Linux)
- **RAM**: 16 GB (minimum 8 GB)
- **CPU**: 4+ cores
- **Disk**: 50 GB+ free
- **Docker**: 24.0+ with Compose v2
- **Network**: Interface `enp2s0` (configurable in `.env`)

## Quick Start

```bash
# 1. Clone / copy the project
cd /home/lawrence/.gemini/antigravity/scratch/siem-homelab

# 2. Review and customize credentials
nano .env

# 3. Run the bootstrap script (as root)
sudo ./setup.sh
```

The setup script will:
1. ✅ Validate prerequisites (Docker, RAM, disk)
2. ✅ Tune kernel parameters (`vm.max_map_count`)
3. ✅ Generate TLS certificates
4. ✅ Generate Wazuh inter-component certificates
5. ✅ Create Docker network & shared volumes
6. ✅ Pull all container images
7. ✅ Start all services
8. ✅ Wait for health checks
9. ✅ Print access URLs & credentials

## Accessing Dashboards

| Service | URL | Default Credentials |
|---------|-----|---------------------|
| **Landing Page** | `https://<host-ip>/` | — |
| **Wazuh** | `https://<host-ip>:5601` | `admin` / `SecretPassword!2025` |
| **Splunk** | `http://<host-ip>:8000` | `admin` / `SplunkAdmin!2025` |
| **TheHive** | `http://<host-ip>:9000` | Set on first login |
| **MISP** | `https://<host-ip>:8443` | `admin@siem.local` / `MISPAdmin!2025` |

> ⚠️ **Change all default passwords immediately after deployment!**

## Enrolling Wazuh Agents

To monitor additional hosts, install a Wazuh agent:

```bash
# On the target host (Debian/Ubuntu)
curl -so wazuh-agent.deb \
  https://packages.wazuh.com/4.x/apt/pool/main/w/wazuh-agent/wazuh-agent_4.9.2-1_amd64.deb

sudo WAZUH_MANAGER='<homelab-ip>' dpkg -i wazuh-agent.deb
sudo systemctl enable --now wazuh-agent
```

## Data Flow

```
Network Traffic
    └── Suricata (IDS) ──eve.json──→ Wazuh Manager
                                          │
Host Agents ─────────────────────────────→│
                                          │
Syslog Sources (UDP:514) ───────────────→│
                                          │
                                    ┌─────┴─────┐
                                    │ Wazuh      │
                                    │ Indexer    │──→ Wazuh Dashboard
                                    └───────────┘
                                          │
                                    alerts.json
                                          │
                                    ┌─────┴─────┐
                                    │  Splunk   │──→ Splunk Web
                                    │  (HEC)    │
                                    └───────────┘
                                          │
                              Alerts ────→│──→ TheHive (Cases)
                                                    │
                              IOCs ─────────────→ MISP
```

## Managing the Stack

```bash
# Check status
docker compose ps

# View logs
docker compose logs -f wazuh-manager
docker compose logs -f splunk
docker compose logs -f suricata

# Stop everything
docker compose down

# Start everything
docker compose up -d

# Restart a single service
docker compose restart splunk

# Update Suricata rules
docker compose exec suricata suricata-update
docker compose restart suricata

# Full reset (destroys data!)
docker compose down -v
```

## Project Structure

```
siem-homelab/
├── docker-compose.yml              # Master orchestrator
├── .env                            # Credentials & config
├── setup.sh                        # Bootstrap script
├── README.md                       # This file
├── wazuh/
│   ├── docker-compose.yml          # Wazuh stack
│   └── config/
│       └── wazuh_cluster/
│           └── wazuh_manager.conf  # Ossec config
├── splunk/
│   ├── docker-compose.yml          # Splunk stack
│   └── config/
│       └── inputs.conf             # Data inputs
├── suricata/
│   ├── docker-compose.yml          # Suricata IDS
│   └── config/
│       └── suricata.yaml           # IDS config
├── thehive/
│   └── docker-compose.yml          # TheHive + MISP + backends
└── nginx/
    ├── docker-compose.yml          # Reverse proxy
    ├── certs/                      # Auto-generated TLS certs
    └── config/
        └── nginx.conf              # Proxy routes
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Wazuh indexer won't start | `sudo sysctl -w vm.max_map_count=262144` |
| Containers restarting | Check RAM: `free -h` (need 16 GB) |
| Suricata no events | Verify interface: `ip link show enp2s0` |
| Splunk license warning | Free tier = 500 MB/day, this is normal |
| Certificate errors | Re-run: `sudo ./setup.sh` (idempotent) |
| Can't reach dashboards | Check: `docker compose ps` for unhealthy containers |
| Port conflicts | Check: `ss -tlnp | grep -E '(443|5601|8000|9000|9200)'` |

## Splunk Free Tier Notes

The Splunk Free license allows 500 MB/day of data ingestion. Limitations:
- No alerting or scheduled searches
- No distributed search
- No authentication (single admin user)
- No clustering

This is sufficient for a homelab. For more capacity, consider [Splunk Dev License](https://dev.splunk.com/enterprise/dev_license/).

## Security Notes

- All inter-service communication uses the `siem-net` bridge network (isolated)
- Wazuh components communicate over TLS with generated certificates
- Nginx provides TLS termination for external access
- Suricata runs in host network mode (required for packet capture)
- **Change all passwords in `.env` before production use**
