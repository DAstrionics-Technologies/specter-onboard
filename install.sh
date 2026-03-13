#!bin/bash

sudo apt update -y

sudo chmod +x scripts/setup_mavlink.sh
sudo chmod +x scripts/setup_camera.sh

sudo ./scripts/setup_mavlink.sh
sudo ./scripts/setup_camera.sh
