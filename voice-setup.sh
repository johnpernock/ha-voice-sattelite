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
#    sudo bash voice-setup.sh                    # fresh install
#    sudo bash voice-setup.sh --reset            # wipe LVA and reinstall
#    sudo bash voice-setup.sh --factory-reset    # wipe LVA + remove HAT driver
#    sudo bash voice-setup.sh --remove-hat       # remove 2-Mic HAT driver only
#    sudo bash voice-setup.sh --update           # pull latest LVA and restart
#    sudo bash voice-setup.sh --detect           # detect audio devices only
#    sudo bash voice-setup.sh --status           # show service status and logs
#    sudo bash voice-setup.sh --list-wake-words  # list available wake word models
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

# LED feedback for ReSpeaker 2-Mic HAT (APA102 LEDs)
# Only applies when VOICE_HARDWARE=2mic_hat
# true = enable LED feedback (wake, listening, processing, idle states)
VOICE_ENABLE_LEDS=true

# LED colors per state — "R G B" format, each value 0-255
# Only used when VOICE_HARDWARE=2mic_hat and VOICE_ENABLE_LEDS=true
LED_COLOR_DETECT="0 0 100"       # dim blue   — idle, waiting for wake word
LED_COLOR_WAKE="0 255 0"         # green      — wake word heard
LED_COLOR_LISTENING="0 0 200"    # blue       — streaming audio to HA
LED_COLOR_PROCESSING="150 75 0"  # amber      — waiting for response
LED_COLOR_SPEAKING="0 100 100"   # cyan       — playing TTS
LED_COLOR_MUTED="200 0 0"        # red        — muted
LED_COLOR_ERROR="200 0 0"        # red        — error

# LED brightness per state — APA102 hardware scale 0-31
LED_BRIGHTNESS_DETECT=4
LED_BRIGHTNESS_WAKE=20
LED_BRIGHTNESS_LISTENING=15
LED_BRIGHTNESS_PROCESSING=10
LED_BRIGHTNESS_SPEAKING=15
LED_BRIGHTNESS_MUTED=1
LED_BRIGHTNESS_ERROR=15

# Mute button — physical button on the 2-Mic HAT (GPIO 17)
# BUTTON_PRESS_THRESHOLD: seconds the pin must stay low to count as a real press
# (WM8960 IRQ pulses are < 10ms; raise if phantom mutes occur, lower if sluggish)
VOICE_ENABLE_BUTTON=true
BUTTON_GPIO=17
BUTTON_PRESS_THRESHOLD=0.20

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
    elif aplay -l 2>/dev/null | grep -qi "wm8960soundcard\|wm8960-soundcard"; then
        echo "voice_bonnet"
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
            # ReSpeaker 2-Mic HAT V1/V2 — PipeWire ACP stereo-fallback names
            # Requires correct dtoverlay (v1_0 or v2_0) in /boot/firmware/config.txt
            # SPK uses pulse/ prefix so mpv finds the device via PipeWire-pulse
            RESOLVED_MIC="alsa_input.platform-soc_sound.stereo-fallback"
            RESOLVED_SPK="pulse/alsa_output.platform-soc_sound.stereo-fallback"
            ;;
        voice_bonnet)
            # Adafruit Voice Bonnet — WM8960 codec via wm8960-soundcard dtoverlay
            # Same platform-soc_sound bus as the 2-Mic HAT; defaults to stereo-fallback.
            # If PipeWire uses different node names on your OS, run --detect and
            # set VOICE_MIC_DEVICE / VOICE_SPEAKER_DEVICE in voice.conf.
            RESOLVED_MIC="alsa_input.platform-soc_sound.stereo-fallback"
            RESOLVED_SPK="pulse/alsa_output.platform-soc_sound.stereo-fallback"
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
#  2-Mic HAT driver removal
# =============================================================================
_remove_hat_driver() {
    # Detect installed version from config.txt first, fall back to voice.conf default
    local HAT_VER
    if grep -q "dtoverlay=respeaker-2mic-v1_0" /boot/firmware/config.txt 2>/dev/null; then
        HAT_VER="v1_0"
    elif grep -q "dtoverlay=respeaker-2mic-v2_0" /boot/firmware/config.txt 2>/dev/null; then
        HAT_VER="v2_0"
    else
        HAT_VER="${VOICE_2MIC_VERSION:-v1_0}"
    fi

    hr; banner "  ReSpeaker 2-Mic HAT ${HAT_VER} — Driver Removal"; hr; echo ""

    local REMOVED=false

    # Remove overlay entry from config.txt
    if grep -q "dtoverlay=respeaker-2mic-${HAT_VER}" /boot/firmware/config.txt 2>/dev/null; then
        sed -i "/dtoverlay=respeaker-2mic-${HAT_VER}/d" /boot/firmware/config.txt
        info "Removed dtoverlay=respeaker-2mic-${HAT_VER} from config.txt"
        REMOVED=true
    else
        log "dtoverlay not found in config.txt — already removed or never installed"
    fi

    # Remove the .dtbo overlay file
    if [[ -f "/boot/firmware/overlays/respeaker-2mic-${HAT_VER}.dtbo" ]]; then
        rm -f "/boot/firmware/overlays/respeaker-2mic-${HAT_VER}.dtbo"
        info "Removed respeaker-2mic-${HAT_VER}.dtbo from overlays"
        REMOVED=true
    else
        log "Overlay file not found — already removed"
    fi

    # Remove the dtoverlays source directory if present
    local DT_DIR="$VOICE_HOME/seeed-linux-dtoverlays"
    if [[ -d "$DT_DIR" ]]; then
        rm -rf "$DT_DIR"
        info "Removed $DT_DIR"
    fi

    # Note: we do NOT remove dtparam=i2c_arm=on or dtparam=spi=on as
    # other hardware may depend on them. Only the respeaker-specific overlay.

    if $REMOVED; then
        echo ""
        warn "A reboot is required to fully unload the driver."
        echo ""
        read -r -p "  Reboot now? [Y/n] " ans
        [[ "${ans,,}" != "n" ]] && reboot
    else
        info "Nothing to remove — driver was not installed"
    fi
}

