#!/usr/bin/env bash
# =============================================================================
# scoring.sh — Orange Pi 5 Scoring Display System Setup
# =============================================================================
#
# Installs and configures a systemd service that:
#   • Drives a WS2812B 8×32 LED matrix as a 4-digit numerical scoreboard
#   • Reads 4 digital sensor inputs (normally HIGH, triggered = LOW)
#     and increments the displayed count on each trigger
#   • Exposes a local HTTP API on port 6969 for remote control
#
# ─── Pin Assignments (Orange Pi 5 40-pin header) ─────────────────────────────
#   WS2812B Data : SPI0 MOSI  — Physical Pin 19  (enable SPI0 overlay)
#   Sensor 1     : GPIO1_B1   — Physical Pin 11  (gpiochip1, offset  9)
#   Sensor 2     : GPIO1_B3   — Physical Pin 13  (gpiochip1, offset 11)
#   Sensor 3     : GPIO1_B5   — Physical Pin 15  (gpiochip1, offset 13)
#   Sensor 4     : GPIO1_B6   — Physical Pin 16  (gpiochip1, offset 14)
#
# ─── LED Matrix Layout ───────────────────────────────────────────────────────
#   8 rows × 32 columns, snake pattern starting top-left, column-first:
#     • Even columns (0, 2, 4 …) run top → bottom
#     • Odd  columns (1, 3, 5 …) run bottom → top
#
# ─── Web API (port 6969) ─────────────────────────────────────────────────────
#   GET  /api/status
#   GET  /api/count
#   POST /api/count/reset
#   POST /api/count/set       { "count": <0-9999> }
#   POST /api/color/text      { "color": "#RRGGBB" }   ← rendered digit color
#   POST /api/color/fill      { "color": "#RRGGBB" }   ← fill all LEDs
#   GET  /api/debounce
#   POST /api/debounce        { "enabled": true|false, "debounce_ms": <N> }
#
# ─── Usage ───────────────────────────────────────────────────────────────────
#   sudo bash scoring.sh
# =============================================================================

set -euo pipefail

# ── Require root ──────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: run as root — sudo bash scoring.sh" >&2
    exit 1
fi

SERVICE_DIR="/opt/scoring"
PYTHON_SCRIPT="${SERVICE_DIR}/scoring_service.py"
SERVICE_FILE="/etc/systemd/system/scoring.service"
NEEDS_REBOOT=0

echo "============================================="
echo "  Scoring Display System — Setup"
echo "============================================="
echo ""

# =============================================================================
# 1. Install Dependencies
# =============================================================================
echo "[1/5] Installing system dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \
    python3-gpiod \
    gpiod \
    spi-tools

echo "[1/5] Installing Python packages..."
pip3 install --quiet --break-system-packages flask spidev 2>/dev/null \
    || pip3 install --quiet flask spidev

# =============================================================================
# 2. Enable SPI0 Interface
# =============================================================================
echo "[2/5] Checking SPI0 interface..."
ARMBIAN_ENV="/boot/armbianEnv.txt"
if [[ -f "$ARMBIAN_ENV" ]]; then
    if ! grep -qE "spi0|spi-0" "$ARMBIAN_ENV"; then
        echo "  Enabling SPI0 overlay in ${ARMBIAN_ENV}…"
        if grep -q "^overlays=" "$ARMBIAN_ENV"; then
            sed -i 's/^overlays=\(.*\)/overlays=\1 rk3588-spi0-m2-cs0-spidev/' "$ARMBIAN_ENV"
        else
            echo "overlays=rk3588-spi0-m2-cs0-spidev" >> "$ARMBIAN_ENV"
        fi
        NEEDS_REBOOT=1
        echo "  SPI0 overlay added — reboot required."
    else
        echo "  SPI0 overlay already configured."
    fi
else
    echo "  WARNING: ${ARMBIAN_ENV} not found."
    echo "  Enable SPI0 manually (orangepi-config or device-tree overlay) then reboot."
    NEEDS_REBOOT=1
fi

if [[ ! -e /dev/spidev0.0 ]]; then
    echo "  NOTE: /dev/spidev0.0 not present yet — service will start after reboot."
else
    echo "  /dev/spidev0.0 is available."
fi

# =============================================================================
# 3. Write Python Service Script
# =============================================================================
echo "[3/5] Writing scoring service script…"
mkdir -p "${SERVICE_DIR}"

