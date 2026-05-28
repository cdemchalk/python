"""
Passive home-network device inventory.

What this does:
  * Reads the local ARP table to list every IP/MAC currently known.
  * Listens for mDNS/Bonjour service advertisements (Chromecast, AirPlay,
    HomeKit, Shelly, ESPHome, Hue, printers, etc.).
  * Sends an SSDP M-SEARCH and collects UPnP responses (Sonos, Roku, Smart TVs,
    routers, some Wi-Fi bulbs).
  * Looks up the MAC vendor (OUI) for each host.
  * Suggests the matching Home Assistant integration for each device.

What this DOES NOT do:
  * It does not connect to, log into, or attempt to control any device.
  * It does not perform port scans, vulnerability probes, or credential tests.
  * Everything it sees, devices have voluntarily broadcast on the LAN.

Run:
    pip install zeroconf
    python discover_devices.py
"""

from __future__ import annotations

import json
import re
import socket
import subprocess
import sys
import time
from dataclasses import dataclass, field, asdict
from typing import Iterable

try:
    from zeroconf import ServiceBrowser, ServiceListener, Zeroconf
except ImportError:
    print("Missing dependency. Run:  pip install zeroconf", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Mapping from a discovery signal to the Home Assistant integration to use.
# Source of truth: https://www.home-assistant.io/integrations/
# ---------------------------------------------------------------------------
MDNS_SERVICE_TO_HA = {
    "_hap._tcp.local.": "HomeKit Controller (homekit_controller)",
    "_hue._tcp.local.": "Philips Hue (hue)",
    "_shelly._tcp.local.": "Shelly (shelly)",
    "_esphomelib._tcp.local.": "ESPHome (esphome)",
    "_googlecast._tcp.local.": "Google Cast (cast)",
    "_airplay._tcp.local.": "AirPlay / Apple TV (apple_tv)",
    "_raop._tcp.local.": "AirPlay audio (apple_tv / airplay)",
    "_sonos._tcp.local.": "Sonos (sonos)",
    "_spotify-connect._tcp.local.": "Spotify Connect (spotify)",
    "_printer._tcp.local.": "(printer - no HA integration needed)",
    "_ipp._tcp.local.": "(printer - no HA integration needed)",
    "_axis-video._tcp.local.": "Axis camera (axis)",
    "_miio._udp.local.": "Xiaomi Miio (xiaomi_miio)",
    "_wled._tcp.local.": "WLED (wled)",
    "_elgato._tcp.local.": "Elgato Key Light (elgato)",
    "_nanoleafapi._tcp.local.": "Nanoleaf (nanoleaf)",
}

VENDOR_TO_HA = {
    "TP-LINK": "TP-Link Kasa (tplink)  /  TP-Link Tapo (tplink)",
    "TP-Link": "TP-Link Kasa (tplink)  /  TP-Link Tapo (tplink)",
    "Tuya":    "Tuya (tuya)  or  LocalTuya (HACS)",
    "Espressif": "Likely ESP-based (ESPHome / Tuya / Shelly Plus / Wyze)",
    "Shenzhen": "Possibly Tuya OEM - try Tuya integration",
    "Sonos":   "Sonos (sonos)",
    "Philips": "Philips Hue (hue)",
    "Signify": "Philips Hue (hue)",
    "Belkin":  "Wemo (wemo)",
    "Wyze":    "Wyze (HACS only - no official integration)",
    "Roku":    "Roku (roku)",
    "Amazon":  "Alexa Media Player (HACS) for Echo devices",
    "Google":  "Google Cast (cast) / Nest (nest)",
    "Ecobee":  "ecobee (ecobee)",
    "Ring":    "Ring (ring)",
    "LIFX":    "LIFX (lifx)",
    "Nest":    "Nest (nest)",
    "Eufy":    "Eufy Security (HACS)",
}


@dataclass
class Device:
    ip: str = ""
    mac: str = ""
    hostname: str = ""
    vendor: str = ""
    mdns_services: list[str] = field(default_factory=list)
    ssdp_info: list[str] = field(default_factory=list)
    suggestions: list[str] = field(default_factory=list)


# ---------------------------------------------------------------------------
# ARP table
# ---------------------------------------------------------------------------
ARP_LINE = re.compile(
    r"(?P<ip>\d{1,3}(?:\.\d{1,3}){3})\s+[\w-]+\s+(?P<mac>[0-9a-fA-F:-]{17})"
)


def read_arp_table() -> dict[str, Device]:
    devices: dict[str, Device] = {}
    try:
        out = subprocess.check_output(["arp", "-a"], text=True, timeout=5)
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"warning: could not read ARP table: {exc}", file=sys.stderr)
        return devices

    for line in out.splitlines():
        m = ARP_LINE.search(line.replace("-", ":"))
        if not m:
            continue
        ip = m.group("ip")
        mac = m.group("mac").lower()
        if mac in ("00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff"):
            continue
        devices[ip] = Device(ip=ip, mac=mac)
    return devices


# ---------------------------------------------------------------------------
# mDNS / Bonjour
# ---------------------------------------------------------------------------
class MdnsCollector(ServiceListener):
    def __init__(self) -> None:
        self.found: dict[str, set[str]] = {}   # ip -> set of services
        self.names: dict[str, str] = {}        # ip -> friendly name

    def add_service(self, zc: Zeroconf, type_: str, name: str) -> None:
        info = zc.get_service_info(type_, name, timeout=2000)
        if not info:
            return
        for addr in info.parsed_addresses():
            self.found.setdefault(addr, set()).add(type_)
            self.names.setdefault(addr, name.split(".", 1)[0])

    def update_service(self, *args, **kwargs) -> None: pass
    def remove_service(self, *args, **kwargs) -> None: pass


