#!/bin/bash
# Professional MapLibre Assets Setup for Linux

# 1. Download Font Glyph Stacks
echo "Downloading professional fonts..."
curl -L https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip -o tileserver/fonts/fonts.zip
unzip tileserver/fonts/fonts.zip -d tileserver/fonts/
rm tileserver/fonts/fonts.zip

# 2. Setup Sprites (Icons)
echo "Setting up sprites..."
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright.json -o tileserver/sprites/sprite.json
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright.png -o tileserver/sprites/sprite.png
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright@2x.json -o tileserver/sprites/sprite@2x.json
curl -L https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright@2x.png -o tileserver/sprites/sprite@2x.png

echo "Assets correctly populated in tileserver/fonts and tileserver/sprites"
