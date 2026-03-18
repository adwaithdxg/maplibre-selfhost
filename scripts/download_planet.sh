set -euo pipefail

DATA_DIR="tileserver/data"
PLANET_FILE="$DATA_DIR/planet.mbtiles"
# Using OpenFreeMap verified OpenMapTiles v3.15 schema planet build
REAL_PLANET_URL="https://btrfs.openfreemap.com/areas/planet/20260311_001001_pt/tiles.mbtiles"

echo -e "\e[33mWarning: You are about to download the Entire Earth Map (~110GB).\e[0m"
echo -e "\e[33mEnsure you have enough disk space in $DATA_DIR\e[0m"
read -p "Proceed with download? (y/n): " confirm

if [[ $confirm != "y" ]]; then
    echo "Download cancelled."
    exit 0
fi

# 2. Download Data
echo -e "\e[36mDownloading Planet Earth MBTiles... This will take a long time.\e[0m"
mkdir -p "$DATA_DIR"

# Using aria2c for stability on massive 110GB transfer
echo -e "\e[36mStarting robust download with aria2c...\e[0m"
aria2c -c -x 16 -s 16 --retry-wait 5 --max-file-not-found=0 --check-certificate=false -d "$DATA_DIR" -o "planet.mbtiles" "$REAL_PLANET_URL"

# 3. Finalize Configuration
echo -e "\e[32mDownload Complete. Finalizing TileServer configuration...\e[0m"

# Restart to pick up the new 110GB file
docker compose restart tileserver

echo -e "\e[32mSuccess! The entire earth is now hosted locally on port 8082.\e[0m"
echo -e "\e[36mFrontend is available at http://localhost:8083\e[0m"