# =============================================================================
#  2-Mic HAT V2.0 driver install (device tree overlay — no kernel compile)
# =============================================================================
_install_2mic_driver() {
    local HAT_VER="${VOICE_2MIC_VERSION:-v1_0}"
    hr; banner "  ReSpeaker 2-Mic HAT ${HAT_VER} — Driver Install"; hr; echo ""

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

    log "Compiling device tree overlay for ReSpeaker 2-Mic HAT ${HAT_VER}..."
    cd "$DT_DIR"
    if ! make overlays/rpi/respeaker-2mic-${HAT_VER}-overlay.dtbo 2>/dev/null; then
        warn "dtbo compile failed — trying pre-built overlay path..."
        if [[ ! -f "overlays/rpi/respeaker-2mic-${HAT_VER}-overlay.dtbo" ]]; then
            err "Could not compile or find the 2-Mic HAT overlay.
  Check your kernel version: uname -r
  Requires: raspberrypi-kernel-headers matching your kernel.
  Try: sudo apt-get install raspberrypi-kernel-headers"
        fi
    fi

    log "Installing overlay to /boot/firmware/overlays/..."
    cp overlays/rpi/respeaker-2mic-${HAT_VER}-overlay.dtbo \
        /boot/firmware/overlays/respeaker-2mic-${HAT_VER}.dtbo

    log "Enabling overlay in /boot/firmware/config.txt..."
    if ! grep -q "dtoverlay=respeaker-2mic-${HAT_VER}" /boot/firmware/config.txt; then
        echo "dtoverlay=respeaker-2mic-${HAT_VER}" >> /boot/firmware/config.txt
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
#  Adafruit Voice Bonnet driver install (wm8960-soundcard dtoverlay)
#
#  The wm8960-soundcard overlay ships with Raspberry Pi OS — no compilation
#  needed. Just add it to config.txt and reboot.
# =============================================================================
# =============================================================================
#  WM8960 mixer init service — persists critical ALSA settings across reboots
#
#  The WM8960 codec resets several controls to off/zero on every boot:
#   - Output Mixer PCM switches (DAC → speaker amp path)
#   - Speaker DC/AC boost (class-D amp gain — zero means very faint output)
#   - Input Mixer Boost switches (mic preamp → ADC path — off means silent mic)
#
#  This service runs after sound.target and re-applies all settings so the
#  bonnet works correctly without manual amixer commands after every reboot.
# =============================================================================
_install_wm8960_mixer_service() {
    local MIXER_SCRIPT="/usr/local/bin/wm8960-mixer-init.sh"
    local MIXER_SVC="/etc/systemd/system/wm8960-mixer-init.service"

    log "Installing WM8960 mixer init service..."

    cat > "$MIXER_SCRIPT" << 'MIXEOF'
#!/bin/bash
# WM8960 mixer init — re-apply capture and output settings on every boot.
CARD=$(aplay -l 2>/dev/null | grep -i wm8960 | grep -oP 'card \K[0-9]+' | head -1)
if [[ -z "$CARD" ]]; then
    echo "[wm8960-mixer-init] wm8960soundcard not found — skipping"
    exit 0
fi
echo "[wm8960-mixer-init] Initializing WM8960 on card $CARD..."

# Output: route DAC to speaker amplifier (default off)
amixer -c "$CARD" sset 'Left Output Mixer PCM'  on >/dev/null
amixer -c "$CARD" sset 'Right Output Mixer PCM' on >/dev/null
# Output: speaker amp boost (DC and AC both default to 0 = very faint)
amixer -c "$CARD" cset numid=15 5     >/dev/null  # Speaker DC Volume → max
amixer -c "$CARD" cset numid=16 5     >/dev/null  # Speaker AC Volume → max
amixer -c "$CARD" cset numid=13 117,117 >/dev/null # Speaker Playback Volume
amixer -c "$CARD" cset numid=10 255,255 >/dev/null # DAC Playback Volume → max
# Input: connect mic preamp to ADC (default off = silent mic)
amixer -c "$CARD" cset numid=50 1     >/dev/null  # Left Input Mixer Boost on
amixer -c "$CARD" cset numid=51 1     >/dev/null  # Right Input Mixer Boost on
amixer -c "$CARD" cset numid=9  3     >/dev/null  # Left Input Boost LINPUT1 Volume (29dB)
amixer -c "$CARD" cset numid=8  3     >/dev/null  # Right Input Boost RINPUT1 Volume (29dB)
amixer -c "$CARD" cset numid=46 1     >/dev/null  # Left Boost Mixer LINPUT1 Switch on
amixer -c "$CARD" cset numid=49 1     >/dev/null  # Right Boost Mixer RINPUT1 Switch on
amixer -c "$CARD" cset numid=1  63,63 >/dev/null  # Capture Volume max
amixer -c "$CARD" cset numid=3  1,1   >/dev/null  # Capture Switch on
amixer -c "$CARD" cset numid=36 195,195 >/dev/null # ADC PCM Capture Volume

echo "[wm8960-mixer-init] Done"
MIXEOF
    chmod +x "$MIXER_SCRIPT"

    cat > "$MIXER_SVC" << SVEOF
[Unit]
Description=WM8960 ALSA mixer initialization
After=sound.target alsa-restore.service
Wants=sound.target

[Service]
Type=oneshot
ExecStart=$MIXER_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVEOF

    systemctl daemon-reload
    systemctl enable wm8960-mixer-init.service
    systemctl start wm8960-mixer-init.service 2>/dev/null || true
    info "WM8960 mixer init service installed — settings persist across reboots"

    # Set PipeWire software sink to 60% via WirePlumber (amp at full is very loud)
    mkdir -p "$VOICE_HOME/.config/wireplumber/main.lua.d"
    cat > "$VOICE_HOME/.config/wireplumber/main.lua.d/50-alsa-config.lua" << 'WPLUA'
rule = {
  matches = {
    {
      { "node.name", "equals", "alsa_output.platform-soc_sound.stereo-fallback" },
    },
  },
  apply_properties = {
    ["node.volume"] = 0.6,
  },
}
table.insert(alsa_monitor.rules, rule)
WPLUA
    chown -R "$VOICE_USER:$VOICE_USER" "$VOICE_HOME/.config/wireplumber"
    log "WirePlumber default sink volume set to 60% (amp at full is too loud)"
}

_install_voice_bonnet_driver() {
    hr; banner "  Adafruit Voice Bonnet — Driver Install"; hr; echo ""

    if aplay -l 2>/dev/null | grep -qi "wm8960soundcard\|wm8960-soundcard"; then
        info "Voice Bonnet (wm8960-soundcard) already detected"
        return 0
    fi

    # The overlay ships with Pi OS firmware — verify it's present
    local OVERLAY_FILE="/boot/firmware/overlays/wm8960-soundcard.dtbo"
    if [[ ! -f "$OVERLAY_FILE" ]]; then
        err "wm8960-soundcard overlay not found at $OVERLAY_FILE.
  This overlay ships with Raspberry Pi OS firmware. Ensure your firmware is
  up to date and try again:
    sudo apt-get update && sudo apt-get full-upgrade"
    fi

    log "Enabling wm8960-soundcard overlay in /boot/firmware/config.txt..."
    if ! grep -q "dtoverlay=wm8960-soundcard" /boot/firmware/config.txt; then
        echo "dtoverlay=wm8960-soundcard" >> /boot/firmware/config.txt
        info "Overlay added to config.txt"
    else
        info "Overlay already in config.txt"
    fi

    # Enable I2C — required for WM8960 codec control
    if ! grep -q "^dtparam=i2c_arm=on" /boot/firmware/config.txt; then
        echo "dtparam=i2c_arm=on" >> /boot/firmware/config.txt
    fi

    echo ""
    warn "REBOOT REQUIRED before the Voice Bonnet will be detected."
    echo ""
    echo "  After rebooting, run the install again:"
    echo "    sudo bash $0"
    echo ""
    echo "  The driver will be detected on the second run and"
    echo "  the LVA install will complete automatically."
    echo ""

    # Mark that we need a reboot (include HARDWARE so post-reboot check knows)
    printf "REBOOT_PENDING=true\nHARDWARE=voice_bonnet\n" > "$INSTALL_MARKER"

    read -r -p "  Reboot now? [Y/n] " ans
    [[ "${ans,,}" != "n" ]] && reboot
    exit 0
}

# =============================================================================
#  2-Mic HAT LED service — APA102 RGB LEDs via SPI
#
#  Watches LVA's systemd journal for pipeline events and drives the 3 APA102
#  LEDs accordingly. No longer uses --event-uri (removed from newer LVA).
#
#  HTTP API on port 2702:
#    POST /leds/on    → enable LEDs (day mode)
#    POST /leds/off   → disable LEDs, turn off (night mode)
#    GET  /leds/state → {"leds": "on"|"off"}
#    GET  /health     → {"status": "ok", "uptime": N}
# =============================================================================
_install_led_service() {
    local LED_SCRIPT="$LVA_DIR/lva_2mic_leds.py"
    local LED_SERVICE_FILE="/etc/systemd/system/lva-2mic-leds.service"
    local LED_API_PORT=2702
    local LED_CFG_FILE="/etc/lva-leds.json"

    log "Installing LED feedback service for 2-Mic HAT..."

    # Install spidev for APA102 SPI communication
    "$LVA_DIR/.venv/bin/pip" install spidev --quiet 2>/dev/null || \
        apt-get install -y python3-spidev --no-install-recommends -qq 2>/dev/null || true

    # Write LED color/brightness config from LED_* voice.conf variables
    IFS=' ' read -r _dr _dg _db <<< "${LED_COLOR_DETECT:-0 0 100}"
    IFS=' ' read -r _wr _wg _wb <<< "${LED_COLOR_WAKE:-0 255 0}"
    IFS=' ' read -r _lr _lg _lb <<< "${LED_COLOR_LISTENING:-0 0 200}"
    IFS=' ' read -r _pr _pg _pb <<< "${LED_COLOR_PROCESSING:-150 75 0}"
    IFS=' ' read -r _sr _sg _sb <<< "${LED_COLOR_SPEAKING:-0 100 100}"
    IFS=' ' read -r _mr _mg _mb <<< "${LED_COLOR_MUTED:-200 0 0}"
    IFS=' ' read -r _er _eg _eb <<< "${LED_COLOR_ERROR:-200 0 0}"
    cat > "$LED_CFG_FILE" << CFGJSON
{
  "colors": {
    "detect":     [${_dr:-0}, ${_dg:-0}, ${_db:-100}],
    "wake":       [${_wr:-0}, ${_wg:-255}, ${_wb:-0}],
    "listening":  [${_lr:-0}, ${_lg:-0}, ${_lb:-200}],
    "processing": [${_pr:-150}, ${_pg:-75}, ${_pb:-0}],
    "speaking":   [${_sr:-0}, ${_sg:-100}, ${_sb:-100}],
    "muted":      [${_mr:-200}, ${_mg:-0}, ${_mb:-0}],
    "error":      [${_er:-200}, ${_eg:-0}, ${_eb:-0}]
  },
  "brightness": {
    "detect":     ${LED_BRIGHTNESS_DETECT:-4},
    "wake":       ${LED_BRIGHTNESS_WAKE:-20},
    "listening":  ${LED_BRIGHTNESS_LISTENING:-15},
    "processing": ${LED_BRIGHTNESS_PROCESSING:-10},
    "speaking":   ${LED_BRIGHTNESS_SPEAKING:-15},
    "muted":      ${LED_BRIGHTNESS_MUTED:-1},
    "error":      ${LED_BRIGHTNESS_ERROR:-15}
  },
  "button": {
    "enabled":         ${VOICE_ENABLE_BUTTON:-true},
    "gpio":            ${BUTTON_GPIO:-17},
    "press_threshold": ${BUTTON_PRESS_THRESHOLD:-0.20}
  }
}
CFGJSON
    chmod 644 "$LED_CFG_FILE"
    log "LED config written to $LED_CFG_FILE"

    # Deploy LED script — prefer repo copy (full-featured), fall back to inline
    if [[ -f "$SCRIPT_DIR/lva_2mic_leds.py" ]]; then
        cp "$SCRIPT_DIR/lva_2mic_leds.py" "$LED_SCRIPT"
        chmod +x "$LED_SCRIPT"
        chown root:root "$LED_SCRIPT"
        log "Deployed lva_2mic_leds.py from repo"
    else
    # Fallback: write minimal LED script inline (no git clone available)
    cat > "$LED_SCRIPT" << LEDEOF
#!/usr/bin/env python3
"""
lva_2mic_leds.py — LED control for ReSpeaker 2-Mic Pi HAT
Watches LVA's systemd journal for pipeline events and drives 3 APA102 LEDs.

HTTP API on port ${LED_API_PORT}:
  POST /leds/on    -> enable LED updates (day mode)
  POST /leds/off   -> disable LEDs, turn dark (night mode)
  GET  /leds/state -> {"leds": "on"|"off"}
  GET  /health     -> {"status": "ok", "uptime": N}
"""

import http.server
import json
import logging
import subprocess
import threading
import time

_LOG = logging.getLogger(__name__)

API_PORT  = ${LED_API_PORT}
VOICE_UID = ${VOICE_UID}

# APA102 LED state colors (r, g, b, unused)
COLORS = {
    "detect":     (0,   0, 100,   0),   # dim blue  — idle, waiting for wake word
    "wake":       (0, 255,   0,   0),   # green     — wake word heard
    "listening":  (0,   0, 200,   0),   # blue      — streaming audio to HA
    "processing": (150, 75,   0,   0),  # amber     — waiting for response
    "speaking":   (0, 100, 100,   0),   # cyan      — playing TTS response
    "error":      (200,  0,   0,   0),  # red       — error state
}
BRIGHTNESS = {
    "detect": 4, "wake": 20, "listening": 15,
    "processing": 10, "speaking": 15, "error": 15, "muted": 1,
}

_CFG_PATH = "/etc/lva-leds.json"
try:
    with open(_CFG_PATH) as _f:
        _cfg = json.load(_f)
    for _state, _rgb in _cfg.get("colors", {}).items():
        if _state in COLORS and len(_rgb) >= 3:
            COLORS[_state] = (int(_rgb[0]), int(_rgb[1]), int(_rgb[2]), 0)
    for _state, _br in _cfg.get("brightness", {}).items():
        if _state in BRIGHTNESS:
            BRIGHTNESS[_state] = max(0, min(31, int(_br)))
except FileNotFoundError:
    pass
except Exception as _e:
    import sys as _sys
    print(f"[leds] Warning: could not load {_CFG_PATH}: {_e}", file=_sys.stderr)

NUM_LEDS = 3
SPI_DEV  = 0
SPI_CS   = 0


class APA102:
    def __init__(self):
        try:
            import spidev
            self.spi = spidev.SpiDev()
            self.spi.open(SPI_DEV, SPI_CS)
            self.spi.max_speed_hz = 1000000
            self._ok = True
        except Exception as e:
            _LOG.warning("SPI/APA102 not available: %s", e)
            self._ok = False

    def set_all(self, r, g, b, brightness=8):
        if not self._ok:
            return
        start  = [0x00] * 4
        end    = [0xFF] * 4
        bright = 0xE0 | min(brightness, 31)
        pixels = [bright, b, g, r] * NUM_LEDS
        try:
            self.spi.xfer2(start + pixels + end)
        except Exception:
            pass

    def off(self):
        self.set_all(0, 0, 0, 0)

    def close(self):
        if self._ok:
            self.off()
            self.spi.close()


# Global state
_enabled   = True
_state_lock = threading.Lock()
_leds      = None
START_TIME = time.time()


def _apply(state):
    """Set LED color for state, respecting the enabled flag."""
    with _state_lock:
        if not _enabled or _leds is None:
            return
        color = COLORS.get(state, COLORS["detect"])
        _leds.set_all(*color[:3], brightness=BRIGHTNESS.get(state, 8))


# Journal keyword → LED state mapping
_JOURNAL_RULES = [
    (["wake word", "wakeword", "detected", "keyword found"], "wake"),
    (["streaming start", "streaming audio", "run pipeline", "listening"],  "listening"),
    (["stt", "transcrib", "speech-to-text"],                               "processing"),
    (["tts", "synthesiz", "text-to-speech", "playing"],                    "speaking"),
    (["pipeline done", "streaming stop", "finished", "idle", "ready"],     "detect"),
    (["error", "exception", "traceback", "failed"],                        "error"),
]


def _journal_watcher():
    """Tail LVA's journal and drive LEDs from log output."""
    cmd = ["journalctl", f"_UID={VOICE_UID}", "-f", "-n", "0", "--output=cat"]
    while True:
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            _LOG.info("Journal watcher started (UID=%s)", VOICE_UID)
            for raw in proc.stdout:
                line = raw.decode("utf-8", errors="replace").lower()
                for keywords, state in _JOURNAL_RULES:
                    if any(k in line for k in keywords):
                        _apply(state)
                        if state == "error":
                            time.sleep(2)
                            _apply("detect")
                        break
        except Exception as e:
            _LOG.error("Journal watcher error: %s — restarting in 5s", e)
        time.sleep(5)


class _ApiHandler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global _enabled
        if self.path == "/leds/on":
            with _state_lock:
                _enabled = True
            _apply("detect")
            self._json(200, {"leds": "on"})
        elif self.path == "/leds/off":
            with _state_lock:
                _enabled = False
            if _leds:
                _leds.off()
            self._json(200, {"leds": "off"})
        else:
            self._json(404, {"error": "not found"})

    def do_GET(self):
        if self.path == "/leds/state":
            self._json(200, {"leds": "on" if _enabled else "off"})
        elif self.path == "/health":
            self._json(200, {"status": "ok", "uptime": int(time.time() - START_TIME)})
        else:
            self._json(404, {"error": "not found"})

    def _json(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(data))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        _LOG.debug("API: " + fmt, *args)


def main():
    global _leds
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [leds] %(message)s",
        datefmt="%H:%M:%S",
    )
    _leds = APA102()
    _apply("detect")

    watcher = threading.Thread(target=_journal_watcher, daemon=True)
    watcher.start()

    server = http.server.HTTPServer(("0.0.0.0", API_PORT), _ApiHandler)
    _LOG.info("LED API listening on port %s", API_PORT)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        _leds.close()


if __name__ == "__main__":
    main()
LEDEOF
    chmod +x "$LED_SCRIPT"
    chown root:root "$LED_SCRIPT"
    fi  # end else (fallback inline script)

    # Systemd service — runs as root for SPI + journal access
    cat > "$LED_SERVICE_FILE" << LEDSVCEOF
[Unit]
Description=LVA 2-Mic HAT LED Control
After=network.target

[Service]
Type=simple
ExecStart=${LVA_DIR}/.venv/bin/python3 ${LED_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
LEDSVCEOF

    systemctl daemon-reload
    systemctl enable lva-2mic-leds.service
    systemctl restart lva-2mic-leds.service 2>/dev/null || true

    info "LED service installed — 3 APA102 LEDs will show satellite state"
    log "  Dim blue  = idle/waiting for wake word"
    log "  Green     = wake word detected"
    log "  Blue      = listening / streaming to HA"
    log "  Amber     = processing (STT/response)"
    log "  Cyan      = speaking TTS response"
    log "  Red       = error (clears after 2s)"
    info "LED API running on port ${LED_API_PORT}"
    log "  POST http://$(hostname -I | awk '{print \$1}'):${LED_API_PORT}/leds/off  (night)"
    log "  POST http://$(hostname -I | awk '{print \$1}'):${LED_API_PORT}/leds/on   (day)"
}

# =============================================================================
#  Voice Bonnet LED service (8 WS2812B NeoPixels on GPIO 18)
# =============================================================================
_install_bonnet_led_service() {
    local LED_SCRIPT="$LVA_DIR/lva_bonnet_leds.py"
    local LED_SERVICE_FILE="/etc/systemd/system/lva-bonnet-leds.service"
    local LED_API_PORT=2702
    local LED_CFG_FILE="/etc/lva-leds.json"

    log "Installing LED feedback service for Voice Bonnet..."

    # rpi_ws281x requires root for DMA/PWM; install system-wide
    # On Trixie, pip module is under python3 and needs --break-system-packages
    apt-get install -y python3-pip --no-install-recommends -qq 2>/dev/null || true
    pip install rpi_ws281x --break-system-packages --quiet 2>/dev/null || \
        pip3 install rpi_ws281x --break-system-packages --quiet 2>/dev/null || true

    # Install lgpio for button (same as 2-Mic HAT)
    "$LVA_DIR/.venv/bin/pip" install lgpio --quiet 2>/dev/null || true

    # Write LED color/brightness config from LED_* voice.conf variables
    IFS=' ' read -r _dr _dg _db <<< "${LED_COLOR_DETECT:-0 0 100}"
    IFS=' ' read -r _wr _wg _wb <<< "${LED_COLOR_WAKE:-0 255 0}"
    IFS=' ' read -r _lr _lg _lb <<< "${LED_COLOR_LISTENING:-0 0 200}"
    IFS=' ' read -r _pr _pg _pb <<< "${LED_COLOR_PROCESSING:-150 75 0}"
    IFS=' ' read -r _sr _sg _sb <<< "${LED_COLOR_SPEAKING:-0 100 100}"
    IFS=' ' read -r _mr _mg _mb <<< "${LED_COLOR_MUTED:-200 0 0}"
    IFS=' ' read -r _er _eg _eb <<< "${LED_COLOR_ERROR:-200 0 0}"
    cat > "$LED_CFG_FILE" << CFGJSON
{
  "colors": {
    "detect":     [${_dr:-0}, ${_dg:-0}, ${_db:-100}],
    "wake":       [${_wr:-0}, ${_wg:-255}, ${_wb:-0}],
    "listening":  [${_lr:-0}, ${_lg:-0}, ${_lb:-200}],
    "processing": [${_pr:-150}, ${_pg:-75}, ${_pb:-0}],
    "speaking":   [${_sr:-0}, ${_sg:-100}, ${_sb:-100}],
    "muted":      [${_mr:-200}, ${_mg:-0}, ${_mb:-0}],
    "error":      [${_er:-200}, ${_eg:-0}, ${_eb:-0}]
  },
  "brightness": {
    "detect":     ${LED_BRIGHTNESS_DETECT:-4},
    "wake":       ${LED_BRIGHTNESS_WAKE:-20},
    "listening":  ${LED_BRIGHTNESS_LISTENING:-15},
    "processing": ${LED_BRIGHTNESS_PROCESSING:-10},
    "speaking":   ${LED_BRIGHTNESS_SPEAKING:-15},
    "muted":      ${LED_BRIGHTNESS_MUTED:-1},
    "error":      ${LED_BRIGHTNESS_ERROR:-15}
  },
  "button": {
    "enabled":         ${VOICE_ENABLE_BUTTON:-true},
    "gpio":            ${BUTTON_GPIO:-17},
    "press_threshold": ${BUTTON_PRESS_THRESHOLD:-0.20}
  }
}
CFGJSON
    chmod 644 "$LED_CFG_FILE"
    log "LED config written to $LED_CFG_FILE"

    # Deploy LED script from repo if available, otherwise error
    if [[ -f "$SCRIPT_DIR/lva_bonnet_leds.py" ]]; then
        cp "$SCRIPT_DIR/lva_bonnet_leds.py" "$LED_SCRIPT"
        chmod +x "$LED_SCRIPT"
        chown root:root "$LED_SCRIPT"
        log "Deployed lva_bonnet_leds.py from repo"
    else
        warn "lva_bonnet_leds.py not found in repo — LED service not installed"
        warn "Re-run after: git pull"
        return 1
    fi

    # Systemd service — runs as root for DMA (NeoPixel PWM) + journal access
    cat > "$LED_SERVICE_FILE" << LEDSVCEOF
[Unit]
Description=LVA Voice Bonnet LED Control
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${LED_SCRIPT}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
LEDSVCEOF

    systemctl daemon-reload
    systemctl enable lva-bonnet-leds.service
    systemctl restart lva-bonnet-leds.service 2>/dev/null || true

    info "LED service installed — 8 NeoPixels will show satellite state"
    log "  Dim blue  = idle/waiting for wake word"
    log "  Green     = wake word detected"
    log "  Blue      = listening / streaming to HA"
    log "  Amber     = processing (STT/response)"
    log "  Cyan      = speaking TTS response"
    log "  Red dim   = muted"
    log "  Red       = error (clears after 2s)"
    info "LED API running on port ${LED_API_PORT}"
    log "  POST http://$(hostname -I | awk '{print \$1}'):${LED_API_PORT}/leds/off  (night)"
    log "  POST http://$(hostname -I | awk '{print \$1}'):${LED_API_PORT}/leds/on   (day)"
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
#  --list-wake-words — list available wake word models
# =============================================================================
if [[ "$1" == "--list-wake-words" ]]; then
    hr; banner "  Available Wake Word Models"; hr; echo ""

    LVA_WAKEWORDS_DIR="$LVA_DIR/wakewords"
    LVA_DOWNLOAD_DIR="$LVA_DIR/local"

    if [[ ! -d "$LVA_DIR" ]]; then
        err "LVA not installed yet. Run a full install first, then --list-wake-words."
    fi

    echo "  Built-in models (shipped with LVA):"
    echo ""
    if [[ -d "$LVA_WAKEWORDS_DIR" ]]; then
        found=false
        while IFS= read -r -d '' f; do
            name=$(basename "$f" .tflite)
            echo "    $name"
            found=true
        done < <(find "$LVA_WAKEWORDS_DIR" -name "*.tflite" -print0 2>/dev/null)
        $found || echo "    (none found in $LVA_WAKEWORDS_DIR)"
    else
        echo "    (wakewords directory not found: $LVA_WAKEWORDS_DIR)"
    fi

    echo ""
    echo "  Downloaded/custom models:"
    echo ""
    if [[ -d "$LVA_DOWNLOAD_DIR" ]]; then
        found=false
        while IFS= read -r -d '' f; do
            name=$(basename "$f" .tflite)
            echo "    $name   ($(dirname "$f"))"
            found=true
        done < <(find "$LVA_DOWNLOAD_DIR" -name "*.tflite" -print0 2>/dev/null)
        $found || echo "    (none — place custom .tflite files in $LVA_DOWNLOAD_DIR)"
    else
        echo "    (none)"
    fi

    echo ""
    echo "  Current active wake word:"
    if [[ -f "/etc/${SERVICE_NAME}.env" ]]; then
        grep "LVA_WAKE_WORD" "/etc/${SERVICE_NAME}.env" | sed 's/LVA_WAKE_WORD=/    /'
    else
        echo "    (not installed — set VOICE_WAKE_WORD in voice.conf)"
    fi

    echo ""
    echo "  To change wake word: edit voice.conf and run --reset"
    echo "    VOICE_WAKE_WORD="hey_jarvis""
    echo ""
    echo "  Community wake words: https://github.com/fwartner/home-assistant-wakewords-collection"
    echo "  Place .tflite files in: $LVA_DOWNLOAD_DIR"
    echo "  Then set: VOICE_WAKE_WORD="your_model_name" (without .tflite)"
    echo ""
    exit 0
fi

# =============================================================================
#  --remove-hat — remove 2-Mic HAT driver without touching LVA
# =============================================================================
if [[ "$1" == "--remove-hat" ]]; then
    [[ $EUID -ne 0 ]] && err "Must be run as root. Try: sudo bash $0 --remove-hat"
    _remove_hat_driver
    exit 0
fi

# =============================================================================
#  --factory-reset — stop LVA service AND remove 2-Mic HAT driver
# =============================================================================
if [[ "$1" == "--factory-reset" ]]; then
    hr; banner "  Factory Reset — LVA + HAT Driver"; hr; echo ""
    echo ""
    echo "  This will:"
    echo "    1. Stop and remove the linux-voice-assistant service"
    echo "    2. Delete the LVA Python venv and clone"
    echo "    3. Remove the ReSpeaker 2-Mic HAT device tree overlay"
    echo "    4. Remove all install markers"
    echo ""
    read -r -p "  Proceed? [y/N] " ans
    [[ "${ans,,}" != "y" ]] && echo "Aborted." && exit 0

    # Stop and remove service
    log "Stopping service..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    rm -f "/etc/${SERVICE_NAME}.env"
    systemctl daemon-reload

    # Remove LVA
    log "Removing LVA directory..."
    rm -rf "$LVA_DIR"

    # Remove install markers
    log "Removing install markers..."
    rm -f "$INSTALL_MARKER"

    info "LVA removed"
    echo ""

    # Remove HAT driver
    _remove_hat_driver

    echo ""
    info "Factory reset complete."
    echo ""
    echo "  The Pi is now clean — no voice assistant, no HAT driver."
    echo "  To reinstall from scratch:"
    echo "    sudo bash $0"
    echo ""
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

    # Check if HAT driver is installed and offer to remove it too
    HAT_INSTALLED=false
    grep -q "dtoverlay=respeaker-2mic-v2_0" /boot/firmware/config.txt 2>/dev/null && HAT_INSTALLED=true

    if $HAT_INSTALLED; then
        echo "  The ReSpeaker 2-Mic HAT driver is currently installed."
        echo ""
        echo "  [1] Reset LVA only          (keep HAT driver — reinstall will use it)"
        echo "  [2] Reset LVA + HAT driver  (full factory reset — requires reboot)"
        echo ""
        read -r -p "  Choice [1/2]: " choice
        if [[ "$choice" == "2" ]]; then
            log "Stopping service..."
            systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            systemctl disable "$SERVICE_NAME" 2>/dev/null || true
            rm -f "$SERVICE_FILE"
            rm -f "/etc/${SERVICE_NAME}.env"
            systemctl daemon-reload
            rm -rf "$LVA_DIR"
            rm -f "$INSTALL_MARKER"
            info "LVA removed"
            echo ""
            _remove_hat_driver
            exit 0
        fi
    fi

    log "Stopping service..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    log "Removing service file..."
    rm -f "$SERVICE_FILE"
    rm -f "/etc/${SERVICE_NAME}.env"
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
    PENDING_HW=$(grep "^HARDWARE=" "$INSTALL_MARKER" 2>/dev/null | cut -d= -f2)
    case "$PENDING_HW" in
        voice_bonnet)
            if aplay -l 2>/dev/null | grep -qi "wm8960soundcard\|wm8960-soundcard"; then
                info "Voice Bonnet detected after reboot — continuing install"
                rm -f "$INSTALL_MARKER"
                VOICE_HARDWARE="voice_bonnet"
            else
                err "Voice Bonnet not detected after reboot.
  Check that the HAT is seated correctly on the GPIO pins.
  Run: aplay -l   to see what audio devices are present.
  Run: dmesg | grep -i wm8960  to check for driver errors."
            fi
            ;;
        *)
            # Default: 2mic_hat (marker predates HARDWARE field)
            if aplay -l 2>/dev/null | grep -qi "seeed2micvoicec"; then
                info "2-Mic HAT detected after reboot — continuing install"
                rm -f "$INSTALL_MARKER"
            else
                err "2-Mic HAT still not detected after reboot.
  Check that the HAT is seated correctly on the GPIO pins.
  Run: aplay -l   to see what audio devices are present.
  Run: dmesg | grep -i seeed  to check for driver errors."
            fi
            ;;
    esac
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

