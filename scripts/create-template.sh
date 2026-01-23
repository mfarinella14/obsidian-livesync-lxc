#!/bin/bash
#
# Create a reusable LXC template backup from an existing container
# This creates a .tar.zst file that can be shared via GitHub releases
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║         LXC Template Creator for GitHub Distribution          ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if running on Proxmox
if ! command -v vzdump &> /dev/null; then
    log_error "This script must be run on a Proxmox VE host."
    exit 1
fi

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
    exit 1
fi

# List available containers
echo "Available containers:"
pct list
echo ""

read -p "Enter the Container ID to create template from: " CT_ID

# Validate container exists
if ! pct status "$CT_ID" &>/dev/null; then
    log_error "Container $CT_ID does not exist."
    exit 1
fi

# Check if container is running
CT_STATUS=$(pct status "$CT_ID" | awk '{print $2}')
if [[ "$CT_STATUS" == "running" ]]; then
    log_warn "Container is running. It will be stopped for backup."
    read -p "Continue? [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

# Get template name
CT_HOSTNAME=$(pct config "$CT_ID" | grep hostname | awk '{print $2}')
DEFAULT_NAME="obsidian-livesync-template-$(date +%Y%m%d)"
read -p "Template name [${DEFAULT_NAME}]: " TEMPLATE_NAME
TEMPLATE_NAME=${TEMPLATE_NAME:-$DEFAULT_NAME}

# Output directory
read -p "Output directory [/tmp]: " OUTPUT_DIR
OUTPUT_DIR=${OUTPUT_DIR:-/tmp}

# Clean the container before backup (optional)
echo ""
log_info "Preparing container for template creation..."

# Stop container if running
if [[ "$CT_STATUS" == "running" ]]; then
    log_info "Stopping container..."
    pct stop "$CT_ID"
    sleep 3
fi

# Start to clean up
log_info "Starting container for cleanup..."
pct start "$CT_ID"
sleep 10

