#!/usr/bin/env python3
"""
WiFi provisioning for the photo frame.

Runs once at boot, before the slideshow. If NetworkManager has already
joined a saved network, exits immediately. Otherwise it starts an access
point, renders a setup screen on the framebuffer (hotspot + portal QRs),
and serves a tiny web form so a phone can pick a network and enter the
password.

Requires Raspberry Pi OS Bookworm (or newer) — NetworkManager is the
default there.

Reset triggers (either file, deleted on use):
  ~/.reset_wifi                     — touch over SSH
  /boot/firmware/wifi-reset         — create on the FAT boot partition
"""

import subprocess
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

AP_SSID = "PhotoFrame-Setup"
AP_PASSWORD = "photoframe"
AP_CON_NAME = "photoframe-ap"
AP_IFACE = "wlan0"
AP_PORTAL_IP = "10.42.0.1"  # nmcli hotspot default
HTTP_PORT = 80

WAIT_FOR_EXISTING_SECS = 25   # how long to give NM before assuming no network
CONNECT_VERIFY_SECS = 20      # after submitting creds, wait this long for link

# Watchdog (--watch mode): reboot if disconnected for this long. A reboot
# cleanly drops us back through the boot-time setup flow; no in-process
# hand-off with the running slideshow.
WATCHDOG_CHECK_EVERY_SECS = 30
WATCHDOG_DISCONNECT_THRESHOLD_SECS = 300

SETUP_IMAGE = Path("/tmp/photoframe_wifi_setup.png")

_BOOT_FW = Path("/boot/firmware")
USER_HOME = Path("__HOME__")  # replaced by installer
RESET_FLAGS = [
    USER_HOME / ".reset_wifi",
    (_BOOT_FW if _BOOT_FW.is_dir() else Path("/boot")) / "wifi-reset",
]


# --- nmcli helpers ---------------------------------------------------------

def nm(*args):
    return subprocess.run(
        ["nmcli", *args], capture_output=True, text=True, check=False
    )


def is_connected() -> bool:
    """True if we have an activated, non-hotspot network link."""
    r = nm("-t", "-f", "NAME,TYPE,STATE", "connection", "show", "--active")
    for line in r.stdout.splitlines():
        parts = line.rsplit(":", 2)
        if len(parts) < 3:
            continue
        name, typ, state = parts
        if state != "activated" or name == AP_CON_NAME:
            continue
        if typ in ("802-11-wireless", "802-3-ethernet"):
            return True
    return False


def active_connection_names():
    r = nm("-t", "-f", "NAME", "connection", "show", "--active")
    return [n for n in r.stdout.splitlines() if n]


def scan_networks():
    nm("device", "wifi", "rescan")
    time.sleep(4)
    r = nm("-t", "-f", "SSID,SIGNAL,SECURITY", "device", "wifi", "list")
    seen, networks = set(), []
    for line in r.stdout.splitlines():
        # SSIDs can contain colons (escaped as \:); split with maxsplit loses
        # info, so use a backwards walk.
        parts = line.split(":")
        if len(parts) < 3:
            continue
        security = parts[-1]
        signal = parts[-2]
        ssid = ":".join(parts[:-2]).replace("\\:", ":")
        if not ssid or ssid == AP_SSID or ssid in seen:
            continue
        seen.add(ssid)
        try:
            sig = int(signal)
        except ValueError:
            sig = 0
        networks.append({
            "ssid": ssid,
            "signal": sig,
            "secured": security not in ("", "--"),
        })
    networks.sort(key=lambda n: -n["signal"])
    return networks


def delete_saved_wifi_profiles():
    r = nm("-t", "-f", "NAME,TYPE", "connection", "show")
    for line in r.stdout.splitlines():
        if ":" not in line:
            continue
        name, typ = line.rsplit(":", 1)
        if typ == "802-11-wireless" and name != AP_CON_NAME:
            nm("connection", "delete", name)


def start_hotspot():
    nm("connection", "delete", AP_CON_NAME)  # clear any zombie profile
    r = nm(
        "device", "wifi", "hotspot",
        "ifname", AP_IFACE,
        "con-name", AP_CON_NAME,
        "ssid", AP_SSID,
        "password", AP_PASSWORD,
    )
    if r.returncode != 0:
        raise RuntimeError(f"hotspot failed: {r.stderr.strip() or r.stdout.strip()}")
    time.sleep(3)


