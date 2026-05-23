# Radxa-Rock-2F-Home-Assistant-Kiosk
Radxa Rock 2F running a full-screen Home Assistant dashboard with touchscreen support, MQTT telemetry, remote access via VNC, and HDMI audio.

---

## Hardware

| Component | Details |
|---|---|
| Board | Radxa Rock 2F (Rockchip RK3528, 4× Cortex-A53) |
| OS | Armbian Ubuntu Noble (24.04) |
| Display | 13.3" 1920×1080 HDMI+USB Touchscreen |
| Connection | HDMI (video) + USB (touch input) |

---

## Features

- **Full-screen kiosk** — Chromium opens Home Assistant on boot, no desktop visible
- **Touchscreen** — works out of the box under X11/Cinnamon
- **MQTT telemetry** — temperature, CPU, RAM, disk, uptime, IP, available updates
- **Screen switch** — turn display on/off from Home Assistant
- **URL navigation** — send any URL from HA to the kiosk browser
- **Current URL sensor** — see what page is open on the kiosk
- **VNC remote access** — manage the kiosk from any device on the network
- **HDMI audio** — sound output through the display
- **Thermal optimized** — CPU/GPU/DMC frequency floors prevent stuttering without overheating

---

## Prerequisites

### 1. Flash Armbian

Download and flash **Armbian Ubuntu Noble** for Rock 2F to your SD card or eMMC.  
Boot and complete the initial setup (set root password, timezone, etc.).

### 2. Install Cinnamon Desktop

```bash
armbian-config
```

Navigate to: **System → Desktops → Cinnamon → minimal**

Wait for installation to complete, then reboot.

After reboot you should see the Cinnamon desktop login screen.

---

## Installation

### Quick Start

```bash
# Clone or download the setup script
wget https://your-repo/setup.sh

# Run with your network settings
HA_IP=192.168.1.50 MQTT_IP=192.168.1.1 bash setup.sh
```

### Parameters

| Variable | Default | Description |
|---|---|---|
| `HA_IP` | `192.168.1.100` | Home Assistant IP address |
| `HA_PORT` | `8123` | Home Assistant port |
| `MQTT_IP` | `192.168.1.100` | MQTT broker IP address |
| `MQTT_PORT` | `1883` | MQTT broker port |

### What the script does

The setup script runs through 12 steps automatically:

1. **User setup** — detects existing non-root users or creates a new one
2. **Packages** — installs Chromium, mosquitto-clients, jq, xdotool, x11vnc, etc.
3. **Touchscreen** — creates udev rule to map USB touchscreen to HDMI output
4. **CPU/GPU/DMC** — sets minimum frequency floors for smooth performance
5. **VNC password** — prompts you to set a VNC password (max 8 characters)
6. **Scripts** — writes `start-panel.sh` and `mqtt-telemetry.sh` to `/usr/local/bin/`
7. **Log files** — creates log files with correct permissions
8. **Autostart** — creates `.desktop` entries for kiosk, MQTT agent, VNC, PulseAudio
9. **Autologin** — configures LightDM to autologin the kiosk user
10. **Sudoers** — allows kiosk user to reboot without password
11. **HDMI audio** — sets HDMI as default PulseAudio output
12. **Screensaver** — disables screen lock and idle blanking

After the script finishes, **reboot** to apply everything.

---

## Home Assistant Integration

### MQTT Configuration

Add to your `configuration.yaml`:

```yaml
mqtt:
  broker: 192.168.1.1       # your MQTT broker IP
  port: 1883
  discovery: true
  discovery_prefix: homeassistant
```

### Entities Created (auto-discovered)

| Entity | Type | Description |
|---|---|---|
| `sensor.rock_2f_temperature` | Sensor | CPU temperature (°C) |
| `sensor.rock_2f_cpu_load` | Sensor | CPU usage (%) |
| `sensor.rock_2f_ram_usage` | Sensor | RAM usage (%) |
| `sensor.rock_2f_disk_usage` | Sensor | Root disk usage (%) |
| `sensor.rock_2f_updates` | Sensor | Available apt updates |
| `sensor.rock_2f_uptime` | Sensor | System uptime |
| `sensor.rock_2f_ip_address` | Sensor | Current IP address |
| `sensor.rock_2f_current_url` | Sensor | URL open in Chromium |
| `switch.rock_2f_screen` | Switch | Turn display on/off |
| `text.rock_2f_navigate` | Text | Send URL to browser |

