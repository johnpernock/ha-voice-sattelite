#!/bin/bash
# =============================================================================
#  voice-setup.sh — Linux Voice Assistant (LVA) setup for Home Assistant
#  github.com/johnpernock/ha-voice-sattelite
# =============================================================================
#
#  Installs OHF-Voice/linux-voice-assistant as a systemd user service.
#  Connects to Home Assistant via ESPHome protocol (auto-discovered).
#
#  Usage:
#    sudo bash voice-setup.sh              # fresh install
#    sudo bash voice-setup.sh --reset      # wipe and reinstall
#    sudo bash voice-setup.sh --update     # pull latest LVA and restart
#    sudo bash voice-setup.sh --detect     # detect audio devices only
#    sudo bash voice-setup.sh --status     # show service status and logs
#
#  Config:
#    cp voice.conf.example voice.conf
#    nano voice.conf
#    sudo bash voice-setup.sh
#
#  NOTE: Flags must be run one at a time. See voice.conf.example for all options.
# =============================================================================

# =============================================================================
#  CONFIG — defaults (override in voice.conf, never edit this file)
# =============================================================================

# Name shown in Home Assistant devices list
VOICE_SATELLITE_NAME="ha-voice-satellite"

# Hardware type — controls driver install and device name resolution
# Options: auto | 2mic_hat | respeaker_lite | usb | custom
VOICE_HARDWARE="auto"

# Audio devices — leave blank to auto-detect based on VOICE_HARDWARE
# Run: sudo bash voice-setup.sh --detect  to find your device names
VOICE_MIC_DEVICE=""
VOICE_SPEAKER_DEVICE=""

# Wake word model — okay_nabu | hey_jarvis | alexa | custom
VOICE_WAKE_WORD="okay_nabu"

# Port for ESPHome server (HA discovers this automatically)
VOICE_PORT=6053

# Speaker output routing — separate from microphone
# Leave blank to use the same card as the microphone (default)
# Options:
#   hdmi         — HDMI 1 (vc4hdmi0 on Pi 4/5, HDMI on Pi 3)
#   hdmi2        — HDMI 2 (Pi 4/5 second HDMI port)
#   headphone    — 3.5mm headphone jack (Pi built-in)
#   usb_speaker  — first USB audio output device
#   (anything else is treated as a literal ALSA device name)
VOICE_SPEAKER_OUTPUT=""

# Home Assistant details (only needed if auto-discovery fails)
VOICE_HA_HOST=""
VOICE_HA_PORT=6053

# =============================================================================
#  LOCAL OVERRIDES — voice.conf (optional, git-ignored)
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/voice.conf" ]]; then
    source "$SCRIPT_DIR/voice.conf"
    echo "[voice-setup] Loaded local config: $SCRIPT_DIR/voice.conf"
fi

# =============================================================================
#  INTERNAL — do not edit below this line
# =============================================================================

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "${RED}Error: Must be run as root. Try: sudo bash $0${NC}" && exit 1

VOICE_USER="${SUDO_USER:-$(logname 2>/dev/null || echo pi)}"
VOICE_HOME="/home/$VOICE_USER"
LVA_DIR="$VOICE_HOME/linux-voice-assistant"
LVA_REPO="https://github.com/OHF-Voice/linux-voice-assistant.git"
SERVICE_NAME="linux-voice-assistant"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
INSTALL_MARKER="/etc/voice-installed"
LOG_FILE="$VOICE_HOME/voice.log"

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
log()   { echo -e "    ${CYAN}→${NC} $*"; }
hr()    { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }
banner(){ echo -e "${BOLD}$*${NC}"; }

# =============================================================================
#  Hardware profiles
# =============================================================================
_detect_hardware() {
    # Auto-detect what's connected
    if aplay -l 2>/dev/null | grep -qi "seeed2micvoicec\|seeed-2mic"; then
        echo "2mic_hat"
    elif aplay -l 2>/dev/null | grep -qi "ReSpeaker\|SEEED\|XVF"; then
        echo "respeaker_lite"
    elif arecord -l 2>/dev/null | grep -qi "USB\|usb"; then
        echo "usb"
    else
        echo "unknown"
    fi
}

