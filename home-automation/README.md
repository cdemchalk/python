# Home Automation Stack (Home Assistant + MQTT + Zigbee2MQTT)

A local-first home automation hub for a **Windows PC** controlling **Wi-Fi**
and **Zigbee** devices through their supported APIs. No exploitation, no
default-credential probing - every device is integrated the way its
manufacturer intends, which is also what survives firmware updates.

## What's in this folder

```
docker-compose.yml          # the three services
mosquitto/config/           # MQTT broker config
zigbee2mqtt-data/           # Zigbee2MQTT config (edit serial.adapter for your stick)
homeassistant-config/       # Home Assistant config (populated on first run)
discover_devices.py         # passive LAN inventory: tells you what to add to HA
```

## Prerequisites on Windows

1. **Docker Desktop** for Windows with the WSL2 backend.
2. A **Zigbee USB coordinator**. Recommended:
   - Home Assistant SkyConnect / Connect ZBT-1 (EmberZNet - `adapter: ember`)
   - Sonoff Zigbee 3.0 USB Dongle Plus (CC2652 - `adapter: zstack`)
3. **usbipd-win** to share the USB stick with WSL2/Docker:
   <https://github.com/dorssel/usbipd-win>

### Attaching the Zigbee dongle to Docker (one-time per reboot)

In an **admin PowerShell** on Windows:

```powershell
usbipd list                            # find the BUSID of the dongle, e.g. 2-3
usbipd bind --busid 2-3                # one-time
usbipd attach --wsl --busid 2-3        # do this after every reboot
```

Then inside WSL the dongle shows up as `/dev/ttyUSB0` (or `ttyACM0`). Adjust
the `devices:` line in `docker-compose.yml` if your path differs.

## First-time setup

1. Generate an MQTT password for Zigbee2MQTT:
   ```powershell
   docker run --rm -v ${PWD}/mosquitto/config:/mosquitto/config eclipse-mosquitto:2 `
     mosquitto_passwd -c -b /mosquitto/config/passwd z2m "<pick-a-password>"
   ```
   Put the same password in `zigbee2mqtt-data/configuration.yaml` under
   `mqtt.password`.

2. Start the stack:
   ```powershell
   docker compose up -d
   ```

3. Open Home Assistant: <http://localhost:8123> - create your owner account.

4. Open Zigbee2MQTT UI: <http://localhost:8080> - confirm it sees the
   coordinator. Use the UI's "Permit join" button only when adding new
   devices.

5. In Home Assistant, add the **MQTT** integration:
   - Broker: `localhost`, port `1883`, user `z2m`, your password.
   - HA will auto-discover every Zigbee device Z2M has paired.

## Adding your Wi-Fi devices

Run the inventory script to see what's on the network and which HA integration
to use for each device:

```powershell
pip install zeroconf
python discover_devices.py
```

It writes `inventory.json` and prints a table like:

```
IP              MAC                Vendor            Hostname               Integration
192.168.1.42    50:c7:bf:11:22:33  TP-Link           kasa-plug-living       TP-Link Kasa (tplink)
192.168.1.55    ec:fa:bc:aa:bb:cc  Espressif         shellyplus1-abc123     Shelly (shelly)
192.168.1.61    d0:73:d5:de:ad:be  LIFX              lifx-bulb-kitchen      LIFX (lifx)
```

Then in Home Assistant: **Settings -> Devices & Services -> Add Integration**
and pick the suggested name. Most local integrations (Kasa, Shelly, LIFX,
Hue, ESPHome, WLED) will auto-discover the device by IP once you add the
integration; cloud integrations (Tuya, Ring, ecobee, Nest) need you to log in
with the vendor account.

## What the inventory script does NOT do

- It does not connect to or log in to any device.
- It does not scan ports, fingerprint services, or try credentials.
- It only reads broadcast traffic (mDNS, SSDP) and your own ARP table.

That is the right way to do this: integrating through supported APIs is more
reliable, survives firmware updates, and doesn't put you on the wrong side of
the Computer Fraud and Abuse Act for devices you may not legally own (guests'
phones, neighbors' bulbs that leaked onto your subnet, etc.).

## Useful next steps

- **Dashboard:** HA's default Lovelace dashboard auto-populates. Customise it
  under *Overview -> Edit dashboard*.
- **Automations:** *Settings -> Automations*. Start with "turn living-room
  lights on at sunset."
- **Backups:** *Settings -> System -> Backups*. Schedule weekly.
- **Remote access:** Nabu Casa Cloud ($6.50/mo) or self-hosted via Tailscale
  / WireGuard. Do **not** port-forward 8123 to the internet.
- **Node-RED** (optional): add as a fourth service if you want a visual
  flow-based automation editor on top of HA.
