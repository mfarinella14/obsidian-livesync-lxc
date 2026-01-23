#!/bin/bash
#
# Obsidian LiveSync - CouchDB Installation Script for LXC
# This script installs and configures CouchDB for use with Obsidian LiveSync
#
# Usage: ./install.sh
#
# Repository: https://github.com/ril3y/obsidian-livesync-lxc
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
COUCHDB_VERSION="3.3"
COUCHDB_BIND_ADDRESS="0.0.0.0"
COUCHDB_PORT="5984"

print_banner() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║         Obsidian LiveSync - CouchDB LXC Installer             ║"
    echo "║                                                               ║"
    echo "║  This script will install and configure CouchDB for use      ║"
    echo "║  with the Obsidian LiveSync plugin.                          ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        log_info "Detected OS: $OS $VERSION"
    else
        log_error "Cannot detect OS. This script supports Debian and Ubuntu."
        exit 1
    fi

    if [[ "$OS" != "debian" && "$OS" != "ubuntu" ]]; then
        log_error "This script only supports Debian and Ubuntu."
        exit 1
    fi
}

get_user_input() {
    echo ""
    log_info "Please provide the following configuration details:"
    echo ""

    # CouchDB Admin Username
    read -p "CouchDB Admin Username [admin]: " COUCHDB_USER
    COUCHDB_USER=${COUCHDB_USER:-admin}

    # CouchDB Admin Password
    while true; do
        read -s -p "CouchDB Admin Password: " COUCHDB_PASSWORD
        echo ""
        if [[ -z "$COUCHDB_PASSWORD" ]]; then
            log_warn "Password cannot be empty. Please try again."
        else
            read -s -p "Confirm Password: " COUCHDB_PASSWORD_CONFIRM
            echo ""
            if [[ "$COUCHDB_PASSWORD" == "$COUCHDB_PASSWORD_CONFIRM" ]]; then
                break
            else
                log_warn "Passwords do not match. Please try again."
            fi
        fi
    done

    # Database name
    read -p "Database name for Obsidian [obsidian]: " DATABASE_NAME
    DATABASE_NAME=${DATABASE_NAME:-obsidian}

    echo ""
    log_info "Configuration Summary:"
    echo "  - CouchDB User: $COUCHDB_USER"
    echo "  - Database Name: $DATABASE_NAME"
    echo "  - CouchDB Port: $COUCHDB_PORT"
    echo ""

    read -p "Proceed with installation? [Y/n]: " CONFIRM
    CONFIRM=${CONFIRM:-Y}
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
}

install_dependencies() {
    log_info "Updating package lists..."
    apt-get update -qq

    log_info "Fixing locale settings..."
    apt-get install -y -qq locales > /dev/null
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
    locale-gen en_US.UTF-8 > /dev/null
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    log_info "Installing dependencies..."
    apt-get install -y -qq \
        curl \
        apt-transport-https \
        gnupg \
        ca-certificates \
        software-properties-common \
        > /dev/null
}

install_couchdb() {
    log_info "Adding CouchDB repository..."

    # Add CouchDB GPG key
    curl -fsSL https://couchdb.apache.org/repo/keys.asc | gpg --dearmor -o /usr/share/keyrings/couchdb-archive-keyring.gpg

    # Determine the correct repo based on OS (use VERSION_CODENAME for accuracy)
    . /etc/os-release
    if [[ "$ID" == "debian" || "$ID" == "ubuntu" ]]; then
        REPO_DISTRO="${VERSION_CODENAME}"
    else
        REPO_DISTRO="focal"  # Fallback
    fi
    log_info "Using repository: ${REPO_DISTRO}"

    # Add CouchDB repository
    echo "deb [signed-by=/usr/share/keyrings/couchdb-archive-keyring.gpg] https://apache.jfrog.io/artifactory/couchdb-deb/ ${REPO_DISTRO} main" \
        > /etc/apt/sources.list.d/couchdb.list

    log_info "Updating package lists..."
    apt-get update -qq

    log_info "Installing CouchDB (this may take a few minutes)..."

    # Pre-seed debconf answers for non-interactive installation
    echo "couchdb couchdb/mode select standalone" | debconf-set-selections
    echo "couchdb couchdb/mode seen true" | debconf-set-selections
    echo "couchdb couchdb/bindaddress string ${COUCHDB_BIND_ADDRESS}" | debconf-set-selections
    echo "couchdb couchdb/bindaddress seen true" | debconf-set-selections
    echo "couchdb couchdb/cookie string $(openssl rand -hex 32)" | debconf-set-selections
    echo "couchdb couchdb/adminpass password ${COUCHDB_PASSWORD}" | debconf-set-selections
    echo "couchdb couchdb/adminpass seen true" | debconf-set-selections
    echo "couchdb couchdb/adminpass_again password ${COUCHDB_PASSWORD}" | debconf-set-selections
    echo "couchdb couchdb/adminpass_again seen true" | debconf-set-selections

    DEBIAN_FRONTEND=noninteractive apt-get install -y couchdb

    log_info "CouchDB installed successfully!"
}