_resolve_devices() {
    local hw="$1"

    case "$hw" in
        2mic_hat)
            RESOLVED_MIC="plughw:CARD=seeed2micvoicec,DEV=0"
            RESOLVED_SPK="plughw:CARD=seeed2micvoicec,DEV=0"
            ;;
        respeaker_lite)
            # ReSpeaker Lite uses USB audio — find it by name
            local card
            card=$(aplay -l 2>/dev/null | grep -i "ReSpeaker\|SEEED" | head -1 | grep -oP 'card \K[0-9]+')
            if [[ -n "$card" ]]; then
                RESOLVED_MIC="plughw:${card},0"
                RESOLVED_SPK="plughw:${card},0"
            else
                RESOLVED_MIC="default"
                RESOLVED_SPK="default"
            fi
            ;;
        usb)
            # Find first USB audio device
            local card
            card=$(arecord -l 2>/dev/null | grep -i "usb\|USB" | head -1 | grep -oP 'card \K[0-9]+')
            if [[ -n "$card" ]]; then
                RESOLVED_MIC="plughw:${card},0"
                RESOLVED_SPK="plughw:${card},0"
            else
                RESOLVED_MIC="default"
                RESOLVED_SPK="default"
            fi
            ;;
        custom)
            # User provided explicit device names in voice.conf
            RESOLVED_MIC="$VOICE_MIC_DEVICE"
            RESOLVED_SPK="$VOICE_SPEAKER_DEVICE"
            ;;
        *)
            RESOLVED_MIC="${VOICE_MIC_DEVICE:-default}"
            RESOLVED_SPK="${VOICE_SPEAKER_DEVICE:-default}"
            ;;
    esac

    # ── Speaker output override ────────────────────────────────────────────────
    # VOICE_SPEAKER_OUTPUT lets you route audio to a different output than
    # the mic card — useful when your mic is on a HAT but speakers are on HDMI,
    # a USB DAC, or the Pi headphone jack.
    case "${VOICE_SPEAKER_OUTPUT:-}" in
        hdmi|hdmi1)
            # HDMI output — Pi has vc4hdmi0 (Pi 4/5) or bcm2835 HDMI (Pi 3)
            local hdmi_card
            hdmi_card=$(aplay -l 2>/dev/null | grep -i "vc4hdmi0\|vc4-hdmi\|bcm2835.*HDMI" | head -1 | grep -oP 'card \K[0-9]+')
            if [[ -n "$hdmi_card" ]]; then
                RESOLVED_SPK="plughw:${hdmi_card},0"
                log "Speaker routed to HDMI (card ${hdmi_card})"
            else
                warn "HDMI audio device not found — check: aplay -l"
                RESOLVED_SPK="default"
            fi
            ;;
        hdmi2)
            local hdmi_card
            hdmi_card=$(aplay -l 2>/dev/null | grep -i "vc4hdmi1" | head -1 | grep -oP 'card \K[0-9]+')
            if [[ -n "$hdmi_card" ]]; then
                RESOLVED_SPK="plughw:${hdmi_card},0"
                log "Speaker routed to HDMI 2 (card ${hdmi_card})"
            else
                warn "HDMI2 audio device not found — falling back to HDMI1"
                VOICE_SPEAKER_OUTPUT="hdmi1"
                _resolve_devices "$hw"
                return
            fi
            ;;
        headphone|jack|3.5mm)
            # Pi 3.5mm headphone jack (bcm2835 Headphones)
            local hp_card
            hp_card=$(aplay -l 2>/dev/null | grep -i "Headphones\|bcm2835.*Head" | head -1 | grep -oP 'card \K[0-9]+')
            if [[ -n "$hp_card" ]]; then
                RESOLVED_SPK="plughw:${hp_card},0"
                log "Speaker routed to headphone jack (card ${hp_card})"
            else
                warn "Headphone jack not found — check: aplay -l"
                RESOLVED_SPK="default"
            fi
            ;;
        usb_dac|usb_speaker)
            local usb_card
            usb_card=$(aplay -l 2>/dev/null | grep -i "USB\|usb" | head -1 | grep -oP 'card \K[0-9]+')
            if [[ -n "$usb_card" ]]; then
                RESOLVED_SPK="plughw:${usb_card},0"
                log "Speaker routed to USB DAC/speaker (card ${usb_card})"
            else
                warn "USB speaker not found — check: aplay -l"
                RESOLVED_SPK="default"
            fi
            ;;
        "")
            : # No override — use the card default resolved above
            ;;
        *)
            # Treat any other value as a literal device name
            RESOLVED_SPK="$VOICE_SPEAKER_OUTPUT"
            log "Speaker set to custom device: $RESOLVED_SPK"
            ;;
    esac

    # Explicit device name overrides always win over everything above
    [[ -n "$VOICE_MIC_DEVICE" ]]     && RESOLVED_MIC="$VOICE_MIC_DEVICE"
    [[ -n "$VOICE_SPEAKER_DEVICE" ]] && RESOLVED_SPK="$VOICE_SPEAKER_DEVICE"
}

