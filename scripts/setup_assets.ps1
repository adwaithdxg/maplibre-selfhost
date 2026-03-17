# Professional MapLibre Assets Setup

# 1. Download Font Glyph Stacks
Write-Host "Downloading professional fonts..." -ForegroundColor Cyan
$fontsUrl = "https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip"
$fontsZip = "tileserver/fonts/fonts.zip"
Invoke-WebRequest -Uri $fontsUrl -OutFile $fontsZip
Expand-Archive -Path $fontsZip -DestinationPath "tileserver/fonts" -Force
Remove-Item $fontsZip

# 2. Setup Sprites (Icons)
Write-Host "Setting up sprites..." -ForegroundColor Cyan
# Downloading pre-compiled OSM Bright sprites
$spritesUrl = "https://github.com/maptiler/tileserver-gl/raw/master/test/sprites/osm-bright.zip"
$spritesZip = "tileserver/sprites/sprites.zip"
Invoke-WebRequest -Uri $spritesUrl -OutFile $spritesZip
Expand-Archive -Path $spritesZip -DestinationPath "tileserver/sprites" -Force
Remove-Item $spritesZip

Write-Host "Assets correctly populated in tileserver/fonts and tileserver/sprites" -ForegroundColor Green
