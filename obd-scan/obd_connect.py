#!/usr/bin/env python3
"""
obd_connect.py - find, connect to, and diagnose an ELM327-style OBD-II scan tool.

Supports the three ways these adapters attach to a computer:
  * USB / Bluetooth Classic (SPP)  -> serial port   (needs: pip install pyserial)
  * Wi-Fi                          -> TCP socket    (stdlib only)
  * Bluetooth Low Energy (BLE)     -> GATT          (needs: pip install bleak)

It walks the whole chain - transport -> adapter (AT commands) -> vehicle bus
(OBD mode 01) - and prints a numbered fix list for whichever layer fails.

Read-only: it never clears codes or writes to any ECU.

Examples:
  python3 obd_connect.py                       # auto-discover everything
  python3 obd_connect.py --list                # just list candidate adapters
  python3 obd_connect.py --port /dev/cu.usbserial-110
  python3 obd_connect.py --host 192.168.0.10 --tcp-port 35000
  python3 obd_connect.py --ble                 # scan + connect over BLE
  python3 obd_connect.py --dtc --live 10       # read codes, then 10s of live data
  python3 obd_connect.py --protocol 6          # force ISO 15765-4 CAN 11-bit/500k
"""

from __future__ import annotations

import argparse
import asyncio
import glob
import platform
import re
import socket
import sys
import threading
import time

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------

RESULTS: list[tuple[str, str, str]] = []
FIXES: list[str] = []


def report(status: str, label: str, detail: str = "") -> None:
    RESULTS.append((status, label, detail))
    print(f"  [{status:4}] {label}" + (f" - {detail}" if detail else ""))


def fix(text: str) -> None:
    if text not in FIXES:
        FIXES.append(text)


def section(title: str) -> None:
    print(f"\n== {title} ==")


IS_MAC = platform.system() == "Darwin"
IS_WIN = platform.system() == "Windows"

BAUD_RATES = [38400, 9600, 115200, 230400, 500000]
WIFI_DEFAULTS = [("192.168.0.10", 35000), ("192.168.4.1", 35000),
                 ("192.168.0.123", 35000), ("192.168.1.10", 35000)]
NAME_HINTS = re.compile(
    r"obd|elm|spp|vgate|veepeak|vlink|v-link|obdlink|konnwei|kw\d|bafx|"
    r"carista|bluedriver|usbserial|wchusbserial|slab|usbmodem|ttyusb|rfcomm|"
    r"ch34|ftdi|pl2303|cp210",
    re.I,
)
PORT_NOISE = re.compile(r"bluetooth-incoming-port|debug-console|wlan-debug|airpods", re.I)

PROTOCOLS = {
    "0": "Automatic", "1": "SAE J1850 PWM (41.6k)", "2": "SAE J1850 VPW (10.4k)",
    "3": "ISO 9141-2 (5 baud init)", "4": "ISO 14230-4 KWP (5 baud init)",
    "5": "ISO 14230-4 KWP (fast init)", "6": "ISO 15765-4 CAN (11 bit, 500k)",
    "7": "ISO 15765-4 CAN (29 bit, 500k)", "8": "ISO 15765-4 CAN (11 bit, 250k)",
    "9": "ISO 15765-4 CAN (29 bit, 250k)", "A": "SAE J1939 CAN (29 bit, 250k)",
}

BUS_ERRORS = ("UNABLE TO CONNECT", "BUS INIT", "CAN ERROR", "BUS ERROR",
              "FB ERROR", "DATA ERROR", "BUS BUSY", "LV RESET", "STOPPED", "ERR")

# --------------------------------------------------------------------------
# Transports: each provides write(bytes), read_until_prompt(timeout)->str, close()
# --------------------------------------------------------------------------


class SerialTransport:
    def __init__(self, port: str, baud: int):
        import serial  # pyserial
        self.name = f"{port} @ {baud}"
        self.ser = serial.Serial(port, baud, timeout=0.1, write_timeout=2)

    def write(self, data: bytes) -> None:
        self.ser.reset_input_buffer()
        self.ser.write(data)
        self.ser.flush()

    def read_until_prompt(self, timeout: float) -> str:
        buf = bytearray()
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            chunk = self.ser.read(256)
            if chunk:
                buf += chunk
                if b">" in chunk:
                    break
        return buf.decode("ascii", "replace")

    def close(self) -> None:
        try:
            self.ser.close()
        except Exception:
            pass


