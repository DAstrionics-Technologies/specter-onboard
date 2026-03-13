# Project Specter - RPi Onboard Setup
Fresh Raspberry Pi setup for project Specter onboard computer.

## Hardware Connections

| Port | Device | Notes |
|------|--------|-------|
| UART (`/dev/ttyAMA0`) / USB | Flight Controller | TX→RX, RX→TX, GND. 57600 baud |
| USB | BL-M8812CU2 WiFi Module | 5GHz air-ground link |
| CSI / USB / Ethernet | Camera | Video feed |
| Power | 5V/3A minimum | Use BEC from drone power system |

## Fresh RPi Setup

### 1. Flash OS

Flash **Raspberry Pi OS Lite (64-bit)** using Raspberry Pi Imager. In imager settings:
- Enable SSH
- Set username: `da`
- Set password
- Configure WiFi (temporary, for initial setup only)

### 2. First Boot

```bash
ssh da@raspberrypi.local

# Update system
sudo apt update && sudo apt upgrade -y

# Enable UART for flight controller
sudo raspi-config
# Interface Options → Serial Port → Login shell: No → Hardware: Yes

# Reboot
sudo reboot
``` 

### 3. Clone the repo

```bash
# Clone the repo
git clone https://github.com/DAstrionics-Technologies/specter-onboard
cd specter-onboard
```

### 4. Mavlink and Video Setup

```bash
# Make the setup script executable and run it
chmod +x install.sh && ./install.sh
```