configure_couchdb_for_livesync() {
    log_info "Configuring CouchDB for Obsidian LiveSync..."

    # Wait for CouchDB to start
    sleep 3

    # Check if CouchDB is running
    if ! systemctl is-active --quiet couchdb; then
        log_info "Starting CouchDB service..."
        systemctl start couchdb
        sleep 5
    fi

    # Base URL for CouchDB API
    COUCH_URL="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}"

    # Wait for CouchDB to be ready
    log_info "Waiting for CouchDB to be ready..."
    for i in {1..30}; do
        if curl -s "${COUCH_URL}/_up" | grep -q "ok"; then
            break
        fi
        sleep 1
    done

    # Configure CouchDB settings for LiveSync
    log_info "Applying LiveSync configuration..."

    # chttpd settings
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/require_valid_user" -d '"true"' > /dev/null
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/enable_cors" -d '"true"' > /dev/null
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/max_http_request_size" -d '"4294967296"' > /dev/null

    # chttpd_auth settings
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd_auth/require_valid_user" -d '"true"' > /dev/null

    # httpd settings
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/httpd/WWW-Authenticate" -d '"Basic realm=\"couchdb\""' > /dev/null
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/httpd/enable_cors" -d '"true"' > /dev/null

    # couchdb settings
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/couchdb/max_document_size" -d '"50000000"' > /dev/null

    # CORS settings
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/cors/credentials" -d '"true"' > /dev/null
    curl -s -X PUT "${COUCH_URL}/_node/_local/_config/cors/origins" -d '"app://obsidian.md,capacitor://localhost,http://localhost"' > /dev/null

    log_info "CouchDB configuration applied!"
}

create_database() {
    log_info "Creating database: ${DATABASE_NAME}..."

    COUCH_URL="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}"

    # Create the database
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${COUCH_URL}/${DATABASE_NAME}")

    if [[ "$HTTP_CODE" == "201" ]]; then
        log_info "Database '${DATABASE_NAME}' created successfully!"
    elif [[ "$HTTP_CODE" == "412" ]]; then
        log_warn "Database '${DATABASE_NAME}' already exists."
    else
        log_error "Failed to create database. HTTP code: ${HTTP_CODE}"
    fi
}

enable_service() {
    log_info "Enabling CouchDB service to start on boot..."
    systemctl enable couchdb
    systemctl restart couchdb
}

verify_installation() {
    log_info "Verifying installation..."

    COUCH_URL="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}"

    # Check CouchDB status
    if curl -s "${COUCH_URL}/_up" | grep -q "ok"; then
        log_info "CouchDB is running and healthy!"
    else
        log_error "CouchDB health check failed!"
        exit 1
    fi

    # Check database exists
    if curl -s "${COUCH_URL}/${DATABASE_NAME}" | grep -q "db_name"; then
        log_info "Database '${DATABASE_NAME}' is accessible!"
    else
        log_error "Database verification failed!"
        exit 1
    fi
}

save_credentials() {
    # Save credentials to a file for reference
    CREDS_FILE="/root/.obsidian-livesync-credentials"
    cat > "${CREDS_FILE}" << EOF
# Obsidian LiveSync - CouchDB Credentials
# Generated on $(date)
# KEEP THIS FILE SECURE!

COUCHDB_USER=${COUCHDB_USER}
COUCHDB_PASSWORD=${COUCHDB_PASSWORD}
DATABASE_NAME=${DATABASE_NAME}
COUCHDB_URL=http://YOUR_SERVER_IP:${COUCHDB_PORT}
EOF
    chmod 600 "${CREDS_FILE}"
    log_info "Credentials saved to ${CREDS_FILE}"
}

print_success() {
    # Get the IP address
    IP_ADDR=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${GREEN}"
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║              Installation Complete!                           ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo "CouchDB Admin Interface:"
    echo "  URL: http://${IP_ADDR}:${COUCHDB_PORT}/_utils"
    echo ""
    echo "Obsidian LiveSync Settings:"
    echo "  URI: http://${IP_ADDR}:${COUCHDB_PORT}"
    echo "  Username: ${COUCHDB_USER}"
    echo "  Password: (as configured)"
    echo "  Database: ${DATABASE_NAME}"
    echo ""
    echo -e "${YELLOW}IMPORTANT:${NC}"
    echo "  1. For mobile devices, you MUST use HTTPS via a reverse proxy"
    echo "  2. Enable End-to-End Encryption in the LiveSync plugin"
    echo "  3. Credentials saved to: /root/.obsidian-livesync-credentials"
    echo ""
    echo "For additional databases (multiple users), run:"
    echo "  /root/obsidian-livesync/scripts/create-database.sh"
    echo ""
}

# Main execution
main() {
    print_banner
    check_root
    check_os
    get_user_input
    install_dependencies
    install_couchdb
    configure_couchdb_for_livesync
    create_database
    enable_service
    verify_installation
    save_credentials
    print_success
}

main "$@"
