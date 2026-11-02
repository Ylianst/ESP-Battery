# Supported Devices

Any ESP32 with an RS485 transceiver should work with ESP-Battery. The devices below are known to work well with the same RS485 forwarding code (originally used in the [ESP-IQ2020](https://github.com/Ylianst/ESP-IQ2020) project). Pick the one that best fits your setup and use the matching `uart` settings in your ESPHome configuration.

All examples use `baud_rate: 9600`. Check your battery's documentation (or the BMS / inverter settings) to confirm the RS485 baud rate used by your SunGold SG48100 batteries, and adjust if needed.

Unlike a hot tub controller, the battery RS485 port does not provide power to the ESP32. You will need to power the device separately, for example over USB-C or using a DC-DC converter from a suitable supply.

## Wiring to the battery

The SG48100 exposes its RS485 bus on an RJ45 connector. Check your battery manual for the exact pinout and connect the RS485 **A** (sometimes labeled `+` or `D+`) and **B** (sometimes labeled `-` or `D-`) lines to the matching A/B terminals on your RS485 module. If you see no data, or only garbage, try swapping A and B. Connect ground too if your RS485 module and battery both have a GND terminal.

### SG48100 battery-to-battery RS485 pinout

The confirmed pinout for the **parallel (battery-to-battery) RS485 port** is below. Wire colors assume an RJ45 cable terminated using **T568B**; verify the connector pin numbers and cable wiring before connecting.

| RJ45 pin | Wire color (T568B) | Signal |
| --- | --- | --- |
| 1 | White/orange | B |
| 2 | Orange | A |
| 3 | White/green | Ground (GND) |
| 4 | Blue | Float (NC) |
| 5 | White/blue | Float (NC) |
| 6 | Green | Ground (GND) |
| 7 | White/brown | A |
| 8 | Brown | B |

**Pins 3 and 6 are ground; pins 4 and 5 must be left unconnected, not grounded.** Connect A to the transceiver's A terminal, B to B, and GND to GND where provided. This matches the parallel communication port definitions in the [battery manual, PDF page 14](SG48100.md#pdf-page-14). Do not apply this pinout to the CAN port or assume other battery models use it.

Most battery BMS RS485 ports need a master (inverter, PC or master battery) to send requests before they reply. In the [observed four-battery installation](../README.md#equipment-and-rs485-polling), setting one SG48100 to address 1 starts battery-to-battery polling; leaving the DIP-switch addresses at their default of 0 produced no traffic. Battery 1 polls batteries 2-4 but not itself, so passive monitoring on that bus only receives data for batteries 2-4.

The ESP-Battery component forwards any bytes you send over TCP to the RS485 bus, so you can send requests from a PC to see how the battery responds. Avoid introducing a second polling master on a bus already being polled by a battery or inverter.

# M5Stack ATOM Lite ESP32 IoT Development Kit

This is the recommended device for most people. It's very small and is perfect for this usage. The parts you need are:

- [ATOM Lite ESP32 IoT Development Kit](https://shop.m5stack.com/products/atom-lite-esp32-development-kit)
- [ATOM Tail485 - RS485 Converter for ATOM](https://shop.m5stack.com/products/atom-tail485)

Once assembled with the wires, the device looks like this:

![image](https://github.com/Ylianst/ESP-IQ2020/assets/1319013/07834e9c-5ef3-4304-add4-3f378a2ccf0a)

In the ESPHome configuration, you will need to use the following settings. Note the GPIO pin numbers.

```yaml
# M5Stack ATOM Lite + ATOM Tail485
uart:
  id: BatteryConnection
  tx_pin: GPIO26
  rx_pin: GPIO32
  baud_rate: 9600

espbattery:
  uart_id: BatteryConnection
  port: 1234
```

# M5StickC PLUS ESP32-PICO Mini IoT Development Kit

This device works well, but is more expensive and has a display which is not used by this project. Since it has a built-in battery and USB-C port, it's convenient for capturing traffic on the bench. Here are the parts:

- [M5StickC PLUS ESP32-PICO Mini IoT Development Kit](https://shop.m5stack.com/products/m5stickc-plus-esp32-pico-mini-iot-development-kit)
- [M5StickC RS485 HAT AOZ1282CI](https://shop.m5stack.com/products/m5stickc-rs485-hat-aoz1282ci)

Once assembled with the wires, the device looks like this:

![image](https://github.com/Ylianst/ESP-IQ2020/assets/1319013/f02fd62a-e8ac-497d-a5d7-e9208d35bb3d)

In the ESPHome configuration, you will need to use the following settings. Note the GPIO pin numbers. The TX Pin is on GPIO 0.

```yaml
# M5StickC PLUS ESP32-PICO Mini + RS485 HAT
uart:
  id: BatteryConnection
  tx_pin: GPIO0
  rx_pin: GPIO26
  baud_rate: 9600

espbattery:
  uart_id: BatteryConnection
  port: 1234
```

# M5Stack ATOM Lite ESP32 IoT Development Kit (2)

Same device as the first option, but a different RS485 interface.

- [ATOM Lite ESP32 IoT Development Kit](https://shop.m5stack.com/products/atom-lite-esp32-development-kit)
- [ATOMIC RS485 Base](https://shop.m5stack.com/products/atomic-rs485-base)

Once assembled, the device looks like this.

![334186423-5f81d5d2-d047-4ceb-b9f0-aef23833bf64](https://github.com/Ylianst/ESP-IQ2020/assets/1319013/5cef14f5-2575-4ac1-9393-596dd468fda1)

In the ESPHome configuration, you will need to use the following settings. Note the GPIO pin numbers.

```yaml
# M5Stack ATOM Lite + ATOMIC RS485 Base
uart:
  id: BatteryConnection
  tx_pin: GPIO19
  rx_pin: GPIO22
  baud_rate: 9600

espbattery:
  uart_id: BatteryConnection
  port: 1234
```

# Industrial ESP32-S3 Control Board

<img width="800" height="544" alt="image" src="https://github.com/user-attachments/assets/b47dbfeb-c8c4-4d53-8268-9baee3f004d3" />

Another option is to use the following device:

- [Amazon US Link](https://www.amazon.com/Industrial-Communication-Interfaces-Bluetooth-Protection/dp/B0FN7VZ8H7)
- [Amazon UK Link](https://www.amazon.co.uk/dp/B0FN4LWLH9)
- [Device Wiki](https://www.waveshare.com/wiki/ESP32-S3-RS485-CAN)

It's not as compact as the devices above, but may be more easily available with fast overnight delivery. It also has a wide-range DC input (see the device wiki), which can make powering it easier. Connect the battery RS485 A/B lines to the board's RS485 A/B terminals.

In the ESPHome configuration, you will need to use the following settings. Note the GPIO pin numbers and the `flow_control_pin`.

```yaml
uart:
  id: BatteryConnection
  tx_pin: GPIO17
  rx_pin: GPIO18
  baud_rate: 9600
  parity: NONE
  stop_bits: 1
  rx_buffer_size: 1024

espbattery:
  uart_id: BatteryConnection
  flow_control_pin: GPIO21
  port: 1234
```

# ESP32 + RS485MAX

This setup is not as nice as the ones above, and you will need to do extra work to power the ESP32 and RS485MAX modules.

Using the RS485MAX module requires an extra GPIO pin to tell the module what is the current traffic direction (send or receive). In order to support this module, this integration supports an extra `flow_control_pin`. The device looks like this and has the following connectors:

![RS485MAX](https://github.com/Ylianst/ESP-IQ2020/assets/1319013/f27715c6-e463-4dc1-b3ed-ff575076ff0c)

![max485](https://github.com/Ylianst/ESP-IQ2020/assets/1319013/20253758-e7fa-41a9-ab1b-d55aff3e9bba)

Here is a suggested wiring. Some of these modules are 3v instead of 5v and so, take care to wire correctly.

![rs485_esp32_wireing](https://github.com/Ylianst/ESP-IQ2020/assets/1319013/8822b497-0453-4daf-bf64-abf90327809f)

In this case, the configuration should look like:

```yaml
uart:
  id: BatteryConnection
  tx_pin: GPIO19
  rx_pin: GPIO18
  baud_rate: 9600

espbattery:
  uart_id: BatteryConnection
  flow_control_pin: GPIO4
  port: 1234
```

The `flow_control_pin` is raised while transmitting on the RS485 bus and lowered when receiving. If you have a setup like this that works, please let me know so I can update this section.
