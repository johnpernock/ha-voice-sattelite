# ha-voice-satellite

A one-script installer that turns a Raspberry Pi into a Home Assistant voice satellite using [OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant). Connects to HA via the ESPHome protocol — auto-discovered like any ESPHome device, no manual configuration required.

Designed as a companion to [ha-pi-smarthome](https://github.com/johnpernock/ha-pi-smarthome) but completely standalone — can run on its own Pi or alongside the kiosk on the same device.

---

## Features

- **One script, all hardware** — ReSpeaker 2-Mic HAT V2.0, ReSpeaker Lite (USB), generic USB mic, or any ALSA device
- **Separate mic and speaker routing** — mic on a HAT, audio through HDMI or headphone jack
- **`voice.conf` local overrides** — settings survive `git pull` with zero merge conflicts
- **Auto-discovery** — HA finds the satellite automatically via mDNS/zeroconf
- **Local wake word detection** — okay_nabu, hey_jarvis, or alexa built-in via OHF LVA
- **systemd service** — starts on boot, auto-restarts on failure, logs to journald
- **Simple flags** — `--detect`, `--status`, `--update`, `--reset`
- **Onboard LEDs disabled** — activity and power LEDs turned off in `config.txt` during install (takes effect after reboot)

---

## Compatibility

| Hardware | Supported |
|---|---|
| Raspberry Pi 3 B/B+ | ✅ |
| Raspberry Pi 4 | ✅ |
| Raspberry Pi 5 | ✅ |
| Raspberry Pi Zero 2 W | ✅ |
| Raspberry Pi OS Bookworm (64-bit) | ✅ |
| Raspberry Pi OS Trixie (64-bit) | ✅ |

> **64-bit OS required.** LVA uses TensorFlow Lite for wake word detection which requires a 64-bit ARM environment.

---

## Hardware

### Recommended

| Device | Type | Notes |
|---|---|---|
| [ReSpeaker Lite](https://wiki.seeedstudio.com/reSpeaker_usb_v3/) | USB | Best quality — XMOS DSP chip handles noise suppression, echo cancellation, and AGC in hardware |
| [ReSpeaker 2-Mic Pi HAT V2.0](https://wiki.seeedstudio.com/respeaker_2_mics_pi_hat_raspberry_v2/) | GPIO HAT | Budget option — requires driver install, good near-field performance |

### Any USB microphone

Any USB microphone that shows up in `arecord -l` will work. Set `VOICE_HARDWARE="usb"` and the script finds it automatically.

### Speaker output

The speaker does not have to be on the same device as the microphone. See [Speaker Output Routing](#speaker-output-routing) below.

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/johnpernock/ha-voice-sattelite.git
cd ha-voice-sattelite

# 2. Copy and edit config
cp voice.conf.example voice.conf
nano voice.conf

# 3. Install
sudo bash voice-setup.sh
```

---

## Configuration

All settings live in `voice.conf` — **never edit `voice-setup.sh` directly**. `voice.conf` is git-ignored so `git pull` never overwrites your settings.

```bash
cp voice.conf.example voice.conf
nano voice.conf
```

### All options

| Variable | Default | Description |
|---|---|---|
| `VOICE_SATELLITE_NAME` | `ha-voice-satellite` | Name shown in HA device list |
| `VOICE_HARDWARE` | `auto` | Hardware type — see [Hardware Types](#hardware-types) |
| `VOICE_MIC_DEVICE` | _(empty)_ | Override mic ALSA device name (e.g. `plughw:1,0`) |
| `VOICE_SPEAKER_DEVICE` | _(empty)_ | Override speaker ALSA device name |
| `VOICE_SPEAKER_OUTPUT` | _(empty)_ | Route audio to a different output — see [Speaker Output Routing](#speaker-output-routing) |
| `VOICE_WAKE_WORD` | `okay_nabu` | Wake word model — `okay_nabu`, `hey_jarvis`, or `alexa` |
| `VOICE_PORT` | `6053` | ESPHome server port — HA discovers this automatically |

### Hardware types

| `VOICE_HARDWARE=` | Hardware | Notes |
|---|---|---|
| `auto` | Auto-detect | Identifies connected hardware and applies the right profile |
| `2mic_hat` | ReSpeaker 2-Mic Pi HAT V2.0 | Installs device tree overlay driver; requires one reboot |
| `respeaker_lite` | ReSpeaker Lite (USB) | Plug and play |
| `usb` | Any USB mic/speaker | Auto-detects first USB audio device |
| `custom` | Manual | Set `VOICE_MIC_DEVICE` and `VOICE_SPEAKER_DEVICE` explicitly |

### Speaker output routing

Set `VOICE_SPEAKER_OUTPUT` to route audio to a different device than the microphone. Common use case: mic on the 2-Mic HAT, responses played through an HDMI TV or the Pi headphone jack.

| `VOICE_SPEAKER_OUTPUT=` | Output |
|---|---|
| `hdmi` | HDMI 1 (vc4hdmi0 on Pi 4/5, bcm2835 HDMI on Pi 3) |
| `hdmi2` | HDMI 2 (Pi 4 and Pi 5 only) |
| `headphone` | 3.5mm headphone jack |
| `usb_speaker` | First USB audio output device |
| _(any other value)_ | Treated as a literal ALSA device name (e.g. `plughw:2,0`) |

**Examples:**

```bash
# Mic on 2-Mic HAT, audio through HDMI TV
VOICE_HARDWARE="2mic_hat"
VOICE_SPEAKER_OUTPUT="hdmi"

# Mic on ReSpeaker Lite, audio through 3.5mm headphone jack
VOICE_HARDWARE="respeaker_lite"
VOICE_SPEAKER_OUTPUT="headphone"

# Mic on USB, audio through second HDMI port
VOICE_HARDWARE="usb"
VOICE_SPEAKER_OUTPUT="hdmi2"

# Fully manual — explicit ALSA card numbers from aplay -l
VOICE_HARDWARE="custom"
VOICE_MIC_DEVICE="plughw:1,0"
VOICE_SPEAKER_DEVICE="plughw:2,0"
```

---

## Two-Pi setup example

**Pi 1 — kiosk display** (`ha-pi-smarthome`):
```bash
# kiosk.conf
KIOSK_URL="http://192.168.1.149:8123/dashboard-wall/home"
ENABLE_BROWSER_MOD=true
BROWSER_MOD_ID="kiosk-front-door"
ENABLE_DISPLAY_API=true
WAVESHARE_10DP=true
```

**Pi 2 — voice satellite** (`ha-voice-sattelite`):
```bash
# voice.conf
VOICE_SATELLITE_NAME="front-door-satellite"
VOICE_HARDWARE="2mic_hat"
VOICE_SPEAKER_OUTPUT="hdmi"
VOICE_WAKE_WORD="okay_nabu"
```

---

## ReSpeaker 2-Mic HAT V2.0 — Two-Stage Install

The HAT requires a device tree overlay driver that needs to be compiled and installed before the Pi can detect it. The script handles this automatically:

**Run 1:**
```bash
sudo bash voice-setup.sh
```
The script installs the device tree overlay, adds it to `/boot/firmware/config.txt`, and asks to reboot.

**After reboot, run again:**
```bash
sudo bash voice-setup.sh
```
The script detects the HAT is now present and completes the LVA install.

> This is a one-time process. Future `--update` and `--reset` runs do not repeat the driver install.

### LED feedback

The 2-Mic HAT has 3 APA102 RGB LEDs. When `VOICE_ENABLE_LEDS=true` (default), the install sets up `lva-2mic-leds.service` — a Python service that watches LVA's systemd journal and drives the LEDs based on pipeline state.

#### LED states

These are the states in the order they occur during a normal voice interaction:

| State | Default color | When it shows | `voice.conf` key |
|---|---|---|---|
| `detect` | Dim blue | Always on — idle, waiting for wake word | `LED_COLOR_DETECT` / `LED_BRIGHTNESS_DETECT` |
| `wake` | Green | Wake word just heard, pipeline starting | `LED_COLOR_WAKE` / `LED_BRIGHTNESS_WAKE` |
| `listening` | Blue | Streaming your voice to Home Assistant | `LED_COLOR_LISTENING` / `LED_BRIGHTNESS_LISTENING` |
| `processing` | Amber | HA received audio, running speech-to-text and thinking | `LED_COLOR_PROCESSING` / `LED_BRIGHTNESS_PROCESSING` |
| `speaking` | Cyan | Playing the TTS response back through the speaker | `LED_COLOR_SPEAKING` / `LED_BRIGHTNESS_SPEAKING` |
| `muted` | Dim red | Mic is muted (auto-detected from LVA logs, no HA automation needed) | `LED_COLOR_MUTED` / `LED_BRIGHTNESS_MUTED` |
| `error` | Red | Something went wrong — clears automatically after 2 seconds | `LED_COLOR_ERROR` / `LED_BRIGHTNESS_ERROR` |

After `speaking` completes (or after 15 seconds as a safety timeout), the LEDs return to `detect`.

#### Customizing colors and brightness

Colors and brightness are configured per state in `voice.conf`. The installer writes your settings to `/etc/lva-leds.json` which the LED service reads at startup.

**Color format:** `"R G B"` — three values 0–255 each (standard RGB).  
**Brightness format:** integer 0–31 — this is the APA102 LED hardware brightness register, separate from the color channels. Lower values conserve power and are easier on the eyes at night.

Add any of these to your `voice.conf`:

```bash
# Colors — "R G B" format
LED_COLOR_DETECT="0 0 100"       # dim blue   (default)
LED_COLOR_WAKE="0 255 0"         # green      (default)
LED_COLOR_LISTENING="0 0 200"    # blue       (default)
LED_COLOR_PROCESSING="150 75 0"  # amber      (default)
LED_COLOR_SPEAKING="0 100 100"   # cyan       (default)
LED_COLOR_MUTED="200 0 0"        # red        (default)
LED_COLOR_ERROR="200 0 0"        # red        (default)

# Brightness — 0 (off) to 31 (full)
LED_BRIGHTNESS_DETECT=4          # very dim   (default)
LED_BRIGHTNESS_WAKE=20           # bright     (default)
LED_BRIGHTNESS_LISTENING=15      # medium     (default)
LED_BRIGHTNESS_PROCESSING=10     # medium     (default)
LED_BRIGHTNESS_SPEAKING=15       # medium     (default)
LED_BRIGHTNESS_MUTED=1           # barely visible (default)
LED_BRIGHTNESS_ERROR=15          # medium     (default)
```

Then re-run the installer to apply: `sudo bash voice-setup.sh`

**To tweak on the fly without re-running the installer**, edit `/etc/lva-leds.json` directly on the Pi and restart the service:

```bash
sudo nano /etc/lva-leds.json
sudo systemctl restart lva-2mic-leds
```

The JSON file uses the same state names as `voice.conf`:

```json
{
  "colors": {
    "detect":     [0, 0, 100],
    "wake":       [0, 255, 0],
    "listening":  [0, 0, 200],
    "processing": [150, 75, 0],
    "speaking":   [0, 100, 100],
    "muted":      [200, 0, 0],
    "error":      [200, 0, 0]
  },
  "brightness": {
    "detect":     4,
    "wake":       20,
    "listening":  15,
    "processing": 10,
    "speaking":   15,
    "muted":      1,
    "error":      15
  }
}
```

You can omit any state you don't want to change — the LED service falls back to the built-in defaults for anything not listed.

**Mute is automatic** — the LED service detects mute/unmute events directly from LVA's own logs. No HA automation required.

#### LED HTTP API (port 2702)

```bash
curl -X POST http://VOICE_PI_IP:2702/leds/off                          # night mode — LEDs go dark
curl -X POST http://VOICE_PI_IP:2702/leds/on                           # day mode — resume state colors
curl -X POST http://VOICE_PI_IP:2702/leds/brightness -d '{"brightness": 0.5}'  # dim all states by 50%
curl http://VOICE_PI_IP:2702/leds/state                                # {"leds":"on","muted":false,"brightness":1.0}
```

For HA automation (day/night schedule), paste the `rest_command` block from `ha-led-config.yaml` into your `configuration.yaml`. Schedule automations are in [ha-custom-automation/voice/](https://github.com/johnpernock/ha-custom-automation/tree/main/voice).

To disable LEDs entirely: set `VOICE_ENABLE_LEDS=false` in `voice.conf` and run `--reset`.

#### Mute button

The 2-Mic HAT has a physical button wired to GPIO 17. Pressing it toggles mute — same effect as the auto-detected mute from LVA's journal, but hardware-driven.

**The complication:** the WM8960 codec on the HAT also uses GPIO 17 as its interrupt output (`IRQ`), and drives the pin low briefly during audio activity. To avoid phantom mute toggles, the button watcher only acts on presses held for at least `BUTTON_PRESS_THRESHOLD` seconds (default 200ms). WM8960 IRQ pulses are typically under 10ms so there's plenty of margin, but if you experience false triggers the threshold can be raised.

The button watcher starts automatically with `lva-2mic-leds.service`. Check its status via the state endpoint:

```bash
curl http://VOICE_PI_IP:2702/leds/state
# {"leds":"on","muted":false,"brightness":1.0,"button":"enabled"}
# button field: "enabled" | "disabled" | "unavailable" (RPi.GPIO not installed)
```

**Tuning in `voice.conf`:**

```bash
VOICE_ENABLE_BUTTON=true        # set false to disable the button entirely
BUTTON_GPIO=17                  # BCM pin number (default matches HAT hardware)
BUTTON_PRESS_THRESHOLD=0.20     # seconds — raise if phantom toggles occur
```

Or edit `/etc/lva-leds.json` directly on the Pi and restart the service:

```json
"button": {
  "enabled": true,
  "gpio": 17,
  "press_threshold": 0.20
}
```

**If `RPi.GPIO` is not installed**, the button watcher exits silently and `"button": "unavailable"` is reported in the state endpoint. Install it with:

```bash
/home/pi/linux-voice-assistant/.venv/bin/pip install RPi.GPIO
sudo systemctl restart lva-2mic-leds
```

**Verify the HAT is detected:**
```bash
aplay -l    # should show seeed2micvoicec
arecord -l  # should show seeed2micvoicec
```

**Test mic and speaker:**
```bash
# Record 3 seconds, then play back
arecord -D "plughw:CARD=seeed2micvoicec,DEV=0" -f S16_LE -r 16000 -d 3 /tmp/test.wav
aplay  -D "plughw:CARD=seeed2micvoicec,DEV=0" /tmp/test.wav
```

---

## Adding to Home Assistant

After install, HA discovers the satellite automatically via mDNS within ~60 seconds.

If not auto-discovered:
1. HA → Settings → Devices & Services → Add Integration
2. Search for **ESPHome**
3. Host: `<Pi IP address>` Port: `6053`
4. Follow the setup wizard — assign it to an area

Once added, go to **Settings → Voice Assistants** and assign the satellite to a voice pipeline.

---

## CLI Reference

```bash
sudo bash voice-setup.sh                    # fresh install
sudo bash voice-setup.sh --reset            # wipe LVA and reinstall
sudo bash voice-setup.sh --factory-reset    # wipe LVA + remove HAT driver
sudo bash voice-setup.sh --remove-hat       # remove 2-Mic HAT driver only
sudo bash voice-setup.sh --update           # pull latest LVA, restart service
sudo bash voice-setup.sh --detect           # list all audio devices
sudo bash voice-setup.sh --list-wake-words  # list available wake word models
sudo bash voice-setup.sh --status           # service status + recent logs
```

### --factory-reset

Stops and removes the LVA service **and** removes the ReSpeaker 2-Mic HAT device tree overlay driver from `/boot/firmware/config.txt` and `/boot/firmware/overlays/`. Asks for confirmation before proceeding, then offers a reboot.

Use this when you want to completely clean a Pi — no voice assistant, no HAT driver — without removing the SD card.

```bash
sudo bash voice-setup.sh --factory-reset
```

### --remove-hat

Removes the ReSpeaker 2-Mic HAT driver only, leaving the LVA service untouched. Useful if you're swapping the HAT for a USB mic and want to cleanly remove the old driver first.

```bash
sudo bash voice-setup.sh --remove-hat
```

### --reset

Wipes the LVA service, Python venv, and install marker, then re-runs the install. If the 2-Mic HAT driver is present, prompts whether to remove it too (turning it into a factory reset) or keep it (reinstall will detect and use it).

```bash
sudo bash voice-setup.sh --reset
```

### --list-wake-words

Lists all wake word models available in the LVA installation — both built-in models and any custom `.tflite` files you've added. Shows the currently active model and links to the community wake words collection.

```bash
sudo bash voice-setup.sh --list-wake-words
```

To use a custom wake word, download a `.tflite` file from the [community collection](https://github.com/fwartner/home-assistant-wakewords-collection), place it in `~/linux-voice-assistant/local/`, then set `VOICE_WAKE_WORD="model_name"` in `voice.conf` and run `--reset`.

---

### --detect

Lists all ALSA playback and capture devices with the detected hardware type. Use this to find the correct card numbers for `VOICE_MIC_DEVICE` / `VOICE_SPEAKER_DEVICE` when using `VOICE_HARDWARE="custom"`.

```bash
sudo bash voice-setup.sh --detect
```

### --status

Shows the systemd service status and the last 30 log lines.

```bash
sudo bash voice-setup.sh --status
```

### --update

Pulls the latest LVA code from GitHub, reinstalls the Python package, and restarts the service. Faster than a full reset — use this for routine updates.

```bash
sudo bash voice-setup.sh --update
```

### --reset

Stops and removes the systemd service, deletes the Python venv and LVA clone, and removes the install marker. If the 2-Mic HAT driver is installed, prompts whether to remove it too. Then re-runs the full install.

```bash
sudo bash voice-setup.sh --reset
```

---

## Updating

```bash
cd ~/ha-voice-sattelite
git pull
sudo bash voice-setup.sh --update
```

`voice.conf` is git-ignored and will never be touched by `git pull`.

---

## Useful commands

```bash
# Service management
sudo systemctl status linux-voice-assistant
sudo systemctl restart linux-voice-assistant
sudo systemctl stop linux-voice-assistant

# Live logs
sudo journalctl -u linux-voice-assistant -f

# Check environment config
cat /etc/linux-voice-assistant.env

# Check install marker
cat /etc/voice-installed

# Test audio devices
arecord -l           # list capture devices
aplay -l             # list playback devices
arecord -D plughw:X,0 -f S16_LE -r 16000 -d 3 /tmp/test.wav
aplay  -D plughw:X,0 /tmp/test.wav
```

---

## Remote management (no SD card removal needed)

All reset and cleanup operations can be done over SSH — no need to physically access the Pi or remove the SD card. This is especially useful for wall-mounted or encased satellites.

```bash
# Wipe LVA and reinstall fresh
sudo bash ~/ha-voice-sattelite/voice-setup.sh --reset

# Full factory reset — removes LVA and HAT driver, then reboots
sudo bash ~/ha-voice-sattelite/voice-setup.sh --factory-reset

# Remove HAT driver only (e.g. swapping to USB mic)
sudo bash ~/ha-voice-sattelite/voice-setup.sh --remove-hat

# Check what's running
sudo bash ~/ha-voice-sattelite/voice-setup.sh --status

# Update to latest LVA without a full reinstall
sudo bash ~/ha-voice-sattelite/voice-setup.sh --update
```

After `--factory-reset` the Pi reboots cleanly with no voice assistant and no HAT driver loaded. Run `sudo bash ~/ha-voice-sattelite/voice-setup.sh` to reinstall from scratch with a different config.

---

## Troubleshooting

### Satellite not appearing in Home Assistant

**Check 1 — Service is running:**
```bash
sudo systemctl status linux-voice-assistant
```
If not active, check logs: `sudo journalctl -u linux-voice-assistant -n 30`

**Check 2 — mDNS/Avahi is running:**
```bash
sudo systemctl status avahi-daemon
```
If not running: `sudo systemctl enable --now avahi-daemon`

**Check 3 — Port not blocked:**
```bash
sudo ss -tlnp | grep 6053
```
Should show the LVA process listening. If your network has a firewall, open port 6053.

**Check 4 — Manual add:**
Go to HA → Settings → Devices & Services → Add Integration → ESPHome and enter the Pi's IP with port 6053.

---

### Wake word not triggering

**Check 1 — Mic is working:**
```bash
sudo bash voice-setup.sh --detect
arecord -D "plughw:CARD=seeed2micvoicec,DEV=0" -f S16_LE -r 16000 -d 3 /tmp/test.wav
aplay /tmp/test.wav
```
If the recording is silent, the mic device name is wrong. Run `--detect` and set `VOICE_MIC_DEVICE` in `voice.conf`.

**Check 2 — Wrong mic device:**
```bash
sudo bash voice-setup.sh --detect
```
Compare the listed devices to what's in `/etc/linux-voice-assistant.env`. If they don't match, update `voice.conf` and run `--reset`.

**Check 3 — Volume too low:**
```bash
alsamixer
```
Press F6, select your sound card, and raise the capture (mic) volume. Save with `sudo alsactl store`.

---

### No audio / responses not playing

**Check 1 — Speaker device:**
```bash
cat /etc/linux-voice-assistant.env | grep SPK
aplay -D "plughw:X,0" /usr/share/sounds/alsa/Front_Left.wav
```

**Check 2 — HDMI audio:**
If using HDMI output, confirm the display is on and set as audio output. Run `--detect` and look for `vc4hdmi0` in the playback list.

**Check 3 — PulseAudio/PipeWire:**
```bash
pactl list sinks short    # list available outputs
```

---

### 2-Mic HAT not detected after reboot

```bash
# Check if overlay loaded
dmesg | grep -i seeed
dmesg | grep -i wm8960

# Check config.txt has the overlay
grep respeaker /boot/firmware/config.txt

# Check ALSA sees the card
aplay -l
arecord -l
```

If the card is not listed, the overlay didn't load. Re-run:
```bash
sudo bash voice-setup.sh --reset
```

---

### PulseAudio / PipeWire errors in logs

LVA uses PulseAudio's compat socket. On Debian Trixie, PipeWire with `pipewire-pulse` is required — standalone PulseAudio does not expose a capture source for the WM8960 codec.

```bash
# Verify PipeWire is running as the pi user
sudo -u pi XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status pipewire wireplumber

# Check PULSE_RUNTIME_PATH is correct in the service env (must be /run/user/1000/pulse)
cat /etc/linux-voice-assistant.env | grep PULSE

# If /run/user/1000/pulse/ is owned by root, fix it:
sudo chown pi:pi /run/user/1000/pulse/
```

> **Critical:** Never run `pactl` as root with the user's PipeWire socket — it corrupts the `/run/user/1000/pulse/` directory ownership and causes LVA to fail with `AssertionError`.

---

## File layout

```
ha-voice-sattelite/
├── voice-setup.sh          Main install script (do not edit — use voice.conf)
├── voice.conf              Your local settings (git-ignored, survives pulls)
├── voice.conf.example      Template — copy to voice.conf to get started
├── lva_2mic_leds.py        LED service for ReSpeaker 2-Mic HAT (SCPed to Pi, not auto-installed)
├── ha-led-config.yaml      HA rest_command snippets for LED control
├── README.md               This file
├── CHANGELOG.md            Version history
├── LICENSE                 MIT
└── .gitignore
```

**Files created on the Pi during install:**

```
/etc/linux-voice-assistant.env      Environment variables for the service
/etc/voice-installed                Install marker (name, hardware, devices)
/etc/systemd/system/linux-voice-assistant.service
~/linux-voice-assistant/            LVA clone + Python venv
~/voice.log                         Log file
```

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md) for full version history.

---

## Related Repositories

| Repo | Purpose |
|---|---|
| [ha-pi-smarthome](https://github.com/johnpernock/ha-pi-smarthome) | Raspberry Pi kiosk display setup for Home Assistant |
| [ha-custom-cards](https://github.com/johnpernock/ha-custom-cards) | Custom Lovelace dashboard cards displayed on the kiosk |
| [ha-custom-automation](https://github.com/johnpernock/ha-custom-automation) | All Home Assistant automations — lighting, climate, blinds, security, kiosk |

---

## License

[MIT](LICENSE)