### Trusted Networks (optional)

To skip the HA login screen on the kiosk, add to `configuration.yaml`:

```yaml
homeassistant:
  auth_providers:
    - type: trusted_networks
      trusted_networks:
        - 192.168.1.0/24
      allow_bypass_login: true
    - type: homeassistant
```

---

## Remote Access

### VNC

Connect from any VNC client on your network:

```
Host: <board IP>
Port: 5900
```

Clients: **RealVNC Viewer**, **TigerVNC** (Windows/Linux/macOS/Android/iOS)

> VNC password is limited to 8 characters by the RFB protocol.

### SSH

```bash
ssh root@<board IP>
```

---

## MQTT Commands

Send these payloads to the command topic `rock2f/command`:

| Payload | Action |
|---|---|
| `screen_off` | Turn off display |
| `screen_on` | Turn on display |
| `reboot` | Reboot the board |

Send a URL to `rock2f/navigate` to navigate the browser:

```
http://192.168.1.50:8123/lovelace/cameras
```

---

## File Structure

```
/usr/local/bin/
├── start-panel.sh        # Chromium kiosk launcher
└── mqtt-telemetry.sh     # MQTT telemetry agent

/home/<user>/.config/autostart/
├── kiosk.desktop         # Autostart: Chromium
├── mqtt-agent.desktop    # Autostart: MQTT agent
├── x11vnc.desktop        # Autostart: VNC server
└── pulseaudio.desktop    # Autostart: Audio

/etc/
├── lightdm/lightdm.conf.d/autologin.conf   # Autologin
├── udev/rules/99-touchscreen.rules          # Touchscreen mapping
├── systemd/system/cpu-minfreq.service       # CPU/GPU frequency floors
└── sudoers.d/rock2f-kiosk                   # Passwordless reboot

/var/log/
├── rock2f-mqtt.log       # MQTT agent log
└── x11vnc.log            # VNC server log
```

---

## Troubleshooting

### Chromium doesn't start

```bash
# Check autostart log
cat /var/log/kiosk-start.log

# Check for stale lock files
find ~/.config/chromium -name "SingletonLock"

# Run manually
DISPLAY=:0 /usr/local/bin/start-panel.sh
```

### MQTT entities not appearing in HA

```bash
# Check agent is running
ps aux | grep mqtt-telemetry

# Check log
tail -f /var/log/rock2f-mqtt.log

# Test MQTT connection manually
mosquitto_pub -h <MQTT_IP> -t test/hello -m "hello"
```

### Touchscreen not responding

```bash
# Check kernel sees the device
ls /dev/input/by-id/ | grep -i touch

# Test raw events (touch the screen)
evtest /dev/input/event3

# Check udev rule applied
udevadm info /dev/input/event3 | grep WL_OUTPUT
```

### VNC connection refused

```bash
# Check x11vnc is running
ps aux | grep x11vnc

# Start manually
x11vnc -display :0 -auth /home/<user>/.Xauthority \
    -rfbauth /home/<user>/.vnc/passwd -rfbport 5900 -forever -bg
```

### High temperature / throttling

```bash
# Monitor in real time
watch -n2 'echo "Temp: $(awk "{print \$1/1000}" /sys/class/thermal/thermal_zone0/temp)°C | \
CPU: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq)Hz"'

# Check throttling
dmesg | grep -i "thermal\|throttl"
```

---

## Notes

- **YouTube / video streaming**: 360p plays smoothly; 1080p will lag. This is a hardware limitation of RK3528 (no HW video decode in browser). For camera streams in HA, use a sub-stream at 640×360 @ 5fps via go2rtc.
- **Screen blanking**: The kiosk script disables all screensaver and DPMS settings. The `switch.rock_2f_screen` entity in HA gives you manual control.
- **Snap Chromium**: The setup uses the **deb** version of Chromium, not the snap. The snap version has Wayland isolation issues with touchscreen input.

---

## License

MIT — do whatever you want with it.
