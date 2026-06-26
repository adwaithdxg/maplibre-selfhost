# Self-Hosted MapLibre Infrastructure (Contabo / Ubuntu 24.04)

A production-grade, fully automated vector-tile stack for **MapLibre GL JS**.
Generates its own OpenStreetMap vector tiles (focused on the **GCC states**,
extensible to any region), serves them with **Martin**, and fronts everything
with a hardened **Nginx** edge (TLS, HTTP/2, Brotli, caching, rate limiting,
automatic Let's Encrypt).

```bash
git clone <repository> maplibre && cd maplibre
cp .env.example .env          # set DOMAIN + LETSENCRYPT_EMAIL
docker compose up -d          # …that's it
```

On first boot the stack downloads the OSM extract(s), verifies them, builds the
tileset, prepares fonts + style, obtains a TLS certificate, and starts serving.
No other manual steps.

- **Live map / self-test:** `https://<your-domain>/`
- **Style JSON (point your frontend here):** `https://<your-domain>/style.json`
- **Tiles:** `https://<your-domain>/tiles/basemap/{z}/{x}/{y}`
- **Glyphs:** `https://<your-domain>/font/{fontstack}/{range}.pbf`

Full design rationale and diagrams: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) ·
Deploy/upgrade/backup: [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md) ·
Testing & troubleshooting: [`docs/TESTING.md`](docs/TESTING.md).

---

## Phase 1 — Research & Architecture Decision

### How MapLibre self-hosting actually works

MapLibre GL JS is only a **client**. To self-host it you must provide four
things over HTTP:

1. **Vector tiles** — `.pbf` (Mapbox Vector Tile) packets per `{z}/{x}/{y}`.
2. **A style** — a JSON document describing how to draw those tiles.
3. **Glyphs** — SDF font ranges (`.pbf`) for text labels.
4. **Sprites** — icon atlases (optional; this build uses label-only styling, so
   no sprite dependency — one less moving part).

Two production-shaped ways to get vector tiles exist:

- **Pre-generate** the whole region into an `.mbtiles`/`.pmtiles` archive and
  serve static tiles (fast, cheap, immutable — ideal for a basemap).
- **Render on demand** from a live PostGIS database (flexible, heavier, needed
  only for frequently-changing data).

For a basemap that updates occasionally, **pre-generation wins decisively** on
cost, RAM, and operational simplicity — so that is what this stack does.

### Tile-server / generation options compared

| Tool | Role | Lang | Pros | Cons | Verdict |
|------|------|------|------|------|---------|
| **Planetiler** | Generator | Java | Extremely fast (planet in hours; a region in minutes), low RAM via mmap, OpenMapTiles-compatible schema, single jar | Batch tool, not a server | **Chosen** generator |
| **OpenMapTiles** | Generator | SQL/Docker | Mature schema, customizable | Slow, Postgres-heavy import, many containers, high maintenance | Rejected (operational weight) |
| **Martin** | Server | Rust | Blazing fast, tiny RAM, serves MBTiles/PMTiles **+ fonts + sprites + styles**, live dir-watch, Prometheus metrics, horizontal-scale friendly | No tile *generation* from OSM (by design) | **Chosen** server |
| **TileServer GL** | Server | Node | Batteries-included (raster too), built-in viewer | Heavier, slower under load, harder to scale out | Rejected (perf/scale) |
| **Tegola** | Server | Go | Good PostGIS server, caching | PostGIS-oriented; overkill for static basemap | Rejected (fit) |
| **tileserver-php / mod_mbtiles** | Server | PHP | Minimal | Dated, weak under load | Rejected |

**Decision: Planetiler (generate) → Martin (serve) → Nginx (edge).**
Rust + Java + a static archive gives the best ratio of performance to RAM to
maintenance for a single Contabo VPS, and Martin's stateless design lets us add
replicas behind Nginx later with zero re-architecture.

### Why these, specifically, for your constraints

- **Region:** GCC states via Geofabrik's ready-made `asia/gcc-states` extract
  (~240 MB PBF), plus any extra countries you list in `.env` (merged with
  `osmium`). Keeps storage and generation time tiny vs. a planet build.
- **Box:** 12 GB RAM / 6 vCPU / 400 GB. Planetiler needs ~1.5× the PBF size in
  RAM (a few GB here), Martin runs in a few hundred MB, Nginx + cache in ~1 GB.
  Comfortable, with the OS page cache accelerating tile reads.
- **Vector (not raster):** smaller storage, client-side restyling, crisp at all
  zooms, native to MapLibre.

### Resource & cost estimates

| Item | GCC extract | + a few neighbours | Whole planet (for comparison) |
|------|-------------|--------------------|-------------------------------|
| Input PBF | ~0.25 GB | ~1–3 GB | ~80 GB |
| Generation RAM | 2–4 GB | 4–6 GB | 32–64 GB+ |
| Generation time (6 vCPU) | ~3–10 min | ~15–40 min | hours |
| Tileset (.mbtiles) | ~1–4 GB | ~5–15 GB | ~60–100 GB |
| Serving RAM (Martin+Nginx) | < 2 GB | < 2.5 GB | < 4 GB |

