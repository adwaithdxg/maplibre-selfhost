# 1. Configuration
$DATA_DIR = "tileserver/data"
$PLANET_FILE = "$DATA_DIR/planet.mbtiles"
# Using OpenFreeMap verified OpenMapTiles v3.15 schema planet build
$REAL_PLANET_URL = "https://btrfs.openfreemap.com/areas/planet/20241021_043810/tiles.mbtiles"

Write-Host "Warning: You are about to download the Entire Earth Map (~110GB)." -ForegroundColor Yellow
Write-Host "Ensure you have enough disk space in $DATA_DIR" -ForegroundColor Yellow
$confirm = Read-Host "Proceed with download? (y/n)"
if ($confirm -ne 'y') { exit }

# 2. Download Data
Write-Host "Downloading Planet Earth MBTiles... This will take a long time." -ForegroundColor Cyan
if (!(Test-Path $DATA_DIR)) { New-Item -ItemType Directory -Path $DATA_DIR }

# Use BITS for background/resumable download if possible, or standard WebRequest
Invoke-WebRequest -Uri $REAL_PLANET_URL -OutFile $PLANET_FILE

# 3. Finalize Configuration
Write-Host "Download Complete. Finalizing TileServer configuration..." -ForegroundColor Green

# Ensure docker containers are restarted to pick up the 100GB file
docker compose restart tileserver

Write-Host "Success! The entire earth is now hosted locally on port 8082." -ForegroundColor Green
Write-Host "Frontend is available at http://localhost:8083" -ForegroundColor Cyan