def collect_mdns(seconds: int = 6) -> MdnsCollector:
    zc = Zeroconf()
    listener = MdnsCollector()
    browsers = [ServiceBrowser(zc, svc, listener) for svc in MDNS_SERVICE_TO_HA]
    print(f"  listening for mDNS for {seconds}s...")
    time.sleep(seconds)
    for b in browsers:
        b.cancel()
    zc.close()
    return listener


# ---------------------------------------------------------------------------
# SSDP / UPnP
# ---------------------------------------------------------------------------
SSDP_REQUEST = (
    "M-SEARCH * HTTP/1.1\r\n"
    "HOST: 239.255.255.250:1900\r\n"
    'MAN: "ssdp:discover"\r\n'
    "MX: 2\r\n"
    "ST: ssdp:all\r\n\r\n"
).encode()


def collect_ssdp(seconds: int = 4) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(seconds)
    sock.sendto(SSDP_REQUEST, ("239.255.255.250", 1900))
    print(f"  collecting SSDP responses for {seconds}s...")
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            data, (ip, _port) = sock.recvfrom(4096)
        except socket.timeout:
            break
        text = data.decode("utf-8", errors="ignore")
        server = ""
        for line in text.splitlines():
            if line.lower().startswith("server:"):
                server = line.split(":", 1)[1].strip()
                break
        if server:
            found.setdefault(ip, []).append(server)
    sock.close()
    return found


# ---------------------------------------------------------------------------
# OUI vendor lookup (offline first; no network call needed for common vendors)
# ---------------------------------------------------------------------------
COMMON_OUI = {
    "ec:fa:bc": "Espressif",
    "84:f3:eb": "Espressif",
    "a4:cf:12": "Espressif",
    "b4:e6:2d": "Espressif",
    "98:f4:ab": "Espressif",
    "50:c7:bf": "TP-Link",
    "ac:84:c6": "TP-Link",
    "b0:be:76": "TP-Link",
    "00:0e:58": "Sonos",
    "94:9f:3e": "Sonos",
    "00:17:88": "Philips Hue",
    "ec:b5:fa": "Philips Hue",
    "ec:1b:bd": "Amazon",
    "fc:65:de": "Amazon",
    "f0:d2:f1": "Amazon",
    "d0:03:4b": "Apple",
    "f4:f5:d8": "Google",
    "6c:ad:f8": "Google",
    "b8:27:eb": "Raspberry Pi",
    "dc:a6:32": "Raspberry Pi",
    "e4:5f:01": "Raspberry Pi",
    "00:62:6e": "Ring",
    "b0:09:da": "Ring",
    "d0:73:d5": "LIFX",
    "94:10:3e": "Belkin",
    "18:b4:30": "Nest",
    "5c:cf:7f": "Espressif",
}


def lookup_vendor(mac: str) -> str:
    return COMMON_OUI.get(mac.lower()[:8], "")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def build_inventory() -> list[Device]:
    print("[1/3] reading ARP table...")
    devices = read_arp_table()
    print(f"      {len(devices)} hosts seen")

    print("[2/3] mDNS discovery...")
    mdns = collect_mdns()

    print("[3/3] SSDP discovery...")
    ssdp = collect_ssdp()

    for ip, services in mdns.found.items():
        dev = devices.setdefault(ip, Device(ip=ip))
        dev.mdns_services = sorted(services)
        if not dev.hostname:
            dev.hostname = mdns.names.get(ip, "")

    for ip, servers in ssdp.items():
        dev = devices.setdefault(ip, Device(ip=ip))
        dev.ssdp_info = servers

    for dev in devices.values():
        if dev.mac:
            dev.vendor = lookup_vendor(dev.mac)
        for svc in dev.mdns_services:
            if svc in MDNS_SERVICE_TO_HA:
                dev.suggestions.append(MDNS_SERVICE_TO_HA[svc])
        for key, integ in VENDOR_TO_HA.items():
            if dev.vendor and key.lower() in dev.vendor.lower():
                dev.suggestions.append(integ)
        for s in dev.ssdp_info:
            if "Sonos" in s: dev.suggestions.append("Sonos (sonos)")
            if "Roku"  in s: dev.suggestions.append("Roku (roku)")
            if "Hue"   in s: dev.suggestions.append("Philips Hue (hue)")
        dev.suggestions = sorted(set(dev.suggestions))

    return sorted(devices.values(), key=lambda d: tuple(int(p) for p in d.ip.split(".")))


def print_table(devs: Iterable[Device]) -> None:
    print()
    print(f"{'IP':<16}{'MAC':<19}{'Vendor':<18}{'Hostname':<24}Integration suggestion")
    print("-" * 110)
    for d in devs:
        sug = d.suggestions[0] if d.suggestions else ""
        print(f"{d.ip:<16}{d.mac:<19}{d.vendor:<18}{d.hostname[:23]:<24}{sug}")


if __name__ == "__main__":
    inv = build_inventory()
    print_table(inv)
    with open("inventory.json", "w") as fh:
        json.dump([asdict(d) for d in inv], fh, indent=2)
    print("\nFull details written to inventory.json")
