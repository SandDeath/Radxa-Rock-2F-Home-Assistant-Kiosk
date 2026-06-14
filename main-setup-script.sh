#!/bin/bash
# =============================================================================
#  Rock 2F HA Kiosk — Master Setup Script
#  Version 1.2
#
#  Changes v1.2:
#   - MQTT: replaced autostart with systemd service (User=KIOSK_USER, DISPLAY=:0)
#     Fixes duplicate-process bug when autostart + service both active
#   - x11vnc: log moved to ${KIOSK_HOME}/x11vnc.log (was /var/log — no write perms)
#   - start-panel.sh updated to v6.0 (watchdog, DPMS, dconf, Chromium flag cleanup)
#   - mqtt-telemetry.sh updated to v5.0 (MQTT v2 cleanup, navigate entity, state file)
#
#  Tested on:
#     Board:    Radxa Rock 2F (Rockchip RK3528)
#     OS:       Armbian Ubuntu Noble (24.04)
#     Display:  13.3" 1920x1080 HDMI+USB Touchscreen
#     DE:       Cinnamon (minimal)
# =============================================================================

set -euo pipefail

# =============================================================================
#  COLORS
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_section() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; \
                echo -e "${BOLD}${BLUE}  $*${NC}"; \
                echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

# =============================================================================
#  ROOT CHECK
# =============================================================================
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root."
    exit 1
fi