cat > "${PYTHON_SCRIPT}" << 'PYEOF'
#!/usr/bin/env python3
"""
scoring_service.py — Orange Pi 5 Scoring Display Daemon
========================================================
Hardware
  WS2812B 8×32 LED matrix   — SPI0 MOSI (physical pin 19)
  Sensor GPIO (gpiochip1), normally HIGH, triggered = LOW:
    Sensor 1 : offset  9  (GPIO1_B1, physical pin 11)
    Sensor 2 : offset 11  (GPIO1_B3, physical pin 13)
    Sensor 3 : offset 13  (GPIO1_B5, physical pin 15)
    Sensor 4 : offset 14  (GPIO1_B6, physical pin 16)

Snake pixel layout
  Even columns (0,2,4…) → top-to-bottom (index = col×8 + row)
  Odd  columns (1,3,5…) → bottom-to-top (index = col×8 + (7−row))
  Origin: top-left corner (row 0, col 0)

Web API  — port 6969
  GET  /api/status
  GET  /api/count
  POST /api/count/reset
  POST /api/count/set       { "count": N }
  POST /api/color/text      { "color": "#RRGGBB" }
  POST /api/color/fill      { "color": "#RRGGBB" }
  GET  /api/debounce
  POST /api/debounce        { "enabled": bool, "debounce_ms": N }
"""

import sys
import time
import threading
import logging

import spidev
from flask import Flask, request, jsonify

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger(__name__)

# ── Hardware constants ────────────────────────────────────────────────────────
LED_ROWS     = 8
LED_COLS     = 32
LED_COUNT    = LED_ROWS * LED_COLS   # 256

SPI_BUS      = 0
SPI_DEVICE   = 0
SPI_SPEED_HZ = 2_400_000             # 2.4 MHz  (3 × 800 kHz WS2812B clock)

GPIO_CHIP       = "gpiochip1"        # verify: gpiodetect
SENSOR_OFFSETS  = [9, 11, 13, 14]   # GPIO1_B1, B3, B5, B6

API_PORT = 6969

# ── Shared state (protected by _lock) ────────────────────────────────────────
class _State:
    def __init__(self):
        self.count       = 0
        self.text_color  = (255, 165, 0)   # orange
        self.bg_color    = (0,   0,   0)   # off
        self.debounce_en = True
        self.debounce_ms = 50

_state = _State()
_lock  = threading.Lock()