# ── Step 2: HAT driver install (if needed) ────────────────────────────────────
if [[ "$ACTUAL_HW" == "2mic_hat" ]]; then
    _install_2mic_driver

    # Apply WM8960 mixer init and persist via alsa-restore.service.
    # On first boot after driver install the ALSA state file has no seeed entry;
    # alsa-restore.service can only restore what it previously saved.  We apply
    # the Seeed-provided baseline state here and run alsactl store so every
    # subsequent boot restores correctly without a separate init service.
    SEEED_STATE="$VOICE_HOME/seeed-linux-dtoverlays/extras/wm8960_asound.state"
    SEEED_CARD=$(aplay -l 2>/dev/null | grep -i seeed2micvoicec | grep -oP 'card \K[0-9]+' | head -1)
    if [[ -f "$SEEED_STATE" ]] && [[ -n "$SEEED_CARD" ]]; then
        if alsactl restore "$SEEED_CARD" -f "$SEEED_STATE" 2>/dev/null; then
            alsactl store "$SEEED_CARD" 2>/dev/null || true
            info "WM8960 mixer initialized and saved (card $SEEED_CARD)"
        else
            warn "Could not apply WM8960 mixer state — run --detect if mic is silent"
        fi
    fi
elif [[ "$ACTUAL_HW" == "voice_bonnet" ]]; then
    _install_voice_bonnet_driver
    _install_wm8960_mixer_service
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