# Clean up inside container
log_info "Cleaning up container (removing logs, temp files, credentials)..."
pct exec "$CT_ID" -- bash -c "
    # Remove credentials (user should set their own)
    rm -f /root/.obsidian-livesync-credentials

    # Clean apt cache
    apt-get clean
    apt-get autoclean
    rm -rf /var/lib/apt/lists/*

    # Remove logs
    find /var/log -type f -name '*.log' -delete
    find /var/log -type f -name '*.gz' -delete
    journalctl --vacuum-time=1s 2>/dev/null || true

    # Remove bash history
    rm -f /root/.bash_history
    rm -f /home/*/.bash_history 2>/dev/null || true

    # Remove temp files
    rm -rf /tmp/*
    rm -rf /var/tmp/*

    # Remove SSH host keys (will be regenerated on first boot)
    rm -f /etc/ssh/ssh_host_*

    # Clear machine-id (will be regenerated)
    echo '' > /etc/machine-id

    # Remove CouchDB data (fresh start for new users)
    systemctl stop couchdb || true
    rm -rf /opt/couchdb/data/*

    echo 'Cleanup complete!'
"

# Stop container
log_info "Stopping container..."
pct stop "$CT_ID"
sleep 5

# Create the backup
OUTPUT_FILE="${OUTPUT_DIR}/${TEMPLATE_NAME}.tar.zst"
log_info "Creating template backup: ${OUTPUT_FILE}"

vzdump "$CT_ID" \
    --dumpdir "$OUTPUT_DIR" \
    --compress zstd \
    --mode stop

# Rename the backup file
BACKUP_FILE=$(ls -t "${OUTPUT_DIR}/vzdump-lxc-${CT_ID}-"*.tar.zst 2>/dev/null | head -1)
if [[ -n "$BACKUP_FILE" ]]; then
    mv "$BACKUP_FILE" "$OUTPUT_FILE"
    log_info "Template created: $OUTPUT_FILE"
else
    log_error "Backup file not found!"
    exit 1
fi

# Get file info
FILE_SIZE=$(du -h "$OUTPUT_FILE" | cut -f1)
FILE_SHA256=$(sha256sum "$OUTPUT_FILE" | awk '{print $1}')

echo ""
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                 Template Created Successfully!                 ${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "File: $OUTPUT_FILE"
echo "Size: $FILE_SIZE"
echo "SHA256: $FILE_SHA256"
echo ""
echo -e "${CYAN}To share on GitHub:${NC}"
echo "1. Create a new release on your repository"
echo "2. Upload ${TEMPLATE_NAME}.tar.zst as a release asset"
echo "3. Include the SHA256 checksum in the release notes"
echo ""
echo -e "${CYAN}For users to import:${NC}"
echo "1. Download the template to Proxmox: /var/lib/vz/template/cache/"
echo "2. Import: pct restore <VMID> /var/lib/vz/template/cache/${TEMPLATE_NAME}.tar.zst"
echo ""
echo -e "${YELLOW}Note: The template has been cleaned - users need to:${NC}"
echo "  - Run the setup wizard to configure CouchDB credentials"
echo "  - Or use the included /root/setup-couchdb.sh script"
echo ""

# Create a first-boot setup script
log_info "Creating first-boot setup script in container..."
pct start "$CT_ID"
sleep 5

pct exec "$CT_ID" -- bash -c 'cat > /root/setup-couchdb.sh << '\''SETUP'\''
#!/bin/bash
#
# First-boot CouchDB setup for Obsidian LiveSync
#

set -e

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
NC="\033[0m"

echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║         Obsidian LiveSync - First Boot Setup                  ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check if CouchDB is installed
if ! systemctl is-active --quiet couchdb; then
    echo "Starting CouchDB..."
    systemctl start couchdb
    sleep 5
fi

echo ""
echo "Please configure your CouchDB credentials:"
echo ""

read -p "Admin username [admin]: " COUCHDB_USER
COUCHDB_USER=${COUCHDB_USER:-admin}

while true; do
    read -s -p "Admin password: " COUCHDB_PASSWORD
    echo ""
    if [[ -z "$COUCHDB_PASSWORD" ]]; then
        echo -e "${YELLOW}Password cannot be empty.${NC}"
    else
        read -s -p "Confirm password: " COUCHDB_PASSWORD_CONFIRM
        echo ""
        if [[ "$COUCHDB_PASSWORD" == "$COUCHDB_PASSWORD_CONFIRM" ]]; then
            break
        else
            echo -e "${YELLOW}Passwords do not match.${NC}"
        fi
    fi
done

read -p "Database name [obsidian]: " DATABASE_NAME
DATABASE_NAME=${DATABASE_NAME:-obsidian}

echo ""
echo "Configuring CouchDB..."

# Set admin password
curl -s -X PUT http://127.0.0.1:5984/_node/_local/_config/admins/${COUCHDB_USER} -d "\"${COUCHDB_PASSWORD}\""

COUCH_URL="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:5984"

# Apply LiveSync configuration
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/require_valid_user" -d "\"true\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/enable_cors" -d "\"true\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/max_http_request_size" -d "\"4294967296\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd_auth/require_valid_user" -d "\"true\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/httpd/WWW-Authenticate" -d "\"Basic realm=\\\"couchdb\\\"\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/httpd/enable_cors" -d "\"true\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/couchdb/max_document_size" -d "\"50000000\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/cors/credentials" -d "\"true\""
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/cors/origins" -d "\"app://obsidian.md,capacitor://localhost,http://localhost\""

# Create database
curl -s -X PUT "${COUCH_URL}/${DATABASE_NAME}"

# Save credentials
cat > /root/.obsidian-livesync-credentials << EOF
COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${COUCHDB_PASSWORD}
DATABASE_NAME=${DATABASE_NAME}
EOF
chmod 600 /root/.obsidian-livesync-credentials

IP_ADDR=$(hostname -I | awk "{print \$1}")

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "CouchDB Admin: http://${IP_ADDR}:5984/_utils"
echo ""
echo "Obsidian LiveSync settings:"
echo "  URI:      http://${IP_ADDR}:5984"
echo "  Username: ${COUCHDB_USER}"
echo "  Database: ${DATABASE_NAME}"
echo ""
SETUP
chmod +x /root/setup-couchdb.sh'

pct stop "$CT_ID"

log_info "Setup script created in container."
log_info "Done! You can now share ${OUTPUT_FILE}"
