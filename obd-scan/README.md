# OBD-II scan tool connection check

For when a car scan tool (ELM327-style OBD-II adapter) won't connect, or
connects to the computer but never reaches the car.

## Files

- `obd_connect.py` - finds the adapter, connects, and checks each layer:
  transport -> adapter (AT commands) -> vehicle bus (OBD mode 01). Prints a
  numbered fix list for whichever layer fails. **Read-only**: it never
  clears codes or writes to an ECU.

## Install

```bash
python3 -m pip install pyserial   # USB + Bluetooth Classic adapters
python3 -m pip install bleak      # BLE adapters (optional)
```

Wi-Fi adapters need nothing extra.

## Run it

Plug the adapter into the car, ignition **ON** (dash lit) or engine running, then:

```bash
python3 obd_connect.py                         # auto-discover serial, Wi-Fi, BLE
python3 obd_connect.py --list                  # just show what it can see
python3 obd_connect.py --port /dev/cu.OBDII-SPPDev
python3 obd_connect.py --port COM5             # Windows
python3 obd_connect.py --host 192.168.0.10     # Wi-Fi (join the adapter's network first)
python3 obd_connect.py --ble                   # BLE scan + connect
python3 obd_connect.py --dtc --live 15         # also read codes + 15 s of RPM/speed
python3 obd_connect.py --protocol 6            # force CAN 11-bit/500k if auto-detect hangs
```

Exit code is 0 only if the car's ECU actually answered.

## Which kind of adapter do I have?

| Adapter type | How it shows up | What to pass |
| ------------ | --------------- | ------------ |
| USB cable | `/dev/cu.usbserial-*`, `/dev/cu.wchusbserial*` (Mac), `/dev/ttyUSB0` (Linux), `COMx` (Windows) | `--port` or auto |
| Bluetooth Classic (most cheap blue ELM327s) | Pair first (PIN `1234`/`0000`), then `/dev/cu.<name>` or `COMx` | `--port` or auto |
| Bluetooth LE (Vgate iCar Pro BLE, Veepeak BLE+, OBDLink CX) | **No serial port on a Mac**, don't pair in Settings | `--ble` |
| Wi-Fi | Its own Wi-Fi network, usually `192.168.0.10:35000` | `--host` or auto |

## What it checks

| Step | Check | Typical failure |
| ---- | ----- | --------------- |
| Discovery | Serial ports, common Wi-Fi addresses, BLE scan | Not paired / BLE adapter looked for as serial / Mac lacks Bluetooth permission |
| Connect | `ATZ` reset at 38400, 9600, 115200, 230400, 500000 baud | Port busy (another app), wrong port, adapter unpowered |
| Adapter | `ATI`, `AT@1`, `STI` chip ID; `ATRV` voltage | v2.1 clone, adapter not seated, weak battery |
| Vehicle | `0100` handshake, `ATDPN` protocol | `UNABLE TO CONNECT`, `BUS INIT ERROR`, `CAN ERROR`, `NO DATA` |
| Quick read | MIL + code count, RPM, speed, coolant, ECU volts | - |
| `--dtc` | Mode 03 stored + mode 07 pending codes | - |

## Most likely fixes

1. **Ignition not ON.** Accessory is not enough; most ECUs only answer with
   the dash fully lit or the engine running.
2. **macOS + BLE adapter.** It will never appear under `/dev`. Use `--ble`,
   and give Terminal Bluetooth access (System Settings > Privacy & Security >
   Bluetooth).
3. **Another app holds the adapter.** Phone apps (Torque, Car Scanner, etc.)
   keep Bluetooth/Wi-Fi adapters busy. Close them or turn the phone's Bluetooth off.
4. **Clone "ELM327 v2.1".** Fine on most CAN cars (2008+), unreliable on
   older K-line / J1850 vehicles.
5. **Wi-Fi adapter.** The computer must be joined to the adapter's network,
   and macOS may hop back to home Wi-Fi because the adapter has no internet.

Run it, paste the Summary + Fixes block back, and I'll point at the exact fix.
