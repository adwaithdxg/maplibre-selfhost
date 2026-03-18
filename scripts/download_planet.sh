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

# Dependency Check: aria2c (Required for stability on 110GB transfer)
if ! command -v aria2c &> /dev/null; then
    echo -e "\e[33mWarning: 'aria2c' is not installed.\e[0m"
    if command -v apt-get &> /dev/null; then
        read -p "Would you like to install it now? (sudo apt-get install aria2) (y/n): " install_confirm
        if [[ $install_confirm == "y" ]]; then
            sudo apt-get update && sudo apt-get install -y aria2
        else
            echo "Error: aria2c is required for this large download. Please install it manually."
            exit 1
        fi
    else
        echo "Error: 'aria2c' is missing. Please install 'aria2' manually for your system."
        exit 1
    fi
fi

echo -e "\e[36mStarting robust download with aria2c...\e[0m"
aria2c -c -x 16 -s 16 --retry-wait 5 --max-file-not-found=0 --check-certificate=false -d "$DATA_DIR" -o "planet.mbtiles" "$REAL_PLANET_URL"

# 3. Finalize Configuration
echo -e "\e[32mDownload Complete. Finalizing TileServer configuration...\e[0m"

# Restart to pick up the new 110GB file
docker compose restart tileserver

echo -e "\e[32mSuccess! The entire earth is now hosted locally on port 8082.\e[0m"
echo -e "\e[36mFrontend is available at http://localhost:8083\e[0m"
