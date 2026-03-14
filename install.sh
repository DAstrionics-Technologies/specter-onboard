#!/bin/bash

sudo apt update -y

cd scripts
sudo chmod +x wifi-start.sh
sudo chmod +x setup_mavlink.sh
sudo chmod +x setup_camera.sh


sudo ./wifi-start.sh
sudo ./setup_mavlink.sh
sudo ./setup_camera.sh
