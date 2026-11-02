# ESP Battery Dashboard

A native Flutter Windows application for the ESP32 RS485-to-TCP bridge. It is
read-only: the app never sends commands to the batteries.

If you have the prebuilt Windows ZIP, extract **all** its contents into one folder
and run `battery_dashboard.exe`. The Flutter SDK is not needed to run that bundle.

## Run

Install Flutter with Windows desktop support and the Visual Studio **Desktop
development with C++** workload. The project currently uses Dart 3.13.7 or newer.

From this directory:

```powershell
flutter pub get
flutter run -d windows
```

Enter the ESP32 **hostname or IP address** and **TCP port**, then click
**Connect**. Defaults are `sunpower.local` and `1234`. If `.local` name resolution
is unavailable on your computer, use the ESP32's IP address instead. The port
must match the ESPHome `espbattery.port` setting.

The bridge must already have traffic from an inverter, a master battery or
another bus controller. This app does not poll the bus. It discovers batteries
from validated replies, not from scans of unused addresses. In the
[observed SG48100 installation](../../README.md#equipment-and-rs485-polling),
battery 1 polls batteries 2-4 but not itself, so only batteries 2-4 appear in the
dashboard. The default DIP-switch address of 0 produced no traffic on that bus.
An idle connection remains open indefinitely.

## Dashboard

- One card per responding battery, sorted by address.
- Pack voltage, signed current, power, remaining/full capacity, calculated SOC,
  cycle count and minimum-to-maximum cell spread.
- Individual voltage values for every cell, with detail-scale bar charts and
  minimum/maximum highlighting. The vertical scale is explicitly labeled.
- Every temperature sensor, with its numeric value and bar graphic. Sensor roles
  are unknown; bar ranges are visual scales, **not alarm thresholds**.
- A rolling voltage trend containing up to 120 samples per battery.
- Cell/temperature warning codes and all twelve status registers. Instruction,
  control and balancing bits are not treated as warnings themselves.
- A traffic inspector with the latest 80 events, raw ASCII frames, checksum
  failures, unsupported payloads and connection errors.
- Raw vendor flags, pack-number/address fields and extension bytes under each
  card's **Protocol details & vendor fields** section.

Measurements and warnings have independent timestamps. Data older than 30
seconds is stale. Disconnecting retains the last readings but marks them stale;
connecting again starts a fresh session and clears old readings/history. Errors
and remote disconnects are displayed explicitly; reconnecting is manual.

## Protocol limitations

The experimental decoder targets the same PACE `25` / CID1 `46` single-pack
layout as the [Node.js monitor](../rs485-monitor.js), observed on SG48100 batteries.
It validates both checksums and frame lengths and reassembles frames across TCP
chunks. Replies are matched to the latest request for their address within five
seconds. Requests `42`, `44` and `90` are recognized.

Pack/cell voltages use millivolts, current uses signed 0.01 A, capacities use
0.01 Ah and temperatures use `(raw - 2731) / 10` degrees C. SOC is calculated as
remaining/full capacity, not taken from a reported SOC field. Current polarity,
unknown status-bit meanings and vendor extensions are not inferred. Other battery
models/firmware and multi-pack reply layouts may differ; unsupported data remains
visible in the inspector instead of generating invented readings.

This is a diagnostic display, not a safety/protection controller. The TCP bridge
is unencrypted and unauthenticated; use it only on a trusted network. Raw TCP is
not available to Flutter web, so a browser build is not supported. Only Windows
platform scaffolding is included.

## Build and test

```powershell
flutter analyze
flutter test
flutter build windows --release
```

The executable is `build\windows\x64\runner\Release\battery_dashboard.exe`.
Keep **all files and the data directory** from that release folder together when
copying it to another computer; copying the executable alone is insufficient.
Clean computers may also need the Microsoft Visual C++ x64 Redistributable
required by Flutter's Windows runtime.

Tests cover framing, checksums, units, malformed payloads, response correlation,
read-only TCP behavior, discovery, disconnects, bounded history, freshness and
responsive layouts. The live test is skipped unless explicitly enabled:

```powershell
flutter test test\live_connection_test.dart --dart-define=LIVE_HOST=sunpower.local --dart-define=LIVE_PORT=1234
```
