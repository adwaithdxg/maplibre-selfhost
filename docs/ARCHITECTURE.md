# Architecture (Phase 2)

This document covers the system design, Docker topology, networking, the
request lifecycle, and the tile generation/serving workflows. Diagrams are
Mermaid (render on GitHub or any Mermaid viewer).

---

## 1. High-level system architecture

```mermaid
flowchart LR
    subgraph Client
      A["MapLibre GL JS<br/>(your frontend)"]
    end

    subgraph VPS["Contabo VPS — Ubuntu 24.04 / Docker"]
      direction TB
      N["Nginx edge<br/>TLS · HTTP/2 · Brotli · cache · rate-limit"]
      M["Martin<br/>vector tiles + glyphs"]
      ST["Static assets<br/>style.json · viewer"]
      G["Generator (run-once)<br/>download · merge · Planetiler"]
      C["Certbot<br/>Let's Encrypt"]
      VT[("tiles<br/>.mbtiles")]
      VA[("assets<br/>fonts · style")]
      VC[("nginx<br/>edge cache")]
      VL[("letsencrypt")]
    end

    EXT["Geofabrik OSM<br/>+ Planetiler sources"]:::ext
    LE["Let's Encrypt"]:::ext

    A -- "HTTPS /tiles /font /style.json" --> N
    N -- "proxy + cache" --> M
    N -- "serve" --> ST
    M --> VT
    M --> VA
    ST --> VA
    N --> VC
    N --> VL
    C --> LE
    C --> VL
    G --> EXT
    G --> VT
    G --> VA

    classDef ext fill:#eee,stroke:#999,stroke-dasharray:4 3;
```

The browser only ever talks to Nginx. Martin and the generator are private to
the Docker network. The generator runs once to produce the tileset and assets,
then exits; serving is handled entirely by Martin + Nginx.

---

## 2. Docker architecture & startup order

```mermaid
flowchart TD
    G["generator<br/>restart: no"] -->|service_completed_successfully| M["martin<br/>restart: unless-stopped"]
    M -->|service_healthy| N["nginx<br/>restart: unless-stopped"]
    N -->|service_started| C["certbot<br/>restart: unless-stopped"]

    subgraph Volumes
      V1[("osm_downloads")]
      V2[("tiles")]
      V3[("assets")]
      V4[("nginx_cache")]
      V5[("letsencrypt")]
      V6[("certbot_webroot")]
    end

    G --- V1
    G --- V2
    G --- V3
    M --- V2
    M --- V3
    N --- V3
    N --- V4
    N --- V5
    N --- V6
    C --- V5
    C --- V6
```

Dependency conditions (in `docker-compose.yml`) guarantee correct ordering and
prevent race conditions: tiles exist before Martin starts; Martin answers
`/health` before Nginx accepts traffic; Nginx serves the ACME path before
Certbot requests a certificate.

---

## 3. Network topology

```mermaid
flowchart LR
    Internet(("Internet"))
    Internet -->|"80/tcp, 443/tcp, 443/udp"| NGX["nginx :80/:443"]

    subgraph mapnet["Docker bridge: maplibre_net (private)"]
      NGX -->|"http :3000"| MAR["martin :3000"]
      CB["certbot"] -->|"http healthz"| NGX
    end
```

Only Nginx publishes ports to the host. `martin`, `generator`, and `certbot`
have **no** published ports; Martin is reachable only as `http://martin:3000`
on the internal `mapnet` bridge. Nginx re-resolves the `martin` service name via
Docker DNS (`resolver 127.0.0.11`) so replica/restart IP changes are picked up.

---

## 4. Request lifecycle (a single tile)

```mermaid
sequenceDiagram
    participant B as Browser (MapLibre)
    participant N as Nginx
    participant Cache as Edge cache (disk)
    participant M as Martin
    participant T as tiles.mbtiles

    B->>N: GET /tiles/basemap/10/645/418 (HTTPS/2)
    N->>N: rate-limit + TLS terminate
    N->>Cache: lookup key
    alt HIT
        Cache-->>N: cached .pbf (gzip)
        N-->>B: 200, X-Cache-Status: HIT
    else MISS
        N->>M: GET /basemap/10/645/418 (keepalive)
        M->>T: read tile (SQLite)
        T-->>M: gzip .pbf
        M-->>N: 200 application/x-protobuf
        N->>Cache: store (TTL = NGINX_TILE_CACHE_TTL)
        N-->>B: 200, X-Cache-Status: MISS
    end
```

Vector tiles are stored gzip-compressed inside the MBTiles and served with
`Content-Encoding: gzip`, so Nginx caches and forwards them **without
re-compressing**. Brotli/gzip in Nginx apply to `style.json`, glyph `.pbf`, and
other text assets.

---

## 5. Tile generation workflow (the run-once job)

```mermaid
flowchart TD
    S(["docker compose up"]) --> D{"extract exists<br/>& md5 valid?"}
    D -- no --> DL["download (resumable)<br/>verify md5"] --> RB
    D -- yes --> RB{"rebuild needed?<br/>(force / missing / stale)"}
    RB -- no --> AS
    RB -- yes --> MG{"> 1 region?"}
    MG -- yes --> OM["osmium merge → merged.pbf"] --> PL
    MG -- no --> PL["Planetiler<br/>--osm-path → .building.mbtiles"]
    PL --> MV["atomic rename → basemap.mbtiles"] --> AS["prepare-assets<br/>fonts · style · viewer"]
    AS --> MK["write .ready marker"] --> E(["exit 0 → Martin starts"])
```

Every stage is **idempotent**: a valid cached extract is reused, an up-to-date
tileset is not rebuilt, and outputs are published atomically (write to a temp
name, then rename on the same filesystem). Re-running `up` is always safe.

---

## 6. Tile serving workflow & scaling

```mermaid
flowchart LR
    subgraph Edge
      N1["Nginx<br/>least_conn LB + cache"]
    end
    subgraph Backends["Martin pool (scale-out ready)"]
      M1["martin"]
      M2["martin-2 (optional)"]
      M3["martin-3 (optional)"]
    end
    N1 --> M1
    N1 -.-> M2
    N1 -.-> M3
    M1 --> TT[("shared tiles volume")]
    M2 -.-> TT
    M3 -.-> TT
```

Martin is stateless — every replica reads the same read-only tiles volume. To
scale, add `server martin-2:3000;` lines to `config/nginx/conf.d/upstream.conf`
and run more replicas. The edge cache absorbs the vast majority of reads, so a
single Martin instance already handles very high request rates.

---

## 7. Observability, health, logging, backup

- **Health:** container healthchecks (`/healthz` on Nginx, `/health` on Martin)
  drive Compose start ordering and restart decisions. `/health/upstream` exposes
  Martin's health through Nginx. Martin also exposes Prometheus metrics at
  `/_/metrics` (internal) for future scraping.
- **Logging:** all services log to Docker's `json-file` driver with rotation
  (10 MB × 5). Nginx access logs include cache status and upstream timing.
- **Backup:** `make backup` snapshots the `tiles`, `assets`, and `letsencrypt`
  volumes to `./backups`. Tiles are reproducible from OSM, so the critical
  irreplaceable state is just the certificates (and your `.env`).
- **Disaster recovery:** re-clone, restore `.env` + the `letsencrypt` snapshot
  (optional — certs re-issue automatically), `docker compose up -d`; tiles
  regenerate from scratch. See DEPLOYMENT for the full runbook.