# ── Step 3b: Disable onboard LEDs ─────────────────────────────────────────────
RASPI_CONFIG_FILE=/boot/firmware/config.txt
[[ ! -f "$RASPI_CONFIG_FILE" ]] && RASPI_CONFIG_FILE=/boot/config.txt

if [[ -f "$RASPI_CONFIG_FILE" ]]; then
    LED_ADDED=false
    for led_param in \
        "dtparam=act_led_trigger=none" \
        "dtparam=act_led_activelow=off" \
        "dtparam=pwr_led_trigger=none" \
        "dtparam=pwr_led_activelow=off"
    do
        if ! grep -q "^${led_param}" "$RASPI_CONFIG_FILE"; then
            echo "$led_param" >> "$RASPI_CONFIG_FILE"
            LED_ADDED=true
        fi
    done
    if $LED_ADDED; then
        log "Onboard LEDs disabled in config.txt (takes effect after reboot)"
    else
        log "Onboard LEDs already disabled in config.txt"
    fi
else
    warn "config.txt not found — skipping LED disable"
fi

# ── Step 4: Enable lingering (run services without login) ─────────────────────
hr; banner "  Step 2/7 — User session setup"; hr; echo ""

loginctl enable-linger "$VOICE_USER" 2>/dev/null || true
info "Linger enabled for $VOICE_USER — service will start on boot"