# ── 5×7 digit font ────────────────────────────────────────────────────────────
# Each row is a 5-bit mask; bit 4 = leftmost pixel, bit 0 = rightmost pixel.
DIGIT_FONT = {
    "0": [0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110],
    "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
    "2": [0b01110, 0b10001, 0b00001, 0b00110, 0b01000, 0b10000, 0b11111],
    "3": [0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110],
    "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
    "5": [0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110],
    "6": [0b01110, 0b10000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
    "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
    "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
    "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00001, 0b01110],
}

# ── Snake-column pixel mapper ─────────────────────────────────────────────────
def pixel_index(row: int, col: int) -> int:
    """Return the LED strip index for a given (row, col) coordinate."""
    if col % 2 == 0:
        return col * LED_ROWS + row                  # even col: top → bottom
    return col * LED_ROWS + (LED_ROWS - 1 - row)    # odd col:  bottom → top

# ── Renderer ──────────────────────────────────────────────────────────────────
def render_number(number: int, fg: tuple, bg: tuple) -> list:
    """
    Render a 4-digit number onto the 8×32 grid.

    Layout: 4 digit slots of 8 columns each (32 columns total).
      Per slot: 1-px left padding | 5-px glyph | 2-px right gap
      Vertically: 1-px top padding | 7-px glyph (fits exactly in 8 rows)
    """
    pixels = [bg] * LED_COUNT
    number = max(0, min(9999, number))
    text   = f"{number:04d}"

    for d_idx, ch in enumerate(text):
        glyph      = DIGIT_FONT.get(ch, DIGIT_FONT["0"])
        col_origin = d_idx * 8 + 1       # 1-px left margin inside each 8-col slot

        for glyph_row, row_bits in enumerate(glyph):
            screen_row = glyph_row + 1    # 1-px top margin

            for bit_pos in range(5):
                if row_bits & (1 << (4 - bit_pos)):
                    col = col_origin + bit_pos
                    if 0 <= col < LED_COLS:
                        pixels[pixel_index(screen_row, col)] = fg

    return pixels

# ── SPI / WS2812B driver ──────────────────────────────────────────────────────
# Pre-compute the 3-SPI-byte encoding for every possible byte value.
#
# At 2.4 MHz one SPI bit = 417 ns → 3 SPI bits = 1.25 µs = one WS2812B bit.
#   WS2812B '1': 110  →  833 ns HIGH + 417 ns LOW   (spec T1H 580–1000 ns)
#   WS2812B '0': 100  →  417 ns HIGH + 833 ns LOW   (spec T0H 220–380 ns)
_SPI_ENCODE: list = []
for _b in range(256):
    _v = 0
    for _i in range(8):
        _v = (_v << 3) | (0b110 if (_b >> (7 - _i)) & 1 else 0b100)
    _SPI_ENCODE.append(_v.to_bytes(3, "big"))

_spi         = spidev.SpiDev()
_spi_lock    = threading.Lock()

def init_spi() -> None:
    _spi.open(SPI_BUS, SPI_DEVICE)
    _spi.max_speed_hz  = SPI_SPEED_HZ
    _spi.mode          = 0
    _spi.bits_per_word = 8
    log.info("SPI ready: /dev/spidev%d.%d @ %d Hz", SPI_BUS, SPI_DEVICE, SPI_SPEED_HZ)

def _build_spi_buf(pixels: list) -> bytearray:
    """Convert (R,G,B) pixel list → WS2812B SPI byte stream (GRB order)."""
    buf = bytearray(LED_COUNT * 9 + 60)   # 9 bytes/pixel + ≥50-byte reset
    idx = 0
    for r, g, b in pixels:
        for component in (g, r, b):        # WS2812B expects GRB
            enc = _SPI_ENCODE[component]
            buf[idx:idx + 3] = enc
            idx += 3
    # remaining bytes are 0x00 → WS2812B reset pulse (>50 µs)
    return buf

def show_pixels(pixels: list) -> None:
    buf = _build_spi_buf(pixels)
    with _spi_lock:
        _spi.writebytes2(buf)

def update_display() -> None:
    """Re-render current count with current colors."""
    with _lock:
        count = _state.count
        fg    = _state.text_color
        bg    = _state.bg_color
    show_pixels(render_number(count, fg, bg))

# ── GPIO sensor thread ────────────────────────────────────────────────────────
def _gpiod_version() -> int:
    """Return 1 for gpiod v1.x API or 2 for v2.x API."""
    import gpiod
    return 2 if hasattr(gpiod, "request_lines") else 1

def _sensor_loop_v1() -> None:
    import gpiod
    chip  = gpiod.Chip(GPIO_CHIP)
    lines = [chip.get_line(o) for o in SENSOR_OFFSETS]
    for ln in lines:
        ln.request(
            consumer="scoring",
            type=gpiod.LINE_REQ_DIR_IN,
            flags=gpiod.LINE_REQ_FLAG_BIAS_PULL_UP,
        )
    log.info("Sensors armed via gpiod v1 (chip=%s offsets=%s)", GPIO_CHIP, SENSOR_OFFSETS)

    prev      = [1] * len(SENSOR_OFFSETS)
    last_trig = [0.0] * len(SENSOR_OFFSETS)

    try:
        while True:
            now = time.monotonic()
            for i, ln in enumerate(lines):
                curr = ln.get_value()
                if prev[i] == 1 and curr == 0:           # falling edge → triggered
                    with _lock:
                        deb_en = _state.debounce_en
                        deb_ms = _state.debounce_ms
                    elapsed_ms = (now - last_trig[i]) * 1000.0
                    if not deb_en or elapsed_ms >= deb_ms:
                        last_trig[i] = now
                        with _lock:
                            _state.count += 1
                            new_count = _state.count
                        log.info("Sensor %d triggered → count=%d", i + 1, new_count)
                        update_display()
                prev[i] = curr
            time.sleep(0.005)       # poll at ~200 Hz
    finally:
        for ln in lines:
            try:
                ln.release()
            except Exception:
                pass
        chip.close()

def _sensor_loop_v2() -> None:
    import gpiod
    from gpiod.line import Direction, Bias, Value

    settings = gpiod.LineSettings(direction=Direction.INPUT, bias=Bias.PULL_UP)
    config   = {offset: settings for offset in SENSOR_OFFSETS}

    with gpiod.request_lines(f"/dev/{GPIO_CHIP}", consumer="scoring", config=config) as req:
        log.info("Sensors armed via gpiod v2 (chip=%s offsets=%s)", GPIO_CHIP, SENSOR_OFFSETS)

        prev      = {o: 1 for o in SENSOR_OFFSETS}
        last_trig = {o: 0.0 for o in SENSOR_OFFSETS}

        while True:
            now = time.monotonic()
            for i, offset in enumerate(SENSOR_OFFSETS):
                raw  = req.get_value(offset)
                curr = 1 if raw == Value.ACTIVE else 0
                if prev[offset] == 1 and curr == 0:
                    with _lock:
                        deb_en = _state.debounce_en
                        deb_ms = _state.debounce_ms
                    elapsed_ms = (now - last_trig[offset]) * 1000.0
                    if not deb_en or elapsed_ms >= deb_ms:
                        last_trig[offset] = now
                        with _lock:
                            _state.count += 1
                            new_count = _state.count
                        log.info("Sensor %d triggered → count=%d", i + 1, new_count)
                        update_display()
                prev[offset] = curr
            time.sleep(0.005)

def start_sensor_thread() -> None:
    try:
        import gpiod  # noqa: F401
    except ImportError:
        log.error("python3-gpiod not found — sensor input disabled.")
        return

    ver    = _gpiod_version()
    target = _sensor_loop_v2 if ver == 2 else _sensor_loop_v1
    log.info("Using gpiod v%d API", ver)
    t = threading.Thread(target=target, daemon=True, name="sensor-thread")
    t.start()

# ── Helpers ───────────────────────────────────────────────────────────────────
def _hex_to_rgb(hex_str: str) -> tuple:
    h = hex_str.lstrip("#")
    if len(h) != 6:
        raise ValueError(f"Expected 6-character hex color, got '{hex_str}'")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)

