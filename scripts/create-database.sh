#!/bin/bash
#
# Create additional database for Obsidian LiveSync
# Useful for multi-user setups where each user needs their own database
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check for credentials file
CREDS_FILE="/root/.obsidian-livesync-credentials"
if [[ -f "$CREDS_FILE" ]]; then
    source "$CREDS_FILE"
else
    log_warn "Credentials file not found. Please enter CouchDB admin credentials."
    read -p "CouchDB Admin Username: " COUCHDB_USER
    read -s -p "CouchDB Admin Password: " COUCHDB_PASSWORD
    echo ""
fi

COUCHDB_PORT=${COUCHDB_PORT:-5984}

# Get new database name
echo ""
read -p "Enter new database name (e.g., obsidian_john): " NEW_DB_NAME

if [[ -z "$NEW_DB_NAME" ]]; then
    log_error "Database name cannot be empty."
    exit 1
fi

# Validate database name (CouchDB naming rules)
if [[ ! "$NEW_DB_NAME" =~ ^[a-z][a-z0-9_\$\(\)+/-]*$ ]]; then
    log_error "Invalid database name. Must start with lowercase letter and contain only: a-z, 0-9, _, \$, (, ), +, -, /"
    exit 1
fi

COUCH_URL="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:${COUCHDB_PORT}"

log_info "Creating database: ${NEW_DB_NAME}..."

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${COUCH_URL}/${NEW_DB_NAME}")

if [[ "$HTTP_CODE" == "201" ]]; then
    log_info "Database '${NEW_DB_NAME}' created successfully!"

    IP_ADDR=$(hostname -I | awk '{print $1}')
    echo ""
    echo "Use these settings in Obsidian LiveSync:"
    echo "  URI: http://${IP_ADDR}:${COUCHDB_PORT}"
    echo "  Username: ${COUCHDB_USER}"
    echo "  Database: ${NEW_DB_NAME}"
    echo ""
elif [[ "$HTTP_CODE" == "412" ]]; then
    log_warn "Database '${NEW_DB_NAME}' already exists."
elif [[ "$HTTP_CODE" == "401" ]]; then
    log_error "Authentication failed. Check your credentials."
    exit 1
else
    log_error "Failed to create database. HTTP code: ${HTTP_CODE}"
    exit 1
fi
