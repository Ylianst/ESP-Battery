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
