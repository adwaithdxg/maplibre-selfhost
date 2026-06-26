# Testing, Validation & Troubleshooting (Phase 8)

Replace `maps.example.com` with your domain (or `localhost` for a local probe).

---

## 1. Health checks

```bash
# Container status + health (want: martin healthy, nginx healthy)
docker compose ps

# Nginx liveness
curl -fsS http://localhost/healthz                       # -> ok

# Martin health, straight from the container
docker compose exec martin curl -fsS http://localhost:3000/health   # -> OK

# Martin health, through the public edge
curl -fsS https://maps.example.com/health/upstream       # -> OK

# What sources/fonts did Martin actually load?
docker compose exec martin curl -fsS http://localhost:3000/catalog | jq
```

## 2. Smoke tests (the four things MapLibre needs)

```bash
# 1) Style JSON loads and is valid
curl -fsS https://maps.example.com/style.json | jq '.name, .sources, .glyphs'

# 2) TileJSON for the tileset
curl -fsS https://maps.example.com/tiles/basemap | jq '.minzoom, .maxzoom, .bounds'

# 3) A real vector tile (expect HTTP 200, content-type protobuf, gzip)
curl -fsS -D - -o /tmp/t.pbf "https://maps.example.com/tiles/basemap/6/40/27" | \
  grep -iE 'HTTP/|content-type|content-encoding|x-cache-status'
file /tmp/t.pbf            # should be gzip / binary, non-empty

# 4) A glyph range (Latin)
curl -fsS -o /tmp/g.pbf "https://maps.example.com/font/Noto%20Sans%20Regular/0-255.pbf"
test -s /tmp/g.pbf && echo "glyphs OK"

# 4b) Arabic glyph range (GCC labels) — non-empty proves the Arabic font loaded
curl -fsS -o /tmp/ar.pbf "https://maps.example.com/font/Noto%20Sans%20Arabic%20Regular/1536-1791.pbf"
test -s /tmp/ar.pbf && echo "arabic glyphs OK"
```

Visual test: open `https://maps.example.com/` — pan/zoom around the Gulf; labels
should render in both Latin and Arabic.

## 3. TLS / security validation

```bash
# Certificate chain + issuer (expect Let's Encrypt, not the self-signed bootstrap)
echo | openssl s_client -connect maps.example.com:443 -servername maps.example.com 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates

# Security headers present
curl -fsS -D - -o /dev/null https://maps.example.com/ | \
  grep -iE 'strict-transport|x-content-type|x-frame|referrer-policy'

# HTTP -> HTTPS redirect
curl -sI http://maps.example.com/ | grep -i location     # -> https://...
```

For an external grade, run SSL Labs against your domain (expect A/A+).

## 4. Cache validation

```bash
# First request = MISS, second = HIT
for i in 1 2; do
  curl -fsS -D - -o /dev/null "https://maps.example.com/tiles/basemap/8/160/108" \
    | grep -i x-cache-status
done
# Expect: MISS then HIT

# Confirm tiles are NOT double-compressed (one Content-Encoding: gzip, from MBTiles)
curl -fsS -D - -o /dev/null "https://maps.example.com/tiles/basemap/8/160/108" | grep -i content-encoding
```

Cache lives on disk in the `nginx_cache` volume; `make purge-cache` clears it.

## 5. Compression validation

```bash
# style.json should be served compressed (br preferred, gzip fallback)
curl -fsS -H 'Accept-Encoding: br' -D - -o /dev/null https://maps.example.com/style.json | grep -i content-encoding   # -> br
curl -fsS -H 'Accept-Encoding: gzip' -D - -o /dev/null https://maps.example.com/style.json | grep -i content-encoding # -> gzip
```

## 6. Performance & load testing

Install a load tool, then hammer the tile endpoint (cache makes this cheap):

```bash
sudo apt -y install hey      # or: apache2-utils (ab), wrk

# 30s, 50 concurrent, against a single tile (tests edge cache throughput)
hey -z 30s -c 50 "https://maps.example.com/tiles/basemap/8/160/108"

# Spread across many tiles (tests Martin + SQLite under cache misses)
hey -z 30s -c 50 -disable-keepalive \
  "https://maps.example.com/tiles/basemap/10/645/418"
```

What to look for:
- p99 latency stays low for cached tiles (sub-10 ms edge service is typical).
- 429s appear only if you exceed `NGINX_RATE_LIMIT` (expected — rate limiting
  works). Raise the limit in `.env` for legitimate high-traffic clients.
- Martin RAM stays flat (a few hundred MB) — `docker stats`.

## 7. Monitoring checklist

| Signal | Where | Healthy |
|--------|-------|---------|
| Container health | `docker compose ps` | all `healthy` |
| Cache hit ratio | Nginx access log `cache=` field | mostly `HIT` after warm-up |
| Martin latency | log `urt=` field | low + stable |
| Martin metrics | `:3000/_/metrics` (internal) | scrape with Prometheus |
| Disk usage | `df -h`, `docker system df` | cache < `NGINX_TILE_CACHE_MAX` |
| Cert expiry | `make cert-status` | > 30 days (auto-renews at 30) |
| Memory | `docker stats` | within per-service limits |

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `martin` never becomes healthy | tileset missing/corrupt | `make logs-gen`; `make rebuild-tiles` |
| Blank map, tiles 404 | tileset id ≠ style source | confirm `TILESET_ID` matches `/tiles/<id>`; check `/catalog` |
| Labels missing | font CDN failed at build | `make logs-gen` (font warnings); re-run `docker compose run --rm generator` |
| Arabic labels missing | Arabic TTF not fetched | same as above; verify `/font/Noto%20Sans%20Arabic%20Regular/1536-1791.pbf` is non-empty |
| Cert stays self-signed | DNS not pointing to VPS, or 80/443 blocked | fix DNS/firewall; `docker compose logs certbot` |
| `429 Too Many Requests` | rate limit hit | raise `NGINX_RATE_LIMIT`/`NGINX_RATE_BURST` in `.env`, recreate nginx |
| HTTP/3 not active | nginx build lacks QUIC | expected; HTTP/2 still on. Build with `ENABLE_HTTP3=true` + QUIC base image |
| Generation OOM (huge region) | RAM < 1.5× PBF | set `PLANETILER_STORAGE=mmap`, lower `PLANETILER_XMX` |
| Disk full | cache too large | `make purge-cache`; lower `NGINX_TILE_CACHE_MAX` |
| Nginx won't start after edit | bad rendered config | `docker compose logs nginx` (shows `nginx -t` error); fix template |

### Common failure scenarios & recovery

- **Interrupted first boot (network drop mid-download):** just run
  `docker compose up -d` again — downloads resume (`curl -C -`) and verified
  files are skipped. The pipeline is fully idempotent.
- **Partial/garbage extract:** md5 verification catches it and re-downloads (up
  to 3 attempts) before generation.
- **Tileset rebuild while serving:** generation writes to a temp file and
  atomically renames; Martin keeps serving the old tileset until the new one is
  in place, then live-reloads it.
- **Let's Encrypt rate-limit lockout:** set `LETSENCRYPT_STAGING=1`, validate
  the whole flow, then switch back to production issuance.