# Start the user's systemd session now (linger doesn't do this immediately)
XDG_RUNTIME_DIR="/run/user/$(id -u "$VOICE_USER")"
export XDG_RUNTIME_DIR
# Start PipeWire user services so the audio socket exists before LVA installs
if sudo -u "$VOICE_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user enable pipewire pipewire-pulse wireplumber 2>/dev/null; then
    sudo -u "$VOICE_USER" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" systemctl --user start pipewire pipewire-pulse wireplumber 2>/dev/null || true
    info "PipeWire user services enabled and started"
else
    warn "Could not enable PipeWire user services — audio may not work until reboot"
fi

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

# Resolve user UID for service environment variables
VOICE_UID=$(id -u "$VOICE_USER" 2>/dev/null || echo "1000")

# Build environment file
ENV_FILE="/etc/${SERVICE_NAME}.env"
cat > "$ENV_FILE" << ENVEOF
LVA_NAME=${VOICE_SATELLITE_NAME}
LVA_PORT=${VOICE_PORT}
LVA_MIC=${RESOLVED_MIC}
LVA_SPK=${RESOLVED_SPK}
LVA_WAKE_WORD=${VOICE_WAKE_WORD}
LVA_DIR=${LVA_DIR}
PULSE_RUNTIME_PATH=/run/user/$(id -u "$VOICE_USER")/pulse
PULSE_COOKIE=${VOICE_HOME}/.config/pulse/cookie
ENVEOF
chmod 640 "$ENV_FILE"
chown root:"$VOICE_USER" "$ENV_FILE"

