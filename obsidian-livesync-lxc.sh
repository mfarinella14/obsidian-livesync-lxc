#!/usr/bin/env bash
#
# Obsidian LiveSync LXC Creator for Proxmox VE
#
# This script creates an LXC container on Proxmox and installs
# CouchDB configured for Obsidian LiveSync.
#
# Run this script directly on your Proxmox host:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/ril3y/obsidian-livesync-lxc/main/obsidian-livesync-lxc.sh)"
#
# Based on the helper script pattern from the Proxmox community
#

set -euo pipefail

# Script version
VERSION="1.0.0"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Default values
DEFAULT_CT_ID=""
DEFAULT_HOSTNAME="obsidian-livesync"
DEFAULT_DISK_SIZE="4"
DEFAULT_RAM="512"
DEFAULT_CORES="1"
DEFAULT_BRIDGE="vmbr0"
DEFAULT_STORAGE="local-lvm"
DEFAULT_TEMPLATE_STORAGE="local"

# Variables to be set by user
CT_ID=""
HOSTNAME=""
DISK_SIZE=""
RAM=""
CORES=""
BRIDGE=""
STORAGE=""
TEMPLATE_STORAGE=""
PASSWORD=""
COUCHDB_USER=""
COUCHDB_PASSWORD=""
DATABASE_NAME=""

print_banner() {
    clear
    echo -e "${BLUE}"
    cat << "EOF"
   ___  _         _     _ _             _     _          ____
  / _ \| |__  ___(_) __| (_) __ _ _ __ | |   (_)_   _____/ ___| _   _ _ __   ___
 | | | | '_ \/ __| |/ _` | |/ _` | '_ \| |   | \ \ / / _ \___ \| | | | '_ \ / __|
 | |_| | |_) \__ \ | (_| | | (_| | | | | |___| |\ V /  __/___) | |_| | | | | (__
  \___/|_.__/|___/_|\__,_|_|\__,_|_| |_|_____|_| \_/ \___|____/ \__, |_| |_|\___|
                                                                |___/
EOF
    echo -e "${NC}"
    echo -e "${CYAN}Proxmox LXC Creator v${VERSION}${NC}"
    echo ""
}

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }

