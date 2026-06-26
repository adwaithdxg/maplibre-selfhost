# Deployment Guide (Phases 5 & 7)

Target: a fresh **Contabo VPS, Ubuntu 24.04 LTS** (12 GB RAM / 6 vCPU / 400 GB).
End state: `https://<your-domain>/` serves a live self-hosted map.

---

## 1. Server preparation

SSH in as a sudo user and update:

```bash
sudo apt update && sudo apt -y upgrade
sudo timedatectl set-timezone Asia/Dubai     # optional; matches TZ default
```

Create a non-root deploy user (skip if you already have one):

```bash
sudo adduser deploy && sudo usermod -aG sudo deploy
```

## 2. Install Docker Engine + Compose plugin

```bash
# Official Docker repo (Compose v2 is bundled as the `docker compose` plugin)
sudo apt -y install ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt update
sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker $USER        # log out/in afterwards
docker --version && docker compose version
```

## 3. Required packages

The only host requirements are Docker + the Compose plugin (above) and `git`.
Everything else (Java/Planetiler, osmium, Nginx, Brotli, Certbot) ships inside
the images.

```bash
sudo apt -y install git make
```

## 4. Firewall

```bash
sudo apt -y install ufw
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp          # HTTP + ACME challenge
sudo ufw allow 443/tcp         # HTTPS
sudo ufw allow 443/udp         # HTTP/3 (QUIC) — harmless if disabled
sudo ufw enable
```

| Port | Proto | Why |
|------|-------|-----|
| 22 | tcp | SSH |
| 80 | tcp | HTTP → HTTPS redirect + Let's Encrypt http-01 |
| 443 | tcp | HTTPS (HTTP/2) |
| 443 | udp | HTTP/3 (optional) |

Martin's `:3000` is **never** exposed to the host or internet.

## 5. DNS

Create an **A record** (and `AAAA` if you have IPv6) pointing your domain at the
VPS public IP, e.g.:

```
maps.example.com.   A     <VPS_PUBLIC_IP>
```

Verify it resolves before first boot (Let's Encrypt needs it):

```bash
dig +short maps.example.com
```

## 6. Clone & configure

```bash
git clone <repository> maplibre && cd maplibre
cp .env.example .env
nano .env
```

Set at least:

```ini
DOMAIN=maps.example.com
LETSENCRYPT_EMAIL=you@example.com
# Optional: add regions, e.g.
# OSM_REGIONS="asia/gcc-states asia/jordan africa/egypt"
```

> **Tip:** while testing TLS, set `LETSENCRYPT_STAGING=1` to avoid hitting Let's
> Encrypt's rate limits. Switch to `0` and `make rebuild`/recreate certbot once
> happy (delete the staging cert first: `docker compose exec certbot rm -rf
> /etc/letsencrypt/live/<domain>`).

## 7. Deploy

```bash
docker compose up -d            # or: make up
```

First boot does everything automatically. Watch progress:

```bash
make logs-gen                   # tile generation (the long step)
make ps                         # wait for martin=healthy, nginx=healthy
make cert-status                # confirm a real certificate was issued
```

Then open `https://maps.example.com/` — you should see the GCC basemap. Point
your existing MapLibre frontend's `style` at
`https://maps.example.com/style.json`.

---

## 8. Upgrade process

**App/config changes (this repo):**

```bash
git pull
docker compose up -d --build    # rebuilds only changed images; tiles untouched
```

**Refresh map data (new OSM):**

```bash
make update-data                # re-download + rebuild + reload (zero-downtime-ish)
```

**Base image updates (Martin/Certbot/Nginx security patches):**

```bash
make pull && docker compose up -d --build
```

## 9. Rollback

Images are rebuilt from the repo, so rollback = checkout the previous commit and
recreate:

```bash
git checkout <previous-good-tag-or-commit>
docker compose up -d --build
```

The tileset and certificates live in volumes and are **not** affected by an app
rollback. To roll back the *tiles* specifically, restore a tiles snapshot:

```bash
make restore VOL=tiles FILE=backups/<timestamp>-tiles.tgz
docker compose restart martin
```

## 10. Backup strategy

```bash
make backup        # → backups/<ts>-tiles.tgz, -assets.tgz, -letsencrypt.tgz
```

What matters, by priority:

1. **`.env`** — keep it in your password manager / secret store (not in git).
2. **`letsencrypt`** volume — avoids re-issuing certs on restore (optional; they
   re-issue automatically anyway).
3. **`tiles`/`assets`** — reproducible from OSM; back up only to skip a rebuild.

Automate a weekly snapshot with cron:

```cron
0 3 * * 0  cd /home/deploy/maplibre && /usr/bin/make backup >> logs/backup.log 2>&1
```

Copy `backups/*.tgz` off-box (e.g. `rclone`/`scp`) for real durability.

## 11. Disaster recovery runbook

| Scenario | Recovery |
|----------|----------|
| Container crash | `restart: unless-stopped` auto-recovers; check `make logs`. |
| Corrupt tileset | `make rebuild-tiles` (regenerates from cached extract). |
| Lost VPS | New VPS → steps 1–7 → `docker compose up -d`. Tiles rebuild; certs re-issue. Restore `letsencrypt`/`tiles` snapshots to skip the wait. |
| Cert issuance fails | Verify DNS + ports 80/443 open; check `make logs` for `certbot`; Nginx keeps serving on the self-signed cert meanwhile. |
| Disk filling | `make purge-cache`; lower `NGINX_TILE_CACHE_MAX`; prune old `backups/`. |

## 12. Scheduled data refresh (optional)

Add a weekly OSM rebuild via cron on the host:

```cron
30 2 * * 1  cd /home/deploy/maplibre && /usr/bin/make update-data >> logs/refresh.log 2>&1
```

`update-data` is idempotent and re-downloads only what changed, then reloads
Martin and Nginx without dropping the public endpoint.