def _rgb_to_hex(rgb: tuple) -> str:
    return "#{:02X}{:02X}{:02X}".format(*rgb)

# ── Flask API ─────────────────────────────────────────────────────────────────
app = Flask(__name__)

@app.route("/api/status", methods=["GET"])
def api_status():
    with _lock:
        return jsonify({
            "count":            _state.count,
            "text_color":       _rgb_to_hex(_state.text_color),
            "bg_color":         _rgb_to_hex(_state.bg_color),
            "debounce_enabled": _state.debounce_en,
            "debounce_ms":      _state.debounce_ms,
            "led_rows":         LED_ROWS,
            "led_cols":         LED_COLS,
            "led_count":        LED_COUNT,
            "api_port":         API_PORT,
            "gpio_chip":        GPIO_CHIP,
            "sensor_offsets":   SENSOR_OFFSETS,
        })

@app.route("/api/count", methods=["GET"])
def api_get_count():
    with _lock:
        return jsonify({"count": _state.count})

@app.route("/api/count/reset", methods=["POST"])
def api_reset_count():
    with _lock:
        _state.count = 0
    update_display()
    return jsonify({"status": "ok", "count": 0})

@app.route("/api/count/set", methods=["POST"])
def api_set_count():
    data = request.get_json(silent=True)
    if not data or "count" not in data:
        return jsonify({"error": "Missing 'count' field"}), 400
    try:
        val = int(data["count"])
    except (ValueError, TypeError):
        return jsonify({"error": "'count' must be an integer"}), 400
    if not 0 <= val <= 9999:
        return jsonify({"error": "'count' must be 0–9999"}), 400
    with _lock:
        _state.count = val
    update_display()
    return jsonify({"status": "ok", "count": val})

@app.route("/api/color/text", methods=["POST"])
def api_set_text_color():
    data = request.get_json(silent=True)
    if not data or "color" not in data:
        return jsonify({"error": "Missing 'color' field"}), 400
    try:
        color = _hex_to_rgb(data["color"])
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    with _lock:
        _state.text_color = color
    update_display()
    return jsonify({"status": "ok", "color": _rgb_to_hex(color)})

@app.route("/api/color/fill", methods=["POST"])
def api_fill_color():
    data = request.get_json(silent=True)
    if not data or "color" not in data:
        return jsonify({"error": "Missing 'color' field"}), 400
    try:
        color = _hex_to_rgb(data["color"])
    except ValueError as exc:
        return jsonify({"error": str(exc)}), 400
    show_pixels([color] * LED_COUNT)
    return jsonify({"status": "ok", "color": _rgb_to_hex(color)})