# =============================================================================
#  2-Mic HAT V2.0 driver install (device tree overlay — no kernel compile)
# =============================================================================
_install_2mic_driver() {
    hr; banner "  ReSpeaker 2-Mic HAT V2.0 — Driver Install"; hr; echo ""

    if aplay -l 2>/dev/null | grep -qi "seeed2micvoicec"; then
        info "2-Mic HAT driver already installed and detected"
        return 0
    fi

    log "Installing build dependencies..."
    apt-get install -y --no-install-recommends \
        git build-essential device-tree-compiler \
        raspberrypi-kernel-headers 2>/dev/null || true

    log "Cloning seeed-linux-dtoverlays..."
    local DT_DIR="$VOICE_HOME/seeed-linux-dtoverlays"
    if [[ -d "$DT_DIR" ]]; then
        git -C "$DT_DIR" pull --quiet
    else
        sudo -u "$VOICE_USER" git clone --quiet \
            https://github.com/Seeed-Studio/seeed-linux-dtoverlays.git "$DT_DIR"
    fi

    log "Compiling device tree overlay..."
    cd "$DT_DIR"
    if ! make overlays/rpi/respeaker-2mic-v2_0-overlay.dtbo 2>/dev/null; then
        warn "dtbo compile failed — trying pre-built overlay path..."
        # Fallback: some kernels have it pre-built
        if [[ ! -f "overlays/rpi/respeaker-2mic-v2_0-overlay.dtbo" ]]; then
            err "Could not compile or find the 2-Mic HAT overlay.
  Check your kernel version: uname -r
  Requires: raspberrypi-kernel-headers matching your kernel.
  Try: sudo apt-get install raspberrypi-kernel-headers"
        fi
    fi

    log "Installing overlay to /boot/firmware/overlays/..."
    cp overlays/rpi/respeaker-2mic-v2_0-overlay.dtbo \
        /boot/firmware/overlays/respeaker-2mic-v2_0.dtbo

    log "Enabling overlay in /boot/firmware/config.txt..."
    if ! grep -q "dtoverlay=respeaker-2mic-v2_0" /boot/firmware/config.txt; then
        echo "dtoverlay=respeaker-2mic-v2_0" >> /boot/firmware/config.txt
        info "Overlay added to config.txt"
    else
        info "Overlay already in config.txt"
    fi

    # Enable I2C and SPI (required for HAT LEDs and codec)
    if ! grep -q "^dtparam=i2c_arm=on" /boot/firmware/config.txt; then
        echo "dtparam=i2c_arm=on" >> /boot/firmware/config.txt
    fi
    if ! grep -q "^dtparam=spi=on" /boot/firmware/config.txt; then
        echo "dtparam=spi=on" >> /boot/firmware/config.txt
    fi

    echo ""
    warn "REBOOT REQUIRED before the 2-Mic HAT will be detected."
    echo ""
    echo "  After rebooting, run the install again:"
    echo "    sudo bash $0"
    echo ""
    echo "  The driver will be detected on the second run and"
    echo "  the LVA install will complete automatically."
    echo ""

    # Mark that we need a reboot
    echo "REBOOT_PENDING=true" > "$INSTALL_MARKER"

    read -r -p "  Reboot now? [Y/n] " ans
    [[ "${ans,,}" != "n" ]] && reboot
    exit 0
}