class TcpTransport:
    def __init__(self, host: str, port: int, connect_timeout: float = 3.0):
        self.name = f"{host}:{port}"
        self.sock = socket.create_connection((host, port), timeout=connect_timeout)
        self.sock.settimeout(0.2)

    def write(self, data: bytes) -> None:
        # drain anything stale first
        self.sock.settimeout(0.01)
        try:
            while self.sock.recv(1024):
                pass
        except (socket.timeout, BlockingIOError):
            pass
        self.sock.settimeout(0.2)
        self.sock.sendall(data)

    def read_until_prompt(self, timeout: float) -> str:
        buf = bytearray()
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            try:
                chunk = self.sock.recv(1024)
            except socket.timeout:
                continue
            if not chunk:
                break
            buf += chunk
            if b">" in chunk:
                break
        return buf.decode("ascii", "replace")

    def close(self) -> None:
        try:
            self.sock.close()
        except Exception:
            pass


class BleTransport:
    """ELM327 over BLE: one notify characteristic (RX) + one write characteristic (TX)."""

    PREFERRED_SERVICES = ("fff0", "ffe0", "18f0", "e7810a71")

    def __init__(self, address: str, timeout: float = 15.0):
        from bleak import BleakClient

        self.name = f"BLE {address}"
        self._buf = bytearray()
        self._lock = threading.Lock()
        self._got = threading.Event()
        self._loop = asyncio.new_event_loop()
        self._thread = threading.Thread(target=self._loop.run_forever, daemon=True)
        self._thread.start()
        self.client = BleakClient(address, timeout=timeout)
        self._run(self.client.connect(), timeout + 5)

        self.rx = self.tx = None
        candidates = []
        for svc in self.client.services:
            notify = [c for c in svc.characteristics
                      if "notify" in c.properties or "indicate" in c.properties]
            write = [c for c in svc.characteristics
                     if "write" in c.properties or "write-without-response" in c.properties]
            if notify and write:
                pref = any(svc.uuid.lower().startswith(p) or svc.uuid.lower()[4:8] == p
                           for p in self.PREFERRED_SERVICES)
                candidates.append((0 if pref else 1, notify[0], write[0]))
        if not candidates:
            self.close()
            raise RuntimeError("no GATT service with notify+write characteristics found")
        candidates.sort(key=lambda c: c[0])
        _, self.rx, self.tx = candidates[0]
        self._with_response = "write" in self.tx.properties
        self._run(self.client.start_notify(self.rx, self._on_notify), 10)

    def _run(self, coro, timeout):
        return asyncio.run_coroutine_threadsafe(coro, self._loop).result(timeout)

    def _on_notify(self, _char, data: bytearray) -> None:
        with self._lock:
            self._buf += data
        self._got.set()

    def write(self, data: bytes) -> None:
        with self._lock:
            self._buf.clear()
        self._run(self.client.write_gatt_char(self.tx, data, response=self._with_response), 5)

    def read_until_prompt(self, timeout: float) -> str:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self._got.wait(0.1)
            self._got.clear()
            with self._lock:
                if b">" in self._buf:
                    break
        with self._lock:
            out = bytes(self._buf)
            self._buf.clear()
        return out.decode("ascii", "replace")

    def close(self) -> None:
        try:
            self._run(self.client.disconnect(), 5)
        except Exception:
            pass
        self._loop.call_soon_threadsafe(self._loop.stop)


# --------------------------------------------------------------------------
# ELM327 protocol layer
# --------------------------------------------------------------------------


class Elm327:
    def __init__(self, transport):
        self.t = transport

    def cmd(self, command: str, timeout: float = 2.0) -> list[str]:
        self.t.write((command + "\r").encode("ascii"))
        raw = self.t.read_until_prompt(timeout)
        lines = []
        for line in re.split(r"[\r\n]+", raw.replace(">", "")):
            line = line.strip()
            if not line or line.replace(" ", "").upper() == command.replace(" ", "").upper():
                continue  # blank or echo
            if line.upper().startswith("SEARCHING"):
                continue
            lines.append(line)
        return lines

    def query(self, pid: str, timeout: float = 5.0) -> tuple[list[list[int]], list[str]]:
        """Send an OBD request; return (list of data-byte lists, raw lines)."""
        lines = self.cmd(pid, timeout)
        frames = []
        for line in lines:
            if any(e in line.upper() for e in BUS_ERRORS + ("NO DATA", "?")):
                continue
            line = re.sub(r"^[0-9A-F]:\s*", "", line.strip(), flags=re.I)  # ISO-TP index
            hexs = re.sub(r"[^0-9A-Fa-f]", "", line)
            if len(hexs) < 2 or len(hexs) % 2:
                continue
            frames.append([int(hexs[i:i + 2], 16) for i in range(0, len(hexs), 2)])
        return frames, lines


