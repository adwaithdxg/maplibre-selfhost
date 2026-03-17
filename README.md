# Production MapLibre Self-Hosted Backend

Properly structured, professional-grade Tile Server for hosting the entire Global Planet.

## Production Setup

### 1. Hardware Requirements
- **Storage**: ~111GB for Planet Tiles (OpenMapTiles Schema).
- **RAM**: 16GB+ for performance.
- **CPU**: 4+ Cores recommended.

### 2. Unified Master Setup
We have provided a single master script to automate the entire structure, assets, and data acquisition.

**On Ubuntu (Linux):**
```bash
bash scripts/setup_full_world.sh
```

**On Windows (PowerShell):**
```powershell
# Run localized scripts in order
.\scripts\setup_assets.ps1
.\scripts\download_planet.ps1
```

### 3. Professional Features
- **OpenMapTiles v3.15 Schema**: 1:1 API compatibility with standard MapLibre frontends.
- **Professional Themes**: Pre-configured support for Bright, Basic, Positron, and Dark Matter.
- **Local Assets**: All fonts and sprites are served locally for 100% independence.

## Access & API
- **Tiles API & Metadata**: `http://localhost:8082`
- **Styles JSON**: `http://localhost:8082/styles/{style}/style.json`