# =============================================================================
#  --detect — show audio devices
# =============================================================================
if [[ "$1" == "--detect" ]]; then
    hr; banner "  Audio Device Detection"; hr; echo ""

    echo "Detected hardware type: $(_detect_hardware)"
    echo ""
    echo "=== Playback devices (aplay -l) ==="
    aplay -l 2>/dev/null || echo "  No playback devices found"
    echo ""
    echo "=== Capture devices (arecord -l) ==="
    arecord -l 2>/dev/null || echo "  No capture devices found"
    echo ""
    echo "=== PulseAudio/PipeWire sources ==="
    pactl list sources short 2>/dev/null || echo "  PulseAudio not running"
    echo ""
    echo "  Set VOICE_HARDWARE=custom in voice.conf and specify:"
    echo "    VOICE_MIC_DEVICE=\"plughw:X,0\"     # from arecord -l, card X"
    echo "    VOICE_SPEAKER_DEVICE=\"plughw:X,0\" # from aplay -l, card X"
    exit 0
fi

# =============================================================================
#  --status — show service status and recent logs
# =============================================================================
if [[ "$1" == "--status" ]]; then
    hr; banner "  Voice Assistant Status"; hr; echo ""
    systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null || echo "Service not running"
    echo ""
    echo "=== Recent logs ==="
    journalctl -u "$SERVICE_NAME" -n 30 --no-pager 2>/dev/null || \
        tail -20 "$LOG_FILE" 2>/dev/null || echo "No logs found"
    exit 0
fi

# =============================================================================
#  --update — pull latest LVA and restart service
# =============================================================================
if [[ "$1" == "--update" ]]; then
    hr; banner "  Updating Linux Voice Assistant"; hr; echo ""

    [[ ! -f "$INSTALL_MARKER" ]] && err "LVA not installed. Run a full install first."

    log "Pulling latest LVA..."
    sudo -u "$VOICE_USER" git -C "$LVA_DIR" pull || err "git pull failed"

    log "Reinstalling Python packages..."
    sudo -u "$VOICE_USER" "$LVA_DIR/.venv/bin/pip" install -e "$LVA_DIR" --quiet

    log "Restarting service..."
    systemctl restart "$SERVICE_NAME"
    sleep 2
    systemctl status "$SERVICE_NAME" --no-pager | head -10

    info "Update complete"
    exit 0
fi

# =============================================================================
#  --reset — wipe and reinstall
# =============================================================================
if [[ "$1" == "--reset" ]]; then
    hr; banner "  Resetting Voice Assistant Install"; hr; echo ""

    log "Stopping service..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    log "Removing service file..."
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload

    log "Removing LVA directory..."
    rm -rf "$LVA_DIR"

    log "Removing install marker..."
    rm -f "$INSTALL_MARKER"

    info "Reset complete — re-running install..."
    echo ""
fi

# =============================================================================
#  Check for pending reboot from 2-Mic HAT driver install
# =============================================================================
if [[ -f "$INSTALL_MARKER" ]] && grep -q "REBOOT_PENDING=true" "$INSTALL_MARKER"; then
    # Check if the driver is now detected post-reboot
    if aplay -l 2>/dev/null | grep -qi "seeed2micvoicec"; then
        info "2-Mic HAT detected after reboot — continuing install"
        rm -f "$INSTALL_MARKER"
    else
        err "2-Mic HAT still not detected after reboot.
  Check that the HAT is seated correctly on the GPIO pins.
  Run: aplay -l   to see what audio devices are present.
  Run: dmesg | grep -i seeed  to check for driver errors."
    fi
fi