def first_reply(frames: list[list[int]], mode: int, pid: int | None = None) -> list[int] | None:
    for f in frames:
        if f and f[0] == mode + 0x40 and (pid is None or (len(f) > 1 and f[1] == pid)):
            return f[2:] if pid is not None else f[1:]
    return None


def decode_dtcs(frames: list[list[int]], is_can: bool) -> list[str]:
    codes: list[str] = []
    data: list[int] = []
    for f in frames:
        if not f:
            continue
        if f[0] == 0x43:
            body = f[1:]
            if is_can and body:
                body = body[1:]  # CAN replies carry a DTC count byte
            data += body
        elif data:  # continuation frame of a multi-frame CAN reply
            data += f
    for i in range(0, len(data) - 1, 2):
        a, b = data[i], data[i + 1]
        if a == 0 and b == 0:
            continue
        code = "PCBU"[a >> 6] + str((a >> 4) & 3) + f"{a & 0xF:X}{b:02X}"
        if code not in codes:
            codes.append(code)
    return codes


# --------------------------------------------------------------------------
# Discovery
# --------------------------------------------------------------------------


def list_serial_ports() -> list[tuple[str, str]]:
    ports: list[tuple[str, str]] = []
    try:
        from serial.tools import list_ports
        for p in list_ports.comports():
            ports.append((p.device, " ".join(x for x in (p.description, p.manufacturer or "") if x and x != "n/a")))
    except ImportError:
        pats = ["/dev/cu.*"] if IS_MAC else ["/dev/ttyUSB*", "/dev/ttyACM*", "/dev/rfcomm*"]
        ports = [(p, "") for pat in pats for p in sorted(glob.glob(pat))]
    if IS_MAC:  # /dev/tty.* blocks on carrier-detect; always use /dev/cu.*
        ports = [(d.replace("/dev/tty.", "/dev/cu."), desc) for d, desc in ports]
    seen, out = set(), []
    for d, desc in ports:
        if d in seen or PORT_NOISE.search(d):
            continue
        seen.add(d)
        out.append((d, desc))
    out.sort(key=lambda x: 0 if NAME_HINTS.search(x[0] + " " + x[1]) else 1)
    return out


def local_ip_toward(host: str) -> str | None:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect((host, 9))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except OSError:
        return None


def probe_wifi(targets, timeout: float = 1.5) -> list[tuple[str, int]]:
    found = []
    for host, port in targets:
        try:
            socket.create_connection((host, port), timeout=timeout).close()
            found.append((host, port))
        except OSError:
            pass
    return found


def scan_ble(seconds: float = 6.0) -> list[tuple[str, str, int | None]]:
    from bleak import BleakScanner

    async def _scan():
        return await BleakScanner.discover(timeout=seconds, return_adv=True)

    res = asyncio.run(_scan())
    out = []
    for dev, adv in res.values():
        name = dev.name or adv.local_name or ""
        out.append((dev.address, name, adv.rssi))
    out.sort(key=lambda x: (0 if NAME_HINTS.search(x[1]) else 1, -(x[2] or -999)))
    return out


# --------------------------------------------------------------------------
# Adapter + vehicle diagnosis
# --------------------------------------------------------------------------


