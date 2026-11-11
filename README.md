# ESP-Battery

ESPHome external component for SunGold SG48100 batteries (and similar) that communicate over RS485.

The goal is to read the batteries' RS485 traffic, decode it and publish the values as ESPHome / Home Assistant sensors. At this stage, the protocol is not yet decoded, so the component acts as a **transparent RS485-to-TCP forwarder**:

- Every byte received on the RS485 bus is sent to all connected TCP clients.
- Every byte received from a TCP client is written to the RS485 bus (with the optional flow control / DE pin asserted while transmitting).

This allows capturing and experimenting with the battery protocol from a PC (e.g. using `nc`, PuTTY in raw mode, or a custom tool) while the ESP32 stays connected to the batteries.

An optional **CAN-to-TCP relay** uses a separate port and SLCAN ASCII frames.
RS485-only, CAN-only and simultaneous RS485/CAN configurations are supported.

## Hardware

- An ESP32 board
- An RS485 transceiver (e.g. M5Stack ATOM Lite + ATOM Tail485, or any MAX485-style module)

See [Supported Devices](documentation/devices.md) for tested hardware and the matching `uart` / GPIO settings.

For the battery-to-battery bus, see the [SG48100 RS485 wiring pinout](documentation/devices.md#sg48100-battery-to-battery-rs485-pinout): pins **3 and 6 are ground**, while pins **4 and 5 are floating (unconnected)**.

See [Additional Information Sources](documentation/additional-sources.md) for
battery/inverter manuals, official monitoring software, owner forums and
community protocol references.

## Observed installation and operating notes

These are owner-reported observations and live diagnostic results from this
installation, not manufacturer specifications or behavior verified for every
battery/inverter configuration.

### Equipment and RS485 polling

- Two BluePower SP6548 inverters (the supplied manual is
  [BluePower_SP6548-20231129](documentation/BluePower_SP6548-20231129.md)) and four
  [SG48100 batteries](documentation/SG48100.md) are available. Only one inverter
  is installed, and it is connected to all four batteries.
- `sunpower.local:1234` bridges the **battery-to-battery RS485 bus**;
  `recliner.local:1234` bridges the **battery's RS485A/inverter bus**.
- The batteries arrived with their DIP-switch addresses set to **0**. With that
  default configuration, no traffic was observed on this bus. Setting one
  battery to **address 1** makes it poll the other batteries; in this installation
  the four batteries use addresses **1, 2, 3 and 4**. Consult the battery manual
  for the DIP-switch positions corresponding to each address.
- Battery 1 **does not poll itself** on this bus. As currently connected, the
  ESP32 therefore receives data only for batteries **2, 3 and 4**. Passive
  monitoring cannot show battery 1's readings when they are absent from the
  captured traffic; its missing data does not by itself indicate a bridge or
  decoder failure.

### Four-pack discovery and bus-specific numbering

Live testing on November 10, 2026 confirmed passive traffic on
`sunpower.local:1234`: 4,312 received bytes in 25 seconds, including
checksum-valid protocol `25` measurement/status exchanges for batteries **2,
3 and 4**. No bytes were transmitted by the listener.

On `recliner.local:1234`, a repeated read-only sweep successfully retrieved
**four distinct packs** using frame destination **0**, protocol **20**, CID1
`46`, commands `42`/`44`, and INFO pack selectors **2, 3, 4 and 5**.
The frame destination and INFO selector are separate fields; these selector
numbers must not be assumed to equal DIP-switch/inter-battery addresses.

| Inter-battery address / likely physical battery | Inverter-bus INFO selector | Pack voltage (V) | Calculated SOC |
| --- | --- | --- | --- |
| 1 (inferred by elimination) | 2 | 53.711 | 73.3% |
| 2 | 3 | 53.736 | 72.8% |
| 3 | 4 | 53.727 | 72.3% |
| 4 | 5 | 53.725 | 73.0% |

The apparent **+1 numbering offset** is installation-specific: mappings for
inter-battery addresses 2-4 are inferred from matching individual cell-voltage
patterns and capacities across the two buses. The remaining selector 2 is
therefore likely physical battery 1; this is not independently confirmed by a
serial number or battery display. Voltages and SOC above are snapshots using
the experimental PACE decoder, not proof of all vendor-specific units.
Each pack returned sixteen cell voltages, five temperatures and status data on
the inverter bus; the passive inter-battery replies contained six temperatures.

From the repository root, the verified all-four-pack command is:

```powershell
node tools\rs485-poll.js recliner.local 1234 --destination 0 --addresses 2,3,4,5 --protocol 20 --timeout 8000 --delay 500 --once
```

**Use only as the sole polling master on that RS485 bus.** The owner confirmed
that no inverter or other master was polling during this test. A quiet capture
alone does not establish that active polling is safe. Do not actively poll the
inter-battery bus alongside battery 1's existing polling.

At destination 0, selectors 0 and 1 returned only `0000` and `0001`, respectively;
selectors 6 and `FF` returned zero-valued placeholder measurements. These
checksum-valid success replies are **not additional batteries or usable
all-pack data**. Direct destination 1 also timed out. Earlier tests restricted
to selectors 1-4 missed selector 5 and incorrectly left the fourth pack
unaccounted for; the working inverter-bus selector range is **2-5**, not 1-4.

### Inverter idle load and AC charging

- The installed inverter consumes approximately **40-60 W while idling**. This
  overhead must be included in the system's energy budget, especially when
  charging slowly.
- Connecting the inverter's AC input to a GFCI-protected outlet trips the GFCI in
  this installation. The owner was told this is normal, but the cause and
  compatibility have not been verified.
- The owner-reported temporary charging setup uses an extension cord from a
  non-GFCI outlet with the inverter limited to **10 A**. A Kill-A-Watt reports
  approximately **600 W of AC input power**, resulting in slow charging. This is
  an input measurement, not measured power delivered to the batteries; inverter
  consumption and conversion losses reduce the power available for charging.

**Electrical safety:** The temporary setup above is an observation, not a
recommended workaround. Do not bypass required GFCI protection or assume a trip
is harmless. Have the manufacturer and a qualified electrician verify the cause,
grounding, required protection and a compliant AC supply. Any cord and circuit
must be suitable for the load and installation.

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
| `uart_id`          |         | ID of the `uart` component connected to the RS485 transceiver; mutually exclusive with `canbus_id`. Existing implicit UART selection is supported. |
| `canbus_id`        |         | ID of an ESPHome `canbus` component; selects CAN/SLCAN instead of raw UART. |
| `port`             | `1234`  | TCP port to listen on. Set to `0` to disable the TCP server. |
| `buffer_size`      | `256`   | Outgoing ring buffer size in bytes, per relay. Must be a power of two; at least 32 for CAN. |
| `flow_control_pin` |         | UART only: optional GPIO driven high while transmitting on RS485 (DE/RE pin for transceivers without automatic direction control). |

### Simultaneous RS485 and CAN

Use a list of `espbattery` instances with different nonzero TCP ports. Existing
single-instance UART configurations do not need to change. Each instance has
independent clients, buffers and transport; CAN traffic is never sent to UART.
Set an instance's `port: 0` to disable its TCP listener.

For the Waveshare ESP32-S3-POE-ETH-8DI-8DO, keep the UART definition above but use
TX **GPIO17**, RX **GPIO18**, and the following CAN/bridge definitions:

```yaml
canbus:
  - platform: esp32_can
    id: BatteryCAN
    tx_pin: GPIO2
    rx_pin:
      number: GPIO3
      ignore_strapping_warning: true
    can_id: 0
    bit_rate: 500kbps

espbattery:
  - id: rs485_bridge
    uart_id: BatteryConnection
    port: 1234
    flow_control_pin: GPIO21
  - id: can_bridge
    canbus_id: BatteryCAN
    port: 1235
    buffer_size: 1024
```

The [complete recliner configuration](esphome/recliner-rs485.md) includes both
relays and the existing accessories and I/O. It contains YAML to copy into your
ESPHome configuration; provide its referenced secrets separately. The
[Waveshare pin table](https://www.waveshare.com/wiki/ESP32-S3-POE-ETH-8DI-8DO)
documents CAN TX/RX as GPIO2/GPIO3. Verify your exact board revision, match the
bus bitrate, and check CAN H/L wiring, ground and termination. Do not assume the
battery CAN connector has the same pinout as its RS485 connector.

The GitHub external-component source requires these changes to be published
and its cached copy refreshed before compiling. To test this checkout instead,
save your YAML in `esphome/` and replace its `external_components` block with:

```yaml
external_components:
  - source:
      type: local
      path: ../components
    components: [espbattery]
```

### CAN TCP protocol

Port **1235** carries classic CAN (0-8 bytes) as SLCAN **frame records**, not raw
UART bytes or SocketCAN binary structures. Every record ends with carriage
return (`\r`); an optional following line feed is accepted. Supported records:

| Record | Meaning | Example |
| --- | --- | --- |
| `tIIILDD...` | 11-bit data frame; 3 hex ID digits, 1 length digit, 2 hex digits per byte | `t1232AABB\r` |
| `TIIIIIIIILDD...` | 29-bit data frame; 8 hex ID digits | `T18FF50E52AABB\r` |
| `rIIIL` | 11-bit remote request, requested length but no data | `r1238\r` |
| `RIIIIIIIIL` | 29-bit remote request | `R18FF50E58\r` |

Incoming CAN frames are broadcast to all CAN TCP clients. Records from each TCP
client are reassembled independently across TCP chunks and transmitted onto CAN.
Received output uses uppercase hex; input accepts either case. Transmitted
records are not software-echoed to clients. Invalid/oversized records disconnect
the sender and log a warning without transmitting that record. Slow receivers
are disconnected on buffer overflow rather than corrupting CAN record boundaries.

This is a **frames-only SLCAN subset**: there are no adapter-control commands
(`O`, `C`, `S`, etc.), timestamps, acknowledgements or CAN FD support. The CAN
controller starts with ESPHome; configure bitrate and controller mode there,
not over TCP. Full SLCAN adapter clients that require control-command responses
are not compatible without a frames-only mode. CAN transmission errors are logged
by ESPHome; there is no per-frame TCP delivery confirmation.

Receive without transmitting:

```sh
nc recliner.local 1235
```

Both TCP listeners are unauthenticated and unencrypted; any connected client
can transmit on the corresponding bus. Use only on a trusted network, do not
expose these ports to the Internet, and only send frames understood by the
connected equipment. Existing RS485 tools and dashboard still use **1234**;
they do not decode CAN.

### Component tests

With ESPHome installed, run configuration validation and C++ generation tests:

```sh
python -m unittest discover -s tests -p test_espbattery_config.py -v
```

The SLCAN parser tests run on a desktop C++17 compiler without ESPHome:

```sh
c++ -std=c++17 -Wall -Wextra -Werror tests/slcan_test.cpp -o slcan_test
./slcan_test
```

On Windows, run `cl /std:c++17 /EHsc /W4 /WX tests\slcan_test.cpp` from a
Visual Studio Developer Command Prompt, then run `slcan_test.exe`.

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
**Ctrl-C**. Decoding is experimental and currently targets protocols `20`/`25`, device
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
Protocol `20` warning replies use the observed eight-byte status block, shown
as `register1` through `register8` without assuming protocol `25` field meanings.
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

### Active Node.js PACE poller

[rs485-poll.js](tools/rs485-poll.js) sends read-only PACE measurement (`42`)
and warning/status (`44`) requests, then decodes replies using the same decoder
as the passive monitor. Node.js 18 or newer is required; no npm dependencies
or ESP32 firmware changes are needed.

**Use only as the sole polling master on the connected RS485 bus.** Do not run
it alongside an inverter, another active TCP client, or battery 1's existing
inter-battery polling. A quiet passive capture does not prove a bus is unused;
verify the connection and configuration first. This tool is a diagnostic reader,
not a replacement for an inverter's BMS control/limit exchange.

For an ESP32 connected to the battery's RS485A/inverter port:

```sh
node tools/rs485-poll.js recliner.local 1234
node tools/rs485-poll.js recliner.local 1234 --once --raw
```

By default it repeatedly queries batteries **1, 2, 3 and 4**, measurements then
warnings for each address, with only one outstanding request at a time.
The response timeout is 2000 ms; a 250 ms gap follows each response or timeout.
Locally transmitted requests are fed into the decoder because the bridge does
not echo TCP writes. `--raw` adds direction-labelled TX/RX byte displays with
escaped CR/LF while retaining decoded output. RX chunks are not frame boundaries.
No configuration/control commands, broadcast queries or automatic protocol scans
are sent.

Initial live testing received checksum-valid protocol `20` replies for addresses 2-4
after protocol `25` requests; these replies use the supported measurement/status
layout. Both reply versions are accepted. Battery 1 did not reply in that test,
including with protocol `20` requests and a five-second timeout. Subsequent
[four-pack discovery](#four-pack-discovery-and-bus-specific-numbering) found
all four packs using destination 0 and INFO selectors **2-5**; inverter-bus
selectors are not the physical/inter-battery addresses. Other configurations may expose
only battery 1 or aggregate bank data, or require a different configured
inverter protocol/address. The tool cannot
make batteries 2-4 individually accessible if that port does not expose them.
It uses the same experimental SG48100 single-pack layout as the monitor and
leaves unfamiliar payloads visible rather than guessing their meaning.

Limit addresses or adjust timing when diagnosing the port:

```sh
node tools/rs485-poll.js recliner.local --addresses 1 --timeout 3000 --delay 500 --raw
node tools/rs485-poll.js recliner.local --addresses 1 --protocol 20 --once --raw
node tools/rs485-poll.js recliner.local --master-ff --once --raw
node tools/rs485-poll.js recliner.local --addresses 0 --once --raw
node tools/rs485-poll.js recliner.local --destination 0 --addresses 1,2,3,4,FF --timeout 8000 --once --raw
node tools/rs485-poll.js --help
```

Requests default to protocol `25`; `--protocol 20` selects version `20`.
`--master-ff` uses INFO byte `FF` for address 1's measurement/status requests,
followed by normal INFO bytes `02`, `03`, `04` for the other default addresses.
The first request is `~25014642E002FFFD05\r`, as used by the
[syssi RS232 test](https://github.com/syssi/esphome-pace-bms/blob/main/tests/esp8266-rs232-test.yaml).
The destination remains `01`, not broadcast `FF`; RS485 support and the meaning
of any aggregate reply still require verification. Without this option,
address 1's INFO byte remains `01`.
Live testing also received no response from address 1 with INFO `FF`, using
protocol `25` or protocol `20` (the latter with a five-second timeout).
Without `--destination`, addresses are unique decimal values from 0 to 15;
address 0 uses destination `00` and INFO `00`. Defaults remain 1-4; the meaning and availability of address 0
depend on the battery's configured protocol. In live testing, address 0 returned
checksum-valid protocol `20` success replies with payload `0000` for both reads,
but no decodable measurements or status.

`--destination 0` fixes the frame destination at `00` and uses `--addresses`
as independent INFO pack selectors. With an explicit destination, the list may
also contain `FF` to request all packs, without sending to a broadcast frame
address. Do not combine `--destination` and `--master-ff`; use an explicit `FF`
selector instead. Replies are matched by frame destination; single-pack layouts
are checked against the requested INFO selector. All-pack payloads remain visible
as hex without assuming a layout or assigning aggregate data to a single pack.

Initial live testing of destination `00` with INFO `01`-`04` and `FF` returned
checksum-valid protocol `20` success replies for every request. INFO `02`-`04`
provided the expected individual measurements and status. INFO `01` returned
only `0001` for both commands, including when requested with protocol `20`;
selector `01` did not contain measurements. INFO `FF` returned a single-pack-shaped
payload with zero-valued measurements, not usable readings for all four packs.
These protocol success replies alone do not establish that the requested data
is present. Later testing added INFO `05` and verified four real packs at
selectors **02-05**, as documented in the
[bus-specific numbering table](#four-pack-discovery-and-bus-specific-numbering).

`--timeout` accepts 1-60000 ms and also sets the active decoder's matching window;
the passive monitor retains its five-second window. An 8000 ms timeout allows
time for four-pack aggregation; it does not establish protocol compatibility.
`--delay` accepts 1-60000 ms. PACE replies do not contain the requested command,
so very late replies can be ambiguous; increase the timeout if replies arrive
late. Timeouts and rejected requests are reported to stderr and polling continues.
`--once` exits after one sweep with code `1` for any timeout/rejected request,
otherwise `0`. A successful protocol response is not a guarantee that its
vendor-specific payload layout is understood. Connection failures/disconnects
exit `1`; Ctrl-C exits `130`. There is no automatic reconnect.

If nothing responds, check the selected battery protocol, UART baud/parity,
connector pinout, addressing, and RS485 transmit direction control
(`flow_control_pin` when required by the transceiver). Receiving passive traffic
alone does not verify that the ESP32 can transmit.

Run the poller, monitor and shared decoder tests with:

```sh
node --test tools/rs485-poll.test.js tools/rs485-monitor.test.js tools/rs485-decoder.test.js
```

### Active Node.js PYLON poller

[rs485-pylon-poll.js](tools/rs485-pylon-poll.js) is a separate read-only poller
for an RS485A/inverter port configured as **PYLON**. It uses the existing
transparent TCP bridge, Node.js 18+, and no npm dependencies or firmware changes.
The inter-battery port can still use PACE while the inverter port uses PYLON;
seeing PACE traffic does not establish the inverter port's selected protocol.

**Use only as the sole polling master on that bus.** Do not run alongside the
inverter or another poller. Do not disconnect or change an operating inverter's
BMS communication without following its safe shutdown procedure. This diagnostic
reader does not replace the inverter's BMS control/limit exchange.

```sh
node tools/rs485-pylon-poll.js recliner.local 1234 --once --raw
node tools/rs485-pylon-poll.js recliner.local --destination 0 --once --raw
node tools/rs485-pylon-poll.js recliner.local --destination 1 --once --raw
node tools/rs485-pylon-poll.js recliner.local --destination 0 --addresses 1,2,3,4 --once --raw
node tools/rs485-pylon-poll.js --help
```

By default it sends version `20`, CID1 `46`, measurement `42` then warning `44`
requests to **destination 2 with INFO FF** (all modules). Destination 2 follows
the [Pylontech reference implementation](https://github.com/Frankkkkk/python-pylontech);
it is **not a verified SG48100 address**. Set `--destination` to the configured
master address. `--addresses` selects INFO bytes independently: unique decimal
values 0-15 or `FF`. These are explicit diagnostic alternatives, not an automatic
protocol/address scan. Whether all packs, the master only, or aggregate readings
are available depends on firmware. **Full SG48100 PYLON compatibility remains
unverified.** Keep the battery configured for its inverter's protocol.

Live testing against `recliner.local:1234` on November 10, 2026 received
checksum-valid version `20` measurement and warning replies using destination
`00` with INFO `02`, `03` and `04`. Pack voltages were approximately 53.862,
53.886 and 53.881 V, respectively, with sixteen cell voltages per pack.
INFO `01` returned only `0001`; INFO `00` returned only `0000`, neither containing
measurements. Destination `01` did not respond to INFO `FF`, `01` or `00`
(individual selectors tested with a five-second timeout). INFO `FF` at
destinations `00` and `02` returned a single-pack-shaped, zero-measurement payload
starting `00FF`, not a PYLON module-count reply. That initial selector range
did not reveal all four packs. Subsequent testing with the PACE poller verified
four packs at destination `00`, INFO **02-05**, using version `20`; see
[four-pack discovery](#four-pack-discovery-and-bus-specific-numbering).
This does not establish PYLON payload scaling or all-module reply support.

The individual replies resemble the previously observed PACE payloads.
The PYLON decoder displayed roughly 2.1-2.2 A and 7.1/10 Ah, but those units
are **not verified for this firmware**; the PACE interpretation differs by a
factor of ten for current and capacity. Neither a version `20` header nor
protocol success proves PYLON payload semantics. Do not rely on the displayed
current, absolute capacity or interpreted status meanings without an independent
comparison to the battery display or a documented firmware protocol.

Unlike the PACE decoder, this tool uses PYLON scaling: current in 0.1 A,
capacity in mAh, voltage in mV and temperature in 0.1 K (2731 offset).
It supports legacy 16-bit and extended 24-bit capacities and all-module replies.
All-module results are labelled by **reply order, not physical battery address**.
Warning/alarm bytes are shown as raw codes/registers without guessing vendor
bit meanings. Unknown/truncated layouts and vendor extensions are reported with
their payload hex rather than decoded using PACE assumptions. A checksum-valid
success frame is not necessarily a supported measurement response.

Polling repeats unless `--once` is supplied. Defaults are a 2000 ms timeout and
250 ms gap; `--timeout` and `--delay` accept 1-60000 ms. Only one request is
outstanding. Replies have no command identifier, so very late responses can be
ambiguous; increase the timeout if needed. `--raw` shows direction-labelled
ASCII chunks with escaped CR/LF, not packet boundaries. The bridge's UART
baud/parity and direction control must match the battery; the tool does not
reconfigure them. No control/write commands are sent.

`--once` exits `1` for timeouts, rejections or unsupported payloads, otherwise
`0`. Connection failures/disconnects exit `1`, Ctrl-C exits `130`; no automatic
reconnect. Errors go to stderr. Tests use a simulated bridge, not real batteries:

```sh
node --test tools/rs485-pylon-poll.test.js tools/rs485-poll.test.js tools/rs485-decoder.test.js
```

### Node.js Modbus RTU poller

[rs485-modbus-poll.js](tools/rs485-modbus-poll.js) is a separate, read-only
Modbus alternative to the ASCII PACE poller. It sends binary **Modbus RTU**
frames, including CRC-16, through the existing transparent TCP bridge.
It is **not Modbus TCP**: it does not use an MBAP header or require port 502.
Node.js 18 or newer is required; no npm dependencies or firmware changes are
needed for the bridge.

**Modbus slave address 1 has been verified in this SG48100 installation after
changing battery 1's inverter protocol from `PYLON` to `PACE`.** It returned
checksum-valid measurements, status, sixteen cell voltages and temperatures
using this register map. After that change, ASCII PACE requests to addresses
1-4 stopped receiving replies; Modbus addresses 2-4 also did not reply.
Reading every physical pack through this port remains unresolved; a response
from one Modbus slave does not establish access to the other packs.

The battery must support and be configured for the compatible Modbus inverter
protocol/register map (`PACE_MODBUS` in the upstream project's instructions).
The protocol menu labels and behavior may vary by firmware. Do not change
the battery's protocol without checking compatibility with its inverter.
Use only as the sole polling master, with other pollers stopped.

```sh
node tools/rs485-modbus-poll.js recliner.local 1234 --once --raw
node tools/rs485-modbus-poll.js recliner.local 1234
node tools/rs485-modbus-poll.js recliner.local --addresses 1 --timeout 3000 --once --raw
node tools/rs485-modbus-poll.js --help
```

By default, the tool polls slaves 1-4 sequentially, using function **03**
(read holding registers), in three groups per slave:

| Registers (zero-based) | Decoded values |
| --- | --- |
| 0-7 | Signed current (0.01 A), pack voltage (0.01 V), reported SOC/SOH, remaining/full/design capacity (0.01 Ah), cycles; calculated power |
| 9-12 | Warning, protection, status/fault and balancing registers, displayed as raw bitmasks |
| 15-36 | Sixteen cell voltages (mV), four battery temperatures plus MOSFET/environment temperatures (signed 0.1 C) |

This map follows [syssi/esphome-pace-bms](https://github.com/syssi/esphome-pace-bms/blob/main/esp32-example.yaml).
Other cell counts, register maps and unavailable-value sentinels are not
auto-detected or guessed. Unused/invalid registers may return unusual values or
a Modbus exception; inspect raw output and the exact battery documentation.
Reserved gaps at 8 and 13-14 are not requested.

`--addresses` accepts unique decimal values from **1 to 247**. Unlike the ASCII
protocol, Modbus address **0 is broadcast** and cannot be polled; `FF` is not an
all-pack selector. The tool never sends broadcasts or write functions.
The timeout defaults to 2000 ms (`--timeout`, 1-60000 ms), followed by a 250 ms
gap (`--delay`, 5-60000 ms) after each reply/timeout. The minimum gap accommodates
RTU framing at 9600 baud; use a larger delay for slower UART rates.
The UART baud/parity are configured on the ESP32, not by this TCP client.

TCP fragments are reassembled; CRCs, slave addresses and response byte counts
are checked. Local request echoes are ignored explicitly. Corrupt/unframed bytes,
incomplete replies and Modbus exceptions are reported to stderr. Only one
request is outstanding. RTU has no transaction ID or returned starting-register
address, so sufficiently late replies may still be ambiguous; increase the
timeout if needed. No automatic reconnect is attempted.

`--raw` adds TX/RX hexadecimal displays; TCP chunks are not frame boundaries.
`--once` exits `1` for any missing reply or Modbus exception, otherwise `0`.
Protocol success alone does not verify the register map or plausibility of the
values. Connection failure/remote disconnect exits `1`; Ctrl-C exits `130`.

Run the Modbus tests with:

```sh
node --test tools/rs485-modbus-poll.test.js
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

Defaults are `sunpower.local:1234`. Passive mode sends no bytes and relies on
existing ASCII polling traffic. Before connecting, optionally enable **active
polling**, select **Modbus RTU** or **ASCII PACE**, and enter addresses such as
`1,2,3,4`. Controls lock until disconnected. Only read requests are sent; do not
run another polling master on the same RS485 bus.

In the [installation described above](#equipment-and-rs485-polling), passive ASCII
initially exposed packs 2-4. After battery 1's inverter setting changed to PACE,
Modbus slave 1 responded while 2-4 timed out; ASCII became silent. Selecting
four addresses does not guarantee four responding physical batteries. The
dashboard labels reported versus calculated SOC, marks stale readings and
preserves unknown vendor fields without guessing their meanings.
