# ESP Battery Dashboard

A native Flutter Windows application for the ESP32 RS485-to-TCP bridge. It is
read-only: passive monitoring sends no bytes, while optional active polling sends
measurement/status read requests only (never battery control or write commands).

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

By default, the bridge must already have ASCII PACE traffic from an inverter,
a master battery or another bus controller. An idle connection remains open
indefinitely. Batteries are discovered from validated replies, not address scans.

### Optional active polling

Before connecting, turn on **Enable active polling**, choose a protocol and enter
comma-separated decimal **Battery addresses** (default `1,2,3,4`):

- **Modbus RTU (PACE register map)**: slaves `1-247`; the default active protocol.
  Uses binary RTU frames with CRC over the raw TCP bridge, **not Modbus TCP**.
  Address `0` is broadcast and cannot be polled.
- **ASCII PACE**: direct addresses `0-15`; sends version `25` reads `42`/`44`
  and accepts version `20` or `25` replies. No aggregate `FF` or fixed-destination
  routing is provided by this UI.

Only one request is outstanding: a two-second reply timeout and a 250 ms delay
between requests, cycling through the selected addresses. Timeouts, exceptions,
transmitted requests and corrupt/unexpected replies appear in the traffic
inspector. Polling stops on disconnect, connection failure or application exit.
Disconnect before changing protocol/addresses or disabling polling.

**Use only one polling master on an RS485 bus.** Stop other pollers/inverters on
that same bus before enabling this option. Select the battery's compatible wire
protocol; similarly named battery menu settings do not guarantee compatibility.
In the [observed SG48100 installation](../../README.md#equipment-and-rs485-polling),
switching battery 1's inverter setting from PYLON to PACE enabled **Modbus slave
1**, while slaves 2-4 timed out and ASCII stopped responding. One slave does not
prove access to all four physical packs. Previously, passive ASCII exposed packs
2-4 only. This app does not change battery configuration or auto-detect protocols.

Later [live four-pack testing](../../README.md#four-pack-discovery-and-bus-specific-numbering)
on `recliner.local:1234` successfully read all four packs with the Node.js PACE
poller using **destination 0, protocol 20 and INFO selectors 2,3,4,5**.
The inverter-bus numbering appears offset by +1 from the inter-battery addresses:
selectors 3-5 match passive batteries 2-4 by cell-voltage patterns; selector 2
is likely battery 1 by elimination. Do not equate the displayed protocol
address/selector with a physical battery's DIP-switch address.
The dashboard does not currently offer those exact fixed-destination/version
settings; this result verifies the CLI command, not the dashboard's active mode.
Passive monitoring on `sunpower.local:1234` still exposes batteries 2-4 only.

## Dashboard

- One card per responding battery, sorted by address.
- Pack voltage, signed current, power, remaining/full capacity, reported Modbus
  SOC or calculated ASCII SOC (clearly labeled),
  cycle count and minimum-to-maximum cell spread.
- Individual voltage values for every cell, with detail-scale bar charts and
  minimum/maximum highlighting. The vertical scale is explicitly labeled.
- Every temperature sensor, with its numeric value and bar graphic. Sensor roles
  are unknown for ASCII; Modbus temperature ordering is documented in protocol
  details. Bar ranges are visual scales, **not alarm thresholds**.
- A rolling voltage trend containing up to 120 samples per battery.
- Available cell/temperature warning codes and protocol-specific status registers.
  Instruction/control/balance bits, unknown version-20 registers and Modbus
  status/fault bits are not treated as confirmed warnings themselves.
- A traffic inspector with the latest 80 events, raw ASCII frames or RTU hex, checksum
  failures, unsupported payloads and connection errors.
- Raw vendor flags, pack-number/address fields and extension bytes under each
  card's **Protocol details & vendor fields** section.

Measurements and warnings have independent timestamps. Data older than 30
seconds is stale. Disconnecting retains the last readings but marks them stale;
connecting again starts a fresh session and clears old readings/history. Errors
and remote disconnects are displayed explicitly; reconnecting is manual.

## Protocol limitations

The experimental ASCII decoder targets the same PACE `20`/`25` / CID1 `46` single-pack
layout as the [Node.js monitor](../rs485-monitor.js), observed on SG48100 batteries.
It validates both checksums and frame lengths and reassembles frames across TCP
chunks. Replies are matched to the latest request for their address within five
seconds in passive mode (two seconds for active polling). Requests `42`, `44`
and `90` are recognized. Version `20` exposes eight raw status bytes with unknown
meanings, rather than applying version `25`'s twelve-register names.

Pack/cell voltages use millivolts, current uses signed 0.01 A, capacities use
0.01 Ah and temperatures use `(raw - 2731) / 10` degrees C. SOC is calculated as
remaining/full capacity, not taken from a reported SOC field. Current polarity,
unknown status-bit meanings and vendor extensions are not inferred. Other battery
models/firmware and multi-pack reply layouts may differ; unsupported data remains
visible in the inspector instead of generating invented readings.

Modbus uses holding-register reads (function `03`), following the map used by
[syssi/esphome-pace-bms](https://github.com/syssi/esphome-pace-bms):

| Registers | Values |
|---|---|
| 0-7 | Signed 0.01 A current, 0.01 V voltage, reported SOC/SOH, remaining/full/design 0.01 Ah capacities, cycles |
| 9-12 | Raw warning, protection, status/fault and balance registers |
| 15-36 | Sixteen 0.001 V cells and six signed 0.1 C temperatures (battery 1-4, MOSFET, environment) |

Modbus measurements are published only after both basic and cell/temperature
blocks arrive in the same polling sweep. Missing blocks produce explicit
timeouts/issues; previous complete readings age normally and become stale.
Per-cell warning codes and ASCII flags are not invented for Modbus. SOC uses the
battery-reported value, which may differ from remaining/full capacity.
Passive mode decodes ASCII only; Modbus needs active request correlation.

RTU replies contain neither a transaction ID nor the starting register address;
slave/CRC/byte-count checks and sequential reads reduce ambiguity, but a very
late response with the same shape can still be ambiguous.

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
passive zero-transmit TCP behavior, active mock-bridge polling for both protocols,
captured Modbus telemetry, timeout/exception recovery, disconnect/reconnect
cleanup, discovery, bounded history, freshness and responsive polling controls.
The passive live test is skipped unless explicitly enabled:

```powershell
flutter test test\live_connection_test.dart --dart-define=LIVE_HOST=sunpower.local --dart-define=LIVE_PORT=1234
```