def open_serial(port: str, baud: int | None):
    """Try each baud until ATZ answers. Returns (Elm327, banner) or (None, error)."""
    last_err = "no response at any baud rate"
    for b in ([baud] if baud else BAUD_RATES):
        try:
            t = SerialTransport(port, b)
        except Exception as e:  # busy, permissions, vanished
            msg = str(e)
            errno_ = getattr(e, "errno", None)
            if errno_ == 16 or "busy" in msg.lower():
                return None, f"port busy (another app has it open): {msg}"
            if errno_ == 13 or "permission" in msg.lower() or "access is denied" in msg.lower():
                return None, f"permission denied: {msg}"
            return None, msg
        elm = Elm327(t)
        t.write(b"\r")
        t.read_until_prompt(0.5)
        banner = " ".join(elm.cmd("ATZ", 3.0))
        if "ELM" not in banner.upper():
            banner = " ".join(elm.cmd("ATI", 1.5))
        if re.search(r"ELM|STN|OBD|v\d", banner, re.I):
            return elm, banner
        t.close()
    return None, last_err


def diagnose(elm: Elm327, banner: str, args) -> bool:
    section("Adapter (AT commands)")
    report("PASS", "Adapter answered reset", banner)

    for c in ("ATE0", "ATL0", "ATS1", "ATH0", "ATAT1"):
        elm.cmd(c, 1.0)
    ver = " ".join(elm.cmd("ATI", 1.5))
    desc = " ".join(elm.cmd("AT@1", 1.0))
    stn = " ".join(elm.cmd("STI", 1.0))

    m = re.search(r"v(\d+\.\d+)", ver, re.I)
    if "STN" in stn.upper() or "OBDLINK" in (desc + stn).upper():
        report("PASS", "Chip", f"genuine STN-based ({stn or desc})")
    elif m:
        v = m.group(1)
        clone = v in ("2.1", "2.2", "2.3") or desc.strip() in ("", "?")
        report("WARN" if clone else "INFO", "Chip", f"ELM327 v{v}" + (" - almost certainly a clone" if clone else ""))
        if clone:
            fix("Adapter reports ELM327 v2.x, which Elm Electronics never made - it's a clone. "
                "Many v2.1 clones lack J1850 PWM/VPW (older Ford/GM) and some K-line support. "
                "If the vehicle won't connect, a genuine-chip adapter (OBDLink, Vgate iCar Pro, "
                "or a v1.5 PIC18F25K80 clone) is the usual fix.")
    else:
        report("INFO", "Chip", ver or "unknown")

    rv = " ".join(elm.cmd("ATRV", 1.5))
    vm = re.search(r"(\d+(?:\.\d+)?)\s*V", rv, re.I)
    volts = float(vm.group(1)) if vm else None
    if volts is None:
        report("WARN", "Battery voltage (pin 16)", rv or "no reading")
    elif volts < 11.0:
        report("FAIL", "Battery voltage (pin 16)", f"{volts:.1f} V")
        fix(f"Adapter sees only {volts:.1f} V. Battery is weak or the adapter isn't seated - "
            "push it fully into the OBD port. Some cars fuse the OBD port with the cigarette "
            "lighter; check that fuse if lighter is dead too.")
    elif volts < 12.2:
        report("WARN", "Battery voltage (pin 16)", f"{volts:.1f} V (engine off / ignition off?)")
    else:
        report("PASS", "Battery voltage (pin 16)", f"{volts:.1f} V" + (" (engine running)" if volts > 13.2 else ""))

    section("Vehicle bus (OBD mode 01)")
    proto = args.protocol.upper() if args.protocol else "0"
    elm.cmd(f"ATSP{proto}", 1.0)
    report("INFO", "Protocol request", f"ATSP{proto} = {PROTOCOLS.get(proto, '?')}")

    frames, lines = elm.query("0100", timeout=12.0)
    raw = " | ".join(lines) or "(no reply)"
    supported = first_reply(frames, 0x01, 0x00)
    if not supported:
        report("FAIL", "ECU handshake (0100)", raw)
        up = raw.upper()
        if "UNABLE TO CONNECT" in up:
            fix("UNABLE TO CONNECT: the adapter tried every protocol and no ECU answered. "
                "Turn the ignition to ON (dash lights lit) or start the engine - accessory "
                "position is not enough on most cars. Confirm the vehicle is OBD-II "
                "(US 1996+, EU petrol 2001+, EU diesel 2004+).")
        if "BUS INIT" in up:
            fix("BUS INIT ERROR: K-line slow init failed (ISO 9141 / KWP). Ignition ON, wait 5 s, "
                "retry; then force it with --protocol 3, 4 or 5. Clone adapters are often weak here.")
        if "CAN ERROR" in up or "BUS ERROR" in up:
            fix("CAN/BUS ERROR: wrong bus speed or no CAN on pins 6/14. Try --protocol 6, 7, 8 "
                "and 9 in turn. If all fail, inspect the OBD port for bent pins.")
        if "NO DATA" in up:
            fix("NO DATA: the bus is up but the ECU didn't answer. Ignition ON (not ACC), "
                "and on some hybrids/EVs the car must be in READY mode.")
        if "LV RESET" in up or "STOPPED" in up:
            fix("Adapter reset or was interrupted mid-search - usually a voltage dip or a flaky "
                "Bluetooth link. Keep the computer close and retry.")
        if raw == "(no reply)":
            fix("Adapter went silent during protocol search. Clone firmware sometimes hangs on "
                "auto-detect; force a protocol: --protocol 6 is right for most 2008+ cars.")
        return False

    dpn = " ".join(elm.cmd("ATDPN", 1.0)).strip().upper().lstrip("A")
    dp = " ".join(elm.cmd("ATDP", 1.0))
    report("PASS", "ECU handshake (0100)", "vehicle responded")
    report("PASS", "Active protocol", f"{dpn} - {dp}")
    is_can = dpn[-1:] in ("6", "7", "8", "9", "A", "B", "C")

    section("Quick read")
    f, _ = elm.query("0101")
    st = first_reply(f, 0x01, 0x01)
    if st:
        mil = bool(st[0] & 0x80)
        count = st[0] & 0x7F
        report("WARN" if mil else "PASS", "Check-engine light", f"{'ON' if mil else 'off'}, {count} stored code(s)")
    for pid, label, fn in (
        ("010C", "Engine RPM", lambda d: f"{((d[0] << 8) | d[1]) / 4:.0f} rpm"),
        ("010D", "Vehicle speed", lambda d: f"{d[0]} km/h ({d[0] * 0.621:.0f} mph)"),
        ("0105", "Coolant temp", lambda d: f"{d[0] - 40} C ({(d[0] - 40) * 9 / 5 + 32:.0f} F)"),
        ("0142", "ECU voltage", lambda d: f"{((d[0] << 8) | d[1]) / 1000:.2f} V"),
    ):
        f, ls = elm.query(pid)
        d = first_reply(f, 0x01, int(pid[2:], 16))
        try:
            report("INFO", label, fn(d) if d else ("not supported" if ls else "no reply"))
        except IndexError:
            report("INFO", label, "short reply")

    if args.dtc:
        section("Stored trouble codes (mode 03)")
        f, ls = elm.query("03", timeout=6.0)
        codes = decode_dtcs(f, is_can)
        report("WARN" if codes else "PASS", "Stored DTCs", ", ".join(codes) if codes else "none")
        f, ls = elm.query("07", timeout=6.0)
        pend = decode_dtcs([[0x43] + x[1:] if x and x[0] == 0x47 else x for x in f], is_can)
        report("WARN" if pend else "PASS", "Pending DTCs", ", ".join(pend) if pend else "none")

    if args.live:
        section(f"Live data ({args.live}s, Ctrl-C to stop)")
        end = time.monotonic() + args.live
        try:
            while time.monotonic() < end:
                f, _ = elm.query("010C", 2.0)
                r = first_reply(f, 0x01, 0x0C)
                f, _ = elm.query("010D", 2.0)
                s = first_reply(f, 0x01, 0x0D)
                rpm = f"{((r[0] << 8) | r[1]) / 4:6.0f}" if r and len(r) > 1 else "   ---"
                spd = f"{s[0]:4d} km/h ({s[0] * 0.621:4.0f} mph)" if s else " --- km/h"
                print(f"  rpm {rpm}   {spd}", flush=True)
                time.sleep(0.5)
        except KeyboardInterrupt:
            pass
    return True