def stop_hotspot():
    nm("connection", "down", AP_CON_NAME)
    nm("connection", "delete", AP_CON_NAME)


def connect_to(ssid: str, password: str) -> bool:
    args = ["device", "wifi", "connect", ssid, "ifname", AP_IFACE]
    if password:
        args += ["password", password]
    r = nm(*args)
    if r.returncode != 0:
        print(f"[!] connect failed: {r.stderr.strip() or r.stdout.strip()}")
        return False
    deadline = time.time() + CONNECT_VERIFY_SECS
    while time.time() < deadline:
        if is_connected():
            return True
        time.sleep(1)
    return False


# --- framebuffer setup screen ---------------------------------------------

def render_setup_image() -> Path:
    from PIL import Image, ImageDraw, ImageFont
    import qrcode

    # Portrait canvas — matches slideshow.sh's 90° rotation.
    W, H = 600, 1024
    img = Image.new("RGB", (W, H), "white")
    draw = ImageDraw.Draw(img)

    def font(size):
        try:
            return ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", size
            )
        except OSError:
            return ImageFont.load_default()

    draw.text((W // 2, 60), "Photo Frame Setup", fill="black",
              font=font(44), anchor="mt")

    draw.text((W // 2, 140), "1. Join this WiFi", fill="black",
              font=font(32), anchor="mt")
    wifi_qr = qrcode.make(
        f"WIFI:T:WPA;S:{AP_SSID};P:{AP_PASSWORD};;", box_size=10, border=2,
    ).convert("RGB").resize((300, 300))
    img.paste(wifi_qr, ((W - 300) // 2, 190))
    draw.text((W // 2, 510), f"{AP_SSID}", fill="black",
              font=font(26), anchor="mt")
    draw.text((W // 2, 545), f"password: {AP_PASSWORD}", fill="#444",
              font=font(22), anchor="mt")

    draw.text((W // 2, 610), "2. Open this page", fill="black",
              font=font(32), anchor="mt")
    portal_qr = qrcode.make(
        f"http://{AP_PORTAL_IP}/", box_size=10, border=2,
    ).convert("RGB").resize((300, 300))
    img.paste(portal_qr, ((W - 300) // 2, 660))
    draw.text((W // 2, 980), f"http://{AP_PORTAL_IP}", fill="#444",
              font=font(22), anchor="mt")

    img.rotate(90, expand=True).save(SETUP_IMAGE)
    return SETUP_IMAGE


def show_setup_screen(path: Path):
    subprocess.run(["killall", "fbi"], check=False, capture_output=True)
    time.sleep(0.3)
    subprocess.Popen([
        "openvt", "-s", "-f", "--",
        "fbi", "--noverbose", "--nocomments", "-a", str(path),
    ])


def hide_setup_screen():
    subprocess.run(["killall", "fbi"], check=False, capture_output=True)


# --- captive portal --------------------------------------------------------

HTML_FORM = """\
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Photo Frame WiFi Setup</title>
<style>
body{{font-family:-apple-system,system-ui,sans-serif;max-width:420px;margin:2em auto;padding:0 1em;color:#222}}
h1{{font-size:1.4em}}
label{{display:block;margin-top:1em;font-weight:600}}
select,input{{width:100%;padding:.6em;font-size:1em;margin-top:.3em;box-sizing:border-box}}
button{{margin-top:1.5em;padding:.8em;width:100%;font-size:1em;background:#0a84ff;color:#fff;border:0;border-radius:6px}}
.err{{background:#fee;color:#900;padding:.8em;border-radius:6px;margin-top:1em}}
.note{{color:#666;font-size:.9em;margin-top:1em}}
</style>
</head><body>
<h1>Photo Frame WiFi Setup</h1>
<p>Pick your network, enter the password, tap Connect.</p>
{error}
<form method="POST" action="/connect">
  <label>Network
    <select name="ssid" required>{options}</select>
  </label>
  <label>Password
    <input type="password" name="password" autocomplete="new-password">
  </label>
  <button type="submit">Connect</button>
</form>
<p class="note">After the frame connects, the hotspot shuts down and your phone will drop back to its normal WiFi.</p>
</body></html>
"""

HTML_CONNECTING = """\
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Connecting…</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:420px;margin:2em auto;padding:0 1em;text-align:center}}</style>
</head><body>
<h1>Connecting to {ssid}…</h1>
<p>The hotspot is about to shut down. If it worked, the frame will start showing your photos in a few seconds.</p>
<p>If it didn't, the frame will come back on <b>{ap}</b> so you can try again.</p>
</body></html>
"""


def _options_html(networks):
    return "\n".join(
        f'<option value="{n["ssid"]}">'
        f'{n["ssid"]}{"" if n["secured"] else " (open)"}'
        f'</option>'
        for n in networks
    )


def make_handler(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            print("[http] " + fmt % args)

        def _html(self, body, status=200):
            data = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _form(self, error=""):
            err_html = f'<div class="err">{error}</div>' if error else ""
            return HTML_FORM.format(
                options=_options_html(state["networks"]), error=err_html,
            )

        def do_GET(self):
            # Any path returns the form, which doubles as a captive-portal hint.
            self._html(self._form(state.get("last_error", "")))

        def do_POST(self):
            length = int(self.headers.get("Content-Length", "0"))
            fields = urllib.parse.parse_qs(self.rfile.read(length).decode("utf-8"))
            ssid = (fields.get("ssid") or [""])[0]
            password = (fields.get("password") or [""])[0]
            if not ssid:
                state["last_error"] = "Please pick a network."
                self._html(self._form(state["last_error"]))
                return
            self._html(HTML_CONNECTING.format(ssid=ssid, ap=AP_SSID))
            state["attempt"] = (ssid, password)

    return Handler


def run_portal() -> bool:
    state = {"networks": scan_networks(), "last_error": "", "attempt": None}
    srv = HTTPServer(("0.0.0.0", HTTP_PORT), make_handler(state))
    print(f"[*] portal at http://{AP_PORTAL_IP}:{HTTP_PORT}")
    while True:
        srv.handle_request()
        attempt = state.pop("attempt", None)
        if not attempt:
            continue
        ssid, password = attempt
        print(f"[*] attempting {ssid!r}")
        srv.server_close()

        stop_hotspot()
        time.sleep(2)
        if connect_to(ssid, password):
            print("[+] connected")
            return True

        print("[!] connect failed; relaunching hotspot")
        start_hotspot()
        state["networks"] = scan_networks()
        state["last_error"] = f"Couldn't connect to {ssid}. Try again."
        srv = HTTPServer(("0.0.0.0", HTTP_PORT), make_handler(state))


# --- main -----------------------------------------------------------------

def honor_reset_flags():
    for flag in RESET_FLAGS:
        try:
            if flag.exists():
                print(f"[*] reset flag at {flag}; clearing saved WiFi")
                flag.unlink()
                delete_saved_wifi_profiles()
                return
        except OSError:
            pass


def wait_for_existing(timeout: int) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if is_connected():
            return True
        time.sleep(2)
    return False


def watch():
    """Reboot if disconnected past the threshold.

    Lets the Pi auto-recover when moved to a new WiFi network: the next
    boot re-enters the setup flow via wifi_setup.service.
    """
    print(f"[*] watchdog: threshold {WATCHDOG_DISCONNECT_THRESHOLD_SECS}s")
    disconnected_since = None
    while True:
        if is_connected():
            if disconnected_since is not None:
                print(f"[*] reconnected after {time.time() - disconnected_since:.0f}s")
            disconnected_since = None
        else:
            disconnected_since = disconnected_since or time.time()
            elapsed = time.time() - disconnected_since
            if elapsed >= WATCHDOG_DISCONNECT_THRESHOLD_SECS:
                print(f"[!] disconnected {elapsed:.0f}s — rebooting to rerun setup")
                subprocess.run(["/sbin/reboot"], check=False)
                return
        time.sleep(WATCHDOG_CHECK_EVERY_SECS)


def provision():
    honor_reset_flags()

    if wait_for_existing(WAIT_FOR_EXISTING_SECS):
        print("[*] already connected; nothing to do")
        return

    print("[*] no connection — entering setup mode")
    try:
        show_setup_screen(render_setup_image())
    except Exception as e:
        print(f"[!] setup screen render failed: {e}")

    try:
        start_hotspot()
    except Exception as e:
        print(f"[!] {e}", file=sys.stderr)
        sys.exit(1)

    try:
        run_portal()
    finally:
        hide_setup_screen()


def main():
    if "--watch" in sys.argv[1:]:
        watch()
    else:
        provision()


if __name__ == "__main__":
    main()
