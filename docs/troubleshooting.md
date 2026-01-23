# Troubleshooting Guide

## Common Issues

### "Database verification failed" in Obsidian

The LiveSync plugin's "Check" button may show failures if CORS or other settings aren't applied correctly.

**Solution:**
```bash
# SSH into your LXC container
source /root/.obsidian-livesync-credentials
COUCH_URL="http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:5984"

# Reapply all settings
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/require_valid_user" -d '"true"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/enable_cors" -d '"true"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd/max_http_request_size" -d '"4294967296"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/chttpd_auth/require_valid_user" -d '"true"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/httpd/WWW-Authenticate" -d '"Basic realm=\"couchdb\""'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/httpd/enable_cors" -d '"true"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/couchdb/max_document_size" -d '"50000000"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/cors/credentials" -d '"true"'
curl -s -X PUT "${COUCH_URL}/_node/_local/_config/cors/origins" -d '"app://obsidian.md,capacitor://localhost,http://localhost"'
```

### Mobile app can't connect

Mobile apps require HTTPS. You need a reverse proxy with SSL.

**Quick test with Cloudflare Tunnel:**
```bash
# Install cloudflared
curl -L --output cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
dpkg -i cloudflared.deb

# Create a quick tunnel (temporary)
cloudflared tunnel --url http://localhost:5984
```

### Sync is slow or stuck

1. Check CouchDB status:
   ```bash
   curl http://localhost:5984/_up
   ```

2. Check for large files causing issues:
   ```bash
   # In Obsidian, check Settings > LiveSync > Hatch > Show status
   ```

3. Restart CouchDB:
   ```bash
   systemctl restart couchdb
   ```

### "Conflict" errors

This happens when the same note is edited on multiple devices simultaneously.

**Solution:**
1. Open the conflicted note
2. LiveSync will show conflict resolution options
3. Choose which version to keep

### High memory usage

CouchDB can be tuned for lower memory:

```bash
# Edit /opt/couchdb/etc/local.d/memory.ini
cat > /opt/couchdb/etc/local.d/memory.ini << EOF
[couchdb]
max_dbs_open = 100

[smoosh]
persist = false

[view_compaction]
keyvalue_buffer_size = 2097152
EOF

systemctl restart couchdb
```

### Container won't start after Proxmox update

Check if nesting is enabled:
```bash
# On Proxmox host
pct set CT_ID -features nesting=1
pct start CT_ID
```

## Logs

### CouchDB logs
```bash
journalctl -u couchdb -f
# or
tail -f /opt/couchdb/var/log/couchdb.log
```

### Check current configuration
```bash
source /root/.obsidian-livesync-credentials
curl -s "http://${COUCHDB_USER}:${COUCHDB_PASSWORD}@127.0.0.1:5984/_node/_local/_config" | python3 -m json.tool
```

## Reset Everything

If you need to start fresh:

```bash
# Stop CouchDB
systemctl stop couchdb

# Remove all data
rm -rf /opt/couchdb/data/*

# Start fresh
systemctl start couchdb

# Run setup again
/root/setup-couchdb.sh  # or /root/obsidian-livesync/scripts/install.sh
```

## Getting Help

1. Check [LiveSync GitHub Issues](https://github.com/vrtmrz/obsidian-livesync/issues)
2. Check [CouchDB Documentation](https://docs.couchdb.org/)
3. Open an issue on this repository
