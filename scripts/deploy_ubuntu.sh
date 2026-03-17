#!/bin/bash
# Master Deployment Script for MapLibre Self-Hosted Stack on Ubuntu

set -e

echo -e "\e[36mInitializing MapLibre Stack Deployment on Ubuntu...\e[0m"

# 1. Update and Install Dependencies
echo "Installing base dependencies (curl, unzip, docker)..."
sudo apt-get update
sudo apt-get install -y curl unzip docker.io docker-compose

# 2. Ensure Directory Structure
echo "Setting up directory structure..."
mkdir -p tileserver/data tileserver/fonts tileserver/sprites tileserver/styles
mkdir -p frontend/src

# 3. Populate Professional Assets (Fonts & Sprites)
# Running the asset setup logic inline or calling the script
echo "Populating professional fonts and sprites..."
bash scripts/setup_assets.sh

# 4. Preparing for Global Data
echo -e "\e[33mData setup is required next.\e[0m"
echo "To download the full 110GB Planet, run: bash scripts/download_planet.sh"

# 5. Build and Start Docker Stack
echo "Starting the Docker containers..."
sudo docker-compose up -d --build

echo -e "\e[32mDeployment Complete!\e[0m"
echo -e "\e[34m- Map Interface: http://localhost:8083\e[0m"
echo -e "\e[34m- TileServer Dashboard: http://localhost:8082\e[0m"