# =============================================================================
#  Existing install guard
# =============================================================================
if [[ -f "$INSTALL_MARKER" ]] && [[ "$1" != "--reset" ]]; then
    echo ""
    hr
    banner "  Voice assistant already installed"
    hr
    echo ""
    INSTALLED_NAME=$(grep "^NAME=" "$INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
    INSTALLED_HW=$(grep "^HARDWARE=" "$INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
    echo "  Satellite name : $INSTALLED_NAME"
    echo "  Hardware       : $INSTALLED_HW"
    echo "  Service status : $(systemctl is-active $SERVICE_NAME 2>/dev/null || echo 'unknown')"
    echo ""
    echo "  Options:"
    echo "    [r] Reset and reinstall   sudo bash $0 --reset"
    echo "    [u] Update LVA only       sudo bash $0 --update"
    echo "    [d] Detect audio devices  sudo bash $0 --detect"
    echo "    [s] Show status/logs      sudo bash $0 --status"
    echo ""
    read -r -p "  Reinstall anyway? [y/N] " ans
    [[ "${ans,,}" != "y" ]] && exit 0
fi

# =============================================================================
#  Full install
# =============================================================================
echo ""
hr
banner "  Linux Voice Assistant — Install"
hr
echo ""
info "Satellite name : $VOICE_SATELLITE_NAME"
info "Hardware       : $VOICE_HARDWARE"
info "Wake word      : $VOICE_WAKE_WORD"
info "Port           : $VOICE_PORT"
echo ""

# ── Step 1: Resolve hardware ──────────────────────────────────────────────────
ACTUAL_HW="$VOICE_HARDWARE"
if [[ "$VOICE_HARDWARE" == "auto" ]]; then
    DETECTED=$(_detect_hardware)
    if [[ "$DETECTED" != "unknown" ]]; then
        info "Auto-detected hardware: $DETECTED"
        ACTUAL_HW="$DETECTED"
    else
        warn "No known audio hardware detected. Defaulting to 'auto' device selection."
        ACTUAL_HW="auto"
    fi
fi

# ── Step 2: 2-Mic HAT driver install (if needed) ──────────────────────────────
if [[ "$ACTUAL_HW" == "2mic_hat" ]]; then
    _install_2mic_driver
fi

# ── Step 3: System dependencies ───────────────────────────────────────────────
hr; banner "  Step 1/7 — System dependencies"; hr; echo ""

apt-get update -qq

apt-get install -y --no-install-recommends \
    git \
    python3-venv \
    python3-dev \
    build-essential \
    libmpv-dev \
    mpv \
    avahi-daemon \
    avahi-utils \
    alsa-utils \
    libasound2-plugins \
    pipewire \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    pulseaudio-utils \
    ca-certificates \
    iproute2 \
    curl \
    wget 2>/dev/null

# Add user to audio group
usermod -a -G audio "$VOICE_USER" 2>/dev/null || true

info "Dependencies installed"

# ── Step 4: Enable lingering (run services without login) ─────────────────────
hr; banner "  Step 2/7 — User session setup"; hr; echo ""

loginctl enable-linger "$VOICE_USER" 2>/dev/null || true
info "Linger enabled for $VOICE_USER — service will start on boot"

# ── Step 5: Clone LVA ─────────────────────────────────────────────────────────
hr; banner "  Step 3/7 — Clone linux-voice-assistant"; hr; echo ""

if [[ -d "$LVA_DIR/.git" ]]; then
    log "Updating existing clone..."
    sudo -u "$VOICE_USER" git -C "$LVA_DIR" pull --quiet
    info "LVA updated"
else
    log "Cloning $LVA_REPO..."
    sudo -u "$VOICE_USER" git clone --quiet "$LVA_REPO" "$LVA_DIR"
    info "LVA cloned to $LVA_DIR"
fi

# ── Step 6: Python venv + package install ─────────────────────────────────────
hr; banner "  Step 4/7 — Python venv setup"; hr; echo ""

log "Creating virtual environment..."
sudo -u "$VOICE_USER" python3 -m venv "$LVA_DIR/.venv"

log "Installing LVA packages (this may take a few minutes)..."
sudo -u "$VOICE_USER" "$LVA_DIR/.venv/bin/pip" install --upgrade pip --quiet
sudo -u "$VOICE_USER" "$LVA_DIR/.venv/bin/pip" install --upgrade \
    wheel setuptools --quiet
sudo -u "$VOICE_USER" "$LVA_DIR/.venv/bin/pip" install \
    -e "$LVA_DIR" --quiet

info "Python venv ready: $LVA_DIR/.venv"

# ── Step 7: Resolve audio devices ─────────────────────────────────────────────
hr; banner "  Step 5/7 — Audio device resolution"; hr; echo ""

_resolve_devices "$ACTUAL_HW"
info "Microphone  : $RESOLVED_MIC"
info "Speaker     : $RESOLVED_SPK"

if [[ "$RESOLVED_MIC" == "default" ]]; then
    warn "Using default audio device. Run --detect to find the correct device name"
    warn "then set VOICE_MIC_DEVICE and VOICE_SPEAKER_DEVICE in voice.conf"
fi

# ── Step 8: Create systemd service ────────────────────────────────────────────
hr; banner "  Step 6/7 — systemd service"; hr; echo ""

# Build environment file
ENV_FILE="/etc/${SERVICE_NAME}.env"
cat > "$ENV_FILE" << ENVEOF
LVA_NAME=${VOICE_SATELLITE_NAME}
LVA_PORT=${VOICE_PORT}
LVA_MIC=${RESOLVED_MIC}
LVA_SPK=${RESOLVED_SPK}
LVA_WAKE_WORD=${VOICE_WAKE_WORD}
LVA_DIR=${LVA_DIR}
PULSE_RUNTIME_PATH=/run/user/$(id -u "$VOICE_USER")
PULSE_COOKIE=${VOICE_HOME}/.config/pulse/cookie
ENVEOF
chmod 640 "$ENV_FILE"
chown root:"$VOICE_USER" "$ENV_FILE"

# Build service file
cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=Linux Voice Assistant — ${VOICE_SATELLITE_NAME}
After=network-online.target sound.target avahi-daemon.service
Wants=network-online.target avahi-daemon.service

[Service]
Type=simple
User=${VOICE_USER}
WorkingDirectory=${LVA_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${LVA_DIR}/.venv/bin/python3 -m linux_voice_assistant \\
    --name "\${LVA_NAME}" \\
    --port "\${LVA_PORT}" \\
    --audio-input-device "\${LVA_MIC}" \\
    --audio-output-device "\${LVA_SPK}" \\
    --wake-model "\${LVA_WAKE_WORD}"
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

sleep 3
SERVICE_STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
if [[ "$SERVICE_STATUS" == "active" ]]; then
    info "Service started successfully"
else
    warn "Service status: $SERVICE_STATUS"
    warn "Check logs: sudo journalctl -u $SERVICE_NAME -n 20"
fi

# ── Step 9: Install marker ────────────────────────────────────────────────────
hr; banner "  Step 7/7 — Finalizing"; hr; echo ""

cat > "$INSTALL_MARKER" << MARKEREOF
NAME=${VOICE_SATELLITE_NAME}
HARDWARE=${ACTUAL_HW}
MIC=${RESOLVED_MIC}
SPEAKER=${RESOLVED_SPK}
WAKE_WORD=${VOICE_WAKE_WORD}
PORT=${VOICE_PORT}
LVA_DIR=${LVA_DIR}
MARKEREOF

info "Install marker → $INSTALL_MARKER"
touch "$LOG_FILE"
chown "$VOICE_USER:$VOICE_USER" "$LOG_FILE"

# =============================================================================
#  Summary
# =============================================================================
echo ""
hr
banner "  Install Complete!"
hr
echo ""
echo -e "  Satellite name  : ${BOLD}${VOICE_SATELLITE_NAME}${NC}"
echo -e "  Hardware        : ${BOLD}${ACTUAL_HW}${NC}"
echo -e "  Microphone      : ${BOLD}${RESOLVED_MIC}${NC}"
echo -e "  Speaker         : ${BOLD}${RESOLVED_SPK}${NC}"
echo -e "  Wake word       : ${BOLD}${VOICE_WAKE_WORD}${NC}"
echo -e "  ESPHome port    : ${BOLD}${VOICE_PORT}${NC}"
echo -e "  Service         : ${BOLD}$(systemctl is-active $SERVICE_NAME)${NC}"
echo ""
hr
banner "  Next step — Add to Home Assistant"
hr
echo ""
echo "  HA should auto-discover the satellite via mDNS within 60 seconds."
echo ""
echo "  If not auto-discovered:"
echo "    HA → Settings → Devices & Services → Add Integration → ESPHome"
echo "    Host: $(hostname -I | awk '{print $1}')    Port: ${VOICE_PORT}"
echo ""
hr
banner "  Useful commands"
hr
echo ""
echo "  Check status    : sudo bash $0 --status"
echo "  Detect devices  : sudo bash $0 --detect"
echo "  Update LVA      : sudo bash $0 --update"
echo "  Reset install   : sudo bash $0 --reset"
echo "  Service logs    : sudo journalctl -u $SERVICE_NAME -f"
echo "  Restart service : sudo systemctl restart $SERVICE_NAME"
echo ""
if [[ "$ACTUAL_HW" == "2mic_hat" ]]; then
    echo "  Test mic/speaker:"
    echo "    arecord -D \"${RESOLVED_MIC}\" -f S16_LE -r 16000 -d 3 /tmp/test.wav"
    echo "    aplay  -D \"${RESOLVED_SPK}\" /tmp/test.wav"
    echo ""
fi
