# Obsidian LiveSync LXC for Proxmox

One-command deployment of self-hosted Obsidian sync using CouchDB in a Proxmox LXC container.

Sync your Obsidian notes across all devices instantly with end-to-end encryption - completely self-hosted on your own server.

Based on the [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin by vrtmrz.

## Features

- **Instant sync** between all your Obsidian devices
- **End-to-end encryption** - your notes stay private
- **Self-hosted** - no cloud services, your data stays on your server
- **Lightweight** - runs in a small LXC container (512MB RAM)
- **Easy setup** - interactive script handles everything

## Quick Start

Run this command on your **Proxmox host**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ril3y/obsidian-livesync-lxc/main/obsidian-livesync-lxc.sh)"
```

The script will:
1. Create an LXC container
2. Install and configure CouchDB
3. Apply all LiveSync-compatible settings
4. Create your Obsidian database

After completion, you'll see:
```
Container Details:
  ID:       102
  Hostname: obsidian-livesync
  IP:       192.168.1.110

CouchDB Admin Interface:
  URL: http://192.168.1.110:5984/_utils

Obsidian LiveSync Settings:
  URI:      http://192.168.1.110:5984
  Username: admin
  Database: obsidian
```

---

## Configuring Obsidian

### Step 1: Install the LiveSync Plugin

1. Open **Obsidian** on your computer
2. Go to **Settings** (gear icon, bottom left)
3. Click **Community plugins** in the sidebar
4. Click **Turn on community plugins** (if prompted)
5. Click **Browse**
6. Search for **Self-hosted LiveSync**
7. Click **Install**, then **Enable**

### Step 2: Configure the Plugin

1. In Settings, find **Self-hosted LiveSync** in the sidebar
2. Click the **🛰️ Remote Database** button (4th icon in the top row)

3. Enter your server details:

   | Setting | Value |
   |---------|-------|
   | Remote Type | `CouchDB` |
   | URI | `http://YOUR_SERVER_IP:5984` |
   | Username | `admin` (or your configured username) |
   | Password | Your configured password |
   | Database | `obsidian` (or your database name) |

4. Click **Test Database Connection**
   - Should say: "Connected to obsidian successfully"

5. Click **Check and Fix**
   - All items should show checkmarks ✓

6. Click **Apply**

### Step 3: Enable Live Sync

1. Click the **🔄 Sync Settings** button (5th icon)
2. Set **Sync Mode** to `LiveSync`
3. Close settings

You should see **Sync: ⚡** or **Sync: zZz** in the status bar - sync is now active!

### Step 4: Enable Encryption (Recommended)

1. In LiveSync settings, scroll to **End-to-end Encryption**
2. Toggle it **ON**
3. Enter a strong passphrase
4. Click **Apply**

> **Important:** Use the same passphrase on ALL your devices!

### Step 5: Set Up Additional Devices

Repeat Steps 1-4 on each device (phone, tablet, other computers).

For mobile devices, see [HTTPS Setup](#https-for-mobile-devices) below.

---

## Container Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM      | 256MB   | 512MB       |
| Disk     | 2GB     | 4-8GB       |
| CPU      | 1 core  | 1 core      |

---

## Alternative Installation Methods

### Install on Existing LXC

If you have an existing Debian/Ubuntu LXC container:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ril3y/obsidian-livesync-lxc/main/scripts/install.sh)"
```

### Use Pre-built Template

1. Download from [Releases](https://github.com/ril3y/obsidian-livesync-lxc/releases)
2. Copy to Proxmox:
   ```bash
   scp obsidian-livesync-*.tar.zst root@proxmox:/var/lib/vz/template/cache/
   ```
3. Restore:
   ```bash
   pct restore 102 /var/lib/vz/template/cache/obsidian-livesync-*.tar.zst
   pct start 102
   pct enter 102
   /root/setup-couchdb.sh
   ```

---

## HTTPS for Mobile Devices

Mobile apps (iOS/Android) **require HTTPS**. You need a reverse proxy.

### Option 1: Nginx Proxy Manager (Easiest)

1. Install [Nginx Proxy Manager](https://nginxproxymanager.com/)
2. Add Proxy Host:
   - Domain: `obsidian.yourdomain.com`
   - Forward IP: Your CouchDB container IP
   - Forward Port: `5984`
   - Enable SSL with Let's Encrypt

3. In Obsidian, use: `https://obsidian.yourdomain.com`

### Option 2: Cloudflare Tunnel

1. Install cloudflared in the container:
   ```bash
   curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o cloudflared.deb
   dpkg -i cloudflared.deb
   ```
2. Create tunnel: `cloudflared tunnel create obsidian`
3. Route to: `http://localhost:5984`

### Option 3: Caddy (Auto HTTPS)

```bash
apt install caddy
cat > /etc/caddy/Caddyfile << EOF
obsidian.yourdomain.com {
    reverse_proxy localhost:5984
}
EOF
systemctl restart caddy
```

---

## Multiple Users

Each user needs their own database. To add a new user:

```bash
pct enter YOUR_CT_ID
/root/obsidian-livesync/scripts/create-database.sh
```

Or via CouchDB admin UI: `http://YOUR_IP:5984/_utils`

---

## Troubleshooting

### "Failed to connect" in Obsidian

1. Verify CouchDB is running:
   ```bash
   pct exec CT_ID -- curl http://localhost:5984/
   ```
2. Check the URI has no trailing slash
3. Ensure it's `http://` not `https://` (unless using reverse proxy)
4. Try accessing `http://YOUR_IP:5984/_utils` in a browser

### "Unauthorized" error

- Double-check username and password
- Try logging into CouchDB admin UI to verify credentials

### Mobile app won't connect

- Mobile requires HTTPS - set up a reverse proxy first
- See [HTTPS for Mobile Devices](#https-for-mobile-devices)

### Sync stuck or slow

1. Check CouchDB status:
   ```bash
   pct exec CT_ID -- systemctl status couchdb
   ```
2. Restart CouchDB:
   ```bash
   pct exec CT_ID -- systemctl restart couchdb
   ```

### Check synced files

```bash
pct exec CT_ID -- bash -c "
source /root/.obsidian-livesync-credentials
curl -s http://\${COUCHDB_USER}:\${COUCHDB_PASSWORD}@127.0.0.1:5984/obsidian/_all_docs
"
```

---

## Backup

### Full Container Backup

```bash
vzdump CT_ID --compress zstd --dumpdir /path/to/backups
```

### Database Only

```bash
pct exec CT_ID -- bash -c "
source /root/.obsidian-livesync-credentials
curl http://\${COUCHDB_USER}:\${COUCHDB_PASSWORD}@localhost:5984/obsidian/_all_docs?include_docs=true > backup.json
"
```

---

## Files

```
obsidian-livesync-lxc/
├── obsidian-livesync-lxc.sh    # Main Proxmox installer
├── scripts/
│   ├── install.sh              # Standalone CouchDB installer
│   ├── create-database.sh      # Add databases for more users
│   └── create-template.sh      # Export as shareable template
├── docs/
│   └── troubleshooting.md
├── README.md
└── LICENSE
```

---

## Credits

- [Obsidian](https://obsidian.md/) - The note-taking app
- [Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) by vrtmrz
- [CouchDB](https://couchdb.apache.org/) - The database
- Original guide from r/selfhosted community

## License

MIT License - See [LICENSE](LICENSE) for details.

## Contributing

Issues and pull requests welcome!

1. Fork the repo
2. Create a feature branch
3. Submit a PR
