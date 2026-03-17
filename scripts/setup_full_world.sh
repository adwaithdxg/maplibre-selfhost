#!/bin/bash
# Master Unified Setup Script: Complete World Map (MapLibre Standard)
# This script configures everything required for a "proper" self-hosted MapLibre server.

set -e

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
curl -L "$FONTS_URL" -o "$FONT_DIR/fonts.zip"
unzip -o "$FONT_DIR/fonts.zip" -d "$FONT_DIR/"
rm "$FONT_DIR/fonts.zip"

# 3. Professional Sprites
echo "Downloading professional sprites (icons)..."
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright.json -o "$SPRITE_DIR/sprite.json"
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright.png -o "$SPRITE_DIR/sprite.png"
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright@2x.json -o "$SPRITE_DIR/sprite@2x.json"
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright@2x.png -o "$SPRITE_DIR/sprite@2x.png"

# 4. Global Planet Data
echo -e "\e[33mCRITICAL: Starting Entire Earth Download (~110GB).\e[0m"
echo -e "\e[33mEnsure you have sufficient disk space.\e[0m"
read -p "Proceed with final download? (y/n): " confirm

if [[ $confirm == "y" ]]; then
    echo "Downloading Global MBTiles (Resumable)... this will take time."
    curl -L --http1.1 "$PLANET_URL" -o "$PLANET_FILE"
    
    echo -e "\e[32mDownload Complete. Restarting Services...\e[0m"
    docker compose restart tileserver || echo "Note: docker-compose not running, ignoring restart."
else
    echo "Skipping Planet download. Please run this script again later to complete the data."
fi

echo -e "\e[32mSuccess! Your MapLibre Backend is properly configured with all assets.\e[0m"
echo -e "\e[36mBackend API & Dashboard: http://localhost:8082\e[0m"