# =============================================================================
#  BANNER
# =============================================================================
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ____            _      ____  _____   _  ___           _   
 |  _ \ __ _  __| |_  _|  _ \|  ___| | |/ (_)___  ___| | __
 | |_) / _` |/ _` \ \/ / |_) | |_    | ' /| / _ \/ __| |/ /
 |  _ < (_| | (_| |>  <|  _ <|  _|   | . \| | (_) \__ \   < 
 |_| \_\__,_|\__,_/_/\_\_| \_\_|     |_|\_\_|\___/|___/_|\_\

 Home Assistant Kiosk Setup for Radxa Rock 2F
 ─────────────────────────────────────────────
 Board:   Radxa Rock 2F (RK3528)
 Display: 13.3" 1080p HDMI+USB Touchscreen
 OS:      Armbian Ubuntu Noble + Cinnamon
EOF
echo -e "${NC}"

# =============================================================================
#  CONFIGURATION — EDIT THESE BEFORE RUNNING
# =============================================================================
log_section "Configuration"

# --- Network ---
HA_IP="${HA_IP:-192.168.1.100}"
HA_PORT="${HA_PORT:-8123}"
MQTT_IP="${MQTT_IP:-192.168.1.100}"
MQTT_PORT="${MQTT_PORT:-1883}"

# --- Paths ---
SCRIPTS_DIR="/usr/local/bin"
LOG_DIR="/var/log"

echo -e "  Home Assistant : ${CYAN}http://${HA_IP}:${HA_PORT}${NC}"
echo -e "  MQTT Broker    : ${CYAN}${MQTT_IP}:${MQTT_PORT}${NC}"
echo ""
echo -e "${YELLOW}  To override, run:${NC}"
echo -e "  ${CYAN}HA_IP=192.168.1.50 MQTT_IP=192.168.1.1 bash setup.sh${NC}"
echo ""

read -rp "  Press Enter to continue or Ctrl+C to abort..."

# =============================================================================
#  STEP 1 — USER SETUP
# =============================================================================
log_section "Step 1 — Kiosk User"

# Find existing non-root users
NON_ROOT_USERS=$(awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /nologin|false/ {print $1}' /etc/passwd)
KIOSK_USER=""

if [[ -n "$NON_ROOT_USERS" ]]; then
    echo -e "  Found existing non-root users:"
    i=1
    declare -A USER_MAP
    while IFS= read -r u; do
        echo -e "    ${CYAN}[$i]${NC} $u"
        USER_MAP[$i]="$u"
        (( i++ ))
    done <<< "$NON_ROOT_USERS"
    echo -e "    ${CYAN}[n]${NC} Create a new user"
    echo ""
    read -rp "  Select user [1]: " USER_CHOICE
    USER_CHOICE="${USER_CHOICE:-1}"

    if [[ "$USER_CHOICE" == "n" ]]; then
        read -rp "  Enter new username: " NEW_USER
        adduser "$NEW_USER"
        KIOSK_USER="$NEW_USER"
    else
        KIOSK_USER="${USER_MAP[$USER_CHOICE]}"
    fi
else
    log_warn "No non-root users found. Creating kiosk user..."
    read -rp "  Enter username for kiosk user [kiosk]: " NEW_USER
    NEW_USER="${NEW_USER:-kiosk}"
    adduser "$NEW_USER"
    KIOSK_USER="$NEW_USER"
fi

KIOSK_HOME=$(getent passwd "$KIOSK_USER" | cut -d: -f6)
KIOSK_UID=$(id -u "$KIOSK_USER")
log_info "Using kiosk user: ${KIOSK_USER} (home: ${KIOSK_HOME})"

# Add to required groups
usermod -aG sudo,video,input,audio "$KIOSK_USER"
log_info "Added ${KIOSK_USER} to sudo, video, input, audio groups"

# =============================================================================
#  STEP 2 — PACKAGES
# =============================================================================
log_section "Step 2 — Installing Packages"

apt-get update -qq

PACKAGES=(
    cinnamon-core           # Desktop Environment core components
    lightdm                 # Display manager
    chromium                # Kiosk browser (deb, not snap)
    mosquitto-clients       # MQTT publish/subscribe
    jq                      # JSON processing for CDP URL reading
    xdotool                 # Browser navigation automation
    x11-xserver-utils       # xset for screen control
    x11vnc                  # VNC remote access
    curl                    # CDP HTTP requests
    libinput-tools          # Touchscreen diagnostics
    evtest                  # Input device testing
    wlopm                   # Wayland display power (fallback)
    seatd                   # Seat manager for Wayland sessions
    pulseaudio              # Audio
)

log_info "Installing: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}" 2>&1 | grep -E "^(Get|Setting up|Unpacking)" || true
log_info "Packages installed."

# =============================================================================
#  STEP 3 — TOUCHSCREEN UDEV RULE
# =============================================================================
log_section "Step 3 — Touchscreen udev Rule"

# Detect touchscreen vendor/product (wch.cn USB touchscreen common in cheap HDMI panels)
TS_VENDOR=$(udevadm info -a /dev/input/event* 2>/dev/null | \
    grep -A2 'wch\|TouchScreen' | grep 'idVendor' | head -1 | \
    grep -oP '=="[^"]*"' | tr -d '"=' | head -1)
TS_PRODUCT=$(udevadm info -a /dev/input/event* 2>/dev/null | \
    grep -A3 'wch\|TouchScreen' | grep 'idProduct' | head -1 | \
    grep -oP '=="[^"]*"' | tr -d '"=' | head -1)

if [[ -n "$TS_VENDOR" && -n "$TS_PRODUCT" ]]; then
    log_info "Detected touchscreen: vendor=${TS_VENDOR} product=${TS_PRODUCT}"
    cat > /etc/udev/rules.d/99-touchscreen.rules << EOF
SUBSYSTEM=="input", \\
ATTRS{idVendor}=="${TS_VENDOR}", \\
ATTRS{idProduct}=="${TS_PRODUCT}", \\
ENV{WL_OUTPUT}="HDMI-A-1", \\
ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0"
EOF
    udevadm control --reload-rules
    udevadm trigger
    log_info "udev rule created for touchscreen."
else
    log_warn "Touchscreen not detected automatically. You may need to create udev rule manually."
    log_warn "Run: udevadm info -a /dev/input/event3 | grep -E 'idVendor|idProduct'"
fi

# =============================================================================
#  STEP 4 — CPU / GPU / DMC FREQUENCY FLOORS
# =============================================================================
log_section "Step 4 — CPU/GPU/DMC Frequency Optimization"

# Detect available CPU frequencies
AVAILABLE_FREQS=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies 2>/dev/null || echo "")

if [[ -n "$AVAILABLE_FREQS" ]]; then
    # Pick ~50% of max as minimum floor
    MAX_FREQ=$(echo "$AVAILABLE_FREQS" | tr ' ' '\n' | sort -n | tail -1)
    MIN_FREQ=$(echo "$AVAILABLE_FREQS" | tr ' ' '\n' | sort -n | \
        awk -v max="$MAX_FREQ" '{if($1 >= max*0.45 && $1 <= max*0.65) print $1}' | head -1)
    MIN_FREQ="${MIN_FREQ:-1008000}"
    log_info "Setting CPU minimum frequency to ${MIN_FREQ} Hz (max: ${MAX_FREQ} Hz)"
else
    MIN_FREQ="1008000"
    log_warn "Could not detect CPU frequencies, using default: ${MIN_FREQ} Hz"
fi

# GPU and DMC
GPU_DEV=$(ls /sys/class/devfreq/ 2>/dev/null | grep -v dmc | head -1)
GPU_MIN_FREQ="528000000"
DMC_MIN_FREQ="600000000"

cat > /etc/systemd/system/cpu-minfreq.service << EOF
[Unit]
Description=Set CPU/GPU/DMC minimum frequency for kiosk performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c '\
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq; do \
        echo ${MIN_FREQ} > "\$cpu" 2>/dev/null || true; \
    done; \
    echo ${GPU_MIN_FREQ} > /sys/class/devfreq/${GPU_DEV:-ff700000.gpu}/min_freq 2>/dev/null || true; \
    echo ${DMC_MIN_FREQ} > /sys/class/devfreq/dmc/min_freq 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now cpu-minfreq.service
log_info "CPU/GPU/DMC frequency floors configured and enabled."

# =============================================================================
#  STEP 5 — VNC PASSWORD
# =============================================================================
log_section "Step 5 — VNC Remote Access"

mkdir -p "${KIOSK_HOME}/.vnc"
echo ""
log_info "Set VNC password (max 8 characters):"
x11vnc -storepasswd "${KIOSK_HOME}/.vnc/passwd"
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.vnc"
log_info "VNC password saved."

# =============================================================================
#  STEP 6 — WRITE KIOSK SCRIPTS
# =============================================================================
log_section "Step 6 — Writing Kiosk Scripts"

# --- start-panel.sh v6.0 ---
cat > "${SCRIPTS_DIR}/start-panel.sh" << 'PANELEOF'
#!/bin/bash
# =============================================================================
#  Rock 2F — Chromium Kiosk Launch Script
#  Version 6.0 (X11 / Cinnamon / Autostart)
# =============================================================================

LOG_FILE="/var/log/kiosk-start.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [KIOSK] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log "Kiosk session starting..."

export DISPLAY=:0
export XAUTHORITY=__KIOSK_HOME__/.Xauthority
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/__KIOSK_UID__/bus"

for i in {1..30}; do
    if xset q &>/dev/null && \
       dconf read /org/cinnamon/desktop/screensaver/lock-enabled &>/dev/null; then
        log "X server and D-Bus are ready (waited ${i}s)."
        break
    fi
    log "Waiting for session... (${i}/30)"
    sleep 1
done

sleep 3

/usr/bin/xset s off
/usr/bin/xset s noblank
/usr/bin/xset -dpms

dconf write /org/cinnamon/desktop/screensaver/lock-enabled false
dconf write /org/cinnamon/desktop/screensaver/idle-activation-enabled false
dconf write /org/cinnamon/desktop/screensaver/ask-for-away-message false
dconf write /org/cinnamon/settings-daemon/plugins/power/sleep-display-ac 0
dconf write /org/cinnamon/settings-daemon/plugins/power/idle-dim-time 0
dconf write /org/cinnamon/settings-daemon/plugins/power/idle-brightness 100

dconf write /org/cinnamon/desktop/interface/effects-enabled false
dconf write /org/cinnamon/desktop/wm/preferences/edge-tiling false
dconf write /org/cinnamon/muffin/edge-tiling false
dconf write /org/cinnamon/desktop/wm/preferences/num-workspaces 1

log "Display and screensaver configured."

FLAGS=(
    --kiosk
    --no-sandbox
    --noerrdialogs
    --disable-infobars
    --no-first-run
    --disable-restore-session-state

    --disable-background-networking
    --disable-background-timer-throttling
    --disable-backgrounding-occluded-windows
    --disable-client-side-phishing-detection
    --disable-default-apps
    --disable-extensions
    --disable-plugins
    --disable-translate
    --disable-sync
    --disable-features=TranslateUI

    --disk-cache-size=67108864
    --media-cache-size=0
    --disable-dev-shm-usage
    --renderer-process-limit=1

    --disable-smooth-scrolling
    --disable-hang-monitor
    --disable-component-update

    --autoplay-policy=no-user-gesture-required

    --remote-debugging-port=9222
    --remote-debugging-address=127.0.0.1

    --app=http://__HA_IP__:__HA_PORT__
)

watchdog() {
    while true; do
        sleep 30
        local WID
        WID=$(xdotool search --onlyvisible --class chromium 2>/dev/null | head -1)
        [[ -z "$WID" ]] && continue
        local ACTIVE_WID
        ACTIVE_WID=$(xdotool getactivewindow 2>/dev/null)
        if [[ "$WID" != "$ACTIVE_WID" ]]; then
            log "Chromium lost focus — restoring window ${WID}."
            xdotool windowraise "$WID"
            xdotool windowfocus --sync "$WID"
        fi
    done
}

watchdog &
WATCHDOG_PID=$!
log "Watchdog started (PID ${WATCHDOG_PID})."

while true; do
    pkill -f "chromium" 2>/dev/null
    sleep 1

    find __KIOSK_HOME__/.config/chromium -name "SingletonLock" -delete 2>/dev/null
    find __KIOSK_HOME__/.config/chromium -name "SingletonSocket" -delete 2>/dev/null

    /usr/bin/xset dpms force on 2>/dev/null || true
    pkill -SIGTERM cinnamon-screensaver 2>/dev/null || true
    sleep 0.5

    log "Launching Chromium..."
    /usr/bin/chromium "${FLAGS[@]}" 2>>/var/log/chromium-kiosk.log

    EXIT_CODE=$?
    log "Chromium exited (code ${EXIT_CODE}), restarting in 3s..."
    sleep 3
done
PANELEOF

# --- mqtt-telemetry.sh v5.0 ---
cat > "${SCRIPTS_DIR}/mqtt-telemetry.sh" << 'MQTTEOF'
#!/bin/bash
# =============================================================================
#  Rock 2F Panel — MQTT Home Assistant Integration
#  Version 5.0 (X11 / Cinnamon)
# =============================================================================

set -uo pipefail

MQTT_HOST="__MQTT_IP__"
MQTT_PORT="${MQTT_PORT:-__MQTT_PORT__}"

SENSOR_BASE="homeassistant/sensor/rock2f_panel"
SWITCH_BASE="homeassistant/switch/rock2f_panel"
TEXT_BASE="homeassistant/text/rock2f_panel"
STATE_TOPIC="${SENSOR_BASE}/state"

COMMAND_TOPIC="rock2f/command"
SCREEN_STATE_TOPIC="rock2f/screen/state"
NAVIGATE_TOPIC="rock2f/navigate"
NAVIGATE_STATE_TOPIC="rock2f/navigate/state"

CDP_URL="http://localhost:9222/json"

LOG_FILE="/var/log/rock2f-mqtt.log"
PID_FILE="__KIOSK_HOME__/rock2f-mqtt.pid"
SCREEN_STATE_FILE="/tmp/rock2f-screen-state"

MAIN_INTERVAL=60
UPDATE_CHECK_EVERY=30
URL_CHECK_EVERY=3
STARTUP_DELAY=15

export DISPLAY=":0"
export XAUTHORITY="__KIOSK_HOME__/.Xauthority"

DEVICE_JSON='{"identifiers":["rock2f_panel"],"name":"Rock 2F Panel","model":"Rock 2F","manufacturer":"Radxa"}'

log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE"
}

# Guard against duplicate instances.
# Note: use kill -0 with fallback for cross-user PID check.
if [[ -f "$PID_FILE" ]]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null || [ -d "/proc/$OLD_PID" ]; then
        log "WARN" "Already running (PID $OLD_PID). Exiting."
        exit 1
    else
        log "INFO" "Stale PID file, removing."
        rm -f "$PID_FILE"
    fi
fi
echo $$ > "$PID_FILE"

cleanup() {
    log "INFO" "Stopping (PID $$)..."
    rm -f "$PID_FILE"
    jobs -p | xargs -r kill 2>/dev/null
    exit 0
}
trap cleanup SIGINT SIGTERM

mqtt_pub() {
    local topic="$1"
    local payload="$2"
    local extra="${3:-}"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" -t "$topic" -m "$payload" $extra
}

publish_sensor_config() {
    local KEY="$1" NAME="$2" DEVICE_CLASS="$3" STATE_CLASS="$4" UNIT="$5"
    local UNIQUE_ID="rock2f_panel_${KEY}"
    local MSG="{\"name\":\"Rock 2F ${NAME}\""
    MSG="${MSG},\"state_topic\":\"${STATE_TOPIC}\""
    MSG="${MSG},\"value_template\":\"{{ value_json.${KEY} }}\""
    MSG="${MSG},\"unique_id\":\"${UNIQUE_ID}\""
    MSG="${MSG},\"device\":${DEVICE_JSON}"
    [[ -n "$STATE_CLASS"  ]] && MSG="${MSG},\"state_class\":\"${STATE_CLASS}\""
    [[ -n "$DEVICE_CLASS" ]] && MSG="${MSG},\"device_class\":\"${DEVICE_CLASS}\""
    [[ -n "$UNIT"         ]] && MSG="${MSG},\"unit_of_measurement\":\"${UNIT}\""
    MSG="${MSG}}"
    mqtt_pub "${SENSOR_BASE}/${KEY}/config" "$MSG" -r
}

publish_switch_config() {
    local MSG
    MSG=$(printf '{"name":"Rock 2F Screen","command_topic":"%s","state_topic":"%s","payload_on":"screen_on","payload_off":"screen_off","state_on":"ON","state_off":"OFF","unique_id":"rock2f_panel_screen","icon":"mdi:monitor","device":%s}' \
        "$COMMAND_TOPIC" "$SCREEN_STATE_TOPIC" "$DEVICE_JSON")
    mqtt_pub "${SWITCH_BASE}/screen/config" "$MSG" -r
}

publish_navigate_config() {
    local MSG
    MSG=$(printf '{"name":"Rock 2F Navigate","command_topic":"%s","state_topic":"%s","unique_id":"rock2f_panel_navigate","icon":"mdi:web","device":%s}' \
        "$NAVIGATE_TOPIC" "$NAVIGATE_STATE_TOPIC" "$DEVICE_JSON")
    mqtt_pub "${TEXT_BASE}/navigate/config" "$MSG" -r
}

send_config() {
    log "INFO" "Registering entities in HA..."
    publish_sensor_config "temp"    "Temperature"  "temperature" "measurement" "°C"
    publish_sensor_config "cpu"     "CPU Load"     ""            "measurement" "%"
    publish_sensor_config "mem"     "RAM Usage"    ""            "measurement" "%"
    publish_sensor_config "disk"    "Disk Usage"   ""            "measurement" "%"
    publish_sensor_config "updates" "Updates"      ""            "measurement" ""
    publish_sensor_config "uptime"  "Uptime"       ""            ""            ""
    publish_sensor_config "ip"      "IP Address"   ""            ""            ""
    publish_sensor_config "url"     "Current URL"  ""            ""            ""
    publish_switch_config
    publish_navigate_config
    log "INFO" "All configs published."
}

clear_discovery() {
    log "INFO" "Clearing old configs..."
    for s in temp cpu mem disk updates uptime ip url; do
        mqtt_pub "${SENSOR_BASE}/${s}/config" "" -r
    done
    mqtt_pub "${SWITCH_BASE}/screen/config"  "" -r
    mqtt_pub "${TEXT_BASE}/navigate/config"  "" -r
    sleep 2
}

get_cpu_usage() {
    local -a s1 s2
    s1=($(head -1 /proc/stat))
    sleep 1
    s2=($(head -1 /proc/stat))
    local idle1=${s1[4]} idle2=${s2[4]}
    local total1=0 total2=0 v
    for v in "${s1[@]:1}"; do (( total1 += v )); done
    for v in "${s2[@]:1}"; do (( total2 += v )); done
    local diff_idle=$(( idle2 - idle1 ))
    local diff_total=$(( total2 - total1 ))
    (( diff_total == 0 )) && echo "0.0" && return
    awk "BEGIN { printf \"%.1f\", (1 - $diff_idle / $diff_total) * 100 }"
}

get_screen_state() {
    [[ -f "$SCREEN_STATE_FILE" ]] && cat "$SCREEN_STATE_FILE" || echo "ON"
}

get_current_url() {
    curl -s --max-time 2 "$CDP_URL" 2>/dev/null \
    | jq -r '[.[] | select(.type=="page")] | first | .url // "unknown"' \
    2>/dev/null || echo "unknown"
}

navigate_to_url() {
    local url="$1"
    local wid
    wid=$(xdotool search --onlyvisible --class chromium 2>/dev/null | head -1)
    [[ -z "$wid" ]] && log "WARN" "Chromium window not found" && return 1
    xdotool windowactivate --sync "$wid"
    xdotool key --clearmodifiers ctrl+l
    sleep 0.3
    xdotool type --clearmodifiers --delay 20 "$url"
    xdotool key Return
    mqtt_pub "$NAVIGATE_STATE_TOPIC" "$url" -r
    log "INFO" "Navigate: $url"
}

start_command_listener() {
    mosquitto_sub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -t "$COMMAND_TOPIC" -t "$NAVIGATE_TOPIC" | \
    while read -r msg; do
        log "INFO" "Command: $msg"
        if [[ "$msg" == *"://"* ]]; then
            navigate_to_url "$msg"
        else
            case "$msg" in
                "screen_off")
                    /usr/bin/xset dpms force off
                    echo "OFF" > "$SCREEN_STATE_FILE"
                    mqtt_pub "$SCREEN_STATE_TOPIC" "OFF" -r
                    ;;
                "screen_on")
                    /usr/bin/xset dpms force on
                    echo "ON" > "$SCREEN_STATE_FILE"
                    mqtt_pub "$SCREEN_STATE_TOPIC" "ON" -r
                    ;;
                "reboot")
                    log "WARN" "Reboot command received!"
                    /sbin/reboot
                    ;;
                *)
                    log "WARN" "Unknown command: $msg"
                    ;;
            esac
        fi
    done &
    log "INFO" "Command listener started (PID $!)."
}