# Write a helper that waits for the PipeWire/PulseAudio user socket before
# starting LVA — without this the service can fail at boot because the
# audio session isn't ready yet even though the system is "up"
AUDIO_WAIT_SCRIPT="/usr/local/bin/lva-audio-wait.sh"
cat > "$AUDIO_WAIT_SCRIPT" << 'WAITEOF'
#!/bin/bash
# Wait for PipeWire or PulseAudio user socket to be ready
USER_ID=$(id -u "$1" 2>/dev/null || echo "1000")
RUNTIME_DIR="/run/user/${USER_ID}"
PULSE_SOCK="${RUNTIME_DIR}/pulse/native"
PIPEWIRE_SOCK="${RUNTIME_DIR}/pipewire-0"
MAX_WAIT=30
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    # Accept either PipeWire or PulseAudio socket
    if [[ -S "$PIPEWIRE_SOCK" ]] || [[ -S "$PULSE_SOCK" ]]; then
        echo "[lva-audio-wait] Audio socket ready after ${WAITED}s"
        exit 0
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done
echo "[lva-audio-wait] Warning: audio socket not found after ${MAX_WAIT}s — starting anyway"
exit 0
WAITEOF
chmod +x "$AUDIO_WAIT_SCRIPT"

# Build service file
cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=Linux Voice Assistant — ${VOICE_SATELLITE_NAME}
After=network-online.target sound.target avahi-daemon.service graphical-session.target
Wants=network-online.target avahi-daemon.service

