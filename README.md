# ESP-Battery

ESPHome external component for SunGold SG48100 batteries (and similar) that communicate over RS485.

The goal is to read the batteries' RS485 traffic, decode it and publish the values as ESPHome / Home Assistant sensors. At this stage, the protocol is not yet decoded, so the component acts as a **transparent RS485-to-TCP forwarder**:

- Every byte received on the RS485 bus is sent to all connected TCP clients.
- Every byte received from a TCP client is written to the RS485 bus (with the optional flow control / DE pin asserted while transmitting).

This allows capturing and experimenting with the battery protocol from a PC (e.g. using `nc`, PuTTY in raw mode, or a custom tool) while the ESP32 stays connected to the batteries.

## Hardware

- An ESP32 board
- An RS485 transceiver (e.g. M5Stack ATOM Lite + ATOM Tail485, or any MAX485-style module)

See [Supported Devices](documentation/devices.md) for tested hardware and the matching `uart` / GPIO settings.

See [Additional Information Sources](documentation/additional-sources.md) for
battery/inverter manuals, official monitoring software, owner forums and
community protocol references.

## Sample ESPHome configuration

```yaml
esphome:
  name: battery
  friendly_name: Battery

esp32:
  board: m5stack-atom
  framework:
    type: arduino

logger:
  baud_rate: 0

api:
  encryption:
    key: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

ota:
  - platform: esphome
    password: "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password

external_components:
  - source: github://ylianst/esp-battery

# Make sure tx/rx pins are correct for your device.
# GPIO26/32 is ok for M5Stack-ATOM + Tail485.
# Check the baud rate used by your batteries (9600 is common for SG48100 RS485).
uart:
  id: BatteryConnection
  tx_pin: GPIO26
  rx_pin: GPIO32
  baud_rate: 9600

espbattery:
  uart_id: BatteryConnection
  port: 1234
  # buffer_size: 256
  # flow_control_pin: GPIO33
```

## Configuration variables

| Option             | Default | Description |
|--------------------|---------|-------------|
| `uart_id`          |         | ID of the `uart` component connected to the RS485 transceiver. |
| `port`             | `1234`  | TCP port to listen on. Set to `0` to disable the TCP server. |
| `buffer_size`      | `256`   | Size of the RS485-to-TCP ring buffer. Must be a power of two. |
| `flow_control_pin` |         | Optional GPIO driven high while transmitting on RS485 (DE/RE pin for transceivers without automatic direction control). |

## Capturing traffic

Once the device is running, connect to it with any raw TCP client, for example:

```
nc battery.local 1234 | xxd
```

### Node.js monitor

With Node.js 18 or newer installed, no npm dependencies are needed:

```sh
node tools/rs485-monitor.js battery.local
node tools/rs485-monitor.js 192.168.1.100 1234
```

The monitor decodes received PACE-style commands and replies until you press
**Ctrl-C**. Decoding is experimental and currently targets protocol `25`, device
type `46`, and the single-pack reply layout observed with SG48100 batteries.
The host is required; the port defaults to `1234` and must match the ESPHome
`port` setting. The monitor only receives traffic and never sends bytes to the bus.

The decoder validates frame lengths and checksums, identifies measurement
(`42`), warning/status (`44`) and pack-number (`90`) requests, and matches replies
to the latest request for the same battery within five seconds. Measurement
replies show pack voltage/current, capacities, calculated state of charge
(remaining/full capacity, not a reported SOC field), cycles, cell voltages and
temperatures. Warning replies show per-cell/per-temperature codes and status
registers; vendor-specific bit meanings and extension fields are not guessed.
Unmatched replies, unknown commands/layouts and undecoded payloads remain visible
as hex. Corrupt, incomplete and unframed data are explicitly reported.

Protocol framing follows the community
[PACE protocol reference](https://github.com/SPDG/pace-bms-mqtt-bridge/blob/main/docs/PROTOCOL.md).
The observed measurement layout uses millivolts for both pack/cell voltage,
0.01 A for current, 0.01 Ah for capacities and `(raw - 2731) / 10` degrees C for
temperatures. Pack voltage scaling also agrees with the
[PACE v25 implementation](https://github.com/nkinnan/esphome-pace-bms/blob/main/components/pace_bms/pace_bms_protocol_v25.cpp)
and the observed sum of cell voltages.
Other battery models/firmware may use different layouts.

Use `--raw` for the readable ASCII command display, without protocol decoding:

```sh
node tools/rs485-monitor.js sunpower.local 1234 --raw
```

In ASCII mode, CR, LF and CR/LF become line breaks, so commands remain on one line
even when split across TCP chunks. Other nonprintable or non-ASCII bytes are
shown as `\xNN`. `--raw` is a readable display, not byte-for-byte binary capture.

Use `--hex` for hexadecimal output (one line per TCP chunk, not necessarily an
RS485 packet):

```sh
node tools/rs485-monitor.js battery.local 1234 --hex
```

Display command-line help without connecting:

```sh
node tools/rs485-monitor.js --help
```

The `--hex` and `--raw` options are mutually exclusive.

Connection messages and errors go to stderr, separate from the captured data.
The monitor exits with an error on connection failure or remote disconnect; it
does not reconnect automatically. Initial connection attempts time out after
10 seconds, but an established connection can remain idle indefinitely.
Ctrl-C closes the socket and exits with code `130`.

Run the monitor's tests with:

```sh
node --test tools/rs485-monitor.test.js tools/rs485-decoder.test.js
```

### Flutter graphical dashboard

The [Flutter dashboard](tools/battery_dashboard/README.md) provides a native
Windows interface with configurable hostname/port, automatic discovery of
responding batteries, SOC gauges, individual cell-voltage charts, temperature
bars, voltage history and warning/status details.

```powershell
cd tools\battery_dashboard
flutter pub get
flutter run -d windows
```

Defaults are `sunpower.local:1234`. The dashboard is read-only and relies on
existing polling traffic from your inverter/controller. It marks stale readings
and exposes unknown vendor fields without guessing their meanings.