log "INFO" "Rock 2F MQTT Agent v5 starting (PID $$)"

clear_discovery
log "INFO" "Waiting ${STARTUP_DELAY}s for network and MQTT broker..."
sleep "$STARTUP_DELAY"

send_config
start_command_listener

[[ ! -f "$SCREEN_STATE_FILE" ]] && echo "ON" > "$SCREEN_STATE_FILE"
mqtt_pub "$SCREEN_STATE_TOPIC" "$(get_screen_state)" -r
mqtt_pub "$NAVIGATE_STATE_TOPIC" "$(get_current_url)" -r

CYCLE=0
UPDATES=0
CURRENT_URL="unknown"
LAST_TEMP=0; LAST_CPU=0; LAST_MEM=0; LAST_DISK=0
LAST_UPDATES=0; LAST_UPTIME=""; LAST_IP=""

log "INFO" "Main loop started (interval ${MAIN_INTERVAL}s)."

while true; do
    if (( CYCLE % UPDATE_CHECK_EVERY == 0 )); then
        UPDATES=$(apt list --upgradable 2>/dev/null | grep -c '\[upgradable')
        LAST_UPDATES=$UPDATES
    fi
    if (( CYCLE % URL_CHECK_EVERY == 0 )); then
        CURRENT_URL=$(get_current_url)
        mqtt_pub "$NAVIGATE_STATE_TOPIC" "$CURRENT_URL" -r
    fi
    (( CYCLE++ )) || true

    CPU=$(get_cpu_usage)
    TEMP=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    MEM=$(free | awk '/^Mem:/ { printf "%.1f", $3/$2*100 }')
    DISK=$(df / | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')
    UPTIME=$(uptime -p | sed 's/^up //')
    IP=$(hostname -I | awk '{print $1}')

    LAST_TEMP=$TEMP; LAST_CPU=$CPU; LAST_MEM=$MEM; LAST_DISK=$DISK
    LAST_UPTIME=$UPTIME; LAST_IP=$IP

    PAYLOAD=$(jq -n \
      --argjson temp "$TEMP" --argjson cpu "$CPU" \
      --argjson mem "$MEM" --argjson disk "$DISK" \
      --argjson updates "$UPDATES" \
      --arg uptime "$UPTIME" --arg ip "$IP" --arg url "$CURRENT_URL" \
      '{temp:$temp,cpu:$cpu,mem:$mem,disk:$disk,updates:$updates,uptime:$uptime,ip:$ip,url:$url}')

    mqtt_pub "$STATE_TOPIC" "$PAYLOAD"
    log "INFO" "Payload sent: temp=${TEMP} cpu=${CPU} mem=${MEM}"

    sleep "$(( MAIN_INTERVAL - 1 ))"
done
MQTTEOF

# Replace placeholders in mqtt script
sed -i "s|__MQTT_IP__|${MQTT_IP}|g" "${SCRIPTS_DIR}/mqtt-telemetry.sh"
sed -i "s|__MQTT_PORT__|${MQTT_PORT}|g" "${SCRIPTS_DIR}/mqtt-telemetry.sh"
sed -i "s|__KIOSK_HOME__|${KIOSK_HOME}|g" "${SCRIPTS_DIR}/mqtt-telemetry.sh"

sed -i "s|__HA_IP__|${HA_IP}|g" "${SCRIPTS_DIR}/start-panel.sh"
sed -i "s|__HA_PORT__|${HA_PORT}|g" "${SCRIPTS_DIR}/start-panel.sh"
sed -i "s|__KIOSK_HOME__|${KIOSK_HOME}|g" "${SCRIPTS_DIR}/start-panel.sh"
sed -i "s|__KIOSK_UID__|${KIOSK_UID}|g" "${SCRIPTS_DIR}/start-panel.sh"

chmod +x "${SCRIPTS_DIR}/start-panel.sh"
chmod +x "${SCRIPTS_DIR}/mqtt-telemetry.sh"
log_info "Scripts written to ${SCRIPTS_DIR}/"

# =============================================================================
#  STEP 7 — LOG FILES
# =============================================================================
log_section "Step 7 — Log Files"

touch "${LOG_DIR}/rock2f-mqtt.log" "${LOG_DIR}/kiosk-start.log" "${LOG_DIR}/chromium-kiosk.log"
chmod 664 "${LOG_DIR}/rock2f-mqtt.log" "${LOG_DIR}/kiosk-start.log" "${LOG_DIR}/chromium-kiosk.log"
chown "${KIOSK_USER}:${KIOSK_USER}" "${LOG_DIR}/rock2f-mqtt.log" "${LOG_DIR}/kiosk-start.log" "${LOG_DIR}/chromium-kiosk.log"
log_info "Log files created and permissions fixed."

# =============================================================================
#  STEP 8 — AUTOSTART
# =============================================================================
log_section "Step 8 — Autostart"

AUTOSTART_DIR="${KIOSK_HOME}/.config/autostart"
mkdir -p "$AUTOSTART_DIR"

# Chromium kiosk
cat > "${AUTOSTART_DIR}/kiosk.desktop" << EOF
[Desktop Entry]
Type=Application
Name=HA Kiosk
Exec=${SCRIPTS_DIR}/start-panel.sh
X-GNOME-Autostart-enabled=true
EOF

# MQTT telemetry — systemd service (runs as KIOSK_USER with DISPLAY=:0)
# Using systemd instead of autostart prevents duplicate-process issues
cat > /etc/systemd/system/mqtt-telemetry.service << EOF
[Unit]
Description=MQTT Telemetry Agent (Rock 2F Panel)
After=network-online.target
Wants=network-online.target

[Service]
User=${KIOSK_USER}
Environment=DISPLAY=:0
Environment=XAUTHORITY=${KIOSK_HOME}/.Xauthority
ExecStart=${SCRIPTS_DIR}/mqtt-telemetry.sh
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable mqtt-telemetry.service
log_info "mqtt-telemetry.service enabled (will start on next boot / after graphical.target)."

# VNC server
cat > "${AUTOSTART_DIR}/x11vnc.desktop" << EOF
[Desktop Entry]
Type=Application
Name=x11vnc
Exec=x11vnc -display :0 -auth ${KIOSK_HOME}/.Xauthority -rfbauth ${KIOSK_HOME}/.vnc/passwd -rfbport 5900 -forever -bg -o ${KIOSK_HOME}/x11vnc.log
X-GNOME-Autostart-enabled=true
EOF

# PulseAudio
cat > "${AUTOSTART_DIR}/pulseaudio.desktop" << EOF
[Desktop Entry]
Type=Application
Name=PulseAudio
Exec=pulseaudio --start
X-GNOME-Autostart-enabled=true
EOF

chown -R "${KIOSK_USER}:${KIOSK_USER}" "${AUTOSTART_DIR}"
log_info "Autostart entries created."

# =============================================================================
#  STEP 9 — AUTOLOGIN
# =============================================================================
log_section "Step 9 — Autologin"

mkdir -p /etc/lightdm/lightdm.conf.d/
cat > /etc/lightdm/lightdm.conf.d/autologin.conf << EOF
[Seat:*]
autologin-user=${KIOSK_USER}
autologin-user-timeout=0
user-session=cinnamon
EOF
log_info "Autologin configured for: ${KIOSK_USER} (Session: Cinnamon)"

# =============================================================================
#  STEP 10 — SUDOERS
# =============================================================================
log_section "Step 10 — Sudoers"

cat > /etc/sudoers.d/rock2f-kiosk << EOF
${KIOSK_USER} ALL=(ALL) NOPASSWD: /sbin/reboot
EOF
chmod 440 /etc/sudoers.d/rock2f-kiosk
log_info "Sudoers configured."

# =============================================================================
#  STEP 11 — HDMI AUDIO DEFAULT
# =============================================================================
log_section "Step 11 — HDMI Audio"

mkdir -p "${KIOSK_HOME}/.config/pulse"
cat > "${KIOSK_HOME}/.config/pulse/default.pa" << 'EOF'
.include /etc/pulse/default.pa
set-default-sink alsa_output.platform-hdmi-sound.stereo-fallback
EOF
chown -R "${KIOSK_USER}:${KIOSK_USER}" "${KIOSK_HOME}/.config/pulse"
log_info "HDMI audio set as default sink."

# =============================================================================
#  STEP 12 — SCREENSAVER DISABLE
# =============================================================================
log_section "Step 12 — Disable Screensaver"

# Will be applied on next login via start-panel.sh
# Pre-configure dconf for the user
mkdir -p /etc/dconf/db/local.d/
cat > /etc/dconf/db/local.d/01-kiosk << 'EOF'
[org/cinnamon/desktop/screensaver]
lock-enabled=false
idle-activation-enabled=false

[org/cinnamon/settings-daemon/plugins/power]
sleep-display-ac=0
idle-dim-time=0
EOF
dconf update 2>/dev/null || true
su - "${KIOSK_USER}" -c "DISPLAY=:0 XAUTHORITY=${KIOSK_HOME}/.Xauthority \
    killall cinnamon-screensaver 2>/dev/null || true"

log_info "Screensaver/lock disabled via dconf (start-panel.sh applies settings at login)."

# =============================================================================
#  DONE
# =============================================================================
log_section "Setup Complete!"

BOARD_IP=$(hostname -I | awk '{print $1}')

echo -e "  ${GREEN}✓${NC} Kiosk user     : ${CYAN}${KIOSK_USER}${NC}"
echo -e "  ${GREEN}✓${NC} Home Assistant : ${CYAN}http://${HA_IP}:${HA_PORT}${NC}"
echo -e "  ${GREEN}✓${NC} MQTT Broker    : ${CYAN}${MQTT_IP}:${MQTT_PORT}${NC}"
echo -e "  ${GREEN}✓${NC} VNC access     : ${CYAN}${BOARD_IP}:5900${NC}  (log: ${KIOSK_HOME}/x11vnc.log)"
echo -e "  ${GREEN}✓${NC} Kiosk script   : ${CYAN}${SCRIPTS_DIR}/start-panel.sh${NC}"
echo -e "  ${GREEN}✓${NC} MQTT script    : ${CYAN}${SCRIPTS_DIR}/mqtt-telemetry.sh${NC}"
echo -e "  ${GREEN}✓${NC} MQTT service   : ${CYAN}systemctl status mqtt-telemetry${NC}
  ${GREEN}✓${NC} MQTT log       : ${CYAN}${LOG_DIR}/rock2f-mqtt.log${NC}"
echo ""
echo -e "  ${YELLOW}HA MQTT Integration:${NC}"
echo -e "  Add to configuration.yaml:"
echo -e "  ${CYAN}mqtt:${NC}"
echo -e "  ${CYAN}    broker: ${MQTT_IP}${NC}"
echo -e "  ${CYAN}    port: ${MQTT_PORT}${NC}"
echo -e "  ${CYAN}    discovery: true${NC}"
echo ""
echo -e "  ${BOLD}Reboot to apply all settings:${NC}"
echo -e "  ${CYAN}systemctl reboot${NC}"
echo ""
