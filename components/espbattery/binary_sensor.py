import esphome.codegen as cg
import esphome.config_validation as cv
from esphome.components import binary_sensor
from esphome.const import DEVICE_CLASS_PROBLEM, ENTITY_CATEGORY_DIAGNOSTIC

from . import ESPBATTERY_ENTITY_SCHEMA, pylon_parent, validate_can_entity

DEPENDENCIES = ["espbattery"]

SENSOR_TYPES = {
    "charging_allowed": binary_sensor.binary_sensor_schema(),
    "discharging_allowed": binary_sensor.binary_sensor_schema(),
    "protection_active": binary_sensor.binary_sensor_schema(
        device_class=DEVICE_CLASS_PROBLEM, entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    ),
    "warning_active": binary_sensor.binary_sensor_schema(
        device_class=DEVICE_CLASS_PROBLEM, entity_category=ENTITY_CATEGORY_DIAGNOSTIC,
    ),
}

CONFIG_SCHEMA = cv.All(
    cv.Schema({cv.Optional(key): schema for key, schema in SENSOR_TYPES.items()})
    .extend(ESPBATTERY_ENTITY_SCHEMA),
    cv.has_at_least_one_key(*SENSOR_TYPES),
)
FINAL_VALIDATE_SCHEMA = validate_can_entity


async def to_code(config):
    parent = await pylon_parent(config)
    cg.add_define("USE_ESPBATTERY_PYLON_BINARY_SENSOR")
    for key in SENSOR_TYPES:
        if key in config:
            entity = await binary_sensor.new_binary_sensor(config[key])
            cg.add(getattr(parent, f"set_{key}_binary_sensor")(entity))