[Service]
Type=simple
User=${VOICE_USER}
WorkingDirectory=${LVA_DIR}
EnvironmentFile=${ENV_FILE}
# Wait for PipeWire/PulseAudio user session before starting
ExecStartPre=${AUDIO_WAIT_SCRIPT} ${VOICE_USER}
ExecStart=${LVA_DIR}/.venv/bin/python3 -m linux_voice_assistant \\
    --name "\${LVA_NAME}" \\
    --port "\${LVA_PORT}" \\
    --audio-input-device "\${LVA_MIC}" \\
    --audio-output-device "\${LVA_SPK}" \\
    --wake-model "\${LVA_WAKE_WORD}"
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal
# Ensure PulseAudio environment is set for the user
Environment=PULSE_RUNTIME_PATH=/run/user/${VOICE_UID}/pulse
Environment=XDG_RUNTIME_DIR=/run/user/${VOICE_UID}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${VOICE_UID}/bus

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
# ── Step 7b: LED service (2-Mic HAT only) ────────────────────────────────────
if [[ "$ACTUAL_HW" == "2mic_hat" ]] && [[ "${VOICE_ENABLE_LEDS:-true}" == "true" ]]; then
    _install_led_service
fi
if [[ "$ACTUAL_HW" == "voice_bonnet" ]] && [[ "${VOICE_ENABLE_LEDS:-true}" == "true" ]]; then
    _install_bonnet_led_service