check_proxmox() {
    if ! command -v pveversion &> /dev/null; then
        log_error "This script must be run on a Proxmox VE host."
        exit 1
    fi
    log_info "Proxmox VE detected: $(pveversion --verbose | head -1)"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

get_next_ct_id() {
    # Find the next available VMID (checking both VMs and containers)
    local id=100
    while pct status $id &>/dev/null || qm status $id &>/dev/null; do
        ((id++))
    done
    echo $id
}

get_storage_list() {
    pvesm status -content rootdir | awk 'NR>1 {print $1}'
}

get_template_storage_list() {
    pvesm status -content vztmpl | awk 'NR>1 {print $1}'
}

get_bridge_list() {
    ip -o link show type bridge | awk -F': ' '{print $2}'
}

select_template() {
    log_step "Selecting container template..."

    # Update template list
    log_info "Updating template list..."
    pveam update &>/dev/null || true

    # Get available Debian templates
    TEMPLATES=$(pveam available -section system | grep -E "debian-1[12]" | awk '{print $2}' | sort -V | tail -5)

    if [[ -z "$TEMPLATES" ]]; then
        log_error "No Debian templates found. Please download a template first."
        exit 1
    fi

    echo ""
    echo "Available templates:"
    echo "$TEMPLATES" | nl -w2 -s") "
    echo ""

    # Use latest Debian by default
    DEFAULT_TEMPLATE=$(echo "$TEMPLATES" | tail -1)
    read -p "Select template number [latest: ${DEFAULT_TEMPLATE}]: " TEMPLATE_NUM

    if [[ -z "$TEMPLATE_NUM" ]]; then
        TEMPLATE="$DEFAULT_TEMPLATE"
    else
        TEMPLATE=$(echo "$TEMPLATES" | sed -n "${TEMPLATE_NUM}p")
    fi

    if [[ -z "$TEMPLATE" ]]; then
        log_error "Invalid template selection."
        exit 1
    fi

    log_info "Selected template: $TEMPLATE"

    # Check if template is downloaded
    if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
        log_info "Downloading template..."
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
    fi
}

get_user_config() {
    echo ""
    log_step "Container Configuration"
    echo ""

    # CT ID
    DEFAULT_CT_ID=$(get_next_ct_id)
    read -p "Container ID [${DEFAULT_CT_ID}]: " CT_ID
    CT_ID=${CT_ID:-$DEFAULT_CT_ID}

    # Validate CT ID
    if [[ ! "$CT_ID" =~ ^[0-9]+$ ]] || [[ "$CT_ID" -lt 100 ]]; then
        log_error "Container ID must be a number >= 100."
        exit 1
    fi

    # Check if VMID exists (as container OR VM)
    if pct status $CT_ID &>/dev/null || qm status $CT_ID &>/dev/null; then
        log_error "VMID $CT_ID already exists (as VM or container)."
        exit 1
    fi

    # Hostname
    read -p "Hostname [${DEFAULT_HOSTNAME}]: " HOSTNAME
    HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

    # Root password
    while true; do
        read -s -p "Root password for container: " PASSWORD
        echo ""
        if [[ -z "$PASSWORD" ]]; then
            log_warn "Password cannot be empty."
        else
            read -s -p "Confirm password: " PASSWORD_CONFIRM
            echo ""
            if [[ "$PASSWORD" == "$PASSWORD_CONFIRM" ]]; then
                break
            else
                log_warn "Passwords do not match."
            fi
        fi
    done

    echo ""
    log_step "Resource Configuration"
    echo ""

    # Disk size
    read -p "Disk size in GB [${DEFAULT_DISK_SIZE}]: " DISK_SIZE
    DISK_SIZE=${DISK_SIZE:-$DEFAULT_DISK_SIZE}

    # RAM
    read -p "RAM in MB [${DEFAULT_RAM}]: " RAM
    RAM=${RAM:-$DEFAULT_RAM}

    # CPU cores
    read -p "CPU cores [${DEFAULT_CORES}]: " CORES
    CORES=${CORES:-$DEFAULT_CORES}

    echo ""
    log_step "Storage Configuration"
    echo ""

    # Storage for container
    STORAGES=$(get_storage_list)
    echo "Available storage for container:"
    echo "$STORAGES" | nl -w2 -s") "
    read -p "Select storage number [${DEFAULT_STORAGE}]: " STORAGE_NUM
    if [[ -n "$STORAGE_NUM" ]]; then
        STORAGE=$(echo "$STORAGES" | sed -n "${STORAGE_NUM}p")
    fi
    STORAGE=${STORAGE:-$DEFAULT_STORAGE}

    # Template storage
    TEMPLATE_STORAGES=$(get_template_storage_list)
    echo ""
    echo "Available template storage:"
    echo "$TEMPLATE_STORAGES" | nl -w2 -s") "
    read -p "Select template storage number [${DEFAULT_TEMPLATE_STORAGE}]: " TSTORAGE_NUM
    if [[ -n "$TSTORAGE_NUM" ]]; then
        TEMPLATE_STORAGE=$(echo "$TEMPLATE_STORAGES" | sed -n "${TSTORAGE_NUM}p")
    fi
    TEMPLATE_STORAGE=${TEMPLATE_STORAGE:-$DEFAULT_TEMPLATE_STORAGE}

    echo ""
    log_step "Network Configuration"
    echo ""

    # Network bridge
    BRIDGES=$(get_bridge_list)
    echo "Available network bridges:"
    echo "$BRIDGES" | nl -w2 -s") "
    read -p "Select bridge number [${DEFAULT_BRIDGE}]: " BRIDGE_NUM
    if [[ -n "$BRIDGE_NUM" ]]; then
        BRIDGE=$(echo "$BRIDGES" | sed -n "${BRIDGE_NUM}p")
    fi
    BRIDGE=${BRIDGE:-$DEFAULT_BRIDGE}

    # VLAN tagging (optional)
    read -p "VLAN ID (optional, leave blank for none): " VLAN_ID

    # IP configuration
    echo ""
    echo "IP Configuration:"
    echo "1) DHCP (recommended)"
    echo "2) Static IP"
    read -p "Select [1]: " IP_CONFIG
    IP_CONFIG=${IP_CONFIG:-1}

    if [[ "$IP_CONFIG" == "2" ]]; then
        read -p "IP Address (e.g., 192.168.1.100/24): " STATIC_IP
        read -p "Gateway (e.g., 192.168.1.1): " GATEWAY
        NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${STATIC_IP},gw=${GATEWAY}"
    else
        NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=dhcp"
    fi

    # Append VLAN tag if provided
    if [[ -n "$VLAN_ID" ]]; then
        NET_CONFIG+=",tag=${VLAN_ID}"
    fi

    echo ""
    log_step "CouchDB Configuration"
    echo ""

    # CouchDB credentials
    read -p "CouchDB admin username [admin]: " COUCHDB_USER
    COUCHDB_USER=${COUCHDB_USER:-admin}

    while true; do
        read -s -p "CouchDB admin password: " COUCHDB_PASSWORD
        echo ""
        if [[ -z "$COUCHDB_PASSWORD" ]]; then
            log_warn "Password cannot be empty."
        else
            read -s -p "Confirm password: " COUCHDB_PASSWORD_CONFIRM
            echo ""
            if [[ "$COUCHDB_PASSWORD" == "$COUCHDB_PASSWORD_CONFIRM" ]]; then
                break
            else
                log_warn "Passwords do not match."
            fi
        fi
    done

    read -p "Database name [obsidian]: " DATABASE_NAME
    DATABASE_NAME=${DATABASE_NAME:-obsidian}
}

show_summary() {
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}                    Configuration Summary                       ${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo "Container Settings:"
    echo "  ID:        $CT_ID"
    echo "  Hostname:  $HOSTNAME"
    echo "  Template:  $TEMPLATE"
    echo ""
    echo "Resources:"
    echo "  Disk:      ${DISK_SIZE}GB"
    echo "  RAM:       ${RAM}MB"
    echo "  CPU:       ${CORES} core(s)"
    echo ""
    echo "Storage:"
    echo "  Container: $STORAGE"
    echo "  Templates: $TEMPLATE_STORAGE"
    echo ""
    echo "Network:"
    echo "  Bridge:    $BRIDGE"
    echo "  Config:    ${NET_CONFIG#*ip=}"
    echo ""
    echo "CouchDB:"
    echo "  Username:  $COUCHDB_USER"
    echo "  Database:  $DATABASE_NAME"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo ""

    read -p "Create container with these settings? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Aborted."
        exit 0
    fi
}

create_container() {
    log_step "Creating LXC container..."

    # Create the container
    pct create "$CT_ID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
        --hostname "$HOSTNAME" \
        --password "$PASSWORD" \
        --rootfs "${STORAGE}:${DISK_SIZE}" \
        --memory "$RAM" \
        --cores "$CORES" \
        --net0 "$NET_CONFIG" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --start 0

    log_info "Container $CT_ID created successfully!"
}

start_container() {
    log_step "Starting container..."
    pct start "$CT_ID"

    # Wait for container to be running
    log_info "Waiting for container to start..."
    sleep 5

    # Wait for network
    log_info "Waiting for network..."
    for i in {1..30}; do
        if pct exec "$CT_ID" -- ping -c1 google.com &>/dev/null; then
            break
        fi
        sleep 2
    done
}

install_couchdb() {
    log_step "Installing CouchDB in container..."

    # Create installation script inside container
    pct exec "$CT_ID" -- bash -c "cat > /tmp/install-couchdb.sh << 'SCRIPT'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# Fix locale issues
apt-get update -qq
apt-get install -y -qq locales
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
locale-gen en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Update and install dependencies
apt-get install -y -qq curl apt-transport-https gnupg ca-certificates

# Add CouchDB repository
curl -fsSL https://couchdb.apache.org/repo/keys.asc | gpg --dearmor -o /usr/share/keyrings/couchdb-archive-keyring.gpg

. /etc/os-release
if [[ \"\$ID\" == \"debian\" ]]; then
    # Use VERSION_CODENAME for correct Debian version (bullseye, bookworm, etc)
    REPO_DISTRO=\"\${VERSION_CODENAME}\"
elif [[ \"\$ID\" == \"ubuntu\" ]]; then
    # Ubuntu codenames: focal (20.04), jammy (22.04), noble (24.04)
    REPO_DISTRO=\"\${VERSION_CODENAME}\"
else
    REPO_DISTRO=\"focal\"
fi

echo \"deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] https://apache.jfrog.io/artifactory/couchdb-deb/ \${REPO_DISTRO} main\" > /etc/apt/sources.list.d/couchdb.list

apt-get update -qq

# Pre-configure CouchDB
echo \"couchdb couchdb/mode select standalone\" | debconf-set-selections
echo \"couchdb couchdb/bindaddress string 0.0.0.0\" | debconf-set-selections
echo \"couchdb couchdb/cookie string \$(openssl rand -hex 32)\" | debconf-set-selections
echo \"couchdb couchdb/adminpass password ${COUCHDB_PASSWORD}\" | debconf-set-selections
echo \"couchdb couchdb/adminpass_again password ${COUCHDB_PASSWORD}\" | debconf-set-selections

# Install CouchDB
apt-get install -y couchdb

systemctl enable couchdb
systemctl start couchdb

echo 'CouchDB installed!'
SCRIPT
chmod +x /tmp/install-couchdb.sh
"

    # Run installation
    pct exec "$CT_ID" -- /tmp/install-couchdb.sh

    log_info "CouchDB installed!"
}

configure_livesync() {
    log_step "Configuring CouchDB for LiveSync..."

    pct exec "$CT_ID" -- bash -c "
        sleep 5

        COUCH_URL='http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:5984'

        # Wait for CouchDB
        for i in {1..30}; do
            curl -s \"\${COUCH_URL}/_up\" | grep -q 'ok' && break
            sleep 1
        done

        # Apply LiveSync configuration
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/chttpd/require_valid_user\" -d '\"true\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/chttpd/enable_cors\" -d '\"true\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/chttpd/max_http_request_size\" -d '\"4294967296\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/chttpd_auth/require_valid_user\" -d '\"true\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/httpd/WWW-Authenticate\" -d '\"Basic realm=\\\"couchdb\\\"\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/httpd/enable_cors\" -d '\"true\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/couchdb/max_document_size\" -d '\"50000000\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/cors/credentials\" -d '\"true\"'
        curl -s -X PUT \"\${COUCH_URL}/_node/_local/_config/cors/origins\" -d '\"app://obsidian.md,capacitor://localhost,http://localhost\"'

        # Create database
        curl -s -X PUT \"\${COUCH_URL}/${DATABASE_NAME}\"

        echo 'Configuration complete!'
    "

    log_info "LiveSync configuration applied!"
}

save_info() {
    # Save credentials inside container
    pct exec "$CT_ID" -- bash -c "cat > /root/.obsidian-livesync-credentials << EOF
# Obsidian LiveSync - CouchDB Credentials
COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${COUCHDB_PASSWORD}
DATABASE_NAME=${DATABASE_NAME}
EOF
chmod 600 /root/.obsidian-livesync-credentials
"
}

print_success() {
    # Get container IP
    sleep 3
    CT_IP=$(pct exec "$CT_ID" -- hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              Installation Complete!                           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "Container Details:"
    echo "  ID:       $CT_ID"
    echo "  Hostname: $HOSTNAME"
    echo "  IP:       $CT_IP"
    echo ""
    echo "CouchDB Admin Interface:"
    echo "  URL: http://${CT_IP}:5984/_utils"
    echo ""
    echo -e "${CYAN}Obsidian LiveSync Settings:${NC}"
    echo "  URI:      http://${CT_IP}:5984"
    echo "  Username: ${COUCHDB_USER}"
    echo "  Password: (as configured)"
    echo "  Database: ${DATABASE_NAME}"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC}"
    echo "  1. For mobile devices, set up HTTPS via reverse proxy"
    echo "  2. Enable End-to-End Encryption in LiveSync plugin"
    echo "  3. Container root password is what you configured"
    echo ""
    echo "Access container: pct enter $CT_ID"
    echo ""
}

# Main
main() {
    print_banner
    check_root
    check_proxmox
    get_user_config
    select_template
    show_summary
    create_container
    start_container
    install_couchdb
    configure_livesync
    save_info
    print_success
}

main "$@"