Your 400 GB disk and 12 GB RAM comfortably cover GCC plus a generous set of
neighbouring countries. Whole-planet on-box generation is **not** advised at
12 GB (it would need `mmap` storage and run very slowly); add regions instead.

### Risks & trade-offs (and how this stack mitigates them)

- **Tile freshness** — OSM changes daily; a static build ages. → `make
  update-data` (or a cron) re-downloads + rebuilds; documented in DEPLOYMENT.
- **First-boot generation time** — the stack is "up" only after tiles build. →
  generation is a gated one-shot job with clear logs; Martin waits for it.
- **Font/asset CDN hiccups** — → font fetch has mirrors and is non-fatal
  (tiles still serve; labels degrade gracefully).
- **HTTP/3 portability** — official Nginx lacks QUIC. → HTTP/2 + Brotli are
  always on; HTTP/3 is an opt-in, auto-detected upgrade.

Sources for the research above are listed at the bottom of this file.

---

## Phase 3 — Project structure

```
.
├── docker-compose.yml          # the whole stack; `docker compose up -d`
├── .env.example                # all tunables (copy to .env)
├── Makefile                    # operator shortcuts (make help)
├── README.md                   # this file (incl. Phase 1 research)
│
├── docker/                     # image build contexts
│   ├── generator/Dockerfile    # JRE + Planetiler + osmium + jq (run-once job)
│   ├── martin/Dockerfile       # official Martin + curl (for healthcheck)
│   └── nginx/Dockerfile        # multi-stage: Nginx + compiled Brotli modules
│
├── config/                     # all configuration, version-controlled
│   ├── martin/martin.yaml       # tile + font server config
│   ├── nginx/
│   │   ├── nginx.conf           # main (compression, cache, limits)
│   │   ├── conf.d/              # upstream + server-block templates
│   │   └── snippets/            # proxy, security headers, TLS, locations
│   └── style/style.template.json# MapLibre style (templated per-deploy)
│
├── scripts/                    # automation (bind-mounted, idempotent)
│   ├── lib.sh                   # logging, retry, resumable+verified download
│   ├── download-data.sh         # fetch + md5-verify Geofabrik extracts
│   ├── generate-tiles.sh        # orchestrator: download→merge→Planetiler→assets
│   ├── prepare-assets.sh        # fonts + rendered style + demo viewer
│   ├── nginx-entrypoint.sh      # render config, TLS bootstrap, cert reload-watch
│   └── certbot-entrypoint.sh    # Let's Encrypt issuance + 12h renewal loop
│
├── assets/web/index.html       # self-test MapLibre viewer (templated)
└── docs/                       # ARCHITECTURE, DEPLOYMENT, TESTING
```

Persistent state lives in **named Docker volumes** (not the repo): the OSM
downloads, the generated tileset, prepared assets, the Nginx cache, and TLS
certificates. This keeps the working tree clean and the stack reproducible.

---

## What runs (4 services)

| Service | Image | Exposed | Purpose |
|---------|-------|---------|---------|
| `generator` | built (JRE+Planetiler) | — (run-once) | Download OSM, build tiles, prep assets |
| `martin` | built (Martin+curl) | internal `:3000` | Serve vector tiles + glyphs |
| `nginx` | built (Nginx+Brotli) | `:80`, `:443` | TLS, cache, proxy, rate-limit, static assets |
| `certbot` | `certbot/certbot` | — | Issue + auto-renew Let's Encrypt certs |

Startup is strictly ordered: `generator` must **complete** → `martin` must be
**healthy** → `nginx` starts → `certbot` swaps the bootstrap cert for a real one.

---

## Common operations

```bash
make up            # build + start everything
make ps            # service status & health
make logs-gen      # watch the tile build
make health        # probe nginx + martin
make update-data   # re-download OSM + rebuild tiles
make rebuild-tiles # force a rebuild from cached extracts
make purge-cache   # clear the Nginx edge cache
make backup        # snapshot tiles + assets + certs
make cert-status   # Let's Encrypt certificate info
```

Add more regions: edit `OSM_REGIONS` in `.env`
(e.g. `"asia/gcc-states asia/jordan africa/egypt"`) then `make update-data`.

---

## Sources

- [Planetiler — repo & docs](https://github.com/onthegomap/planetiler) ·
  [PLANET.md (RAM/disk guidance)](https://github.com/onthegomap/planetiler/blob/main/PLANET.md)
- [Martin — config](https://maplibre.org/martin/config-file/) ·
  [endpoints](https://maplibre.org/martin/using/) ·
  [repo](https://github.com/maplibre/martin)
- [Geofabrik — GCC States extract](https://download.geofabrik.de/asia/gcc-states.html)
- [OpenMapTiles styles / OSM Liberty](https://github.com/openmaptiles/osm-liberty-gl-style)
- [osmium merge](https://docs.osmcode.org/osmium/latest/osmium-merge.html)
- [Nginx + Brotli/HTTP-3 community builds](https://github.com/macbre/docker-nginx-http3)
