#!/bin/bash
# Master Unified Setup Script: Complete World Map (MapLibre Standard)
# This script configures everything required for a "proper" self-hosted MapLibre server.

set -e
set -uo pipefail

# Configuration
DATA_DIR="tileserver/data"
FONT_DIR="tileserver/fonts"
SPRITE_DIR="tileserver/sprites"
PLANET_FILE="$DATA_DIR/planet.mbtiles"
PLANET_URL="https://btrfs.openfreemap.com/areas/planet/20260311_001001_pt/tiles.mbtiles"
FONTS_URL="https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"

echo -e "\e[36m--- MapLibre Full World Setup --- \e[0m"

# 1. Directory Structure
echo "Setting up proper directory structure..."
mkdir -p "$DATA_DIR" "$FONT_DIR" "$SPRITE_DIR" "tileserver/styles"

# 2. Professional Fonts
echo "Downloading professional fonts..."
curl -L --fail --show-error --http1.1 "$FONTS_URL" -o "$FONT_DIR/fonts.zip"
unzip -o "$FONT_DIR/fonts.zip" -d "$FONT_DIR/"
rm "$FONT_DIR/fonts.zip"

# 3. Professional Sprites
echo "Downloading professional sprites (icons)..."
curl -L --fail --show-error --http1.1 https://openmaptiles.github.io/osm-bright-gl-style/sprite.json -o "$SPRITE_DIR/sprite.json"
curl -L --fail --show-error --http1.1 https://openmaptiles.github.io/osm-bright-gl-style/sprite.png -o "$SPRITE_DIR/sprite.png"
curl -L --fail --show-error --http1.1 https://openmaptiles.github.io/osm-bright-gl-style/sprite@2x.json -o "$SPRITE_DIR/sprite@2x.json"
curl -L --fail --show-error --http1.1 https://openmaptiles.github.io/osm-bright-gl-style/sprite@2x.png -o "$SPRITE_DIR/sprite@2x.png"

# 4. Global Planet Data
echo -e "\e[33mCRITICAL: Starting Entire Earth Download (~110GB).\e[0m"
echo -e "\e[33mEnsure you have sufficient disk space.\e[0m"
read -p "Proceed with final download? (y/n): " confirm

if [[ $confirm == "y" ]]; then
    # Dependency Check: aria2c
    if ! command -v aria2c &> /dev/null; then
        echo -e "\e[33mWarning: 'aria2c' is not installed. It is highly recommended for the 110GB download.\e[0m"
        if command -v apt-get &> /dev/null; then
            read -p "Would you like to install it now? (sudo apt-get install aria2) (y/n): " install_confirm
            if [[ $install_confirm == "y" ]]; then
                sudo apt-get update && sudo apt-get install -y aria2
            else
                echo "Proceeding without aria2c... this might be slower or less reliable."
            fi
        else
            echo "Please install 'aria2' manually for your system."
            echo "Example: 'sudo apt install aria2' (Ubuntu/Debian) or 'brew install aria2' (macOS)"
            read -p "Proceed anyway with standard curl? (y/n): " curl_confirm
            if [[ $curl_confirm != "y" ]]; then exit 1; fi
        fi
    fi

    echo "Downloading Global MBTiles... this will take time."
    if command -v aria2c &> /dev/null; then
        aria2c -c -x 16 -s 16 --retry-wait 5 --max-file-not-found=0 --check-certificate=false -d "$DATA_DIR" -o "planet.mbtiles" "$PLANET_URL"
    else
        echo "Using curl fallback (Note: slower and no auto-resume support)..."
        curl -L --fail --show-error --http1.1 "$PLANET_URL" -o "$PLANET_FILE"
    fi
    
    echo -e "\e[32mDownload Complete. Restarting Services...\e[0m"
    docker compose restart tileserver || echo "Note: docker-compose not running, ignoring restart."
else
    echo "Skipping Planet download. Please run this script again later to complete the data."
fi

echo -e "\e[32mSuccess! Your MapLibre Backend is properly configured with all assets.\e[0m"
echo -e "\e[36mBackend API & Dashboard: http://localhost:8082\e[0m"