@app.route("/api/debounce", methods=["GET"])
def api_get_debounce():
    with _lock:
        return jsonify({
            "debounce_enabled": _state.debounce_en,
            "debounce_ms":      _state.debounce_ms,
        })

@app.route("/api/debounce", methods=["POST"])
def api_set_debounce():
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "No JSON body"}), 400
    with _lock:
        if "enabled" in data:
            _state.debounce_en = bool(data["enabled"])
        if "debounce_ms" in data:
            try:
                ms = int(data["debounce_ms"])
            except (ValueError, TypeError):
                return jsonify({"error": "'debounce_ms' must be an integer"}), 400
            if ms < 0:
                return jsonify({"error": "'debounce_ms' must be ≥ 0"}), 400
            _state.debounce_ms = ms
        enabled = _state.debounce_en
        ms_val  = _state.debounce_ms
    return jsonify({"status": "ok", "debounce_enabled": enabled, "debounce_ms": ms_val})

# ── Entry point ───────────────────────────────────────────────────────────────
if __name__ == "__main__":
    try:
        init_spi()
    except Exception as exc:
        log.error("SPI init failed: %s", exc)
        log.error("Ensure SPI0 is enabled in /boot/armbianEnv.txt and reboot.")
        sys.exit(1)

    # Blank display then show initial count (0000)
    show_pixels([(0, 0, 0)] * LED_COUNT)
    update_display()
    log.info("Display initialized (count=0)")

    start_sensor_thread()

    log.info("Web API listening on 0.0.0.0:%d", API_PORT)
    app.run(host="0.0.0.0", port=API_PORT, threaded=True)
PYEOF

chmod +x "${PYTHON_SCRIPT}"
echo "  Written: ${PYTHON_SCRIPT}"

# =============================================================================
# 4. Write systemd Service Unit
# =============================================================================
echo "[4/5] Writing systemd service unit…"

cat > "${SERVICE_FILE}" << 'SVCEOF'
[Unit]
Description=Scoring Display Service (WS2812B 8x32 + Sensors + Web API)
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/scoring
ExecStart=/usr/bin/python3 /opt/scoring/scoring_service.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=scoring

[Install]
WantedBy=multi-user.target
SVCEOF

echo "  Written: ${SERVICE_FILE}"

# =============================================================================
# 5. Enable (and conditionally start) the Service
# =============================================================================
echo "[5/5] Enabling service…"
systemctl daemon-reload
systemctl enable scoring.service

if [[ -e /dev/spidev0.0 ]]; then
    systemctl restart scoring.service
    echo "  Service started."
    systemctl --no-pager status scoring.service || true
else
    echo "  Service enabled but not started (SPI not yet available)."
    echo "  After rebooting run:  sudo systemctl start scoring"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================="
echo "  Installation Complete!"
echo "============================================="
echo ""
echo "Pin Assignments (Orange Pi 5 40-pin header)"
echo "  WS2812B Data : SPI0 MOSI  — Physical Pin 19"
echo "  Sensor 1     : GPIO1_B1   — Physical Pin 11"
echo "  Sensor 2     : GPIO1_B3   — Physical Pin 13"
echo "  Sensor 3     : GPIO1_B5   — Physical Pin 15"
echo "  Sensor 4     : GPIO1_B6   — Physical Pin 16"
echo ""
echo "Web API  (port 6969)"
echo "  GET  http://<device-ip>:6969/api/status"
echo "  GET  http://<device-ip>:6969/api/count"
echo "  POST http://<device-ip>:6969/api/count/reset"
echo "  POST http://<device-ip>:6969/api/count/set       {\"count\": 42}"
echo "  POST http://<device-ip>:6969/api/color/text      {\"color\": \"#FF6600\"}"
echo "  POST http://<device-ip>:6969/api/color/fill      {\"color\": \"#0000FF\"}"
echo "  GET  http://<device-ip>:6969/api/debounce"
echo "  POST http://<device-ip>:6969/api/debounce        {\"enabled\": true, \"debounce_ms\": 50}"
echo ""
echo "Service management"
echo "  sudo systemctl status  scoring"
echo "  sudo systemctl restart scoring"
echo "  sudo journalctl -u scoring -f"
echo ""

if [[ $NEEDS_REBOOT -eq 1 ]]; then
    echo "⚠  REBOOT REQUIRED to activate the SPI interface."
    echo "   sudo reboot"
    echo ""
fi