# --------------------------------------------------------------------------
# Main flow
# --------------------------------------------------------------------------


def mac_bt_hints() -> None:
    fix("macOS + Bluetooth: Classic (SPP) adapters must be paired in System Settings > "
        "Bluetooth first (PIN usually 1234 or 0000); they then appear as /dev/cu.<name>. "
        "BLE-only adapters (Vgate iCar Pro BLE, Veepeak BLE+, OBDLink CX) never create a "
        "serial port on a Mac - run with --ble instead (pip install bleak).")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true", help="list candidate adapters and exit")
    ap.add_argument("--port", help="serial port (e.g. /dev/cu.usbserial-110, COM3, /dev/rfcomm0)")
    ap.add_argument("--baud", type=int, help="serial baud rate (default: auto-detect)")
    ap.add_argument("--host", help="Wi-Fi adapter IP (default: probe common addresses)")
    ap.add_argument("--tcp-port", type=int, default=35000, help="Wi-Fi adapter TCP port (default 35000)")
    ap.add_argument("--ble", nargs="?", const="scan", metavar="ADDRESS",
                    help="use Bluetooth LE; optional device address/UUID, else scan")
    ap.add_argument("--protocol", help="force OBD protocol 1-9/A (default 0 = auto)")
    ap.add_argument("--dtc", action="store_true", help="read stored + pending trouble codes")
    ap.add_argument("--live", type=int, default=0, metavar="SEC", help="stream RPM/speed for SEC seconds")
    args = ap.parse_args()

    print(f"OBD-II scan tool connection check  ({platform.system()} {platform.release()}, Python {platform.python_version()})")

    try:
        import serial  # noqa: F401
        have_serial = True
    except ImportError:
        have_serial = False
    try:
        import bleak  # noqa: F401
        have_bleak = True
    except ImportError:
        have_bleak = False

    # ---- Discovery -------------------------------------------------------
    section("Discovery")
    report("PASS" if have_serial else "WARN", "pyserial", "installed" if have_serial else "missing (needed for USB / Bluetooth Classic)")
    if not have_serial:
        fix("Install pyserial for USB and Bluetooth-Classic adapters:  python3 -m pip install pyserial")

    explicit = args.port or args.host or args.ble
    ports = [(args.port, "user-specified")] if args.port else ([] if explicit else list_serial_ports())
    for d, desc in ports:
        tag = "likely OBD" if NAME_HINTS.search(d + " " + desc) else "other"
        report("INFO", f"Serial port {d}", f"{desc} [{tag}]" if desc else f"[{tag}]")
    if not explicit and not ports:
        report("WARN", "Serial ports", "none found")

    wifi_targets = [(args.host, args.tcp_port)] if args.host else ([] if explicit else WIFI_DEFAULTS)
    wifi = probe_wifi(wifi_targets) if wifi_targets else []
    for h, p in wifi:
        report("PASS", f"Wi-Fi adapter {h}:{p}", "TCP port open")
    if wifi_targets and not wifi:
        ip = local_ip_toward(wifi_targets[0][0])
        report("WARN" if not args.host else "FAIL", "Wi-Fi adapter",
               f"nothing listening on {', '.join(f'{h}:{p}' for h, p in wifi_targets)}; this machine is {ip or 'offline'}")
        if args.host:
            fix(f"Join the adapter's own Wi-Fi network (often 'WiFi_OBDII', 'V-LINK' or 'OBDII') "
                f"before connecting to {args.host}. Your IP is {ip or 'unknown'} - it should be on "
                f"the same subnet. On macOS, if the Mac drops back to your home Wi-Fi because the "
                f"adapter has no internet, turn off 'Auto-Join' for the home network temporarily.")

    ble_devs = []
    if args.ble == "scan" or (not explicit and have_bleak):
        if not have_bleak:
            report("FAIL", "BLE scan", "bleak not installed")
            fix("Install bleak for BLE adapters:  python3 -m pip install bleak")
        else:
            try:
                ble_devs = scan_ble()
                hits = [d for d in ble_devs if NAME_HINTS.search(d[1])]
                for addr, name, rssi in hits:
                    report("INFO", f"BLE {name}", f"{addr}  rssi {rssi}")
                if not hits:
                    report("WARN", "BLE scan", f"{len(ble_devs)} device(s) seen, none look like an OBD adapter")
            except Exception as e:
                report("FAIL", "BLE scan", str(e))
                if IS_MAC:
                    fix("macOS blocks Bluetooth for apps without permission: System Settings > "
                        "Privacy & Security > Bluetooth -> enable Terminal (or iTerm / VS Code), "
                        "then re-run.")

    if args.list:
        return summary(False)

    # ---- Connect: try each candidate until one answers ATZ --------------
    section("Connect")
    elm = None
    banner = ""

    if args.ble and args.ble != "scan":
        targets_ble = [(args.ble, "user-specified", None)]
    elif args.ble == "scan" or not (ports or wifi):
        targets_ble = [d for d in ble_devs if NAME_HINTS.search(d[1])]
    else:
        targets_ble = []

    for h, p in wifi:
        try:
            t = TcpTransport(h, p)
            e = Elm327(t)
            b = " ".join(e.cmd("ATZ", 3.0))
            if "ELM" in b.upper() or "OBD" in b.upper():
                elm, banner = e, b
                report("PASS", f"Wi-Fi {h}:{p}", b)
                break
            report("FAIL", f"Wi-Fi {h}:{p}", f"connected but got '{b or 'nothing'}' to ATZ")
            fix(f"{h}:{p} accepts TCP but isn't answering like an ELM327. Power-cycle the adapter "
                "(unplug 10 s). Close any phone app that may already hold the single allowed connection.")
            t.close()
        except OSError as ex:
            report("FAIL", f"Wi-Fi {h}:{p}", str(ex))

    if not elm and have_serial:
        for d, _ in sorted(ports, key=lambda x: 0 if NAME_HINTS.search(x[0] + x[1]) else 1):
            if not args.port and not NAME_HINTS.search(d) and len(ports) > 3:
                continue  # don't hammer unrelated ports when there are many
            e, msg = open_serial(d, args.baud)
            if e:
                elm, banner = e, msg
                report("PASS", f"Serial {e.t.name}", msg)
                break
            report("FAIL", f"Serial {d}", msg)
            if "busy" in msg:
                fix(f"{d} is held by another program. Quit other OBD apps, Arduino IDE, "
                    f"screen/minicom sessions; on macOS 'lsof {d}' shows the culprit.")
            elif "permission" in msg:
                fix(f"No permission for {d}. Linux: sudo usermod -aG dialout $USER (then log out/in).")
            else:
                fix(f"{d} opened but never answered ATZ. Check: adapter plugged into the car "
                    "(its LED should be lit), correct port, and for Bluetooth that it's paired and "
                    "within range. Cheap Bluetooth clones sometimes need a re-pair after the car is "
                    "restarted.")

    if not elm and targets_ble and have_bleak:
        for addr, name, _ in targets_ble:
            try:
                t = BleTransport(addr)
                e = Elm327(t)
                b = " ".join(e.cmd("ATZ", 4.0))
                if re.search(r"ELM|OBD|STN|v\d", b, re.I):
                    elm, banner = e, b
                    report("PASS", f"BLE {name or addr}", b)
                    break
                report("FAIL", f"BLE {name or addr}", f"connected but ATZ returned '{b or 'nothing'}'")
                t.close()
            except Exception as ex:
                report("FAIL", f"BLE {name or addr}", str(ex) or type(ex).__name__)
                fix("BLE connect failed. Make sure no phone is connected to the adapter (BLE adapters "
                    "accept one client), and on macOS do NOT pair it in System Settings - BLE adapters "
                    "connect directly; remove it there if you added it.")

    if not elm:
        report("FAIL", "Scan tool connection", "no adapter answered")
        if not ports and not wifi and not ble_devs:
            fix("Nothing that looks like an OBD adapter was found. Plug it into the car's OBD port "
                "(under the dash, driver side) and confirm its LED lights up.")
        if IS_MAC:
            mac_bt_hints()
        elif IS_WIN:
            fix("Windows: after pairing a Bluetooth Classic adapter, open Bluetooth > More "
                "Bluetooth options > COM Ports and use the 'Outgoing' COM port with --port COMx.")
        return summary(False)

    try:
        ok = diagnose(elm, banner, args)
    finally:
        elm.t.close()
    return summary(ok)


def summary(ok: bool) -> int:
    section("Summary")
    fails = sum(1 for r in RESULTS if r[0] == "FAIL")
    warns = sum(1 for r in RESULTS if r[0] == "WARN")
    print(f"  {'CONNECTED to vehicle' if ok else 'NOT connected to vehicle'}  ({fails} fail, {warns} warn)")
    if FIXES:
        print("\n== Fixes (in order) ==")
        for i, f in enumerate(FIXES, 1):
            print(f"  {i}. {f}")
    return 0 if ok else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\ninterrupted")
        sys.exit(130)