fi

hr; banner "  Step 7/7 — Finalizing"; hr; echo ""

cat > "$INSTALL_MARKER" << MARKEREOF
NAME=${VOICE_SATELLITE_NAME}
HARDWARE=${ACTUAL_HW}
MIC=${RESOLVED_MIC}
SPEAKER=${RESOLVED_SPK}
WAKE_WORD=${VOICE_WAKE_WORD}
PORT=${VOICE_PORT}
LVA_DIR=${LVA_DIR}
LEDS_ENABLED=${VOICE_ENABLE_LEDS:-true}
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
if [[ "$ACTUAL_HW" == "2mic_hat" ]] && [[ "${VOICE_ENABLE_LEDS:-true}" == "true" ]]; then
    echo -e "  LED API         : ${BOLD}http://$(hostname -I | awk '{print $1}'):2702${NC}"
fi
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
echo "  List wake words : sudo bash $0 --list-wake-words"
echo "  Update LVA      : sudo bash $0 --update"
echo "  Reset LVA       : sudo bash $0 --reset"
echo "  Factory reset   : sudo bash $0 --factory-reset   (LVA + HAT driver)"
echo "  Remove HAT only : sudo bash $0 --remove-hat"
echo "  Service logs    : sudo journalctl -u $SERVICE_NAME -f"
echo "  Restart service : sudo systemctl restart $SERVICE_NAME"
echo ""
if [[ "$ACTUAL_HW" == "2mic_hat" ]]; then
    echo "  Test mic/speaker:"
    echo "    arecord -D \"${RESOLVED_MIC}\" -f S16_LE -r 16000 -d 3 /tmp/test.wav"
    echo "    aplay  -D \"${RESOLVED_SPK}\" /tmp/test.wav"
    echo ""
    if [[ "${VOICE_ENABLE_LEDS:-true}" == "true" ]]; then
        echo "  LED API (port 2702):"
        echo "    curl -X POST http://localhost:2702/leds/off   # night mode"
        echo "    curl -X POST http://localhost:2702/leds/on    # day mode"
        echo "    curl http://localhost:2702/leds/state         # check state"
        echo "    sudo journalctl -u lva-2mic-leds -f           # LED service logs"
        echo ""
    fi
fi
