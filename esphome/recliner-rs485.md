substitutions:
  device_name: recliner
  device_comment: "WaveShare ESP32-S3-POE-ETH-8DI-8DO Device"
  friendly_name: "Recliner"

esphome:
  name: ${device_name}
  friendly_name: ${friendly_name}
  min_version: 2025.5.0
  comment: ${device_comment}
  name_add_mac_suffix: false
  on_boot:
    then:
      - pcf85063.read_time:
          id: pcf85063_time

# ==========================================================
# Board Configuration
# ==========================================================
esp32:
  variant: esp32s3
  flash_size: 16MB
  framework:
    type: esp-idf

psram:
  mode: octal
  speed: 80MHz

# ==========================================================
# Core Configuration
# ==========================================================
logger:
  baud_rate: 0
  level: ERROR

api:
  encryption:
    key: !secret recliner_api_key

ota:
  - platform: esphome

captive_portal:

# ==========================================================
# Network Configuration
# ==========================================================
wifi:
  ssid: !secret wifi_ssid
  password: !secret wifi_password
  ap:
    ssid: Recliner Fallback Hotspot
    password: !secret recliner_ap_password

# ==========================================================
# RS485 and CAN to TCP Bridges
# ==========================================================
external_components:
  - source: github://ylianst/esp-battery
    components: [espbattery]

uart:
  id: BatteryConnection
  tx_pin: GPIO17
  rx_pin: GPIO18
  baud_rate: 9600
  data_bits: 8
  parity: NONE
  stop_bits: 1

# Waveshare ESP32-S3-POE-ETH-8DI-8DO CAN transceiver pins.
# Match bit_rate to the connected CAN bus.
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

# ==========================================================
# PYLON CAN Battery Bank Telemetry
# ==========================================================
sensor:
  - platform: espbattery
    espbattery_id: can_bridge
    voltage:
      name: "Battery Bank Voltage"
    current:
      name: "Battery Bank Current"
    power:
      name: "Battery Bank Power"
    temperature:
      name: "Battery Bank Temperature"
    state_of_charge:
      name: "Battery Bank State of Charge"
    state_of_health:
      name: "Battery Bank State of Health"
    charge_voltage_limit:
      name: "Battery Bank Charge Voltage Limit"
    charge_current_limit:
      name: "Battery Bank Charge Current Limit"
    discharge_current_limit:
      name: "Battery Bank Discharge Current Limit"
    module_count:
      name: "Battery Bank Module Count"
    protection_flags:
      name: "Battery Bank Protection Flags"
      disabled_by_default: true
    warning_flags:
      name: "Battery Bank Warning Flags"
      disabled_by_default: true

text_sensor:
  - platform: espbattery
    espbattery_id: can_bridge
    manufacturer:
      name: "Battery Bank Manufacturer"

# ==========================================================
# Hardware Buses
# ==========================================================
i2c:
  sda: GPIO42
  scl: GPIO41
  frequency: 100kHz
  id: i2cbus
  scan: false

pca9554:
  - id: tca9554_hub
    address: 0x20

# ==========================================================
# Accessories
# ==========================================================
time:
  - platform: pcf85063
    id: pcf85063_time

output:
  - platform: ledc
    id: buzzer
    pin:
      number: GPIO46
      ignore_strapping_warning: true

rtttl:
  id: rtttl_buzzer
  output: buzzer
  gain: 30%

light:
  - platform: esp32_rmt_led_strip
    id: rgb_led
    name: "RGB LED"
    chipset: WS2812
    rgb_order: RGB
    pin: GPIO38
    num_leds: 1

# ==========================================================
# CAN Status and Digital Inputs
# ==========================================================
binary_sensor:
  - platform: espbattery
    espbattery_id: can_bridge
    charging_allowed:
      name: "Battery Bank Charging Allowed"
    discharging_allowed:
      name: "Battery Bank Discharging Allowed"
    protection_active:
      name: "Battery Bank Protection Active"
    warning_active:
      name: "Battery Bank Warning Active"

  - platform: gpio
    name: "Boot Button"
    pin:
      number: GPIO0
      ignore_strapping_warning: true
      mode:
        input: true
      inverted: true
    disabled_by_default: true

  - platform: gpio
    id: di1
    name: "DI1"
    pin:
      number: GPIO4
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di2
    name: "DI2"
    pin:
      number: GPIO5
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di3
    name: "DI3"
    pin:
      number: GPIO6
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di4
    name: "DI4"
    pin:
      number: GPIO7
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di5
    name: "DI5"
    pin:
      number: GPIO8
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di6
    name: "DI6"
    pin:
      number: GPIO9
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di7
    name: "DI7"
    pin:
      number: GPIO10
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

  - platform: gpio
    id: di8
    name: "DI8"
    pin:
      number: GPIO11
      mode: INPUT_PULLUP
      inverted: true
    filters:
      - delayed_on_off: 10ms

# ==========================================================
# Digital Outputs
# ==========================================================
switch:
  - platform: gpio
    name: "DO1"
    id: do1
    pin:
      pca9554: tca9554_hub
      number: 0
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO2"
    id: do2
    pin:
      pca9554: tca9554_hub
      number: 1
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO3"
    id: do3
    pin:
      pca9554: tca9554_hub
      number: 2
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO4"
    id: do4
    pin:
      pca9554: tca9554_hub
      number: 3
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO5"
    id: do5
    pin:
      pca9554: tca9554_hub
      number: 4
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO6"
    id: do6
    pin:
      pca9554: tca9554_hub
      number: 5
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO7"
    id: do7
    pin:
      pca9554: tca9554_hub
      number: 6
      mode:
        output: true
    inverted: true

  - platform: gpio
    name: "DO8"
    id: do8
    pin:
      pca9554: tca9554_hub
      number: 7
      mode:
        output: true
    inverted: true