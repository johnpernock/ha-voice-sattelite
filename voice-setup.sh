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
#  2-Mic HAT V2.0 driver removal
# =============================================================================
_remove_hat_driver() {
    hr; banner "  ReSpeaker 2-Mic HAT V2.0 — Driver Removal"; hr; echo ""

    local REMOVED=false

    # Remove overlay entry from config.txt
    if grep -q "dtoverlay=respeaker-2mic-v2_0" /boot/firmware/config.txt 2>/dev/null; then
        sed -i '/dtoverlay=respeaker-2mic-v2_0/d' /boot/firmware/config.txt
        info "Removed dtoverlay=respeaker-2mic-v2_0 from config.txt"
        REMOVED=true
    else
        log "dtoverlay not found in config.txt — already removed or never installed"
    fi

    # Remove the .dtbo overlay file
    if [[ -f /boot/firmware/overlays/respeaker-2mic-v2_0.dtbo ]]; then
        rm -f /boot/firmware/overlays/respeaker-2mic-v2_0.dtbo
        info "Removed respeaker-2mic-v2_0.dtbo from overlays"
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
#  2-Mic HAT LED service — APA102 RGB LEDs via SPI
# =============================================================================
_install_led_service() {
    local LED_SCRIPT="$LVA_DIR/lva_2mic_leds.py"
    local LED_SERVICE_FILE="/etc/systemd/system/lva-2mic-leds.service"

    log "Installing LED feedback service for 2-Mic HAT..."

    # Install spidev for APA102 SPI communication
    "$LVA_DIR/.venv/bin/pip" install spidev --quiet 2>/dev/null ||         apt-get install -y python3-spidev --no-install-recommends -qq 2>/dev/null || true

    # Write the LED event handler script
    cat > "$LED_SCRIPT" << 'LEDEOF'
#!/usr/bin/env python3
"""
lva_2mic_leds.py — LED event handler for ReSpeaker 2-Mic Pi HAT V2.0
Connects to LVA via --event-uri and drives the 3 APA102 RGB LEDs
to show wake word, listening, processing, and idle states.
"""

import asyncio
import logging
import struct
import sys
import time

_LOG = logging.getLogger(__name__)

# APA102 LED state colors
COLORS = {
    "idle":        (0,   0,   0,   0),    # off
    "detect":      (0,   0, 100,   0),    # dim blue — waiting for wake word
    "wake":        (0, 255,   0,   0),    # green — wake word heard
    "listening":   (0,   0, 200,   0),    # blue — streaming audio
    "processing":  (150, 75,   0,   0),   # amber — waiting for response
    "speaking":    (0, 100, 100,   0),    # cyan — playing response
    "error":       (200,  0,   0,   0),   # red — error state
}
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
        # APA102 frame: start frame + LED frames + end frame
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

async def handle_events(leds):
    """Read LVA events from stdin — one JSON object per line."""
    import json
    _LOG.info("LED event handler started")
    leds.set_all(*COLORS["detect"][:3], brightness=4)

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        try:
            line = await reader.readline()
            if not line:
                break
            event = json.loads(line.decode().strip())
            etype = event.get("type", "")
            _LOG.debug("Event: %s", etype)

            if etype == "detection":
                leds.set_all(*COLORS["wake"][:3], brightness=20)
            elif etype == "streaming-start":
                leds.set_all(*COLORS["listening"][:3], brightness=15)
            elif etype == "stt-start":
                leds.set_all(*COLORS["listening"][:3], brightness=20)
            elif etype in ("stt-stop", "synthesize"):
                leds.set_all(*COLORS["processing"][:3], brightness=10)
            elif etype == "tts-start":
                leds.set_all(*COLORS["speaking"][:3], brightness=15)
            elif etype in ("tts-played", "streaming-stop"):
                leds.set_all(*COLORS["detect"][:3], brightness=4)
            elif etype == "error":
                leds.set_all(*COLORS["error"][:3], brightness=15)
                await asyncio.sleep(2)
                leds.set_all(*COLORS["detect"][:3], brightness=4)
        except json.JSONDecodeError:
            pass
        except Exception as e:
            _LOG.error("Event handler error: %s", e)

def main():
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s [leds] %(message)s",
                        datefmt="%H:%M:%S")
    leds = APA102()
    try:
        asyncio.run(handle_events(leds))
    except KeyboardInterrupt:
        pass
    finally:
        leds.close()

if __name__ == "__main__":
    main()
LEDEOF
    chmod +x "$LED_SCRIPT"
    chown "$VOICE_USER:$VOICE_USER" "$LED_SCRIPT"

    # Write LED systemd service — reads events piped from LVA via --event-uri
    # LVA connects to this service on tcp://127.0.0.1:10500 and sends JSON events
    local LED_PORT=10500

    # Create a simple TCP→stdin bridge so LVA can send events to the script
    local LED_BRIDGE="/usr/local/bin/lva-led-bridge.sh"
    cat > "$LED_BRIDGE" << BRIDGEOF
#!/bin/bash
# Bridge: listen on TCP port $LED_PORT, pipe events to the LED Python script
exec socat TCP-LISTEN:${LED_PORT},fork,reuseaddr - |     ${LVA_DIR}/.venv/bin/python3 ${LED_SCRIPT}
BRIDGEOF
    chmod +x "$LED_BRIDGE"

    # Install socat for the TCP bridge
    apt-get install -y socat --no-install-recommends -qq 2>/dev/null || true

    cat > "$LED_SERVICE_FILE" << LEDSVCEOF
[Unit]
Description=LVA 2-Mic HAT LED Feedback
After=${SERVICE_NAME}.service
BindsTo=${SERVICE_NAME}.service

[Service]
Type=simple
User=${VOICE_USER}
ExecStart=${LED_BRIDGE}
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
LEDSVCEOF

    systemctl daemon-reload
    systemctl enable lva-2mic-leds.service
    systemctl restart lva-2mic-leds.service 2>/dev/null || true

    # Update LVA service to pass --event-uri (only if this LVA version supports it)
    if ! grep -q "event-uri" "$SERVICE_FILE"; then
        if "$LVA_DIR/.venv/bin/python3" -m linux_voice_assistant --help 2>&1 | grep -q "event-uri"; then
            sed -i "s|--wake-model.*|--wake-model "\${LVA_WAKE_WORD}" \\
    --event-uri 'tcp://127.0.0.1:${LED_PORT}'|" "$SERVICE_FILE"
            systemctl daemon-reload
            systemctl restart "$SERVICE_NAME" 2>/dev/null || true
        else
            warn "--event-uri not supported by this LVA version — LED state indicators disabled"
        fi
    fi

    info "LED service installed — 3 APA102 LEDs will show satellite state"
    log "  Off/dim blue  = idle/waiting"
    log "  Green flash   = wake word detected"
    log "  Blue          = listening"
    log "  Amber         = processing"
    log "  Cyan          = speaking response"
    log "  Red           = error"
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
PULSE_RUNTIME_PATH=/run/user/$(id -u "$VOICE_USER")
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
Environment=PULSE_RUNTIME_PATH=/run/user/${VOICE_UID}
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
fi
