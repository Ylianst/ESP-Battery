import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.components import sensor
from esphome.const import (
    CONF_FILTERS,
    CONF_FORCE_UPDATE,
    DEVICE_CLASS_BATTERY,
    DEVICE_CLASS_CURRENT,
    DEVICE_CLASS_POWER,
    DEVICE_CLASS_TEMPERATURE,
    DEVICE_CLASS_VOLTAGE,
    ENTITY_CATEGORY_DIAGNOSTIC,
    STATE_CLASS_MEASUREMENT,
    UNIT_AMPERE,
    UNIT_CELSIUS,
    UNIT_PERCENT,
    UNIT_VOLT,
    UNIT_WATT,
)

from . import ESPBATTERY_ENTITY_SCHEMA, pylon_parent, validate_can_entity

DEPENDENCIES = ["espbattery"]

def append_change_filter(config):
    if not config[CONF_FORCE_UPDATE]:
        # Keep raw samples flowing through timeout/averaging filters before deduplication.
        config[CONF_FILTERS] = config.get(CONF_FILTERS, []) + sensor.validate_filters([{
            "lambda": cv.Lambda(
                "static esphome::espbattery::ChangeDetector<float> changes;\n"
                "if (!changes.changed(x)) return {};\n"
                "return x;"
            ),
        }])
    return config

SENSOR_TYPES = {
    "voltage": sensor.sensor_schema(
        unit_of_measurement=UNIT_VOLT, accuracy_decimals=2,
        device_class=DEVICE_CLASS_VOLTAGE, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "current": sensor.sensor_schema(
        unit_of_measurement=UNIT_AMPERE, accuracy_decimals=1,
        device_class=DEVICE_CLASS_CURRENT, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "power": sensor.sensor_schema(
        unit_of_measurement=UNIT_WATT, accuracy_decimals=1,
        device_class=DEVICE_CLASS_POWER, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "temperature": sensor.sensor_schema(
        unit_of_measurement=UNIT_CELSIUS, accuracy_decimals=1,
        device_class=DEVICE_CLASS_TEMPERATURE, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "state_of_charge": sensor.sensor_schema(
        unit_of_measurement=UNIT_PERCENT, accuracy_decimals=0,
        device_class=DEVICE_CLASS_BATTERY, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "state_of_health": sensor.sensor_schema(
        unit_of_measurement=UNIT_PERCENT, accuracy_decimals=0,
        device_class=DEVICE_CLASS_BATTERY, state_class=STATE_CLASS_MEASUREMENT,
        entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    ),
    "charge_voltage_limit": sensor.sensor_schema(
        unit_of_measurement=UNIT_VOLT, accuracy_decimals=1,
        device_class=DEVICE_CLASS_VOLTAGE, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "charge_current_limit": sensor.sensor_schema(
        unit_of_measurement=UNIT_AMPERE, accuracy_decimals=1,
        device_class=DEVICE_CLASS_CURRENT, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "discharge_current_limit": sensor.sensor_schema(
        unit_of_measurement=UNIT_AMPERE, accuracy_decimals=1,
        device_class=DEVICE_CLASS_CURRENT, state_class=STATE_CLASS_MEASUREMENT,
    ),
    "module_count": sensor.sensor_schema(
        accuracy_decimals=0, icon="mdi:battery-multiple",
        state_class=STATE_CLASS_MEASUREMENT,
        entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    ),
    "protection_flags": sensor.sensor_schema(
        accuracy_decimals=0, entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    ),
    "warning_flags": sensor.sensor_schema(
        accuracy_decimals=0, entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    ),
}

CONFIG_SCHEMA = cv.All(
    cv.Schema({
        cv.Optional(key): cv.All(schema, append_change_filter)
        for key, schema in SENSOR_TYPES.items()
    })
    .extend(ESPBATTERY_ENTITY_SCHEMA),
    cv.has_at_least_one_key(*SENSOR_TYPES),
)
FINAL_VALIDATE_SCHEMA = validate_can_entity


async def to_code(config):
    parent = await pylon_parent(config)
    cg.add_define("USE_ESPBATTERY_PYLON_SENSOR")
    for key in SENSOR_TYPES:
        if key in config:
            entity = await sensor.new_sensor(config[key])
            cg.add(getattr(parent, f"set_{key}_sensor")(entity))
