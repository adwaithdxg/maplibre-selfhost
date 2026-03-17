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
if (!(Test-Path "tileserver/sprites")) { New-Item -ItemType Directory -Path "tileserver/sprites" }

$baseUrl = "https://openmaptiles.github.io/osm-bright-gl-style"
$files = "sprite.json", "sprite.png", "sprite@2x.json", "sprite@2x.png"

foreach ($file in $files) {
    Invoke-WebRequest -Uri "$baseUrl/$file" -OutFile "tileserver/sprites/$file"
}

Write-Host "Assets correctly populated in tileserver/fonts and tileserver/sprites" -ForegroundColor Green
